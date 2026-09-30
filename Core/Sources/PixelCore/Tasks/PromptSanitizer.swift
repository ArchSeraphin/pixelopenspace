import Foundation

/// A prompt as it will be typed (or pasted) into Claude Code's input box. The editor's preview shows exactly this
/// text (mockup 6(l)); only `PromptSanitizer.sanitize` makes one, and nothing outside this file can change it.
public struct SanitizedPrompt: Equatable, Sendable {
    public private(set) var text: String
    /// Characters removed by rules 2 and 3, and the invisible characters rule 4 drops at the start (Unicode
    /// scalars: each removed character is one).
    public private(set) var removedCount: Int
    /// Rule 4 added "Tâche : ".
    public private(set) var prefixed: Bool
    /// ≤ 800 characters and ≤ 3 lines: typed, not pasted (5.6).
    public private(set) var isShort: Bool
    /// Over 16 KB (UTF-8): the app asks before sending.
    public private(set) var needsConfirmation: Bool
    public var isEmpty: Bool { text.isEmpty }
}

/// Cleans a composed prompt before it reaches the PTY (proposal 5.6, "Nettoyage"). Pure. The rules, in order:
/// 1. CRLF and CR become LF; a tab becomes two spaces (a tab can trigger completion).
/// 2. ESC, the C0 controls except LF, DEL and the C1 controls are removed. Without ESC, no `ESC[201~` can close
///    a bracketed paste.
/// 3. Invisible characters are removed: zero width (U+200B, U+200C, U+200D, U+2060), every bidi control
///    (Unicode `Bidi_Control`, U+061C included), the BOM (U+FEFF) and the tag characters (U+E0000 to U+E007F).
///    Claude Code removes such characters itself on Enter, then sends nothing, puts the cleaned text back and
///    waits for a second Enter (interactive-mode.md, "Invisible characters in prompts"): what it would remove
///    must be gone from the preview. Removing more than Claude Code does is harmless for delivery (it never
///    makes Claude Code hold the prompt back), so two losses are deliberate until spike S3 pins down its exact
///    rule. The joiners go everywhere, although Claude Code keeps them inside Persian and Indic words and emoji
///    sequences: a Persian word loses its U+200C, and woman, U+200D, laptop becomes two emoji. The tags of a
///    subdivision flag go too: the flag of England becomes a plain black flag (U+1F3F4).
/// 4. Leading blanks (spaces, and blank lines too: a leading line break must not hide a command) and leading
///    invisible characters (Unicode `Default_Ignorable_Code_Point`: selectors, soft hyphen, invisible
///    operators, fillers...) are dropped, the latter counted as removed. A text that then starts with `!`
///    (shell mode, run without approval), `/` (command or skill), `?` (help) or `@` (path completion) is
///    prefixed with "Tâche : ". Looking past every invisible character, whatever Claude Code strips, means no
///    hidden lead can turn into a command once Claude Code has cleaned the text.
/// 5. Trailing line breaks and spaces are removed. A text that then ends with a backslash (trailing invisible
///    characters aside) gets one space after it: in Claude Code, a backslash followed by Enter inserts a line
///    break instead of submitting.
public enum PromptSanitizer {
    public static let shortMaxCharacters = 800
    public static let shortMaxLines = 3
    public static let confirmationBytes = 16 * 1024

    /// Added by rule 4.
    public static let commandPrefix = "Tâche : "

    /// First characters Claude Code reads as something other than a prompt (rule 4).
    static let commandCharacters: Set<Unicode.Scalar> = ["!", "/", "?", "@"]

    /// Rule 3, besides `Bidi_Control` and the tag characters.
    static let invisibleCharacters: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"]

    /// Rule 3: the Tags block.
    static let tagCharacters: ClosedRange<UInt32> = 0xE0000...0xE007F

    public static func sanitize(_ raw: String) -> SanitizedPrompt {
        var scalars = normalizingLineBreaks(raw)
        let countBefore = scalars.count
        scalars.removeAll(where: isControl)
        scalars.removeAll(where: isInvisible)

        // Rule 4: nothing blank or invisible at the start. Rule 5: nothing blank at the end.
        let start = scalars.firstIndex { !isBlank($0) && !isDefaultIgnorable($0) } ?? scalars.endIndex
        let droppedInvisibles = scalars[..<start].count(where: isDefaultIgnorable)
        let end = scalars[start...].lastIndex { !isBlank($0) }.map { $0 + 1 } ?? start
        let body = scalars[start..<end]
        let removedCount = countBefore - scalars.count + droppedInvisibles
        let prefixed = body.first.map(commandCharacters.contains) ?? false

        var view = String.UnicodeScalarView()
        if prefixed { view.append(contentsOf: commandPrefix.unicodeScalars) }
        view.append(contentsOf: body)
        if body.last(where: { !isDefaultIgnorable($0) }) == "\\" { view.append(" ") }
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

    /// Rule 3: zero width, bidi controls, BOM, tag characters.
    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        invisibleCharacters.contains(scalar) || scalar.properties.isBidiControl || tagCharacters.contains(scalar.value)
    }

    /// Spaces, tabs and line breaks of any kind (Unicode `White_Space`).
    static func isBlank(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace
    }

    /// Drawn as nothing (Unicode `Default_Ignorable_Code_Point`), whether rule 3 removes it or not.
    static func isDefaultIgnorable(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isDefaultIgnorableCodePoint
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
