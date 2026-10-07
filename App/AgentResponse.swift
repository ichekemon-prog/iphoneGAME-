import Foundation

struct Decision: Decodable {
    var observation: String?
    var thought: String?
    var action: String
    var x: Double?
    var y: Double?
    var x2: Double?
    var y2: Double?
    var seconds: Double?
    var memo: String?
}

enum BrainError: LocalizedError {
    case rateLimited
    case http(Int, String)
    case format(String)
    case response(String, Int?)

    var errorDescription: String? {
        switch self {
        case .rateLimited: return "利用上限に達しました（429）"
        case let .http(code, message): return "HTTP \(code): \(message)"
        case let .format(message): return "応答の形式が不正: \(message)"
        case let .response(message, tokens):
            return "AI応答を操作に使えません: \(message) / API報告トークン: \(tokens.map(String.init) ?? "不明")"
        }
    }
}

enum AgentResponse {
    // Schema constrains the API output; local validation still checks each action.
    static var generationConfig: [String: Any] {
        let coordinate: [String: Any] = ["type": "number", "minimum": 0, "maximum": 1000]
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": ["tap", "swipe", "wait", "done"]],
                "x": coordinate, "y": coordinate, "x2": coordinate, "y2": coordinate,
                "seconds": ["type": "number", "minimum": 0, "maximum": 10],
                "observation": ["type": "string"],
                "thought": ["type": "string"],
                "memo": ["type": "string"],
            ] as [String: Any],
            "required": ["action", "x", "y", "x2", "y2", "seconds"],
            "additionalProperties": false,
        ]
        return ["responseMimeType": "application/json", "responseJsonSchema": schema, "temperature": 0.2]
    }

    static func decode(_ json: [String: Any]) throws -> (Decision, Int?) {
        let tokens = (json["usageMetadata"] as? [String: Any])?["totalTokenCount"] as? Int
        func failure(_ message: String) -> BrainError { .response(message, tokens) }
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first else {
            throw failure("候補なし（ブロックまたは空応答）")
        }
        let finish = candidate["finishReason"] as? String ?? "不明"
        guard finish == "STOP" else {
            throw failure("生成未完了・利用不可。finishReason=\(finish)")
        }
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        var answer = parts.filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip only an enclosing fence. Never repair malformed coordinates/JSON.
        if answer.hasPrefix("```json"), answer.hasSuffix("```") {
            answer = String(answer.dropFirst(7).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if answer.hasPrefix("```"), answer.hasSuffix("```"), answer.count >= 6 {
            answer = String(answer.dropFirst(3).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !answer.isEmpty else { throw failure("本文なし。finishReason=\(finish)") }
        let decision: Decision
        do {
            decision = try JSONDecoder().decode(Decision.self, from: Data(answer.utf8))
        } catch {
            // Do not print a truncated body: it looks like model-side truncation.
            throw failure("JSONまたは項目の型が不正。finishReason=\(finish) / 本文\(answer.count)文字")
        }
        func coordinate(_ value: Double?) -> Bool {
            guard let value else { return false }
            return value.isFinite && (0...1000).contains(value)
        }
        switch decision.action {
        case "tap":
            guard coordinate(decision.x), coordinate(decision.y) else { throw failure("tapの座標が欠落または範囲外") }
        case "swipe":
            guard [decision.x, decision.y, decision.x2, decision.y2].allSatisfy(coordinate) else {
                throw failure("swipeの座標が欠落または範囲外")
            }
        case "wait":
            guard let seconds = decision.seconds, seconds.isFinite, (1...10).contains(seconds) else {
                throw failure("waitの秒数が欠落または範囲外")
            }
        case "done": break
        default: throw failure("未対応のaction")
        }
        return (decision, tokens)
    }
}
