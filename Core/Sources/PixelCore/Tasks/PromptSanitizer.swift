import Foundation

/// A prompt as it will be typed (or pasted) into Claude Code's input box. The editor's preview shows exactly this
/// text (mockup 6(l)); only `PromptSanitizer.sanitize` makes one.
public struct SanitizedPrompt: Equatable, Sendable {
    public var text: String
    /// Characters removed by rules 2 and 3 (Unicode scalars: each removed character is one).
    public var removedCount: Int
    /// Rule 4 added "Tâche : ".
    public var prefixed: Bool
    /// ≤ 800 characters and ≤ 3 lines: typed, not pasted (5.6).
    public var isShort: Bool
    /// Over 16 KB (UTF-8): the app asks before sending.
    public var needsConfirmation: Bool
    public var isEmpty: Bool { text.isEmpty }
}

/// Cleans a composed prompt before it reaches the PTY (proposal 5.6, "Nettoyage"). Pure. The rules, in order:
/// 1. CRLF and CR become LF; a tab becomes two spaces (a tab can trigger completion).
/// 2. ESC, the C0 controls except LF, DEL and the C1 controls are removed. Without ESC, no `ESC[201~` can close
///    a bracketed paste.
/// 3. Invisible characters are removed: zero width (U+200B, U+200C, U+200D, U+2060), bidi controls (U+200E,
///    U+200F, U+202A to U+202E, U+2066 to U+2069) and the BOM (U+FEFF). Claude Code would strip them itself on
///    Enter, put the cleaned text back and wait for a second Enter.
/// 4. Leading blanks are dropped (spaces, and blank lines too: a leading line break must not hide a command);
///    a text that then starts with `!` (shell mode, run without approval), `/` (command), `?` (help) or `@`
///    (path completion) is prefixed with "Tâche : ".
/// 5. Trailing line breaks and spaces are removed.
public enum PromptSanitizer {
    public static let shortMaxCharacters = 800
    public static let shortMaxLines = 3
    public static let confirmationBytes = 16 * 1024

    /// Added by rule 4.
    public static let commandPrefix = "Tâche : "

    /// First characters Claude Code reads as something other than a prompt (rule 4).
    static let commandCharacters: Set<Unicode.Scalar> = ["!", "/", "?", "@"]

    /// Rule 3.
    static let invisibleCharacters: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}",
        "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
        "\u{FEFF}",
    ]

    public static func sanitize(_ raw: String) -> SanitizedPrompt {
        var scalars = normalizingLineBreaks(raw)
        let countBefore = scalars.count
        scalars.removeAll(where: isControl)
        scalars.removeAll(where: invisibleCharacters.contains)
        let removedCount = countBefore - scalars.count

        // Rules 4 and 5: nothing blank at either end.
        let start = scalars.firstIndex { !isBlank($0) } ?? scalars.endIndex
        let end = scalars.lastIndex { !isBlank($0) }.map { $0 + 1 } ?? start
        let body = scalars[start..<end]
        let prefixed = body.first.map(commandCharacters.contains) ?? false

        var view = String.UnicodeScalarView()
        if prefixed { view.append(contentsOf: commandPrefix.unicodeScalars) }
        view.append(contentsOf: body)
        let text = String(view)

        let lines = text.unicodeScalars.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        return SanitizedPrompt(
            text: text,
            removedCount: removedCount,
            prefixed: prefixed,
            isShort: text.count <= shortMaxCharacters && lines <= shortMaxLines,
            needsConfirmation: text.utf8.count > confirmationBytes
        )
    }

    /// "112 caractères · saisie courte · aucun caractère retiré" (mockup 6(l)); a long text reads "collage",
    /// removed characters "3 caractères retirés", and rule 4 adds "préfixé par « Tâche : »".
    public static func summary(_ prompt: SanitizedPrompt) -> String {
        var parts = [counted(prompt.text.count, "caractère", "caractères")]
        parts.append(prompt.isShort ? "saisie courte" : "collage")
        parts.append(prompt.removedCount == 0
            ? "aucun caractère retiré"
            : counted(prompt.removedCount, "caractère retiré", "caractères retirés"))
        if prompt.prefixed { parts.append("préfixé par « Tâche : »") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Rules

    /// Rule 1, on the raw text: a CR followed by LF is one line break.
    static func normalizingLineBreaks(_ raw: String) -> [Unicode.Scalar] {
        var result: [Unicode.Scalar] = []
        result.reserveCapacity(raw.unicodeScalars.count)
        var afterCarriageReturn = false
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\r":
                result.append("\n")
            case "\n" where afterCarriageReturn:
                break
            case "\t":
                result.append(contentsOf: [" ", " "])
            default:
                result.append(scalar)
            }
            afterCarriageReturn = scalar == "\r"
        }
        return result
    }

    /// Rule 2: C0 except LF, DEL, C1.
    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A: false
        case 0x00...0x1F, 0x7F...0x9F: true
        default: false
        }
    }

    /// Spaces, tabs and line breaks of any kind (Unicode `White_Space`).
    static func isBlank(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace
    }

    // MARK: - Summary

    /// French count: singular for 0 and 1; thousands grouped by a narrow no-break space ("16 385").
    static func counted(_ count: Int, _ singular: String, _ plural: String) -> String {
        grouped(count) + " " + (count > 1 ? plural : singular)
    }

    static func grouped(_ count: Int) -> String {
        var digits = Array(String(count))
        var groups: [String] = []
        while digits.count > 3 {
            groups.insert(String(digits.suffix(3)), at: 0)
            digits.removeLast(3)
        }
        groups.insert(String(digits), at: 0)
        return groups.joined(separator: "\u{202F}")
    }
}
