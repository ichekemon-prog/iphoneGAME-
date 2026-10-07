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
    @AppStorage("observeName") private var targetName = ""
    @AppStorage("geminiModel") private var model = "gemini-3.5-flash-lite"
    @AppStorage("agentInstruction") private var instruction = ""
    @AppStorage("agentMaxSteps") private var maxSteps = 20
    @AppStorage("agentInterval") private var interval = 6.0
    @AppStorage("agentExecute") private var execute = false
    @AppStorage("keepAliveAudio") private var keepAlive = true
    @State private var keyInput = ""
    @State private var hasKey = KeyStore.load() != nil
    @State private var keyNote = ""
    @State private var importing = false
    @State private var editingInstruction = false
    @State private var pickingApp = false
    @State private var apps: [AppEntry] = []
    @FocusState private var instructionFocused: Bool
    @State private var status = "Phone Runner Probe"
    @State private var running = false
    @State private var connectionReport = ConnectionReport.empty
    @State private var hasPairing = false
    @State private var ddiReady = DiskImage.ready
    @State private var ddiBusy = false
    @State private var ddiNote = ""
    @State private var audioNote = ""
    @State private var expiry = ProvisionInfo.expiration
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var supportURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    private var pairingURL: URL { supportURL.appendingPathComponent("remote-pairing.plist") }
    private var documentsURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    private func row(_ prefix: String) -> ConnectionReport.Row? {
        connectionReport.rows.last { $0.id.hasPrefix(prefix) }
    }
    private func state(of prefix: String) -> SetupItem.State {
        switch row(prefix)?.state {
        case "passed": return .ok
        case "failed", "warning": return .ng
        default: return .unknown
        }
    }
    private var setupItems: [SetupItem] {
        let vpn: SetupItem.State = {
            if state(of: "R1") == .ng || state(of: "R5") == .ng { return .ng }
            return state(of: "R8")
        }()
        return [
            SetupItem(id: "pair", title: "認証ファイル（Remote Pairing）", state: hasPairing ? .ok : .ng,
                      next: "「詳細設定」の「認証ファイルを読み込む」から、このiPhone用のファイルを選んでください。"),
            SetupItem(id: "vpn", title: "LocalDevVPNで接続できる", state: vpn,
                      next: vpn == .unknown ? "LocalDevVPNを接続してから「接続を診断する」を押してください。"
                                            : "LocalDevVPNを開いて接続し直し、もう一度診断してください。"),
            SetupItem(id: "ddi", title: "開発用ディスクイメージ", state: ddiReady ? state(of: "DDI") : .ng,
                      next: ddiReady ? "「接続を診断する」で自動的に準備されます。"
                                     : "「開発用ディスクイメージを準備」を押してください（Wi-Fi推奨・約16MB）。"),
            SetupItem(id: "wda", title: "WDA（操作用の部品）", state: runner.isEmpty ? (state(of: "W0") == .ng ? .ng : .unknown) : state(of: "WDA"),
                      next: state(of: "W0") == .ng ? "WDAが見つかりません。PCでWDAをインストールしてください。"
                                                   : "「接続を診断する」を押すと自動で見つけて確認します。"),
            SetupItem(id: "key", title: "AIのAPIキー（Gemini）", state: hasKey ? .ok : .ng,
                      next: "「AI設定」でAPIキーを貼り付けて保存してください。"),
            SetupItem(id: "app", title: "操作するアプリ", state: target.isEmpty ? .ng : .ok,
                      next: "「操作するアプリを選ぶ」から選んでください。"),
        ]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("はじめに（準備の確認）") {
                    SetupChecklistView(items: setupItems)
                    Text(ProvisionInfo.describe(expiry)).font(.footnote)
                }
                Section("接続診断（AIを呼び出さない）") {
                    Text("LocalDevVPNを接続してから押してください。WDA起動時に画面が切り替わったら、このアプリに戻ってください。")
                        .font(.footnote)
                    Button("接続を診断する") { startDiagnostics() }
                        .disabled(running || agent.active || !hasPairing)
                    Text(ddiReady ? "開発用ディスクイメージ：準備済み（再起動後は診断・開始時に自動でマウント）"
                                  : "開発用ディスクイメージ：未準備（再起動後の復旧に必要）")
                        .font(.footnote)
                    Button(ddiBusy ? "取得中…" : (ddiReady ? "開発用ディスクイメージを取り直す" : "開発用ディスクイメージを準備（約16MB）")) {
                        prepareDiskImage()
                    }.disabled(ddiBusy || running || agent.active)
                    if !ddiNote.isEmpty { Text(ddiNote).font(.caption) }
                    ConnectionDiagnosticsView(report: connectionReport)
                }
                Section("操作するアプリ") {
                    Text(target.isEmpty ? "未選択" : (targetName.isEmpty ? target : targetName))
                    Button("操作するアプリを選ぶ") { apps = InstalledApps.targets(InstalledApps.read()); pickingApp = true }
                        .disabled(running || agent.active)
                    Button("アプリ一覧を取得（VPN接続中に）") { startService(list: true) }
                        .disabled(running || agent.active || !hasPairing)
                }
                Section("指示") {
                    TextField("例: 今の画面から、ステージを1回クリアして", text: $instruction, axis: .vertical)
                        .lineLimit(8...)
                        .focused($instructionFocused)
                        .disabled(agent.active)
                    HStack {
                        Button("全画面で編集") {
                            instructionFocused = false
                            editingInstruction = true
                        }.buttonStyle(.borderless)
                        Spacer()
                        Menu("テンプレート") {
                            ForEach(InstructionTemplates.all) { item in
                                Button(item.title) { instruction = item.text }
                            }
                        }
                    }.disabled(agent.active)
                    Text("\(instruction.count)文字 · 自動保存")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("実際に操作する（OFF=見て考えるだけ）", isOn: $execute)
                    Stepper("最大 \(maxSteps) 手", value: $maxSteps, in: 1...200)
                    Stepper("AIに聞く間隔 \(Int(interval)) 秒以上", value: $interval, in: 2...60, step: 1)
                    Button(agent.active || running ? "エージェント実行中…" : "エージェント開始") { startAgent() }
                        .disabled(agent.active || running || !hasPairing || !hasKey || target.isEmpty || instruction.isEmpty)
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
                Section("AI設定（Gemini）") {
                    SecureField(hasKey ? "APIキー保存済み（変更する場合のみ入力）" : "APIキーを貼り付け", text: $keyInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("APIキーを保存して確認") { saveKey() }.disabled(keyInput.isEmpty)
                    if !keyNote.isEmpty { Text(keyNote).font(.caption) }
                    Link("APIキーの取得（Google AI Studio）", destination: URL(string: "https://aistudio.google.com/apikey")!)
                        .font(.footnote)
                }.disabled(agent.active)
                Section("詳細設定") {
                    DisclosureGroup("通常は変更不要") {
                        Text("接続状態：\(status)").font(.footnote).textSelection(.enabled)
                        Toggle("背景維持（無音オーディオ）", isOn: $keepAlive)
                        if !audioNote.isEmpty { Text(audioNote).font(.footnote) }
                        TextField("AIのモデル名", text: $model)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("VPNの接続先IP", text: $host)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("WDAのBundle ID（空欄なら自動検出）", text: $runner)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("操作するアプリのBundle ID", text: $target)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("認証ファイルを読み込む") { importing = true }
                        Text(hasPairing ? "Remote Pairing情報を確認済み（端末内のみ）" : "Remote Pairing情報が未設定、または形式が不正です")
                            .font(.footnote)
                    }
                }.disabled(running || agent.active)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Phone Runner Probe")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if instructionFocused {
                        Spacer()
                        Button("キーボードを閉じる") { instructionFocused = false }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $editingInstruction) {
            InstructionEditor(instruction: $instruction)
        }
        .sheet(isPresented: $pickingApp) {
            AppPickerView(apps: apps, selection: $target)
        }
        .onChange(of: target) { newValue in
            targetName = InstalledApps.read().first { $0.id == newValue }?.name ?? ""
        }
        .onAppear {
            refreshPairing()
            agent.probeInFront = true
            Notifier.requestPermission()
            expiry = ProvisionInfo.expiration
            Notifier.scheduleExpiryReminder(expiry)
        }
        .onReceive(timer) { _ in
            let wasRunning = running
            running = probe_running()
            connectionReport = ConnectionReport.read()
            if let text = probe_status() {
                let value = String(cString: text)
                probe_free_string(text)
                if !value.isEmpty { status = value }
            }
            if wasRunning && !running {
                // A list/diagnostic run may have found WDA automatically.
                let detected = InstalledApps.detectedRunner()
                if runner.isEmpty && !detected.isEmpty { runner = detected }
            }
            if !running && !agent.active {
                endBackgroundTask()
                if SilentAudio.shared.active { SilentAudio.shared.stop(); audioNote = "無音オーディオ停止" }
            }
            if !running && agent.active { agent.stop() }
        }
        .onChange(of: agent.active) { isActive in
            if !isActive && phase != .active {
                let last = agent.log.last ?? ""
                Notifier.post("エージェントが停止しました", String(last.prefix(120)))
            }
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
                expiry = ProvisionInfo.expiration
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
    private func saveKey() {
        let value = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        keyInput = ""
        guard !value.isEmpty, KeyStore.save(value) else { hasKey = false; keyNote = "APIキーを保存できませんでした"; return }
        hasKey = true
        keyNote = "保存しました。確認中…"
        let currentModel = model
        Task {
            let (_, message) = await KeyCheck.verify(apiKey: value, model: currentModel)
            keyNote = message
        }
    }
    @discardableResult
    private func startService(list: Bool, diagnostic: Bool = false) -> Bool {
        let selfBundle = Bundle.main.bundleIdentifier ?? ""
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = runner.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = list ? "" : target.trimmingCharacters(in: .whitespacesAndNewlines)
        let docs = documentsURL.path
        let configured = t.withCString { tp in docs.withCString { dp in probe_configure(tp, dp, 3600) } }
        guard configured else { status = "設定を渡せませんでした"; return false }
        if diagnostic && !probe_enable_diagnostics() { status = "診断を準備できませんでした"; return false }
        DiskImage.directory.path.withCString { probe_set_ddi_dir($0) }
        let ok = pairingURL.path.withCString { p in
            h.withCString { hp in r.withCString { rp in selfBundle.withCString { sp in probe_start(p, hp, rp, sp) } } }
        }
        running = ok
        if !ok { status = "開始できませんでした" }
        return ok
    }
    private func prepareDiskImage() {
        ddiBusy = true
        ddiNote = "取得中（Wi-Fi推奨）…"
        Task {
            do {
                try await DiskImage.download()
                ddiNote = "取得しました"
            } catch {
                ddiNote = "取得できませんでした: \(error.localizedDescription)"
            }
            ddiReady = DiskImage.ready
            ddiBusy = false
        }
    }
    private func startDiagnostics() {
        guard !running && !agent.active else { return }
        guard startService(list: true, diagnostic: true) else { return }
        connectionReport = ConnectionReport.read()
        // WDA may bring its runner to the foreground during the check.
        if keepAlive {
            audioNote = SilentAudio.shared.start() ? "無音オーディオ再生中" : "無音オーディオを開始できません"
        }
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

private struct InstructionEditor: View {
    @Binding var instruction: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("指示は自動保存されます。長文はスクロールして編集できます。")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $instruction)
                    .font(.body)
                    .focused($focused)
                    .scrollDismissesKeyboard(.interactively)
                    .accessibilityLabel("エージェントへの指示")
                Text("\(instruction.count)文字").font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("指示を編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { focused = false; dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("キーボードを閉じる") { focused = false }
                }
            }
        }
    }
}
