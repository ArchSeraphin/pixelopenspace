import Foundation

/// JSON value used to read hook input tolerantly, without `JSONSerialization`'s platform differences.
/// Objects keep document order (the "first string value" summary rule depends on it) and numbers keep
/// their literal text, so 64-bit integers such as `ts_ns` stay exact.
enum HookJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    /// The number exactly as written in the document.
    case number(String)
    case string(String)
    case array([HookJSON])
    case object(HookJSONObject)

    struct SyntaxError: Error, Equatable, Sendable {
        /// Byte offset where parsing failed.
        var offset: Int
    }

    /// Containers nested deeper than this are skipped (read as `null`) instead of being parsed recursively,
    /// which bounds stack use whatever the input.
    static let defaultMaxDepth = 64

    /// Parses one JSON document (RFC 8259). A UTF-8 BOM and surrounding whitespace are allowed;
    /// invalid UTF-8 inside strings is repaired with U+FFFD.
    static func parse(_ data: Data, maxDepth: Int = defaultMaxDepth) throws(SyntaxError) -> HookJSON {
        var parser = HookJSONParser(bytes: [UInt8](data), maxDepth: maxDepth)
        return try parser.parseDocument()
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [HookJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: HookJSONObject? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Integral numbers only (`42`, `4.2e1`); nil for fractions and out-of-range values.
    var int64Value: Int64? {
        guard case .number(let literal) = self else { return nil }
        if let exact = Int64(literal) { return exact }
        guard let double = Double(literal), double.isFinite else { return nil }
        return Int64(exactly: double)
    }

    var uint64Value: UInt64? {
        guard case .number(let literal) = self else { return nil }
        if let exact = UInt64(literal) { return exact }
        guard let double = Double(literal), double.isFinite else { return nil }
        return UInt64(exactly: double)
    }

    var intValue: Int? { int64Value.flatMap { Int(exactly: $0) } }

    /// Member lookup; nil when this is not an object or has no such key.
    subscript(key: String) -> HookJSON? { objectValue?[key] }
}

/// A JSON object that remembers key order. A repeated key keeps its first position and its last value.
struct HookJSONObject: Equatable, Sendable {
    private(set) var keys: [String] = []
    private var storage: [String: HookJSON] = [:]

    init() {}

    subscript(key: String) -> HookJSON? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    /// Values in document order.
    var values: [HookJSON] { keys.compactMap { storage[$0] } }

    var count: Int { keys.count }
}

/// Recursive-descent parser over UTF-8 bytes.
private struct HookJSONParser {
    let bytes: [UInt8]
    let maxDepth: Int
    var index = 0

    init(bytes: [UInt8], maxDepth: Int) {
        self.bytes = bytes
        self.maxDepth = max(1, maxDepth)
    }

    mutating func parseDocument() throws(HookJSON.SyntaxError) -> HookJSON {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw failure() }
        return value
    }

    private func failure() -> HookJSON.SyntaxError { HookJSON.SyntaxError(offset: index) }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case JSONByte.space, JSONByte.tab, JSONByte.lineFeed, JSONByte.carriageReturn: index += 1
            default: return
            }
        }
    }

    private mutating func parseValue(depth: Int) throws(HookJSON.SyntaxError) -> HookJSON {
        guard index < bytes.count else { throw failure() }
        switch bytes[index] {
        case JSONByte.openBrace, JSONByte.openBracket:
            guard depth < maxDepth else {
                try skipContainer()
                return .null
            }
            if bytes[index] == JSONByte.openBrace { return try parseObject(depth: depth + 1) }
            return try parseArray(depth: depth + 1)
        case JSONByte.quote:
            return .string(try parseString())
        case UInt8(ascii: "t"):
            try consume("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try consume("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try consume("null")
            return .null
        case JSONByte.minus, JSONByte.digitZero ... JSONByte.digitNine:
            return .number(try parseNumber())
        default:
            throw failure()
        }
    }

    private mutating func parseObject(depth: Int) throws(HookJSON.SyntaxError) -> HookJSON {
        index += 1
        var object = HookJSONObject()
        skipWhitespace()
        if index < bytes.count, bytes[index] == JSONByte.closeBrace {
            index += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == JSONByte.quote else { throw failure() }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == JSONByte.colon else { throw failure() }
            index += 1
            skipWhitespace()
            object[key] = try parseValue(depth: depth)
            skipWhitespace()
            guard index < bytes.count else { throw failure() }
            switch bytes[index] {
            case JSONByte.comma:
                index += 1
            case JSONByte.closeBrace:
                index += 1
                return .object(object)
            default:
                throw failure()
            }
        }
    }

    private mutating func parseArray(depth: Int) throws(HookJSON.SyntaxError) -> HookJSON {
        index += 1
        var elements: [HookJSON] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == JSONByte.closeBracket {
            index += 1
            return .array(elements)
        }
        while true {
            skipWhitespace()
            elements.append(try parseValue(depth: depth))
            skipWhitespace()
            guard index < bytes.count else { throw failure() }
            switch bytes[index] {
            case JSONByte.comma:
                index += 1
            case JSONByte.closeBracket:
                index += 1
                return .array(elements)
            default:
                throw failure()
            }
        }
    }

    private mutating func parseString() throws(HookJSON.SyntaxError) -> String {
        index += 1
        let start = index
        // Fast path: most strings have no escape sequence.
        while index < bytes.count {
            switch bytes[index] {
            case JSONByte.quote:
                let value = String(decoding: bytes[start..<index], as: UTF8.self)
                index += 1
                return value
            case JSONByte.backslash:
                return try parseEscapedString(prefix: bytes[start..<index])
            default:
                index += 1
            }
        }
        throw failure()
    }

    private mutating func parseEscapedString(prefix: ArraySlice<UInt8>) throws(HookJSON.SyntaxError) -> String {
        var buffer = [UInt8](prefix)
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case JSONByte.quote:
                return String(decoding: buffer, as: UTF8.self)
            case JSONByte.backslash:
                guard index < bytes.count else { throw failure() }
                let escape = bytes[index]
                index += 1
                switch escape {
                case JSONByte.quote, JSONByte.backslash, JSONByte.slash: buffer.append(escape)
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(JSONByte.lineFeed)
                case UInt8(ascii: "r"): buffer.append(JSONByte.carriageReturn)
                case UInt8(ascii: "t"): buffer.append(JSONByte.tab)
                case UInt8(ascii: "u"):
                    let scalar = try parseUnicodeEscape()
                    UTF8.encode(scalar) { buffer.append($0) }
                default:
                    throw failure()
                }
            default:
                buffer.append(byte)
            }
        }
        throw failure()
    }

    /// Reads the `XXXX` of `\uXXXX` (the `\u` is consumed), joining a UTF-16 surrogate pair when one follows.
    /// A lone surrogate becomes U+FFFD.
    private mutating func parseUnicodeEscape() throws(HookJSON.SyntaxError) -> Unicode.Scalar {
        let unit = try parseHex4()
        switch unit {
        case 0xD800...0xDBFF:
            if index + 6 <= bytes.count, bytes[index] == JSONByte.backslash, bytes[index + 1] == UInt8(ascii: "u") {
                let save = index
                index += 2
                let low = try parseHex4()
                if (0xDC00...0xDFFF).contains(low) {
                    let value = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                    return Unicode.Scalar(value) ?? "\u{FFFD}"
                }
                index = save
            }
            return "\u{FFFD}"
        case 0xDC00...0xDFFF:
            return "\u{FFFD}"
        default:
            return Unicode.Scalar(unit) ?? "\u{FFFD}"
        }
    }

    private mutating func parseHex4() throws(HookJSON.SyntaxError) -> UInt16 {
        guard index + 4 <= bytes.count else { throw failure() }
        var value: UInt16 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt8
            switch byte {
            case JSONByte.digitZero ... JSONByte.digitNine: digit = byte - JSONByte.digitZero
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: throw failure()
            }
            value = value << 4 | UInt16(digit)
            index += 1
        }
        return value
    }

    /// Validates the RFC 8259 number grammar and returns the literal.
    private mutating func parseNumber() throws(HookJSON.SyntaxError) -> String {
        let start = index
        if bytes[index] == JSONByte.minus { index += 1 }
        guard index < bytes.count, JSONByte.isDigit(bytes[index]) else { throw failure() }
        if bytes[index] == JSONByte.digitZero {
            index += 1
        } else {
            skipDigits()
        }
        if index < bytes.count, bytes[index] == JSONByte.dot {
            index += 1
            guard index < bytes.count, JSONByte.isDigit(bytes[index]) else { throw failure() }
            skipDigits()
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == JSONByte.plus || bytes[index] == JSONByte.minus { index += 1 }
            guard index < bytes.count, JSONByte.isDigit(bytes[index]) else { throw failure() }
            skipDigits()
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func skipDigits() {
        while index < bytes.count, JSONByte.isDigit(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ literal: StaticString) throws(HookJSON.SyntaxError) {
        let count = literal.utf8CodeUnitCount
        guard index + count <= bytes.count else { throw failure() }
        let matches = literal.withUTF8Buffer { expected in
            expected.elementsEqual(bytes[index..<(index + count)])
        }
        guard matches else { throw failure() }
        index += count
    }

    /// Skips a container nested too deep to build, iteratively. Its content is only checked for balance.
    private mutating func skipContainer() throws(HookJSON.SyntaxError) {
        var depth = 0
        while index < bytes.count {
            switch bytes[index] {
            case JSONByte.openBrace, JSONByte.openBracket:
                depth += 1
                index += 1
            case JSONByte.closeBrace, JSONByte.closeBracket:
                depth -= 1
                index += 1
                if depth == 0 { return }
            case JSONByte.quote:
                try skipString()
            default:
                index += 1
            }
        }
        throw failure()
    }

    private mutating func skipString() throws(HookJSON.SyntaxError) {
        index += 1
        while index < bytes.count {
            switch bytes[index] {
            case JSONByte.quote:
                index += 1
                return
            case JSONByte.backslash:
                index += 2
            default:
                index += 1
            }
        }
        throw failure()
    }
}

private enum JSONByte {
    static let space = UInt8(ascii: " ")
    static let tab = UInt8(ascii: "\t")
    static let lineFeed = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let openBrace = UInt8(ascii: "{")
    static let closeBrace = UInt8(ascii: "}")
    static let openBracket = UInt8(ascii: "[")
    static let closeBracket = UInt8(ascii: "]")
    static let quote = UInt8(ascii: "\"")
    static let backslash = UInt8(ascii: "\\")
    static let slash = UInt8(ascii: "/")
    static let colon = UInt8(ascii: ":")
    static let comma = UInt8(ascii: ",")
    static let minus = UInt8(ascii: "-")
    static let plus = UInt8(ascii: "+")
    static let dot = UInt8(ascii: ".")
    static let digitZero = UInt8(ascii: "0")
    static let digitNine = UInt8(ascii: "9")

    static func isDigit(_ byte: UInt8) -> Bool { byte >= digitZero && byte <= digitNine }
}
