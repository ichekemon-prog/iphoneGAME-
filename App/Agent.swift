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
    var detail: ImageDetail = .medium
    /// Seconds to wait for one answer. Usual answers take a few seconds; past this
    /// the server is congested and a fresh retry is faster than waiting longer.
    static let timeout: TimeInterval = 30
    /// Models that rejected the thinking setting (older or renamed models).
    nonisolated(unsafe) static var noThinking = Set<String>()

    static let system = """
    あなたはiPhoneを操作するAIエージェントです。毎回、iPhoneの現在の画面画像と、ユーザーの指示・これまでの行動・経験メモが与えられます。
    指示を達成するための「次の1手」だけを決め、JSONだけを返してください。

    座標: 画面の左上が(0,0)、右下が(1000,1000)。xは横、yは縦。画像の縦横比に関係なくこの範囲で答えます。
    画像全体を基準に、x=画像内の横位置/画像幅×1000、y=画像内の縦位置/画像高さ×1000で指定します。ピクセル数やiOSのポイント値をそのまま返さないでください。
    出力形式:
    {"action":"tap","x":500,"y":500,"x2":0,"y2":0,"seconds":0,"observation":"画面の状況（短く）","thought":"判断理由（短く）","memo":""}
    actionはtap・swipe・wait・doneのいずれか1つ。x,y,x2,y2,secondsは必須で、その操作で使わない数値は0にします。observationとthoughtは各20文字以内。迷わず素早く答えてください。
    - tap: x,yをタップ。ボタンや文字の中心を狙う。
    - swipe: (x,y)から(x2,y2)へスワイプ。
    - wait: 読み込み中・演出中などで待つ。secondsに秒数（1〜10）。
    - done: 指示を達成した、または続行できない。thoughtに理由。
    - memo: このアプリについて次回以降も役立つ気づきがあれば30文字以内で1つだけ（例: 「出撃ボタンは画面下中央」）。なければ空。同じ言葉を繰り返さない。
    ルール:
    - 課金・購入・有料通貨の使用、アカウントや設定の変更、外部へのリンクは絶対に押さない。その画面になったらdone。
    - 指示の次の手順に合うボタンが見えたら、迷わず押す。waitは読み込み中・演出中など押せるものがないときだけ。
    - 「画面の文字」に座標が書かれていれば、そのボタンはその座標を押す（自分で位置を推測するより正確）。
    - 同じ操作を繰り返して画面が変わらないときは別の方法を考える。
    - 直前の操作の結果を、今の画面で確認してから次を決める。
    - WDA受理は画面が進んだ証拠ではありません。進まない場合、ボタンの背景を含む領域を見直し、実際に押せる中心を再確認してください。
    """

    func decide(instruction: String, step: Int, maxSteps: Int, history: [String], memos: [String], jpeg: Data,
                screenText: String = "") async throws -> (Decision, TokenUsage) {
        var text = "指示: \(instruction)\nステップ: \(step)/\(maxSteps)\n"
        text += "直近の行動:\n" + (history.isEmpty ? "（なし）\n" : history.suffix(6).joined(separator: "\n") + "\n")
        text += "経験メモ:\n" + (memos.isEmpty ? "（なし）\n" : memos.suffix(20).map { "- \($0)" }.joined(separator: "\n") + "\n")
        if !screenText.isEmpty { text += "画面の文字（端末で読み取り、中心座標）: \(screenText)\n" }
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
            "generationConfig": AgentResponse.generationConfig(
                model: model, detail: detail, thinking: !Self.noThinking.contains(model)),
        ]
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(trimmed):generateContent") else {
            throw BrainError.format("モデル名")
        }
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw BrainError.transient("\(Int(Self.timeout))秒以内に応答なし")
            case .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed:
                throw BrainError.transient("通信できません（\(error.code.rawValue)）")
            default: throw error
            }
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if code == 429 { throw BrainError.rateLimited }
        guard code == 200, let json else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "-"
            if AgentResponse.isTransient(status: code) { throw BrainError.transient("HTTP \(code) 混雑") }
            // A model that does not take the thinking setting: drop it and ask again once.
            if code == 400, message.lowercased().contains("thinking"), !Self.noThinking.contains(model) {
                Self.noThinking.insert(model)
                return try await decide(instruction: instruction, step: step, maxSteps: maxSteps,
                                        history: history, memos: memos, jpeg: jpeg, screenText: screenText)
            }
            throw BrainError.http(code, String(message.prefix(160)))
        }
        let (decision, _) = try AgentResponse.decode(json)
        return (decision, AgentResponse.usage(json))
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
    /// Leave each step (AI decision, tokens, result) in Notification Center without banners.
    var notifyHistory = false
    /// Read the screen's text on the iPhone: quoted buttons (「出撃」) are pressed without the AI,
    /// and the AI gets the text positions so it aims precisely.
    var quickText = true
    /// After pressing this quoted word (e.g. 出撃), flick without the AI until the battle ends. Empty = off.
    var flickAfter = ""
    var flickWait = 4.0
    private var runThread = "tapilot"

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
        runThread = "tapilot-\(Int(Date().timeIntervalSince1970))"
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

    private struct Screen {
        let jpeg: Data
        let image: UIImage
        let pixels: CGImage
    }

    /// Wait for a newly delivered frame rather than reusing a stalled stream.
    private func freshScreen() async -> Screen? {
        let previous = agent_frame_seq()
        var waits = 0
        while agent_frame_seq() == previous && waits < 25 && !stopRequested {
            await pause(0.2)
            waits += 1
        }
        guard agent_frame_seq() != previous, let jpeg = latestFrame(),
              let image = UIImage(data: jpeg), let pixels = image.cgImage else { return nil }
        return Screen(jpeg: jpeg, image: image, pixels: pixels)
    }

    /// True once the screen differs from `before` (checked every 0.25 s, up to `limit` seconds).
    private func waitForChange(from before: [UInt8], limit: Double) async -> Bool {
        guard !before.isEmpty else { await pause(1); return true }
        var waited = 0.0
        while waited < limit && !stopRequested {
            await pause(0.25)
            waited += 0.25
            guard let jpeg = latestFrame(), let image = UIImage(data: jpeg)?.cgImage else { continue }
            if ScreenText.difference(TextReader.thumbnail(image), before) >= ScreenText.unchanged { return true }
        }
        return false
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
        var transientRetries = 0
        var aiSeconds = 0.0
        var aiCalls = 0
        let quickWords = quickText ? ScreenText.quickWords(in: instruction) : []
        if !quickWords.isEmpty {
            add("AIなしで押す文字: " + quickWords.map { "「\($0)」" }.joined(separator: " "))
        }
        var lastWord: Int?
        var blocked = Set<String>()
        var blockedPrint: [UInt8] = []
        var deadSpots: [TextBox] = [] // text that did nothing when pressed (titles, labels); skipped for this run
        var lastTapPrint: [UInt8] = []
        var textTaps = 0
        let flickKey = ScreenText.normalize(flickAfter)
        var flicking = false
        var flicks = 0
        var stuckFlicks = 0
        if !flickKey.isEmpty { add("「\(flickAfter)」の後はAIなしではじきます（\(Int(flickWait))秒ごと）") }

        while step < maxSteps && !stopRequested && agent_ready() {
            if probeInFront {
                phaseText = "このアプリが前面のため一時停止中（対象アプリに切り替えると再開）"
                await pause(1)
                continue
            }
            await pause(0.8) // let the last action settle
            if stopRequested { break }
            if probeInFront { continue }
            guard var screen = await freshScreen() else {
                if !stopRequested { add("新しい画面を取得できないため停止しました。接続を確認してください") }
                break
            }
            if probeInFront { continue }
            var boxes = quickText ? await TextReader.read(screen.pixels) : []
            var shot = TextReader.thumbnail(screen.pixels)
            if !blocked.isEmpty, ScreenText.difference(shot, blockedPrint) >= ScreenText.unchanged {
                blocked.removeAll()
            }

            // Fixed buttons written in 「」: press by their text, no AI call.
            if execute, let hit = ScreenText.pick(words: quickWords, boxes: boxes, after: lastWord,
                                                             blocked: blocked, dead: deadSpots) {
                step += 1
                textTaps += 1
                let word = quickWords[hit.index]
                phaseText = "\(step)手目: 「\(word)」を押しています（AIなし）"
                let started = Date()
                let result = await command(["type": "tap", "x": hit.box.x, "y": hit.box.y,
                                            "image_width": screen.pixels.width, "image_height": screen.pixels.height])
                if result.hasPrefix("error") { add("\(step)手目 文字タップ「\(word)」: \(result)"); add("操作エラーのため停止しました"); break }
                let changed = await waitForChange(from: shot, limit: 3)
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
                let line = "\(step)手目 文字タップ「\(word)」(\(Int(hit.box.x)),\(Int(hit.box.y)))［AIなし \(elapsed)秒］→ \(changed ? "画面が変化" : "変化なし")"
                add(line)
                if notifyHistory { Notifier.postQuiet("Tapilot \(step)手目 「\(word)」", line, thread: runThread) }
                if changed {
                    lastWord = hit.index
                    flicking = !flickKey.isEmpty && ScreenText.normalize(word) == flickKey
                    stuckFlicks = 0
                } else {
                    blocked.insert(word)
                    blockedPrint = shot
                    deadSpots.append(hit.box)
                    add("  「\(word)」はこの位置では押しても変わらないため、今回は押しません（AIに任せます）")
                }
                history.append("\(step). tap「\(word)」→ \(changed ? "画面変化" : "変化なし")")
                lastTap = nil
                repeatedTaps = 0
                continue
            }

            // Simple battles: flick in a random direction without the AI. A screen that stops moving
            // (results, dialogs) gets a tap in the middle; after 3 still screens the AI takes over.
            if execute && flicking {
                if ScreenText.risky(boxes) {
                    add("  購入・コンティニュー等の文字があるため、はじくのをやめてAIに任せます")
                    flicking = false
                } else if stuckFlicks >= 3 {
                    add("  画面が動かないため、はじくのをやめてAIに任せます")
                    flicking = false
                    stuckFlicks = 0
                } else {
                    flicks += 1
                    let size = ["image_width": screen.pixels.width, "image_height": screen.pixels.height]
                    let label: String
                    var action: [String: Any]
                    if stuckFlicks == 0 {
                        let f = ScreenText.flick(angle: Double.random(in: 0..<(2 * Double.pi)))
                        action = ["type": "swipe", "x": f.x, "y": f.y, "x2": f.x2, "y2": f.y2, "ms": 250]
                        label = "はじく(\(Int(f.x2)),\(Int(f.y2)))"
                    } else {
                        action = ["type": "tap", "x": 500.0, "y": 500.0]
                        label = "中央をタップ"
                    }
                    action.merge(size) { a, _ in a }
                    phaseText = "はじき \(flicks)回目（AIなし）"
                    let result = await command(action)
                    if result.hasPrefix("error") { add("はじき: \(result)"); add("操作エラーのため停止しました"); break }
                    await pause(flickWait)
                    let after = latestFrame().flatMap { UIImage(data: $0)?.cgImage }.map(TextReader.thumbnail) ?? []
                    let moved = shot.isEmpty || after.isEmpty || ScreenText.difference(after, shot) >= ScreenText.unchanged
                    stuckFlicks = moved ? 0 : stuckFlicks + 1
                    add("はじき\(flicks)回目 \(label)［AIなし］\(moved ? "" : "→ 画面変化なし")")
                    history.append("（AIなし）\(label)")
                    if history.count > 50 { history.removeFirst(history.count - 50) }
                    continue
                }
            }

            // Respect the minimum interval between AI calls (free tier limits), then look again.
            let gap = interval - Date().timeIntervalSince(lastCall)
            if gap > 0.3 {
                await pause(gap)
                if stopRequested { break }
                if probeInFront { continue }
                guard let newer = await freshScreen() else {
                    if !stopRequested { add("新しい画面を取得できないため停止しました。接続を確認してください") }
                    break
                }
                screen = newer
                boxes = quickText ? await TextReader.read(screen.pixels) : []
                shot = TextReader.thumbnail(screen.pixels)
            }
            let jpeg = screen.jpeg, frame = screen.image, pixels = screen.pixels
            step += 1
            phaseText = "\(step)手目: AIが判断中"
            lastCall = Date()
            let decision: Decision
            var cost = ""
            do {
                let started = Date()
                let (d, usage) = try await brain.decide(instruction: instruction, step: step, maxSteps: maxSteps,
                                                       history: history, memos: memos, jpeg: jpeg,
                                                       screenText: ScreenText.describe(boxes))
                decision = d
                let seconds = Date().timeIntervalSince(started)
                aiSeconds += seconds
                aiCalls += 1
                totalTokens += usage.total
                cost = String(format: "［AI %.1f秒・%d tok", seconds, usage.total)
                    + (usage.thoughts > 0 ? "（思考\(usage.thoughts)）］" : "］")
                transientRetries = 0
            } catch let BrainError.transient(reason) {
                // Busy server or no reply: not the model's mistake. Retry with a fresh screen.
                transientRetries += 1
                if transientRetries > 5 {
                    add("AIの混雑・無応答が続くため停止しました（\(reason)）。時間をおくか、別のモデルを選んでください")
                    break
                }
                let wait = min(20.0, 3.0 * pow(2.0, Double(transientRetries - 1)))
                add("\(step)手目: \(reason)。\(Int(wait))秒後に再試行（\(transientRetries)/5）")
                step -= 1
                await pause(wait)
                continue
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
            add("\(step)手目 \(decision.action)\(coords) \(cost)\n  見: \((decision.observation ?? "-").prefix(60))\n  考: \((decision.thought ?? "-").prefix(60))")
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
                    // Count only taps that left the screen as it was (result screens advanced by tapping are fine).
                    let point = CGPoint(x: x, y: y)
                    let sameSpot = lastTap.map { abs($0.x - point.x) <= 15 && abs($0.y - point.y) <= 15 } ?? false
                    let sameScreen = shot.isEmpty || lastTapPrint.isEmpty
                        || ScreenText.difference(shot, lastTapPrint) < ScreenText.unchanged
                    repeatedTaps = sameSpot && sameScreen ? repeatedTaps + 1 : 1
                    lastTap = point
                    lastTapPrint = shot
                    if repeatedTaps > 3 {
                        add("同じ場所を押しても画面が変わらない状態が3回続いたため、4回目は送らず停止しました。赤丸の位置と実際のボタンを確認してください")
                        break
                    }
                }
            }

            if let memo = decision.memo?.trimmingCharacters(in: .whitespacesAndNewlines), memo.count > 60 {
                add("  メモが長すぎるため保存しません（\(memo.count)文字）")
            } else if let memo = decision.memo?.trimmingCharacters(in: .whitespacesAndNewlines), !memo.isEmpty,
               !memos.contains(memo) {
                let all = (memos + [memo]).suffix(50).joined(separator: "\n") + "\n"
                try? all.write(to: memoryURL, atomically: true, encoding: .utf8)
                add("  メモ追加: \(memo)")
            }

            var result = "見送り（観察のみ）"
            switch decision.action {
            case "tap" where execute:
                // Keep the order of the quoted steps when the AI pressed one of them.
                if let index = ScreenText.word(at: decision.x ?? -1, decision.y ?? -1, words: quickWords, boxes: boxes) {
                    lastWord = index
                    flicking = !flickKey.isEmpty && ScreenText.normalize(quickWords[index]) == flickKey
                    stuckFlicks = 0
                }
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
            if notifyHistory {
                Notifier.postQuiet("Tapilot \(step)手目 \(decision.action)\(coords)",
                                   "\((decision.thought ?? "-").prefix(60)) \(cost)\n→ \(result)", thread: runThread)
            }
            if result.hasPrefix("error") { add("操作エラーのため停止しました"); break }
            history.append("\(step). \(decision.action)\(coords) → \(result)｜\(decision.thought ?? "")")
        }
        let average = aiCalls > 0 ? String(format: " / AI平均 %.1f秒・%d tok／手", aiSeconds / Double(aiCalls), totalTokens / aiCalls) : ""
        add("終了: \(step)手（うちAIなし \(textTaps)手）＋はじき\(flicks)回\(average) / API報告トークン合計 \(totalTokens)（取得できた分）")
        phaseText = "終了"
    }
}
