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
    @AppStorage("targetIP") private var host = "10.7.0.1"
    @AppStorage("runnerBundle") private var runner = ""
    @AppStorage("observeBundle") private var target = ""
    @AppStorage("observeSeconds") private var seconds = 300
    @AppStorage("keepAliveAudio") private var keepAlive = true
    @State private var importing = false
    @State private var status = "診断版7: 前面アプリの画面受信試験"
    @State private var running = false
    @State private var hasPairing = false
    @State private var audioNote = ""
    @State private var lifecycle = "前面で待機中"
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var supportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    private var pairingURL: URL { supportURL.appendingPathComponent("remote-pairing.plist") }
    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("診断版7") {
                    Text("①『アプリ一覧を取得』で対象アプリのBundle IDを確認 → ②下の欄に入力 → ③『前面アプリ観察を開始』。")
                    Text("観察中は対象アプリが前面になり、Probeは背景で画面を受信します（タップはしません）。終了すると自動でこの画面に戻ります。保存画像は『ファイル』アプリ→このiPhone内→Phone Runner Probe→frames。")
                    Toggle("背景維持（無音オーディオ）", isOn: $keepAlive)
                    if !audioNote.isEmpty { Text(audioNote).font(.footnote) }
                }
                Section("接続設定") {
                    TextField("VPNの接続先IP", text: $host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("WDAのBundle ID", text: $runner)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("認証ファイルを読み込む") { importing = true }
                    Text(hasPairing ? "Remote Pairing情報を確認済み（端末内のみ）" : "Remote Pairing情報が未設定、または形式が不正です")
                }.disabled(running)
                Section("観察設定") {
                    TextField("対象アプリのBundle ID", text: $target)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("観察時間", selection: $seconds) {
                        Text("1分").tag(60)
                        Text("5分").tag(300)
                        Text("10分").tag(600)
                        Text("30分").tag(1800)
                    }
                }.disabled(running)
                Section("試験") {
                    Button("アプリ一覧を取得") { start(list: true) }
                        .disabled(running || !hasPairing)
                    Button("前面アプリ観察を開始") { start(list: false) }
                        .disabled(running || !hasPairing || runner.isEmpty || target.isEmpty)
                    Button("停止", role: .destructive) { probe_stop() }.disabled(!running)
                    Text(status).textSelection(.enabled)
                    Text(lifecycle).font(.footnote)
                }
            }.navigationTitle("Phone Runner Probe")
        }
        .onAppear { refreshPairing() }
        .onReceive(timer) { _ in
            running = probe_running()
            if let text = probe_status() {
                let value = String(cString: text)
                probe_free_string(text)
                if !value.isEmpty { status = value }
            }
            if !running {
                endBackgroundTask()
                if SilentAudio.shared.active { SilentAudio.shared.stop(); audioNote = "無音オーディオ停止" }
            }
        }
        .onChange(of: phase) { newPhase in
            if newPhase == .background && running {
                lifecycle = "バックグラウンド移行: \(Date().formatted(date: .omitted, time: .standard))"
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "BoundedProbe") {
                    if SilentAudio.shared.active {
                        lifecycle = "背景猶予は終了（無音オーディオで継続中）"
                    } else {
                        probe_stop()
                        lifecycle = "バックグラウンド猶予切れで停止要求"
                    }
                    endBackgroundTask()
                }
            } else if newPhase == .active {
                endBackgroundTask()
                lifecycle = "前面に復帰: \(Date().formatted(date: .omitted, time: .standard))"
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
                      isRemotePairing(plist) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
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
    private func start(list: Bool) {
        let selfBundle = Bundle.main.bundleIdentifier ?? ""
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = runner.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = list ? "" : target.trimmingCharacters(in: .whitespacesAndNewlines)
        let docs = documentsURL.path
        let configured = t.withCString { tp in docs.withCString { dp in probe_configure(tp, dp, UInt32(seconds)) } }
        guard configured else { status = "設定を渡せませんでした"; return }
        let ok = pairingURL.path.withCString { p in
            h.withCString { hp in r.withCString { rp in selfBundle.withCString { sp in probe_start(p, hp, rp, sp) } } }
        }
        running = ok
        if ok {
            if !list && keepAlive {
                audioNote = SilentAudio.shared.start() ? "無音オーディオ再生中" : "無音オーディオを開始できません"
            } else if !list {
                audioNote = "背景維持なし（猶予のみ）"
            }
        } else { status = "試験を開始できませんでした" }
    }
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
