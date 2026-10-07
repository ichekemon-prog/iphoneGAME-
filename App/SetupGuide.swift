import Foundation
import SwiftUI
import UserNotifications

// MARK: - Installed apps (filled by "アプリ一覧を取得" or by a diagnostic run)

struct AppEntry: Codable, Identifiable, Hashable {
    let name: String
    let id: String
}

enum InstalledApps {
    static func cached() -> [AppEntry] {
        guard let data = UserDefaults.standard.data(forKey: "installedAppsCache") else { return [] }
        return (try? JSONDecoder().decode([AppEntry].self, from: data)) ?? []
    }

    static func cache(_ apps: [AppEntry]) {
        if let data = try? JSONEncoder().encode(apps) {
            UserDefaults.standard.set(data, forKey: "installedAppsCache")
        }
    }
    static func read() -> [AppEntry] {
        guard let pointer = probe_apps() else { return [] }
        defer { probe_free_string(pointer) }
        let list = (try? JSONDecoder().decode([AppEntry].self, from: Data(String(cString: pointer).utf8))) ?? []
        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func detectedRunner() -> String {
        guard let pointer = probe_detected_runner() else { return "" }
        defer { probe_free_string(pointer) }
        return String(cString: pointer)
    }

    /// Apps a user would want to operate (hides WDA and this app).
    static func targets(_ apps: [AppEntry]) -> [AppEntry] {
        let me = Bundle.main.bundleIdentifier ?? ""
        return apps.filter { !$0.id.lowercased().contains("webdriveragent") && $0.id != me }
    }
}

// MARK: - Signing expiry (free Apple ID: about 7 days)

enum ProvisionInfo {
    /// Expiration date of this app's provisioning profile, if embedded.
    static var expiration: Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any]
        return plist?["ExpirationDate"] as? Date
    }

    static func describe(_ date: Date?) -> String {
        guard let date else { return "署名の有効期限：不明" }
        let days = Int(floor(date.timeIntervalSinceNow / 86_400))
        let when = date.formatted(date: .abbreviated, time: .shortened)
        if days < 0 { return "署名の有効期限：切れています（\(when)）" }
        return "署名の有効期限：あと\(days)日（\(when)まで）"
    }
}

// MARK: - Local notifications

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Reminds one day before the signature expires (replaces the previous reminder).
    static func scheduleExpiryReminder(_ date: Date?) {
        let id = "signing-expiry"
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard let date else { return }
        let fire = date.addingTimeInterval(-86_400)
        guard fire > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = "署名の期限が近づいています"
        content.body = "明日、本アプリとWDAの署名が切れます。再署名（更新）してください。"
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}

// MARK: - API key check (metadata request; does not use generation quota)

enum KeyCheck {
    static func verify(apiKey: String, model: String) async -> (Bool, String) {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(name)") else {
            return (false, "モデル名が不正です")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: return (true, "APIキーとモデル名を確認しました")
            case 400, 401, 403: return (false, "APIキーが無効です。コピーし直してください")
            case 404: return (false, "モデル名が見つかりません（例: gemini-3.5-flash-lite）")
            case let code: return (false, "確認できませんでした（HTTP \(code)）")
            }
        } catch {
            return (false, "通信できませんでした。インターネット接続を確認してください")
        }
    }
}

// MARK: - Setup checklist

struct SetupItem: Identifiable {
    enum State { case ok, ng, unknown }
    let id: String
    let title: String
    let state: State
    let next: String
}

struct SetupChecklistView: View {
    let items: [SetupItem]

    private func mark(_ state: SetupItem.State) -> String {
        switch state {
        case .ok: return "✅"
        case .ng: return "⚠️"
        case .unknown: return "⬜️"
        }
    }

    var body: some View {
        ForEach(items) { item in
            VStack(alignment: .leading, spacing: 3) {
                Text("\(mark(item.state)) \(item.title)")
                if item.state != .ok {
                    Text(item.next).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: - App picker

struct AppPickerView: View {
    let apps: [AppEntry]
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [AppEntry] {
        query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { app in
                Button {
                    selection = app.id
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(app.name)
                            Text(app.id).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection == app.id { Image(systemName: "checkmark") }
                    }
                }
            }
            .searchable(text: $query, prompt: "アプリ名で検索")
            .navigationTitle("操作するアプリを選ぶ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
            .overlay {
                if apps.isEmpty {
                    Text("アプリ一覧がまだありません。\n「アプリ一覧を取得」を先に押してください。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).padding()
                } else if filtered.isEmpty {
                    Text("一致するアプリがありません").foregroundStyle(.secondary)
                }
            }
        }
    }
}

enum ModelChoices {
    struct Choice: Identifiable {
        let id: String
        let name: String
    }
    static let all: [Choice] = [
        Choice(id: "gemini-3.5-flash-lite", name: "Gemini 3.5 Flash Lite"),
        Choice(id: "gemini-3.1-flash-lite", name: "Gemini 3.1 Flash Lite"),
        Choice(id: "gemini-3.5-flash", name: "Gemini 3.5 Flash"),
    ]
}

// MARK: - Instruction templates (generic; app-specific know-how stays in the user's own text)

struct InstructionTemplate: Identifiable {
    let title: String
    let text: String
    var id: String { title }
}

enum InstructionTemplates {
    static let all: [InstructionTemplate] = [
        InstructionTemplate(title: "画面の説明だけ（操作しない）", text: "今の画面に何が表示されているかを説明してください。操作はせずに完了してください。"),
        InstructionTemplate(title: "ホーム画面へ戻る", text: "このアプリのホーム画面（メイン画面）に戻ってください。戻れたら完了してください。"),
        InstructionTemplate(title: "お知らせを閉じる", text: "表示されているお知らせやポップアップを閉じて、通常の画面に戻ってください。課金や購入の画面では何も押さずに完了してください。"),
        InstructionTemplate(title: "同じ操作の繰り返し（ひな形）", text: "【目的】ここに達成したいことを書く\n【繰り返し】終わったら最初に戻って、指定回数まで繰り返す\n【やめる条件】スタミナ不足・エラー・課金画面が出たら何も押さずに完了\n【コツ】迷ったら待つ。同じ場所を押しても進まないときは別の方法を試す"),
    ]
}
