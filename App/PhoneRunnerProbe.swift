import SwiftUI
import UIKit
import UniformTypeIdentifiers
import AVFoundation

/// Plays silence so iOS keeps this app running in the background
/// (UIBackgroundModes=audio). Mixes with other apps, so the game's sound is kept.
final class SilentAudio {
    static let shared = SilentAudio()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var attached = false
    private(set) var active = false

    func start() -> Bool {
        if active { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return false }
            buffer.frameLength = 44_100
            if let channels = buffer.floatChannelData {
                for c in 0..<Int(format.channelCount) { channels[c].update(repeating: 0, count: 44_100) }
            }
            if !attached {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                attached = true
            }
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            active = true
            return true
        } catch { return false }
    }

    func stop() {
        guard active else { return }
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        active = false
    }
}

@main
struct PhoneRunnerProbeApp: App {
    var body: some Scene { WindowGroup { ProbeView() } }
}

struct ProbeView: View {
    @Environment(\.scenePhase) private var phase
    @StateObject private var agent = AgentRunner()
    @AppStorage("targetIP") private var host = "10.7.0.1"
    @AppStorage("runnerBundle") private var runner = ""
    @AppStorage("observeBundle") private var target = ""
    @AppStorage("geminiModel") private var model = "gemini-3.5-flash"
    @AppStorage("agentInstruction") private var instruction = ""
    @AppStorage("agentMaxSteps") private var maxSteps = 20
    @AppStorage("agentInterval") private var interval = 6.0
    @AppStorage("agentExecute") private var execute = false
    @AppStorage("keepAliveAudio") private var keepAlive = true
    @State private var keyInput = ""
    @State private var hasKey = KeyStore.load() != nil
    @State private var importing = false
    @State private var status = "診断版8: AIエージェント"
    @State private var running = false
    @State private var hasPairing = false
    @State private var audioNote = ""
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var supportURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    private var pairingURL: URL { supportURL.appendingPathComponent("remote-pairing.plist") }
    private var documentsURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    var body: some View {
        NavigationStack {
            Form {
                Section("指示") {
                    TextField("例: 今いる画面から、イベントのステージを1回クリアして", text: $instruction, axis: .vertical)
                        .lineLimit(2...6)
                    Toggle("実行する（OFF=観察のみ・操作しない）", isOn: $execute)
                    Stepper("最大 \(maxSteps) 手", value: $maxSteps, in: 1...200)
                    Stepper("AIに聞く間隔 \(Int(interval)) 秒以上", value: $interval, in: 2...60, step: 1)
                    Button(agent.active || running ? "エージェント実行中…" : "エージェント開始") { startAgent() }
                        .disabled(agent.active || running || !hasPairing || !hasKey || runner.isEmpty || target.isEmpty || instruction.isEmpty)
                    Button("停止", role: .destructive) { agent.stop(); probe_stop() }
                        .disabled(!agent.active && !running)
                    if !agent.phaseText.isEmpty { Text(agent.phaseText).font(.footnote) }
                }
                Section("AIの判断ログ（新しい順）") {
                    if agent.log.isEmpty { Text("まだありません").foregroundStyle(.secondary) }
                    ForEach(Array(agent.log.reversed().prefix(40).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.footnote).textSelection(.enabled)
                    }
                    Button("経験メモを消去（\(agent.memos.count)件）", role: .destructive) { agent.clearMemos() }
                        .disabled(agent.active)
                }
                Section("接続状態") {
                    Text(status).font(.footnote).textSelection(.enabled)
                    Toggle("背景維持（無音オーディオ）", isOn: $keepAlive)
                    if !audioNote.isEmpty { Text(audioNote).font(.footnote) }
                }
                Section("AI設定（Gemini）") {
                    SecureField(hasKey ? "APIキー保存済み（変更する場合のみ入力）" : "APIキーを貼り付け", text: $keyInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("APIキーを保存（この端末のキーチェーンのみ）") {
                        let value = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        hasKey = !value.isEmpty && KeyStore.save(value)
                        keyInput = ""
                        status = hasKey ? "APIキーを保存しました" : "APIキーを保存できませんでした"
                    }.disabled(keyInput.isEmpty)
                    TextField("モデル名", text: $model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }.disabled(agent.active)
                Section("対象アプリと接続") {
                    TextField("対象アプリのBundle ID", text: $target)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("アプリ一覧を取得") { startService(list: true) }
                        .disabled(running || !hasPairing)
                    TextField("VPNの接続先IP", text: $host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("WDAのBundle ID", text: $runner)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("認証ファイルを読み込む") { importing = true }
                    Text(hasPairing ? "Remote Pairing情報を確認済み（端末内のみ）" : "Remote Pairing情報が未設定、または形式が不正です")
                }.disabled(running || agent.active)
            }.navigationTitle("Phone Runner Probe")
        }
        .onAppear { refreshPairing(); agent.probeInFront = true }
        .onReceive(timer) { _ in
            running = probe_running()
            if let text = probe_status() {
                let value = String(cString: text)
                probe_free_string(text)
                if !value.isEmpty { status = value }
            }
            if !running && !agent.active {
                endBackgroundTask()
                if SilentAudio.shared.active { SilentAudio.shared.stop(); audioNote = "無音オーディオ停止" }
            }
            if !running && agent.active { agent.stop() }
        }
        .onChange(of: phase) { newPhase in
            agent.probeInFront = newPhase == .active
            if newPhase == .background && (running || agent.active) {
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "BoundedProbe") {
                    if !SilentAudio.shared.active { agent.stop(); probe_stop() }
                    endBackgroundTask()
                }
            } else if newPhase == .active {
                endBackgroundTask()
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard data.count < 1_048_576,
                      let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      isRemotePairing(plist) else { throw CocoaError(.fileReadCorruptFile) }
                try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
                try data.write(to: pairingURL, options: [.atomic, .completeFileProtection])
                var directory = supportURL
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try directory.setResourceValues(values)
                refreshPairing()
                status = "Remote Pairing情報を保存しました"
            } catch { status = "ファイルを読み込めません。Remote Pairing形式か確認してください" }
        }
    }

    private func isRemotePairing(_ plist: [String: Any]) -> Bool {
        guard let publicKey = plist["public_key"] as? Data, publicKey.count == 32,
              let privateKey = plist["private_key"] as? Data, privateKey.count == 32,
              let identifier = plist["identifier"] as? String, !identifier.isEmpty else { return false }
        return true
    }
    private func refreshPairing() {
        guard let data = try? Data(contentsOf: pairingURL), data.count < 1_048_576,
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = object as? [String: Any] else { hasPairing = false; return }
        hasPairing = isRemotePairing(plist)
    }
    @discardableResult
    private func startService(list: Bool) -> Bool {
        let selfBundle = Bundle.main.bundleIdentifier ?? ""
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = runner.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = list ? "" : target.trimmingCharacters(in: .whitespacesAndNewlines)
        let docs = documentsURL.path
        let configured = t.withCString { tp in docs.withCString { dp in probe_configure(tp, dp, 3600) } }
        guard configured else { status = "設定を渡せませんでした"; return false }
        let ok = pairingURL.path.withCString { p in
            h.withCString { hp in r.withCString { rp in selfBundle.withCString { sp in probe_start(p, hp, rp, sp) } } }
        }
        running = ok
        if !ok { status = "開始できませんでした" }
        return ok
    }
    private func startAgent() {
        guard let key = KeyStore.load() else { status = "APIキーがありません"; hasKey = false; return }
        guard startService(list: false) else { return }
        if keepAlive {
            audioNote = SilentAudio.shared.start() ? "無音オーディオ再生中" : "無音オーディオを開始できません"
        }
        agent.start(instruction: instruction, brain: GeminiBrain(apiKey: key, model: model),
                    maxSteps: maxSteps, interval: interval, execute: execute)
    }
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
