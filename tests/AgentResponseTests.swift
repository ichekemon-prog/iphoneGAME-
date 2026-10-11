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
        precondition(AgentResponse.thinkingLevel(for: "gemini-3.5-flash-lite") == "MINIMAL")
        precondition(AgentResponse.thinkingLevel(for: "gemini-3.1-flash-lite") == "MINIMAL")
        precondition(AgentResponse.thinkingLevel(for: "gemini-3.5-flash") == "LOW")
        precondition(AgentResponse.thinkingLevel(for: "gemini-2.5-flash") == nil)
        let fast = AgentResponse.generationConfig(model: "gemini-3.5-flash-lite", detail: .medium, thinking: true)
        precondition(fast["mediaResolution"] as? String == "MEDIA_RESOLUTION_MEDIUM")
        precondition((fast["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String == "MINIMAL")
        _ = try JSONSerialization.data(withJSONObject: fast)
        let plain = AgentResponse.generationConfig(model: "gemini-3.5-flash-lite", detail: .low, thinking: false)
        precondition(fast["temperature"] == nil && fast["maxOutputTokens"] as? Int == 512)
        precondition(AgentResponse.generationConfig(model: "gemini-2.5-flash", detail: .low, thinking: true)["temperature"] as? Double == 0.2)
        precondition(plain["thinkingConfig"] == nil && plain["mediaResolution"] as? String == "MEDIA_RESOLUTION_LOW")
        precondition(AgentResponse.isTransient(status: 503) && !AgentResponse.isTransient(status: 429))
        let used = AgentResponse.usage(["usageMetadata": ["promptTokenCount": 700, "candidatesTokenCount": 40,
                                                          "thoughtsTokenCount": 12, "totalTokenCount": 752]])
        precondition(used.prompt == 700 && used.output == 40 && used.thoughts == 12 && used.total == 752)
        let words = ScreenText.quickWords(in: """
        1. ホーム画面で「クエスト」を押す。
        2. 「追憶の書庫」を開き、難易度「究極」のクエストを1つ選ぶ。
        3. 「ソロ」を押す。
        5. 編成画面で「出撃」を押す。
        12. 「オーブ」は絶対に押さない。
        13. 「ガチャ」を押す。
        14. 「ＯＫ」をタップ
        """)
        precondition(words == ["クエスト", "追憶の書庫", "究極", "ソロ", "出撃", "ＯＫ"], "\(words)")
        precondition(ScreenText.normalize("Ｏ Ｋ") == "ok")
        let solo = TextBox(text: "ソロ", x: 300, y: 700, width: 80, height: 30)
        let sortie = TextBox(text: "出撃!", x: 500, y: 880, width: 120, height: 40)
        let long = TextBox(text: "出撃する前に編成を確認", x: 500, y: 200, width: 400, height: 30)
        precondition(ScreenText.matches(sortie, "出撃") && !ScreenText.matches(long, "出撃"))
        precondition(ScreenText.pick(words: words, boxes: [solo, sortie, long], after: nil, blocked: [])?.index == 3)
        precondition(ScreenText.pick(words: words, boxes: [solo, sortie], after: 3, blocked: [])?.index == 4)
        precondition(ScreenText.pick(words: words, boxes: [solo, sortie], after: 3, blocked: ["出撃"]) == nil)
        precondition(ScreenText.pick(words: words, boxes: [solo, solo], after: nil, blocked: []) == nil)
        precondition(ScreenText.pick(words: words, boxes: [long], after: nil, blocked: []) == nil)
        let title = TextBox(text: "追憶の書庫", x: 500, y: 80, width: 200, height: 40)
        precondition(ScreenText.pick(words: words, boxes: [title, solo], after: 2, blocked: [])?.index == 3)
        precondition(ScreenText.pick(words: words, boxes: [title], after: 2, blocked: []) == nil)
        precondition(ScreenText.pick(words: words, boxes: [title], after: nil, blocked: [])?.index == 1)
        precondition(ScreenText.pick(words: words, boxes: [title], after: nil, blocked: [], dead: [title]) == nil)
        precondition(ScreenText.pick(words: words, boxes: [title], after: 5, blocked: [])?.index == 1)
        precondition(ScreenText.word(at: 505, 875, words: words, boxes: [solo, sortie]) == 4)
        precondition(ScreenText.word(at: 100, 100, words: words, boxes: [solo, sortie]) == nil)
        precondition(ScreenText.risky([TextBox(text: "コンティニューしますか？", x: 0, y: 0, width: 1, height: 1)]))
        precondition(!ScreenText.risky([solo, sortie]))
        let f = ScreenText.flick(angle: Double.pi / 2)
        precondition(f.x == 500 && f.y == 550 && f.y2 == 810 && abs(f.x2 - 500) < 0.001)
        let edge = ScreenText.flick(angle: Double.pi * 1.5, length: 900)
        precondition(edge.y2 == 120)
        precondition(ScreenText.describe([sortie, solo]) == "ソロ(300,700) 出撃!(500,880)")
        precondition(ScreenText.difference([0, 10], [0, 20]) == 5 && ScreenText.difference([], []) == 255)
        print("Agent response tests passed")
    }
}
