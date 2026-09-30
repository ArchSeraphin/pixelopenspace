import Foundation

/// Reads the visible terminal lines of Claude Code's TUI (proposal 3.1, 5.6, 5.8). Pure and versioned.
///
/// Version 2: tuned on the captures of Claude Code 2.1.285 taken by the step 2 spikes (S3 ready, draft, turn in
/// progress, bracketed paste, permission dialog; S5 and S7 permission and question dialogs, then the screen after
/// Esc; folder trust; `/resume` picker), which are test fixtures. The synthetic screens of version 1 (older
/// layouts with a `╭╮` box) still parse the same. Errors are meant to fall on the safe side: an unrecognised input
/// box is `.unknown`, a prompt suggestion reads as a draft (never as empty), and anything that looks like a dialog
/// blocks keystrokes.
///
/// Heuristics:
/// - input box: the lowest line whose content (box borders `│` stripped) starts with ">" or "❯", directly below
///   a top border ("╭…", a "────" rule, or a rule with a label: "──── api-nova ─") and followed, within a few
///   lines, by a bottom border ("╰…" or a rule).
///   Its text is the prompt row plus the rows down to the bottom border, joined by a space (a draft typed with line
///   feeds; a word cut by the wrap of a very narrow terminal reads as two, which only makes a guard refuse).
///   No text at all, or the `Try "…"` placeholder alone → `.empty`; otherwise `.draft`, whose prefix is
///   normalised exactly like `PendingDelivery.prefix` (`AgentStateMachine.normalizedPromptPrefix`: whitespace
///   runs, line breaks included, collapsed to one space, first 40 characters), so that a delivery guard can
///   compare the two. A bracketed paste shows as `❯ <typed primer>[Pasted text #1 +12 lines]`: the primer
///   comes first, so the prefix of a delivery made of a primer and a paste is the primer's.
/// - spinner: a line "<glyph> <Word>…" with glyph in ✻ ✶ ✳ ✢ ✽ · *, or any line with "esc to interrupt"
///   ("· Photosynthesizing… (1s · thinking)"; the turn summary "✻ Worked for 2s · done 18:53" is not one).
/// - dialog: a "❯ 1."-style cursor line; or, when no input box is visible (a dialog replaces it),
///   "Do you want to…", at least two numbered options 1., 2., …, or an unnumbered "❯ <option>" line with an
///   "Enter to confirm" / "Esc to cancel" hint (the 2.1.285 trust dialog: "❯ No, exit" above "Yes, I trust this
///   folder", where digits do nothing).
/// - quota: a line with "usage limit", "limit reached" (not "context limit") or "You've hit your … limit".
/// Spinner, dialog and quota are searched in the last `bottomRegionLines` non-empty lines only, so that
/// the conversation above (lists, quoted text) does not match.
public enum ScreenPatterns {
    public static let version = 2

    /// Non-empty lines, from the bottom, where the spinner, dialogs and the quota line are looked for.
    public static let bottomRegionLines = 16

    static let spinnerGlyphs: Set<Character> = ["✻", "✶", "✳", "✢", "✽", "·", "*"]
    static let borderCharacters: Set<Character> = ["│", "┃", "║", "|"]
    static let ruleCharacters: Set<Character> = ["─", "━", "═", "╌", "┄"]

    public static func parse(lines: [String]) -> ScreenFacts {
        let region = bottomRegion(lines)
        let inputBox = findInputBox(lines)
        let spinner = region.contains(where: isSpinnerLine)
        let cursorOption = region.contains { line in
            let c = content(line)
            guard c.first == "❯" else { return false }
            return option(in: c) != nil
        }
        let question = region.contains { content($0).localizedCaseInsensitiveContains("Do you want to") }
        let optionCount = optionBlock(region).count
        let focusedOption = region.contains { line in
            let c = content(line)
            return c.first == "❯" && !c.dropFirst().trimmingBlanks().isEmpty
        }
        let hint = region.contains(where: isDialogHint)
        let dialog = cursorOption || (inputBox == nil && (question || optionCount >= 2 || (focusedOption && hint)))
        return ScreenFacts(
            inputBox: inputBox ?? .unknown,
            dialogVisible: dialog,
            spinnerVisible: spinner,
            quotaLine: region.reversed().lazy.map(content).first(where: isQuotaLine).map(String.init),
            recognized: inputBox != nil || spinner || dialog
        )
    }

    /// Options of the visible dialog, in order, keyed by their digit: `[("1", "Yes"), ("2", "No")]`.
    /// Empty when no dialog is visible or its options are not numbered 1, 2, … without gaps.
    public static func quickAnswerOptions(lines: [String]) -> [(key: Character, label: String)] {
        guard parse(lines: lines).dialogVisible else { return [] }
        return optionBlock(bottomRegion(lines)).map { (key: Character(String($0.number)), label: $0.label) }
    }

    // MARK: - Lines

    /// The line without surrounding blanks and without the side borders of a box.
    static func content(_ line: String) -> Substring {
        var s = Substring(line).trimmingBlanks()
        if let first = s.first, borderCharacters.contains(first) { s = s.dropFirst().trimmingBlanks() }
        if let last = s.last, borderCharacters.contains(last) { s = s.dropLast().trimmingBlanks() }
        return s
    }

    static func bottomRegion(_ lines: [String]) -> [String] {
        Array(lines.filter { !content($0).isEmpty }.suffix(bottomRegionLines))
    }

    static func isTopBorder(_ line: String) -> Bool {
        let t = Substring(line).trimmingBlanks()
        return t.first == "╭" || t.first == "┌" || isRule(t)
    }

    static func isBottomBorder(_ line: String) -> Bool {
        let t = Substring(line).trimmingBlanks()
        return t.first == "╰" || t.first == "└" || isRule(t)
    }

    /// A horizontal rule: at least 8 rule characters and nothing else, or a rule with one label set off by spaces
    /// ("──────── api-nova ─": Claude Code shows the session name in the input box's top rule).
    static func isRule(_ t: Substring) -> Bool {
        let isRuleCharacter: (Character) -> Bool = { ruleCharacters.contains($0) }
        guard t.count >= 8, let first = t.first, let last = t.last, isRuleCharacter(first), isRuleCharacter(last) else {
            return false
        }
        let head = t.prefix(while: isRuleCharacter)
        if head.count == t.count { return true }
        let tailCount = t.reversed().prefix(while: isRuleCharacter).count
        let label = t.dropFirst(head.count).dropLast(tailCount)
        return head.count + tailCount >= 8 && label.first == " " && label.last == " "
            && !label.trimmingBlanks().isEmpty
    }

    /// The key hint under a dialog: "Enter to confirm · Esc to cancel".
    static func isDialogHint(_ line: String) -> Bool {
        let c = content(line)
        let hints = ["enter to confirm", "enter to select", "esc to cancel"]
        return hints.contains { c.localizedCaseInsensitiveContains($0) }
    }

    // MARK: - Input box

    /// How far below the prompt line the bottom border may be (multi-line drafts).
    static let maxInputLines = 12

    static func findInputBox(_ lines: [String]) -> InputBoxState? {
        var i = lines.count - 1
        while i > 0 {
            defer { i -= 1 }
            guard let text = promptText(lines[i]), isTopBorder(lines[i - 1]) else { continue }
            let end = min(lines.count - 1, i + maxInputLines)
            guard i + 1 <= end, let bottom = lines[(i + 1)...end].firstIndex(where: isBottomBorder) else { continue }
            // Rows of a draft typed with line feeds (or wrapped), down to the bottom border.
            let rows = lines[(i + 1)..<bottom].map(content).filter { !$0.isEmpty }
            if rows.isEmpty && (text.isEmpty || isPlaceholder(text)) { return .empty }
            let whole = ([text] + rows).joined(separator: " ")
            return .draft(prefix: AgentStateMachine.normalizedPromptPrefix(whole))
        }
        return nil
    }

    /// Text after the ">" / "❯" prompt marker, or `nil` when the line is not a prompt (or is a dialog option).
    static func promptText(_ line: String) -> Substring? {
        let c = content(line)
        guard let marker = c.first, marker == ">" || marker == "❯", option(in: c) == nil else { return nil }
        return c.dropFirst().trimmingBlanks()
    }

    static func isPlaceholder(_ text: Substring) -> Bool {
        text.hasPrefix("Try \"") || text.hasPrefix("Try “")
    }

    // MARK: - Spinner

    static func isSpinnerLine(_ line: String) -> Bool {
        let c = content(line)
        if c.localizedCaseInsensitiveContains("esc to interrupt") { return true }
        guard let glyph = c.first, spinnerGlyphs.contains(glyph) else { return false }
        let rest = c.dropFirst()
        guard rest.first == " " else { return false }
        let word = rest.dropFirst().prefix { $0.isLetter }
        guard let initial = word.first, initial.isUppercase else { return false }
        let after = rest.dropFirst().dropFirst(word.count)
        return after.hasPrefix("…") || after.hasPrefix("...")
    }

    // MARK: - Dialog options

    struct NumberedOption: Equatable {
        var number: Int
        var label: String
    }

    /// `^[❯>]?\s*([1-9])\.\s+(.+)$` on the line content, without a regex.
    static func option(in content: Substring) -> NumberedOption? {
        var s = content
        if s.first == "❯" || s.first == ">" { s = s.dropFirst().trimmingBlanks() }
        guard let digit = s.first, let number = digit.wholeNumberValue, (1...9).contains(number), digit.isASCII else {
            return nil
        }
        s = s.dropFirst()
        guard s.first == "." else { return nil }
        s = s.dropFirst()
        guard let space = s.first, space == " " || space == "\u{00A0}" else { return nil }
        let label = s.trimmingBlanks()
        guard !label.isEmpty else { return nil }
        return NumberedOption(number: number, label: String(label))
    }

    /// The lowest run of options numbered 1, 2, …, n (n ≥ 2), read bottom-up. Up to 3 other lines (option
    /// descriptions, wrapped labels) may sit between two options.
    static func optionBlock(_ lines: [String]) -> [NumberedOption] {
        var collected: [NumberedOption] = []
        var gap = 0
        for line in lines.reversed() {
            if let found = option(in: content(line)) {
                if let last = collected.last, found.number == last.number - 1 {
                    collected.append(found)
                } else {
                    collected = [found]
                }
                gap = 0
                if found.number == 1 {
                    if collected.count >= 2 { return collected.reversed() }
                    collected = []
                }
            } else if !collected.isEmpty {
                gap += 1
                if gap > 3 {
                    collected = []
                    gap = 0
                }
            }
        }
        return []
    }

    // MARK: - Quota

    static func isQuotaLine(_ c: Substring) -> Bool {
        let lower = c.lowercased()
        if lower.contains("context limit") { return false }
        if lower.contains("usage limit") || lower.contains("limit reached") { return true }
        return (lower.contains("you've hit your") || lower.contains("you’ve hit your")) && lower.contains("limit")
    }
}

extension Substring {
    /// Without leading and trailing spaces, tabs and no-break spaces.
    fileprivate func trimmingBlanks() -> Substring {
        let isBlank: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" }
        guard let start = firstIndex(where: { !isBlank($0) }), let end = lastIndex(where: { !isBlank($0) }) else {
            return self[endIndex...]
        }
        return self[start...end]
    }
}
