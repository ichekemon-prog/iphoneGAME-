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
    @State private var status = "診断版4: 携帯通信復帰後の接続維持試験"
    @State private var holding = false
    @State private var markedRestored = false
    @State private var running = false
    @State private var hasPairing = false
    @State private var lifecycle = "前面で待機中"
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var pairingURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("remote-pairing.plist")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("診断版4・接続維持の試験") {
                    Text("LocalDevVPN接続後、機内モードONで開始します。接続成功と表示されたら機内モードをOFFにし、4G/5G表示に戻ったら『携帯通信を戻しました』を押してください。")
                    Text("同じ接続を約2分保ち、応答を確認します。切り替え後はこの画面を開いたままにしてください。ゲーム通信・WDA操作はまだ検証しません。")
                }
                Section("接続設定") {
                    TextField("VPNの接続先IP", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("認証ファイルを読み込む") { importing = true }
                    Text(hasPairing ? "Remote Pairing情報を確認済み（端末内のみ）" : "Remote Pairing情報が未設定、または形式が不正です")
                }.disabled(running)
                Section("試験") {
                    Button("Remote Pairing接続試験を開始") { start() }
                        .disabled(running || !hasPairing)
                    Button(markedRestored ? "携帯通信の復帰を記録済み" : "携帯通信を戻しました") {
                        probe_mark_cellular_restored()
                        markedRestored = true
                    }.disabled(!running || !holding || markedRestored)
                    Button("停止", role: .destructive) { probe_stop() }.disabled(!running)
                    Text(status).textSelection(.enabled)
                    Text(lifecycle).font(.footnote)
                }
            }.navigationTitle("Phone Runner Probe")
        }
        .onAppear { refreshPairing() }
        .onReceive(timer) { _ in
            running = probe_running()
            holding = probe_holding()
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
                      let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let destination: URL
                if isRemotePairing(plist) {
                    destination = pairingURL
                } else if plist["HostID"] is String, plist["HostPrivateKey"] is Data {
                    destination = pairingURL.deletingLastPathComponent().appendingPathComponent("pairing.plist")
                } else { throw CocoaError(.fileReadCorruptFile) }
                try FileManager.default.createDirectory(at: pairingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: [.atomic, .completeFileProtection])
                var directory = pairingURL.deletingLastPathComponent()
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try directory.setResourceValues(values)
                refreshPairing()
                status = destination == pairingURL ? "Remote Pairing情報を保存しました" : "通常の認証情報を別ファイルに保存しました。この試験にはRemote Pairing情報が必要です。"
            } catch { status = "ファイルを読み込めません。認証ファイルの形式を確認してください" }
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
    private func start() {
        let ok = pairingURL.path.withCString { p in
            host.trimmingCharacters(in: .whitespacesAndNewlines).withCString { h in
                bundle.trimmingCharacters(in: .whitespacesAndNewlines).withCString { b in probe_start(p,h,b) }
            }
        }
        running = ok
        if ok { markedRestored = false; holding = false }
        if !ok { status = "試験を開始できませんでした" }
    }
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
