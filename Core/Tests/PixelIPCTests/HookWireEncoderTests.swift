import Foundation
import Testing
import PixelCore
import PixelIPC

@Suite struct HookWireEncoderTests {
    private func encode(_ hook: [String: Any], agent: String? = "A", token: String? = "T", claudePID: Int32? = 42) throws -> Data {
        let input = try JSONSerialization.data(withJSONObject: hook)
        return HookWireEncoder.envelope(stdin: input, stdinLength: input.count, agent: agent, token: token,
                                        claudePID: claudePID, timestampNs: 123_456_789)
    }

    private func decode(_ line: Data) throws -> (root: [String: Any], hook: [String: Any]) {
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        let root = try #require(try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        let hook = try #require(root[HookWire.keyHook] as? [String: Any])
        return (root, hook)
    }

    private let base: [String: Any] = [
        "session_id": "3f6c2a9e-8d41-4b7a-9c55-1e2f7a8b9c0d",
        "hook_event_name": "PreToolUse",
        "cwd": "/Users/seraphin/Projets/pixel demo",
        "tool_name": "Bash",
        "tool_input": ["command": "swift test"],
        "tool_use_id": "toolu_01",
    ]

    @Test func wrapsTheHookWithRoutingFields() throws {
        let (root, hook) = try decode(try encode(base))
        #expect(root[HookWire.keyVersion] as? Int == HookWire.version)
        #expect(root[HookWire.keyAgent] as? String == "A")
        #expect(root[HookWire.keyToken] as? String == "T")
        #expect(root[HookWire.keyClaudePID] as? Int == 42)
        #expect((root[HookWire.keyTimestamp] as? NSNumber)?.uint64Value == 123_456_789)
        #expect(root[HookWire.keyTruncated] == nil)
        #expect(root[HookWire.keyPromptLength] == nil)
        #expect(hook["session_id"] as? String == "3f6c2a9e-8d41-4b7a-9c55-1e2f7a8b9c0d")
        #expect(hook["cwd"] as? String == "/Users/seraphin/Projets/pixel demo")
        #expect((hook["tool_input"] as? [String: Any])?["command"] as? String == "swift test")
    }

    @Test func omitsMissingRoutingFields() throws {
        let (root, _) = try decode(try encode(base, agent: "", token: nil, claudePID: nil))
        #expect(root[HookWire.keyAgent] == nil)
        #expect(root[HookWire.keyToken] == nil)
        #expect(root[HookWire.keyClaudePID] == nil)
    }

    @Test func invalidOrNonObjectInputIsReportedAsUnparsed() throws {
        for input in ["not json", "[1, 2]", "\"text\"", ""] {
            let data = Data(input.utf8)
            let line = HookWireEncoder.envelope(stdin: data, stdinLength: 5_000_000, agent: "A", token: nil,
                                                claudePID: 7, timestampNs: 1)
            let (root, hook) = try decode(line)
            #expect(hook["_unparsed"] as? Bool == true)
            #expect(hook["len"] as? Int == 5_000_000)
            #expect(root[HookWire.keyClaudePID] as? Int == 7)
        }
    }

    @Test func largeFieldsAreCutOnCharacterBoundaries() throws {
        var hook = base
        hook["hook_event_name"] = "UserPromptSubmit"
        hook["prompt"] = String(repeating: "é", count: 5_000)
        hook["last_assistant_message"] = String(repeating: "👨‍👩‍👧", count: 1_000)
        hook["assistant_message"] = "short"
        let (root, decoded) = try decode(try encode(hook))

        let prompt = try #require(decoded["prompt"] as? String)
        #expect(prompt == String(repeating: "é", count: HookWire.truncateFieldBytes / 2))
        #expect(root[HookWire.keyPromptLength] as? Int == 5_000)

        let message = try #require(decoded["last_assistant_message"] as? String)
        let family = "👨‍👩‍👧"
        #expect(message.utf8.count <= HookWire.truncateFieldBytes)
        #expect(message == String(repeating: family, count: HookWire.truncateFieldBytes / family.utf8.count))
        #expect(decoded["assistant_message"] as? String == "short")
        #expect(Set(root[HookWire.keyTruncated] as? [String] ?? []) == ["prompt", "last_assistant_message"])
    }

    @Test func shortPromptKeepsItsLength() throws {
        var hook = base
        hook["prompt"] = "Salut 👋"
        let (root, decoded) = try decode(try encode(hook))
        #expect(decoded["prompt"] as? String == "Salut 👋")
        #expect(root[HookWire.keyPromptLength] as? Int == 7)
        #expect(root[HookWire.keyTruncated] == nil)
    }

    @Test func largeNonStringFieldBecomesTheHeadOfItsJSON() throws {
        var hook = base
        hook["hook_event_name"] = "PostToolUse"
        hook["tool_response"] = ["stdout": String(repeating: "ligne à lire\n", count: 2_000), "interrupted": false] as [String: Any]
        hook["tool_output"] = ["small": true]
        let (root, decoded) = try decode(try encode(hook))

        let response = try #require(decoded["tool_response"] as? String)
        #expect(response.hasPrefix("{"))
        #expect(response.utf8.count <= HookWire.truncateFieldBytes)
        #expect(response.utf8.count > HookWire.truncateFieldBytes - 4)
        #expect((decoded["tool_output"] as? [String: Any])?["small"] as? Bool == true)
        #expect(root[HookWire.keyTruncated] as? [String] == ["tool_response"])
    }

    @Test func envelopeAlwaysFitsTheServerLimit() throws {
        // Unlisted but huge: a Write tool's content.
        var hook = base
        hook["tool_name"] = "Write"
        hook["tool_input"] = ["file_path": "/tmp/big.txt", "content": String(repeating: "a", count: 3_000_000)]
        let line = try encode(hook)
        #expect(line.count <= HookWire.maxMessageBytes + 1)
        let (root, decoded) = try decode(line)
        let content = try #require((decoded["tool_input"] as? [String: Any])?["content"] as? String)
        #expect(content.utf8.count == HookWire.truncateFieldBytes)
        #expect(root[HookWire.keyTruncated] as? [String] == ["tool_input"])
        #expect(decoded["tool_use_id"] as? String == "toolu_01")

        // Too many nested values even once strings are cut: nested values go, scalars stay.
        var crowded = base
        crowded["tool_input"] = (0..<400).map { _ in String(repeating: "b", count: 4_000) }
        let crowdedLine = try encode(crowded)
        #expect(crowdedLine.count <= HookWire.maxMessageBytes + 1)
        let (crowdedRoot, crowdedHook) = try decode(crowdedLine)
        #expect(crowdedHook["tool_input"] == nil)
        #expect(crowdedHook["session_id"] as? String == "3f6c2a9e-8d41-4b7a-9c55-1e2f7a8b9c0d")
        #expect(crowdedHook["tool_use_id"] as? String == "toolu_01")
        #expect(crowdedRoot[HookWire.keyTruncated] as? [String] == ["tool_input"])
    }

    private func encodeText(_ text: String) -> Data {
        let input = Data(text.utf8)
        return HookWireEncoder.envelope(stdin: input, stdinLength: input.count, agent: "A", token: "T", claudePID: 42,
                                        timestampNs: 1)
    }

    /// JavaScript's JSON.stringify writes a lone surrogate for a string cut inside an emoji; strict parsers
    /// (JSONSerialization on both platforms) reject the whole document.
    @Test func loneSurrogatesNoLongerLoseTheEvent() throws {
        let text = #"{"session_id":"s1","hook_event_name":"PostToolUse","tool_use_id":"toolu_1","#
            + #""tool_response":{"stdout":"ok \ud83d"},"error":"\udc00 fin","emoji":"\ud83d\ude00","#
            + #""twice":"\ud83d\ud83d\ude00","escaped":"\\ud83d"}"#
        let (root, hook) = try decode(encodeText(text))
        #expect(hook["_unparsed"] == nil)
        #expect(hook["session_id"] as? String == "s1")
        #expect(hook["hook_event_name"] as? String == "PostToolUse")
        #expect(hook["tool_use_id"] as? String == "toolu_1")
        #expect((hook["tool_response"] as? [String: Any])?["stdout"] as? String == "ok \u{FFFD}")
        #expect(hook["error"] as? String == "\u{FFFD} fin")
        #expect(hook["emoji"] as? String == "😀")
        #expect(hook["twice"] as? String == "\u{FFFD}😀")
        #expect(hook["escaped"] as? String == "\\ud83d")
        #expect(root[HookWire.keyTruncated] == nil)

        // Also when the field is cut.
        let long = #"{"session_id":"s1","hook_event_name":"PostToolUseFailure","error":""#
            + String(repeating: "é", count: 3_000) + #"\ud83d"}"#
        let (_, cut) = try decode(encodeText(long))
        #expect(cut["session_id"] as? String == "s1")
        #expect((cut["error"] as? String)?.hasSuffix("\u{FFFD}") == true)
    }

    @Test func loneSurrogateEscapesBecomeReplacementCharacters() {
        func fixed(_ text: String) -> String {
            String(decoding: HookWireEncoder.replacingLoneSurrogateEscapes(Data(text.utf8)), as: UTF8.self)
        }
        #expect(fixed(#"{"a":"\ud83d"}"#) == #"{"a":"\uFFFD"}"#)
        #expect(fixed(#"{"a":"\uDE00x"}"#) == #"{"a":"\uFFFDx"}"#)
        #expect(fixed(#"{"a":"\ud83d\ude00"}"#) == #"{"a":"\ud83d\ude00"}"#)
        #expect(fixed(#"{"a":"\ud83d\n\ude00"}"#) == #"{"a":"\uFFFD\n\uFFFD"}"#)
        #expect(fixed(#"{"a":"\\ud83d","b":"\"\ud800"}"#) == #"{"a":"\\ud83d","b":"\"\uFFFD"}"#)
        #expect(fixed(#"{"\ud83d":1}"#) == #"{"\uFFFD":1}"#)
        // Outside strings, or cut short: left alone (the parser decides).
        #expect(fixed(#"\ud83d {"a":"\ud8"#) == #"\ud83d {"a":"\ud8"#)
    }

    @Test func invalidUTF8IsRepaired() throws {
        var input = Data(#"{"session_id":"s1","hook_event_name":"Stop","last_assistant_message":"a"#.utf8)
        input.append(contentsOf: [0xFF, 0xC3])
        input.append(contentsOf: Array(#"b"}"#.utf8))
        let line = HookWireEncoder.envelope(stdin: input, stdinLength: input.count, agent: nil, token: nil,
                                            claudePID: nil, timestampNs: 1)
        let (_, hook) = try decode(line)
        #expect(hook["hook_event_name"] as? String == "Stop")
        #expect(hook["last_assistant_message"] as? String == "a\u{FFFD}\u{FFFD}b")
    }

    /// The app's "first string value of tool_input" summary and exact numbers need the hook text as written.
    @Test func hookTextKeepsItsKeyOrderAndNumbers() throws {
        let text = #"{"session_id":"s1","hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode","#
            + #""tool_input":{"zeta":"premier","alpha":"second"},"big":18446744073709551615,"url":"https://a/b"}"#
        let line = encodeText(text)
        #expect(String(decoding: line, as: UTF8.self).hasSuffix(#","hook":"# + text + "}\n"))
        let envelope = try HookDecoder.decodeEnvelope(line)
        #expect(envelope.event.payload == .permissionRequest(tool: "ExitPlanMode", toolUseID: nil, summary: "premier"))
        #expect(envelope.agentID == nil && envelope.token == "T" && envelope.claudePID == 42)
    }

    @Test func multiLineInputIsSentOnOneLine() throws {
        let text = "\u{FEFF}\n{\r\n  \"session_id\": \"s1\",\n  \"hook_event_name\": \"Stop\",\n  \"n\": [1,\n 2]\n}\n\n"
        let line = encodeText(text)
        let (_, hook) = try decode(line)
        #expect(hook["hook_event_name"] as? String == "Stop")
        #expect((hook["n"] as? [Any])?.count == 2)
    }

    @Test func clipRespectsTheByteBudget() {
        #expect(HookWireEncoder.clip("abc", maxBytes: 3) == nil)
        #expect(HookWireEncoder.clip("abcd", maxBytes: 3) == "abc")
        #expect(HookWireEncoder.clip("aé", maxBytes: 2) == "a")
        #expect(HookWireEncoder.clip("éé", maxBytes: 3) == "é")
        #expect(HookWireEncoder.clip("e\u{301}x", maxBytes: 2) == "")
        #expect(HookWireEncoder.clip("", maxBytes: 0) == nil)
    }
}
