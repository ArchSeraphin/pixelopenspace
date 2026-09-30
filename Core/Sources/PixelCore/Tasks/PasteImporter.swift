import Foundation

/// A post-it read from a pasted list, before it is created (C1).
public struct PastedCard: Equatable, Sendable {
    public var title: String
    public var details: String

    public init(title: String, details: String = "") {
        self.title = title
        self.details = details
    }
}

/// Turns a pasted list into post-its (proposal 3.5, "Import collé"). Pure.
///
/// - One card per line (LF, CRLF or CR); blank lines are ignored.
/// - A list marker is removed from a card's line: "-", "*", "•", a number of 1 to 9 digits followed by "." or ")",
///   then a checkbox "[ ]", "[x]" or "[X]", in any combination ("- [ ] A", "1. [x] B"). A marker counts only when a
///   blank or the end of the line follows it: "-v", "1.5 kg" and "*important*" stay as written. A line made of
///   markers only is ignored.
/// - An indented line (a tab, or at least 2 spaces) under a card is appended to its details, trimmed and joined
///   by "\n", as written (its own bullet included). Indentation shared by every line is ignored first, so a
///   list copied from an indented block reads like the same list flush left; an indented line with no card
///   above it starts a card.
public enum PasteImporter {
    static let bullets: Set<Character> = ["-", "*", "•"]
    static let checkboxes = ["[ ]", "[x]", "[X]"]
    static let maxNumberDigits = 9

    /// One card per line; bullets "-", "*", "•", "1.", "1)", "[ ]", "[x]", "- [ ]" removed; blank lines ignored;
    /// an indented line (tab or ≥ 2 spaces) under a card is appended to its details (joined by "\n").
    public static func cards(from text: String) -> [PastedCard] {
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        let margin = commonIndentation(lines).count
        var cards: [PastedCard] = []
        for line in lines {
            let body = line.dropFirst(margin)
            let content = String(body).trimmingCharacters(in: .whitespaces)
            if isIndented(body), !cards.isEmpty {
                let last = cards.count - 1
                cards[last].details += cards[last].details.isEmpty ? content : "\n" + content
                continue
            }
            let title = withoutMarkers(content[...])
            if !title.isEmpty { cards.append(PastedCard(title: title)) }
        }
        return cards
    }

    // MARK: - Indentation

    static func indentation(_ line: Substring) -> Substring {
        line.prefix(while: \.isWhitespace)
    }

    /// The longest run of blanks every line starts with.
    static func commonIndentation(_ lines: [Substring]) -> Substring {
        guard var common = lines.first.map(indentation) else { return "" }
        for line in lines.dropFirst() {
            let shared = zip(common, indentation(line)).prefix { $0 == $1 }.count
            common = common.prefix(shared)
        }
        return common
    }

    static func isIndented(_ line: Substring) -> Bool {
        let blanks = indentation(line)
        return blanks.contains("\t") || blanks.count >= 2
    }

    // MARK: - Markers

    /// The title without its list marker and checkbox.
    static func withoutMarkers(_ line: Substring) -> String {
        var rest = line
        if let afterBullet = afterListMarker(rest) { rest = afterBullet }
        if let afterBox = afterCheckbox(rest) { rest = afterBox }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    static func afterListMarker(_ line: Substring) -> Substring? {
        if let first = line.first, bullets.contains(first) {
            return afterMarker(line.dropFirst())
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard (1...maxNumberDigits).contains(digits.count) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let separator = rest.first, separator == "." || separator == ")" else { return nil }
        return afterMarker(rest.dropFirst())
    }

    static func afterCheckbox(_ line: Substring) -> Substring? {
        guard let box = checkboxes.first(where: { line.hasPrefix($0) }) else { return nil }
        return afterMarker(line.dropFirst(box.count))
    }

    /// What follows a marker, or nil when the marker is glued to a word ("-v", "1.5").
    static func afterMarker(_ rest: Substring) -> Substring? {
        guard let next = rest.first else { return rest }
        return next.isWhitespace ? rest.drop(while: \.isWhitespace) : nil
    }
}
