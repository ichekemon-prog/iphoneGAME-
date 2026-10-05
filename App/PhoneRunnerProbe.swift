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
    @AppStorage("runnerBundle") private var bundle = ""
    @State private var importing = false
    @State private var status = "ペアリングファイルを読み込んでください"
    @State private var running = false
    @State private var hasPairing = false
    @State private var lifecycle = "前面で待機中"
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var pairingURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairing.plist")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("端末内起動の検証用・周回機能なし") {
                    Text("このアプリから自分のiPhoneの開発用サービスへ接続します。外部のloopback VPNが必要です。TCP経路が使えない場合は停止します。")
                    Text("ゲーム表示中の継続動作は未確認です。バックグラウンド猶予が切れたら試験を停止します。")
                }
                Section("接続設定") {
                    TextField("VPNの接続先IP", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("署名後のWDA Bundle ID", text: $bundle).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(hasPairing ? "ペアリングファイルを置き換える" : "ペアリングファイルを読み込む") { importing = true }
                    Text(hasPairing ? "ファイル保存済み（端末内のみ）" : "ファイル未設定")
                }.disabled(running)
                Section("試験") {
                    Button("接続・起動試験を開始") { start() }
                        .disabled(running || !hasPairing || bundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("停止", role: .destructive) { probe_stop() }.disabled(!running)
                    Text(status).textSelection(.enabled)
                    Text(lifecycle).font(.footnote)
                }
            }.navigationTitle("Phone Runner Probe")
        }
        .onAppear { hasPairing = FileManager.default.fileExists(atPath: pairingURL.path) }
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
                      plist["HostID"] != nil, plist["HostPrivateKey"] != nil else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try FileManager.default.createDirectory(at: pairingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: pairingURL, options: [.atomic, .completeFileProtection])
                var directory = pairingURL.deletingLastPathComponent()
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try directory.setResourceValues(values)
                hasPairing = true; status = "ペアリングファイルを保存しました"
            } catch { status = "ファイルを読み込めません。通常のAppleペアリングplistを選択してください" }
        }
    }
    private func start() {
        let ok = pairingURL.path.withCString { p in
            host.trimmingCharacters(in: .whitespacesAndNewlines).withCString { h in
                bundle.trimmingCharacters(in: .whitespacesAndNewlines).withCString { b in probe_start(p,h,b) }
            }
        }
        running = ok
        if !ok { status = "試験を開始できませんでした" }
    }
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
