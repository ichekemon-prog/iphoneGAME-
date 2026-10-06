import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct PhoneRunnerProbeApp: App {
    var body: some Scene { WindowGroup { ProbeView() } }
}

struct ProbeView: View {
    @Environment(\.scenePhase) private var phase
    @AppStorage("targetIP") private var host = "10.7.0.1"
    @AppStorage("runnerBundle") private var runner = ""
    @State private var importing = false
    @State private var status = "診断版5: WDA起動とタップの試験"
    @State private var running = false
    @State private var hasPairing = false
    @State private var wdaTaps = 0
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
                    Section("診断版5") {
                        Text("LocalDevVPNを接続してから開始します。Remote Pairingのトンネル上でWDAを起動し、上の目標を1回タップします。")
                        Text("WDAの画面が一時的に前面に出たら、そのまま待ってください（自動でこの画面に戻ります）。戻らない場合は手でこのアプリを開いてください。")
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
                        Button("WDA起動・タップ試験を開始") { start() }
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
            if !running { endBackgroundTask() }
        }
        .onChange(of: phase) { newPhase in
            if newPhase == .background && running {
                lifecycle = "バックグラウンド移行: \(Date().formatted(date: .omitted, time: .standard))"
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "BoundedProbe") {
                    probe_stop()
                    lifecycle = "バックグラウンド猶予切れで停止要求"
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
        if ok { wdaTaps = 0 } else { status = "試験を開始できませんでした" }
    }
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
