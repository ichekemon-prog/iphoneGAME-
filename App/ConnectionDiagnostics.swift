import SwiftUI

struct ConnectionReport: Decodable {
    struct Row: Decodable, Identifiable {
        let id: String
        let state: String
        let detail: String
        let hint: String
    }
    var state: String
    var rows: [Row]
    var summary: String

    static let empty = ConnectionReport(state: "idle", rows: [], summary: "未実施")

    static func read() -> ConnectionReport {
        guard let pointer = probe_diagnostics() else { return .empty }
        defer { probe_free_string(pointer) }
        return (try? JSONDecoder().decode(Self.self, from: Data(String(cString: pointer).utf8))) ?? .empty
    }
}

struct ConnectionDiagnosticsView: View {
    let report: ConnectionReport

    private func label(_ state: String) -> String {
        switch state {
        case "passed": return "確認済み"
        case "failed": return "失敗"
        case "running": return "確認中"
        case "warning": return "要確認"
        case "cancelled": return "中断"
        default: return "未実施"
        }
    }

    var body: some View {
        Text(report.summary).font(.footnote)
        ForEach(report.rows) { row in
            VStack(alignment: .leading, spacing: 5) {
                Text("\(label(row.state)) · \(row.id)").font(.subheadline).bold()
                Text(row.detail).font(.caption)
                if row.state == "failed" || row.state == "warning" {
                    Text("次の操作：\(row.hint)").font(.caption).foregroundStyle(.orange)
                }
            }.textSelection(.enabled)
        }
        if report.state != "idle" {
            Text("これは診断時点の結果です。通常運転中の常時監視ではありません。未到達の項目は未確認です。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
