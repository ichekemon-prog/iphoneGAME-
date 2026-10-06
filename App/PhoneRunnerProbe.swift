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
    @State private var importing = false
    @State private var status = "診断版6: 背景での維持試験"
    @State private var running = false
    @State private var hasPairing = false
    @State private var wdaTaps = 0
    @AppStorage("keepAliveAudio") private var keepAlive = true
    @State private var audioNote = ""
    @State private var lifecycle = "前面で待機中"
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var pairingURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("remote-pairing.plist")
    }

    var body: some View {
        VStack(spacing: 0) {
            // WDA taps the center of this target. Do not tap it by hand during the test.
            Button { wdaTaps += 1 } label: {
                VStack {
                    Text("タップ目標（手で触らないでください）").font(.headline)
                    Text("WDAからのタップ回数: \(wdaTaps)").font(.title2.bold())
                }
                .frame(maxWidth: .infinity, minHeight: 110)
                .background(wdaTaps > 0 ? Color.green.opacity(0.35) : Color.orange.opacity(0.25))
            }
            .buttonStyle(.plain)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { report(geo.frame(in: .global)) }
                    .onChange(of: geo.frame(in: .global)) { report($0) }
            })

            NavigationStack {
                Form {
                    Section("診断版6") {
                        Text("WDA起動→目標を1回タップ→WDAがホーム画面へ移動し、約90秒Probeを背景にしたまま接続・画面取得を確認→自動でこの画面に戻ります。")
                        Text("試験中はiPhoneに触らずに待ってください（約3〜4分）。戻らない場合は手でこのアプリを開いてください。")
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
                    Section("試験") {
                        Button("背景維持試験を開始") { start() }
                            .disabled(running || !hasPairing || runner.isEmpty)
                        Button("停止", role: .destructive) { probe_stop() }.disabled(!running)
                        Text(status).textSelection(.enabled)
                        Text(lifecycle).font(.footnote)
                    }
                }.navigationTitle("Phone Runner Probe")
            }
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
                try FileManager.default.createDirectory(at: pairingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: pairingURL, options: [.atomic, .completeFileProtection])
                var directory = pairingURL.deletingLastPathComponent()
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try directory.setResourceValues(values)
                refreshPairing()
                status = "Remote Pairing情報を保存しました"
            } catch { status = "ファイルを読み込めません。Remote Pairing形式か確認してください" }
        }
    }

    private func report(_ frame: CGRect) {
        probe_set_tap_point(Double(frame.midX), Double(frame.midY))
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
    private func start() {
        let selfBundle = Bundle.main.bundleIdentifier ?? ""
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = runner.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = pairingURL.path.withCString { p in
            h.withCString { hp in r.withCString { rp in selfBundle.withCString { sp in probe_start(p, hp, rp, sp) } } }
        }
        running = ok
        if ok {
            wdaTaps = 0
            if keepAlive { audioNote = SilentAudio.shared.start() ? "無音オーディオ再生中" : "無音オーディオを開始できません" }
            else { audioNote = "背景維持なし（猶予のみ）" }
        } else { status = "試験を開始できませんでした" }
    }
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
