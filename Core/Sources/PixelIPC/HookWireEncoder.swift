import Foundation

/// Builds the envelope line `pixel-hook` sends (`HookWire`). Pure: every input is passed in.
public enum HookWireEncoder {
    /// The envelope for `stdin`, the (possibly capped) hook JSON Claude Code wrote, terminated by "\n".
    ///
    /// - `stdinLength`: bytes actually read, reported as `len` when the input is not a JSON object.
    /// - Empty `agent` and `token` are omitted, as is a `nil` `claudePID`.
    ///
    /// The fields in `HookWire.truncatedFields` are cut to `HookWire.truncateFieldBytes`: strings on a character
    /// boundary, other values (such as a `tool_response` object) replaced by the head of their JSON text.
    /// If the line would still exceed `HookWire.maxMessageBytes`, every long string is cut, then nested values
    /// are dropped (top-level scalars such as `session_id` stay). Cut or dropped fields are listed in `truncated`.
    ///
    /// When nothing needs cutting, `hook` is the input text itself: key order (which the app's "first string value"
    /// summary relies on) and number literals survive. Lone UTF-16 surrogate escapes, which Claude Code writes when
    /// it cuts a string inside an emoji, become U+FFFD instead of making the whole event unreadable, and so does
    /// invalid UTF-8.
    public static func envelope(stdin: Data, stdinLength: Int, agent: String?, token: String?,
                                claudePID: Int32?, timestampNs: UInt64) -> Data {
        var root: [String: Any] = [
            HookWire.keyVersion: HookWire.version,
            HookWire.keyTimestamp: NSNumber(value: timestampNs),
        ]
        if let agent, !agent.isEmpty { root[HookWire.keyAgent] = agent }
        if let token, !token.isEmpty { root[HookWire.keyToken] = token }
        if let claudePID { root[HookWire.keyClaudePID] = Int(claudePID) }

        guard let (text, parsed) = parseHook(stdin) else {
            return unparsedLine(root, stdinLength: stdinLength)
        }
        var hook = parsed

        var truncated: [String] = []
        if let prompt = hook["prompt"] as? String {
            root[HookWire.keyPromptLength] = prompt.count
        }
        for field in HookWire.truncatedFields {
            guard let value = hook[field], let cut = clipField(value) else { continue }
            hook[field] = cut
            truncated.append(field)
        }

        if truncated.isEmpty, let data = splicedLine(root, hookText: text) { return data }
        // Size guard: the server drops anything over `maxMessageBytes`, which would lose the event.
        if let data = fittingLine(root, hook: hook, truncated: truncated) { return data }
        clipAllStrings(&hook, &truncated)
        if let data = fittingLine(root, hook: hook, truncated: truncated) { return data }
        keepScalarsOnly(&hook, &truncated)
        if let data = fittingLine(root, hook: hook, truncated: truncated) { return data }
        return unparsedLine(root, stdinLength: stdinLength)
    }

    /// `s` cut to at most `maxBytes` UTF-8 bytes, on a character boundary; `nil` when it already fits.
    public static func clip(_ s: String, maxBytes: Int) -> String? {
        var s = s
        s.makeContiguousUTF8()
        guard s.utf8.count > maxBytes else { return nil }
        var end = s.startIndex
        var used = 0
        while end < s.endIndex {
            let next = s.index(after: end)
            let size = s.utf8.distance(from: end, to: next)
            if used + size > maxBytes { break }
            used += size
            end = next
        }
        return String(s[..<end])
    }

    /// `hook_event_name` of a hook input, read as leniently as `envelope` reads it; `nil` when there is none.
    public static func eventName(stdin: Data) -> String? {
        parseHook(stdin)?.object["hook_event_name"] as? String
    }

    /// `data` with every lone UTF-16 surrogate escape (`\uD83D` not followed by a low surrogate escape, or a low
    /// one alone) replaced by `\uFFFD`, which has the same length. Strict JSON parsers reject lone surrogates,
    /// which JavaScript's `JSON.stringify` writes for a string cut between the two halves of an emoji.
    public static func replacingLoneSurrogateEscapes(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        var changed = false
        var inString = false
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            guard inString else {
                if byte == ascii("\"") { inString = true }
                i += 1
                continue
            }
            if byte == ascii("\"") {
                inString = false
                i += 1
                continue
            }
            guard byte == ascii("\\"), i + 1 < bytes.count else {
                i += 1
                continue
            }
            guard bytes[i + 1] == ascii("u"), let unit = hex4(bytes, at: i + 2) else {
                i += 2  // any other escape, including an escaped backslash
                continue
            }
            switch unit {
            case 0xD800...0xDBFF:
                if i + 12 <= bytes.count, bytes[i + 6] == ascii("\\"), bytes[i + 7] == ascii("u"),
                   let low = hex4(bytes, at: i + 8), (0xDC00...0xDFFF).contains(low) {
                    i += 12
                    continue
                }
                fallthrough
            case 0xDC00...0xDFFF:
                bytes.replaceSubrange((i + 2)..<(i + 6), with: Array("FFFD".utf8))
                changed = true
            default:
                break
            }
            i += 6
        }
        return changed ? Data(bytes) : data
    }

    // MARK: - Helpers

    /// The hook object and the UTF-8 JSON text it was read from (repaired if needed), or `nil` for input that is
    /// not a JSON object.
    private static func parseHook(_ stdin: Data) -> (text: Data, object: [String: Any])? {
        let text = replacingLoneSurrogateEscapes(stdin)
        if let object = (try? JSONSerialization.jsonObject(with: text)) as? [String: Any] {
            return (text, object)
        }
        // Invalid UTF-8 (a strict decoder rejects the whole document): repair it with U+FFFD and try again.
        let repaired = Data(String(decoding: text, as: UTF8.self).utf8)
        guard repaired != text,
              let object = (try? JSONSerialization.jsonObject(with: repaired)) as? [String: Any] else { return nil }
        return (repaired, object)
    }

    /// The envelope with the hook's own JSON text spliced in as `hook`, or `nil` when it would not fit or the text
    /// is not plain UTF-8 JSON (JSONSerialization also reads UTF-16 and UTF-32).
    private static func splicedLine(_ root: [String: Any], hookText: Data) -> Data? {
        var bytes = [UInt8](hookText)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        while let last = bytes.last, whitespace.contains(last) { bytes.removeLast() }
        guard let start = bytes.firstIndex(where: { !whitespace.contains($0) }), bytes[start] == ascii("{"),
              bytes.last == ascii("}"), String(bytes: bytes[start...], encoding: .utf8) != nil,
              var head = try? JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes]),
              head.last == ascii("}") else { return nil }
        head.removeLast()
        var line = head
        line.append(contentsOf: ",\"\(HookWire.keyHook)\":".utf8)
        // Outside strings a raw line break is only whitespace (inside, JSON forbids it): the wire is one line.
        line.append(contentsOf: bytes[start...].map { $0 == 0x0A || $0 == 0x0D ? 0x20 : $0 })
        line.append(contentsOf: [ascii("}"), 0x0A])
        return line.count <= HookWire.maxMessageBytes + 1 ? line : nil
    }

    private static func ascii(_ character: Unicode.Scalar) -> UInt8 {
        UInt8(ascii: character)
    }

    /// The value of the four hex digits at `index`, if there are four.
    private static func hex4(_ bytes: [UInt8], at index: Int) -> UInt16? {
        guard index + 4 <= bytes.count else { return nil }
        var value: UInt16 = 0
        for byte in bytes[index..<(index + 4)] {
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: return nil
            }
            value = value << 4 | UInt16(digit)
        }
        return value
    }

    private static func fittingLine(_ root: [String: Any], hook: [String: Any], truncated: [String]) -> Data? {
        var envelope = root
        envelope[HookWire.keyHook] = hook
        if !truncated.isEmpty { envelope[HookWire.keyTruncated] = truncated }
        guard let data = line(envelope), data.count <= HookWire.maxMessageBytes + 1 else { return nil }
        return data
    }

    /// `hook` = `{"_unparsed": true, "len": n}`: the input was not a JSON object (or could not be made to fit).
    private static func unparsedLine(_ root: [String: Any], stdinLength: Int) -> Data {
        var envelope = root
        envelope[HookWire.keyHook] = ["_unparsed": true, "len": stdinLength] as [String: Any]
        return line(envelope)
            ?? Data("{\"\(HookWire.keyVersion)\":\(HookWire.version),\"\(HookWire.keyHook)\":{\"_unparsed\":true,\"len\":\(stdinLength)}}\n".utf8)
    }

    private static func line(_ object: [String: Any]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            return nil
        }
        data.append(0x0A)
        return data
    }

    /// The cut replacement for one of `HookWire.truncatedFields`, or `nil` when it is small enough.
    private static func clipField(_ value: Any) -> Any? {
        if let text = value as? String {
            return clip(text, maxBytes: HookWire.truncateFieldBytes)
        }
        guard value is [Any] || value is [String: Any],
              let json = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]),
              json.count > HookWire.truncateFieldBytes else { return nil }
        return utf8Prefix(json, maxBytes: HookWire.truncateFieldBytes)
    }

    /// The longest prefix of UTF-8 `data` within `maxBytes` that does not split a scalar.
    private static func utf8Prefix(_ data: Data, maxBytes: Int) -> String {
        var end = min(maxBytes, data.count)
        let start = data.startIndex
        // 0b10xxxxxx: continuation byte, not a place to cut.
        while end > 0, end < data.count, data[start + end] & 0xC0 == 0x80 { end -= 1 }
        return String(decoding: data[start..<(start + end)], as: UTF8.self)
    }

    /// Shrink step 1: cuts every string longer than `truncateFieldBytes`, at any depth.
    private static func clipAllStrings(_ hook: inout [String: Any], _ truncated: inout [String]) {
        for (key, value) in hook {
            var changed = false
            let cut = clipDeep(value, changed: &changed)
            if changed {
                hook[key] = cut
                if !truncated.contains(key) { truncated.append(key) }
            }
        }
    }

    private static func clipDeep(_ value: Any, changed: inout Bool) -> Any {
        if let text = value as? String {
            guard let cut = clip(text, maxBytes: HookWire.truncateFieldBytes) else { return text }
            changed = true
            return cut
        }
        if let array = value as? [Any] {
            return array.map { clipDeep($0, changed: &changed) }
        }
        if let object = value as? [String: Any] {
            return object.mapValues { clipDeep($0, changed: &changed) }
        }
        return value
    }

    /// Shrink step 2: drops nested arrays and objects; scalars (`session_id`, `hook_event_name`,
    /// `tool_use_id`…) stay.
    private static func keepScalarsOnly(_ hook: inout [String: Any], _ truncated: inout [String]) {
        for (key, value) in hook where value is [Any] || value is [String: Any] {
            hook[key] = nil
            if !truncated.contains(key) { truncated.append(key) }
        }
    }
}
