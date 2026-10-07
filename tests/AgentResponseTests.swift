import Foundation

@main
struct AgentResponseTests {
    static func envelope(_ text: String, finish: String = "STOP") -> [String: Any] {
        ["candidates": [["finishReason": finish, "content": ["parts": [["text": text]]]]],
         "usageMetadata": ["totalTokenCount": 2539]]
    }

    static func expectFailure(_ json: [String: Any], contains: String) {
        do {
            _ = try AgentResponse.decode(json)
            fatalError("Invalid action accepted")
        } catch let BrainError.response(message, tokens) {
            precondition(message.contains(contains), message)
            precondition(tokens == 2539, "Lost usage on failure")
        } catch { fatalError("Unexpected error: \(error)") }
    }

    static func main() throws {
        let tap = #"{"action":"tap","x":125,"y":545}"#
        let (decision, tokens) = try AgentResponse.decode(envelope(tap))
        precondition(decision.x == 125 && decision.y == 545 && tokens == 2539)
        expectFailure(envelope(#"{"action":"tap","x":125,y:545}"#), contains: "JSON")
        expectFailure(envelope(#"{"action":"tap","x":125}"#), contains: "座標")
        expectFailure(envelope(#"{"action":"tap","x":"125","y":545}"#), contains: "型")
        expectFailure(envelope(#"{"action":"tap","x":1001,"y":545}"#), contains: "範囲外")
        expectFailure(envelope(#"{"action":"swipe","x":1,"y":2,"x2":3}"#), contains: "座標")
        expectFailure(envelope(#"{"action":"wait","seconds":0}"#), contains: "秒数")
        expectFailure(envelope(#"{"action":"purchase"}"#), contains: "action")
        expectFailure(envelope(tap, finish: "MAX_TOKENS"), contains: "MAX_TOKENS")
        expectFailure(envelope(tap, finish: "SAFETY"), contains: "SAFETY")
        var split = envelope("")
        split["candidates"] = [["finishReason": "STOP", "content": ["parts": [
            ["thought": true, "text": "ignored"],
            ["text": #"{"action":"tap","x":125,"#],
            ["text": #""y":545}"#],
        ]]]]
        let (joined, _) = try AgentResponse.decode(split)
        precondition(joined.y == 545)
        let (fenced, _) = try AgentResponse.decode(envelope("```json\n" + tap + "\n```"))
        precondition(fenced.action == "tap")
        _ = try AgentResponse.decode(envelope(#"{"action":"swipe","x":1,"y":2,"x2":3,"y2":4}"#))
        _ = try AgentResponse.decode(envelope(#"{"action":"wait","seconds":2}"#))
        _ = try AgentResponse.decode(envelope(#"{"action":"done"}"#))
        var noUsage = envelope(tap)
        noUsage.removeValue(forKey: "usageMetadata")
        let (_, missingUsage) = try AgentResponse.decode(noUsage)
        precondition(missingUsage == nil)
        _ = try JSONSerialization.data(withJSONObject: AgentResponse.generationConfig)
        print("Agent response tests passed")
    }
}
