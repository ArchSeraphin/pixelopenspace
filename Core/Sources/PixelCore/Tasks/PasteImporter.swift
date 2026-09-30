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
/// - Blank means drawn as space or as nothing: Unicode `White_Space` and `Default_Ignorable_Code_Point` (BOM, zero
///   width space, selectors...), the same on every platform. Blanks are trimmed from both ends of a line, so an
///   invisible character before a bullet does not hide it.
/// - A list marker is removed from a card's line: "-", "*", "•", a number of 1 to 9 digits followed by "." or ")",
///   then a checkbox "[ ]", "[x]" or "[X]", in any combination ("- [ ] A", "1. [x] B"). A marker counts only when a
///   blank or the end of the line follows it, invisible characters aside: "-v", "1.5 kg" and "*important*" stay
///   as written. A line made of markers only is ignored.
/// - A line indented under a card is appended to its details, trimmed and joined by "\n", as written (its own
///   bullet included). An indented line with no card above it starts a card.
/// - Indentation is a width in columns: a tab moves to the next multiple of 4, an invisible character takes none,
///   any other blank takes one, so "\t- A" and "    - B" sit at the same depth. It is measured from the least
///   indented line, so a list copied whole from an indented block reads like the same list flush left. A line is
///   indented when it sits at least 2 columns deeper than that line: " A" then "  B" are two cards, as "A" then
///   " B" would be, and so are "\tA" then "\tB".
/// - A copy that starts at the first bullet of an indented block loses that bullet's indentation only: "- A" then
///   "    - B" reads as A with B in its details, like the nested list it cannot be told apart from.
public enum PasteImporter {
    static let bullets: Set<Character> = ["-", "*", "•"]
    static let checkboxes = ["[ ]", "[x]", "[X]"]
    static let maxNumberDigits = 9
    static let tabWidth = 4
    /// Columns deeper than the least indented line that make a line a detail.
    static let detailIndent = 2

    /// One card per line; bullets "-", "*", "•", "1.", "1)", "[ ]", "[x]", "- [ ]" removed; blank lines ignored;
    /// a line at least 2 columns deeper than the least indented line (a tab reaching the next multiple of 4) is
    /// appended to the details of the card above it (joined by "\n").
    public static func cards(from text: String) -> [PastedCard] {
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(isBlank) }
        let margin = lines.map(indentWidth).min() ?? 0
        var cards: [PastedCard] = []
        for line in lines {
            let content = trimmed(line)
            if indentWidth(line) - margin >= detailIndent, !cards.isEmpty {
                let last = cards.count - 1
                cards[last].details += (cards[last].details.isEmpty ? "" : "\n") + content
                continue
            }
            let title = withoutMarkers(content)
            if !title.isEmpty { cards.append(PastedCard(title: title)) }
        }
        return cards
    }

    // MARK: - Blanks and indentation

    /// Drawn as space or as nothing: every scalar is `White_Space` or `Default_Ignorable_Code_Point`. Not
    /// `CharacterSet.whitespaces`, which differs between platforms (U+200B is in it on macOS).
    static func isBlank(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.properties.isWhitespace || $0.properties.isDefaultIgnorableCodePoint }
    }

    /// Drawn as nothing: every scalar is `Default_Ignorable_Code_Point`.
    static func isInvisible(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(\.properties.isDefaultIgnorableCodePoint)
    }

    /// `text` without the blanks at both ends.
    static func trimmed(_ text: Substring) -> Substring {
        let start = text.firstIndex { !isBlank($0) } ?? text.endIndex
        let end = text.lastIndex { !isBlank($0) }.map(text.index(after:)) ?? start
        return text[start..<end]
    }

    /// Columns taken by a line's leading blanks: a tab moves to the next multiple of `tabWidth`, an invisible
    /// character takes none.
    static func indentWidth(_ line: Substring) -> Int {
        line.prefix(while: isBlank).reduce(0) { column, blank in
            if blank == "\t" { return (column / tabWidth + 1) * tabWidth }
            return isInvisible(blank) ? column : column + 1
        }
    }

    // MARK: - Markers

    /// The title without its list marker and checkbox.
    static func withoutMarkers(_ line: Substring) -> String {
        var rest = line
        if let afterBullet = afterListMarker(rest) { rest = afterBullet }
        if let afterBox = afterCheckbox(rest) { rest = afterBox }
        return String(trimmed(rest))
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

    /// What follows a marker, or nil when the marker is glued to a word ("-v", "1.5"), invisible characters aside.
    static func afterMarker(_ rest: Substring) -> Substring? {
        if let next = rest.first(where: { !isInvisible($0) }), !isBlank(next) { return nil }
        return rest.drop(while: isBlank)
    }
}
