import Foundation

/// A `major.minor.patch` version, as printed by `claude --version`
/// (https://code.claude.com/docs/en/cli-reference.md). Pre-release and build suffixes are ignored.
public struct SemVer: Comparable, Hashable, Sendable, CustomStringConvertible, Codable {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// The first `X.Y.Z` in the text: accepts "2.1.280 (Claude Code)", "claude 2.1.280", "v2.1.280".
    public init?(parsing text: String) {
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let startsNumber = SemVer.isDigit(scalars[i]) && (i == 0 || !SemVer.isDigit(scalars[i - 1]) && scalars[i - 1] != ".")
            if startsNumber, let (parts, _) = SemVer.readComponents(scalars, from: i), parts.count == 3 {
                self.init(parts[0], parts[1], parts[2])
                return
            }
            i += 1
        }
        return nil
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// Encoded as its text, "2.1.280".
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = SemVer(parsing: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a version: \(text)"))
        }
        self = version
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    private static func isDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 48 && s.value <= 57 }

    /// Up to three dot-separated numbers starting at `start`; the index after the last digit read.
    private static func readComponents(_ scalars: [Unicode.Scalar], from start: Int) -> ([Int], Int)? {
        var parts: [Int] = []
        var i = start
        while parts.count < 3 {
            var value = 0
            var digits = 0
            while i < scalars.count, isDigit(scalars[i]), digits < 9 {
                value = value * 10 + Int(scalars[i].value - 48)
                digits += 1
                i += 1
            }
            guard digits > 0 else { return nil }
            parts.append(value)
            guard parts.count < 3, i + 1 < scalars.count, scalars[i] == ".", isDigit(scalars[i + 1]) else { break }
            i += 1
        }
        // "2.1.280.4" is not a semantic version.
        if i < scalars.count, scalars[i] == ".", i + 1 < scalars.count, isDigit(scalars[i + 1]) { return nil }
        return (parts, i)
    }
}

public enum ClaudeRequirements {
    /// Decision 20: `prompt_id` / `last_assistant_message` need v2.1.196, the `quota_auto_resume_*`
    /// notification types v2.1.234 (https://code.claude.com/docs/en/hooks.md). Below: warning, degraded features.
    public static let minimumVersion = SemVer(2, 1, 234)
}
