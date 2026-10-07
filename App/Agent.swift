import Foundation
import Security
import UIKit

// MARK: - API key (stored only in this iPhone's Keychain)

enum KeyStore {
    private static let service = "PhoneRunnerProbe.gemini"

    static func save(_ value: String) -> Bool {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Brain (vision model). Replaceable: only `decide` is used by the loop.

struct GeminiBrain {
    let apiKey: String
    let model: String

    static let system = """
    あなたはiPhoneを操作するAIエージェントです。毎回、iPhoneの現在の画面画像と、ユーザーの指示・これまでの行動・経験メモが与えられます。
    指示を達成するための「次の1手」だけを決め、JSONだけを返してください。

    座標: 画面の左上が(0,0)、右下が(1000,1000)。xは横、yは縦。画像の縦横比に関係なくこの範囲で答えます。
    画像全体を基準に、x=画像内の横位置/画像幅×1000、y=画像内の縦位置/画像高さ×1000で指定します。ピクセル数やiOSのポイント値をそのまま返さないでください。
    出力形式:
    {"action":"tap","x":500,"y":500,"x2":0,"y2":0,"seconds":0,"observation":"画面の状況（短く）","thought":"判断理由（短く）","memo":""}
    actionはtap・swipe・wait・doneのいずれか1つ。x,y,x2,y2,secondsは必須で、その操作で使わない数値は0にします。説明は各1文で簡潔にしてください。
    - tap: x,yをタップ。ボタンや文字の中心を狙う。
    - swipe: (x,y)から(x2,y2)へスワイプ。
    - wait: 読み込み中・演出中などで待つ。secondsに秒数（1〜10）。
    - done: 指示を達成した、または続行できない。thoughtに理由。
    - memo: このアプリについて次回以降も役立つ気づきがあれば1行で（例: 「出撃ボタンは画面下中央」）。なければ空。
    ルール:
    - 課金・購入・有料通貨の使用、アカウントや設定の変更、外部へのリンクは絶対に押さない。その画面になったらdone。
    - 確信がないときは押さずにwaitを選ぶ。同じ操作を繰り返して画面が変わらないときは別の方法を考える。
    - 直前の操作の結果を、今の画面で確認してから次を決める。
    - WDA受理は画面が進んだ証拠ではありません。進まない場合、ボタンの背景を含む領域を見直し、実際に押せる中心を再確認してください。
    """

    func decide(instruction: String, step: Int, maxSteps: Int, history: [String], memos: [String], jpeg: Data) async throws -> (Decision, Int?) {
        var text = "指示: \(instruction)\nステップ: \(step)/\(maxSteps)\n"
        text += "直近の行動:\n" + (history.isEmpty ? "（なし）\n" : history.suffix(10).joined(separator: "\n") + "\n")
        text += "経験メモ:\n" + (memos.isEmpty ? "（なし）\n" : memos.suffix(30).map { "- \($0)" }.joined(separator: "\n") + "\n")
        text += "今の画面を見て、次の1手をJSONで答えてください。"

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": Self.system]]],
            "contents": [[
                "role": "user",
                "parts": [
                    ["text": text],
                    ["inline_data": ["mime_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                ],
            ]],
            "generationConfig": AgentResponse.generationConfig,
        ]
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(trimmed):generateContent") else {
            throw BrainError.format("モデル名")
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if code == 429 { throw BrainError.rateLimited }
        guard code == 200, let json else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "-"
            throw BrainError.http(code, String(message.prefix(160)))
        }
        return try AgentResponse.decode(json)
    }
}

// MARK: - Agent loop: look -> decide -> act -> look again

@MainActor
final class AgentRunner: ObservableObject {
    @Published var log: [String] = []
    @Published var active = false
    @Published var phaseText = ""
    @Published var tapPreview: UIImage?
    /// Set by the view. While this app is in front, frames show this app, so the loop pauses.
    var probeInFront = true
    private var stopRequested = false
    private var task: Task<Void, Never>?

    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var memoryURL: URL { documents.appendingPathComponent("agent_memory.txt") }
    private var logURL: URL { documents.appendingPathComponent("agent_log.txt") }

    var memos: [String] {
        ((try? String(contentsOf: memoryURL, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    func clearMemos() {
        try? FileManager.default.removeItem(at: memoryURL)
        add("経験メモを消去しました")
    }

    func stop() {
        stopRequested = true
        phaseText = "停止要求"
    }

    func start(instruction: String, brain: GeminiBrain, maxSteps: Int, interval: Double, execute: Bool) {
        guard task == nil else { return }
        stopRequested = false
        active = true
        log = []
        tapPreview = nil
        add("開始: \(execute ? "実行モード" : "観察のみ（操作しない）") / 最大\(maxSteps)手 / \(brain.model)")
        add("指示: \(instruction)")
        task = Task { [weak self] in
            await self?.loop(instruction: instruction, brain: brain, maxSteps: maxSteps, interval: interval, execute: execute)
            self?.active = false
            self?.task = nil
        }
    }

    private func add(_ line: String) {
        let stamped = "[\(Date().formatted(date: .omitted, time: .standard))] \(line)"
        log.append(stamped)
        if log.count > 300 { log.removeFirst(log.count - 300) }
        if let data = (stamped + "\n").data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    private func latestFrame() -> Data? {
        var length = 0
        guard let pointer = agent_copy_frame(&length), length > 0 else { return nil }
        let data = Data(bytes: pointer, count: length)
        agent_free_frame(pointer, length)
        return data
    }

    private func command(_ object: [String: Any]) async -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return "error: JSON作成失敗" }
        return await Task.detached {
            json.withCString { pointer -> String in
                guard let reply = agent_command(pointer) else { return "error: 応答なし" }
                defer { probe_free_string(reply) }
                return String(cString: reply)
            }
        }.value
    }

    private func loop(instruction: String, brain: GeminiBrain, maxSteps: Int, interval: Double, execute: Bool) async {
        phaseText = "WDAとゲーム画面の準備待ち"
        var waited = 0.0
        while !agent_ready() {
            if stopRequested || (!probe_running() && waited > 5) { add("準備できずに終了"); return }
            await pause(1); waited += 1
            if waited > 180 { add("準備が180秒以内に完了しませんでした"); return }
        }
        let stepsDir = documents.appendingPathComponent("steps")
        try? FileManager.default.createDirectory(at: stepsDir, withIntermediateDirectories: true)
        var history: [String] = []
        var step = 0
        var totalTokens = 0
        var lastCall = Date.distantPast
        var lastTap: CGPoint?
        var repeatedTaps = 0
        var rateLimitRetries = 0
        var consecutiveFailures = 0

        while step < maxSteps && !stopRequested && agent_ready() {
            if probeInFront {
                phaseText = "このアプリが前面のため一時停止中（対象アプリに切り替えると再開）"
                await pause(1)
                continue
            }
            // Respect the minimum interval between AI calls (free tier limits).
            let gap = interval - Date().timeIntervalSince(lastCall)
            if gap > 0 { await pause(gap) }
            await pause(0.8) // let the last action settle
            if stopRequested { break }
            if probeInFront { continue }
            // Require a newly delivered frame, rather than reusing a stalled stream.
            let previousSequence = agent_frame_seq()
            var frameWaits = 0
            while agent_frame_seq() == previousSequence && frameWaits < 25 && !stopRequested {
                await pause(0.2)
                frameWaits += 1
            }
            if stopRequested { break }
            if probeInFront { continue }
            guard agent_frame_seq() != previousSequence,
                  let jpeg = latestFrame(), let frame = UIImage(data: jpeg), let pixels = frame.cgImage else {
                add("新しい画面を取得できないため停止しました。接続を確認してください")
                break
            }
            step += 1
            phaseText = "\(step)手目: AIが判断中"
            lastCall = Date()
            let decision: Decision
            do {
                let (d, tokens) = try await brain.decide(instruction: instruction, step: step, maxSteps: maxSteps,
                                                        history: history, memos: memos, jpeg: jpeg)
                decision = d
                totalTokens += tokens ?? 0
            } catch BrainError.rateLimited {
                rateLimitRetries += 1
                if rateLimitRetries > 2 { add("利用上限が続くため停止しました。モデルと利用枠を確認してください"); break }
                add("\(step)手目: 利用上限（429）。60秒待って再試行")
                step -= 1
                await pause(60)
                continue
            } catch {
                if let failure = error as? BrainError, case let .response(_, tokens) = failure {
                    totalTokens += tokens ?? 0
                }
                consecutiveFailures += 1
                add("\(step)手目: AI判断失敗 \(error.localizedDescription)")
                if consecutiveFailures >= 3 { add("3回連続で失敗したため終了"); break }
                await pause(5)
                continue
            }
            rateLimitRetries = 0
            consecutiveFailures = 0
            if stopRequested { break }
            if probeInFront {
                add("アプリが前面に戻ったため、古い画面に対する判断を破棄しました")
                continue
            }
            let values = decision.action == "swipe" ? [decision.x, decision.y, decision.x2, decision.y2] :
                (decision.action == "tap" ? [decision.x, decision.y] : [])
            guard values.allSatisfy({ value in
                guard let value else { return false }
                return value.isFinite && (0...1000).contains(value)
            }), decision.seconds?.isFinite != false else {
                add("AIの座標または待機秒数が不正なため停止しました")
                break
            }
            try? jpeg.write(to: stepsDir.appendingPathComponent(String(format: "step_%03d.jpg", step)))
            let coords: String = {
                switch decision.action {
                case "tap": return "(\(Int(decision.x ?? -1)),\(Int(decision.y ?? -1)))"
                case "swipe": return "(\(Int(decision.x ?? -1)),\(Int(decision.y ?? -1)))→(\(Int(decision.x2 ?? -1)),\(Int(decision.y2 ?? -1)))"
                case "wait": return "\(decision.seconds ?? 2)秒"
                default: return ""
                }
            }()
            add("\(step)手目 \(decision.action)\(coords)\n  見: \(decision.observation ?? "-")\n  考: \(decision.thought ?? "-")")
            if decision.action == "tap", let x = decision.x, let y = decision.y {
                let size = CGSize(width: CGFloat(pixels.width), height: CGFloat(pixels.height))
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let preview = UIGraphicsImageRenderer(size: size, format: format).image { context in
                    frame.draw(in: CGRect(origin: .zero, size: size))
                    let center = CGPoint(x: x / 1000 * size.width, y: y / 1000 * size.height)
                    let radius = max(12, size.width * 0.025)
                    context.cgContext.setStrokeColor(UIColor.red.cgColor)
                    context.cgContext.setLineWidth(max(3, size.width * 0.005))
                    context.cgContext.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                                              width: radius * 2, height: radius * 2))
                }
                tapPreview = preview
                try? preview.jpegData(compressionQuality: 0.85)?.write(to: stepsDir.appendingPathComponent(String(format: "step_%03d_tap.jpg", step)))
                if execute {
                    let point = CGPoint(x: x, y: y)
                    if let previous = lastTap, abs(previous.x - point.x) <= 15, abs(previous.y - point.y) <= 15 {
                        repeatedTaps += 1
                    } else {
                        lastTap = point
                        repeatedTaps = 1
                    }
                    if repeatedTaps > 3 {
                        add("同じ付近へのタップが3回続いたため、4回目は送らず停止しました。赤丸の位置と実際のボタンを確認してください（画面変化の自動判定ではありません）")
                        break
                    }
                }
            }

            if let memo = decision.memo?.trimmingCharacters(in: .whitespacesAndNewlines), !memo.isEmpty,
               !memos.contains(memo) {
                let all = (memos + [memo]).suffix(50).joined(separator: "\n") + "\n"
                try? all.write(to: memoryURL, atomically: true, encoding: .utf8)
                add("  メモ追加: \(memo)")
            }

            var result = "見送り（観察のみ）"
            switch decision.action {
            case "tap" where execute:
                result = await command(["type": "tap", "x": decision.x ?? -1, "y": decision.y ?? -1,
                                        "image_width": pixels.width, "image_height": pixels.height])
            case "swipe" where execute:
                result = await command(["type": "swipe", "x": decision.x ?? -1, "y": decision.y ?? -1,
                                        "x2": decision.x2 ?? -1, "y2": decision.y2 ?? -1, "ms": 400,
                                        "image_width": pixels.width, "image_height": pixels.height])
                lastTap = nil
                repeatedTaps = 0
            case "wait":
                result = "待機"
                await pause(min(max(decision.seconds ?? 2, 1), 10))
            case "done":
                add("完了と判断: \(decision.thought ?? "-")")
                history.append("\(step). done")
                stopRequested = true
                continue
            case "tap", "swipe":
                break
            default:
                result = "未対応の行動"
            }
            add("  結果: \(result)")
            if result.hasPrefix("error") { add("操作エラーのため停止しました"); break }
            history.append("\(step). \(decision.action)\(coords) → \(result)｜\(decision.thought ?? "")")
        }
        add("終了: \(step)手 / API報告トークン合計 \(totalTokens)（取得できた分・形式不正を含む）")
        phaseText = "終了"
    }
}
