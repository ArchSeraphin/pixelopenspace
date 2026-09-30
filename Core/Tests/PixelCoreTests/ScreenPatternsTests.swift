import Foundation
import Testing
@testable import PixelCore

/// Screens in `Fixtures/screens/`: synthetic ones (older layouts, kept as regression cases), hand-made screens of
/// Claude Code 2.1.285 (`trust-folder`, `fullscreen-offer`, `*-named-rule`), and in `real-2.1.285/` the captures of
/// the step 2 spikes (`Tools/spikes/results/20260930-185108/<scenario>/screens/`, header line removed).
enum ScreenFixtures {
    static func lines(_ name: String) throws -> [String] {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/screens/\(name).txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        // The terminal shows fixed-height screens: pad with blank rows like SwiftTerm's visible rows.
        return lines + Array(repeating: "", count: 4)
    }

    static func facts(_ name: String) throws -> ScreenFacts {
        ScreenPatterns.parse(lines: try lines(name))
    }

    static func options(_ name: String) throws -> [String] {
        ScreenPatterns.quickAnswerOptions(lines: try lines(name)).map { "\($0.key) \($0.label)" }
    }
}

@Suite struct ScreenPatternsTests {
    typealias F = ScreenFixtures

    @Test func versionIsTunedOnRealCaptures() {
        #expect(ScreenPatterns.version == 2)
    }

    @Test func idleWithPlaceholderIsEmpty() throws {
        let facts = try F.facts("idle-empty-box")
        #expect(facts == ScreenFacts(inputBox: .empty, dialogVisible: false, spinnerVisible: false, quotaLine: nil, recognized: true))
    }

    @Test func idleWithRulesIsEmptyDespiteQuotedPromptAbove() throws {
        let facts = try F.facts("idle-empty-rules")
        #expect(facts.inputBox == .empty)
        #expect(!facts.dialogVisible && !facts.spinnerVisible && facts.recognized)
    }

    @Test func draftPrefixIsFortyCharacters() throws {
        let facts = try F.facts("draft")
        #expect(facts.inputBox == .draft(prefix: "Ajoute aussi un test unitaire pour la fo"))
        #expect(!facts.dialogVisible)
    }

    @Test func spinnerWhileThinking() throws {
        let facts = try F.facts("thinking")
        #expect(facts.spinnerVisible)
        #expect(facts.inputBox == .empty)
        #expect(!facts.dialogVisible)
    }

    @Test func spinnerWithoutInputBox() throws {
        let facts = try F.facts("working-no-box")
        #expect(facts.spinnerVisible && facts.recognized)
        #expect(facts.inputBox == .unknown)
        #expect(!facts.dialogVisible)
    }

    @Test func bashPermissionDialog() throws {
        let facts = try F.facts("permission-bash")
        #expect(facts.dialogVisible && facts.recognized)
        #expect(facts.inputBox == .unknown)
        #expect(try F.options("permission-bash") == [
            "1 Yes",
            "2 Yes, and don't ask again for rm commands in /Users/seraphin/Projets/demo",
            "3 No, and tell Claude what to do differently (esc)",
        ])
    }

    @Test func editPermissionWithAsciiCursor() throws {
        let facts = try F.facts("permission-edit")
        #expect(facts.dialogVisible)
        #expect(facts.inputBox == .unknown)
        #expect(try F.options("permission-edit").map(\.first) == ["1", "2", "3"])
    }

    @Test func askUserQuestionOptionsSkipDescriptions() throws {
        #expect(try F.facts("ask-question").dialogVisible)
        #expect(try F.options("ask-question") == ["1 SQLite", "2 PostgreSQL", "3 Type something."])
    }

    /// Claude Code 2.1.285: "No, exit" first and focused, no numbers (digits do nothing): no quick answers.
    @Test func folderTrustDialog() throws {
        #expect(try F.facts("trust-folder") == ScreenFacts(inputBox: .unknown, dialogVisible: true, spinnerVisible: false,
                                                           quotaLine: nil, recognized: true))
        #expect(try F.options("trust-folder").isEmpty)
        // The numbered layout of earlier versions.
        #expect(try F.facts("trust-folder-numbered").dialogVisible)
        #expect(try F.options("trust-folder-numbered") == ["1 Yes, proceed", "2 No, exit"])
    }

    @Test func fullscreenRendererOffer() throws {
        let facts = try F.facts("fullscreen-offer")
        #expect(facts.dialogVisible && facts.recognized && facts.inputBox == .unknown)
        #expect(try F.options("fullscreen-offer") == ["1 Yes, try it", "2 Not now"])
    }

    /// `--name` puts the session name in the input box's top rule.
    @Test func inputBoxUnderANamedRule() throws {
        #expect(try F.facts("idle-named-rule") == ScreenFacts(inputBox: .empty, dialogVisible: false, spinnerVisible: false,
                                                              quotaLine: nil, recognized: true))
        #expect(try F.facts("draft-named-rule").inputBox == .draft(prefix: "Corrige le bug de login puis relance les"))
    }

    @Test func labeledRules() {
        #expect(ScreenPatterns.isRule("──────── api-nova ─"))
        #expect(ScreenPatterns.isRule("────────"))
        #expect(!ScreenPatterns.isRule("────────api-nova─"))
        #expect(!ScreenPatterns.isRule("── a ─"))
        #expect(!ScreenPatterns.isRule("──────── fin"))
    }

    @Test func numberedListInTheConversationIsNotADialog() throws {
        let facts = try F.facts("numbered-list-in-transcript")
        #expect(!facts.dialogVisible)
        #expect(facts.inputBox == .empty)
        #expect(try F.options("numbered-list-in-transcript").isEmpty)
    }

    @Test func quotaLine() throws {
        let facts = try F.facts("quota-waiting")
        #expect(facts.quotaLine == "Usage limit reached · continuing automatically at 3:45pm · esc to cancel")
        #expect(facts.inputBox == .empty)
        #expect(!facts.spinnerVisible)
        let sessionLimit = ScreenPatterns.parse(lines: ["  ⎿  You've hit your session limit · resets 3:45pm"])
        #expect(sessionLimit.quotaLine == "⎿  You've hit your session limit · resets 3:45pm")
    }

    @Test func contextLimitIsNotAQuota() throws {
        #expect(try F.facts("context-limit").quotaLine == nil)
    }

    @Test func plainShellIsNotRecognized() throws {
        #expect(try F.facts("shell-output") == ScreenFacts())
        #expect(ScreenPatterns.parse(lines: []) == ScreenFacts())
        #expect(ScreenPatterns.parse(lines: Array(repeating: "", count: 36)) == ScreenFacts())
    }

    @Test func spinnerVariants() {
        for line in ["✻ Thinking…", "· Pondering… (3s)", "✢ Brewing... ", "* Compacting…", "✽ Working (esc to interrupt)",
                     "   ✳ Reticulating… (12s · ↑ 1.2k tokens · esc to interrupt)"] {
            #expect(ScreenPatterns.parse(lines: [line]).spinnerVisible, "\(line)")
        }
        for line in ["* fixed the bug…", "✻ Welcome to Claude Code!", "- Thinking…", "·Thinking…", "Thinking…"] {
            #expect(!ScreenPatterns.parse(lines: [line]).spinnerVisible, "\(line)")
        }
    }

    @Test func draftInputOverridesPlaceholderLookalike() {
        let screen = ["╭────────────────────╮", "│ > Try this instead  │", "╰────────────────────╯"]
        #expect(ScreenPatterns.parse(lines: screen).inputBox == .draft(prefix: "Try this instead"))
        let placeholder = ["╭────────────────────╮", "│ > Try “fix lint”    │", "╰────────────────────╯"]
        #expect(ScreenPatterns.parse(lines: placeholder).inputBox == .empty)
    }

    @Test func unclosedBoxIsUnknown() {
        let screen = ["────────────────────", "> brouillon", "suite du texte sans bordure"]
        #expect(ScreenPatterns.parse(lines: screen).inputBox == .unknown)
    }

    @Test func questionWithoutInputBoxIsADialog() {
        let screen = ["Bash command", "  npm install", "Do you want to proceed?", "Esc to cancel"]
        #expect(ScreenPatterns.parse(lines: screen).dialogVisible)
        #expect(ScreenPatterns.quickAnswerOptions(lines: screen).isEmpty)
    }

    @Test func optionsMustStartAtOneWithoutGaps() {
        #expect(ScreenPatterns.quickAnswerOptions(lines: ["❯ 2. Oui", "  3. Non"]).isEmpty)
        #expect(ScreenPatterns.quickAnswerOptions(lines: ["❯ 1. Oui", "  3. Non"]).isEmpty)
        let far = ["❯ 1. Oui", "a", "b", "c", "d", "  2. Non"]
        #expect(ScreenPatterns.quickAnswerOptions(lines: far).isEmpty)
        let options = ScreenPatterns.quickAnswerOptions(lines: ["Do you want to proceed?", "❯ 1. Oui", "  2. Non"])
        #expect(options.map(\.key) == ["1", "2"])
        #expect(options.map(\.label) == ["Oui", "Non"])
    }

    @Test func optionLineParsing() {
        #expect(ScreenPatterns.option(in: "❯ 1. Yes") == .init(number: 1, label: "Yes"))
        #expect(ScreenPatterns.option(in: "> 2.  No thanks") == .init(number: 2, label: "No thanks"))
        #expect(ScreenPatterns.option(in: "3. Maybe") == .init(number: 3, label: "Maybe"))
        #expect(ScreenPatterns.option(in: "0. Zero") == nil)
        #expect(ScreenPatterns.option(in: "10. Ten") == nil)
        #expect(ScreenPatterns.option(in: "1.5 kg") == nil)
        #expect(ScreenPatterns.option(in: "1. ") == nil)
        #expect(ScreenPatterns.option(in: "١. Arabic digit") == nil)
    }

    @Test func parsingIsDeterministic() throws {
        for name in ["idle-empty-box", "permission-bash", "ask-question", "quota-waiting"] {
            let lines = try F.lines(name)
            #expect(ScreenPatterns.parse(lines: lines) == ScreenPatterns.parse(lines: lines))
        }
    }
}

/// Version 2: the captures of Claude Code 2.1.285 (macOS, 120x36, `--name` label in the input box's top rule, one
/// capture per state the delivery guards and the waits depend on).
@Suite struct RealScreenPatternsTests {
    static let folder = "real-2.1.285"
    static let all = [
        "S3.a-01-confiance", "S3.a-02-pret", "S3.a-03-avant-saisie", "S3.a-04-brouillon", "S3.a-05-en-cours",
        "S3.b-04-brouillon-deux-lignes", "S3.b-05-en-cours-deux-lignes", "S3.c-04-apres-collage",
        "S3.e-03-permission", "S3.e-04-apres-stop", "S4-04-selecteur-resume", "S5-03-permission",
        "S5-04-apres-echap", "S7-03-question", "S7-04-apres-echap",
    ]

    static func facts(_ name: String) throws -> ScreenFacts {
        try ScreenFixtures.facts("\(folder)/\(name)")
    }

    static func options(_ name: String) throws -> [String] {
        try ScreenFixtures.options("\(folder)/\(name)")
    }

    static let idle = ScreenFacts(inputBox: .empty, dialogVisible: false, spinnerVisible: false, quotaLine: nil,
                                  recognized: true)

    /// `❯ Try "fix lint errors"` under the rule labelled with the session name.
    @Test(arguments: ["S3.a-02-pret", "S3.a-03-avant-saisie"])
    func readyInputBoxIsEmpty(name: String) throws {
        #expect(try Self.facts(name) == Self.idle)
    }

    @Test func typedPromptIsADraft() throws {
        #expect(try Self.facts("S3.a-04-brouillon") == ScreenFacts(inputBox: .draft(prefix: "Réponds juste OK."),
                                                                    dialogVisible: false, spinnerVisible: false,
                                                                    quotaLine: nil, recognized: true))
    }

    /// `· Photosynthesizing… (1s · thinking)` above an empty input box; the submitted prompt, echoed higher up
    /// (`❯ Réponds juste OK.`), is not the input box.
    @Test(arguments: ["S3.a-05-en-cours", "S3.b-05-en-cours-deux-lignes"])
    func turnInProgressShowsTheSpinnerAndAnEmptyBox(name: String) throws {
        #expect(try Self.facts(name) == ScreenFacts(inputBox: .empty, dialogVisible: false, spinnerVisible: true,
                                                    quotaLine: nil, recognized: true))
    }

    /// A draft typed with a line feed spans two rows: the prefix reads the whole input, normalised like
    /// `PendingDelivery.prefix`, so that the delivery guard can compare them.
    @Test func multiLineDraftReadsAsOneNormalizedPrefix() throws {
        let typed = "Ligne 1 : réponds juste OK.\nLigne 2 : rien d'autre."
        let facts = try Self.facts("S3.b-04-brouillon-deux-lignes")
        #expect(facts.inputBox == .draft(prefix: AgentStateMachine.normalizedPromptPrefix(typed)))
        #expect(facts.inputBox == .draft(prefix: "Ligne 1 : réponds juste OK. Ligne 2 : ri"))
        #expect(!facts.dialogVisible && !facts.spinnerVisible && facts.recognized)
    }

    /// `❯ <primer>[Pasted text #1 +12 lines]`: the marker is glued to the primer, which stays readable.
    @Test func pastedTextShowsThePrimerFirst() throws {
        let primer = "Réalise la tâche décrite dans le texte collé ci-dessous."
        let facts = try Self.facts("S3.c-04-apres-collage")
        guard case .draft(let prefix) = facts.inputBox else {
            Issue.record("expected a draft, got \(facts.inputBox)")
            return
        }
        #expect(prefix == AgentStateMachine.normalizedPromptPrefix(primer))
        #expect(primer.hasPrefix(prefix))
        #expect(!facts.dialogVisible && !facts.spinnerVisible && facts.recognized)
    }

    @Test(arguments: ["S3.e-03-permission", "S5-03-permission"])
    func permissionDialog(name: String) throws {
        #expect(try Self.facts(name) == ScreenFacts(inputBox: .unknown, dialogVisible: true, spinnerVisible: false,
                                                    quotaLine: nil, recognized: true))
        #expect(try Self.options(name) == ["1 Yes", "2 No"])
    }

    /// AskUserQuestion: descriptions under the options, and the fourth option below a rule.
    @Test func askUserQuestionDialog() throws {
        let facts = try Self.facts("S7-03-question")
        #expect(facts.dialogVisible && facts.recognized && !facts.spinnerVisible)
        #expect(facts.inputBox == .unknown)
        #expect(try Self.options("S7-03-question") == ["1 Rouge", "2 Bleu", "3 Type something.", "4 Chat about this"])
    }

    /// After Esc on a dialog no hook fires: only the screen says the dialog is gone. The turn summary
    /// (`✻ Worked for 2s · done 18:53`) is not a spinner.
    @Test(arguments: ["S5-04-apres-echap", "S7-04-apres-echap", "S3.e-04-apres-stop"])
    func inputBoxIsBackAfterTheDialog(name: String) throws {
        #expect(try Self.facts(name) == Self.idle)
        #expect(try Self.options(name).isEmpty)
    }

    /// "❯ No, exit" above "Yes, I trust this folder": unnumbered, so no quick answers.
    @Test func folderTrustDialog() throws {
        #expect(try Self.facts("S3.a-01-confiance") == ScreenFacts(inputBox: .unknown, dialogVisible: true,
                                                                    spinnerVisible: false, quotaLine: nil,
                                                                    recognized: true))
        #expect(try Self.options("S3.a-01-confiance").isEmpty)
    }

    /// `/resume` replaces the input box by a session picker ("❯ pos-spike-s4", "Esc to cancel").
    @Test func resumePickerIsADialog() throws {
        let facts = try Self.facts("S4-04-selecteur-resume")
        #expect(facts.dialogVisible && facts.recognized)
        #expect(facts.inputBox == .unknown)
        #expect(try Self.options("S4-04-selecteur-resume").isEmpty)
    }

    @Test(arguments: all)
    func everyCaptureIsRecognized(name: String) throws {
        #expect(try Self.facts(name).recognized)
    }

    @Test func turnSummaryLinesAreNotSpinners() {
        for line in ["✻ Baked for 10s · done 18:52", "✻ Worked for 2s · done 18:53", "✻ Sautéed for 4s · done 18:52"] {
            #expect(!ScreenPatterns.parse(lines: [line]).spinnerVisible, "\(line)")
        }
        for line in ["· Photosynthesizing… (1s · thinking)", "✳ Musing… (1s · thinking)"] {
            #expect(ScreenPatterns.parse(lines: [line]).spinnerVisible, "\(line)")
        }
    }

    /// A prompt row left empty with text on the next row (a line feed typed first) is a draft, never empty.
    @Test func emptyFirstRowWithTextBelowIsADraft() {
        let screen = ["──────────────────── api-nova ─", "❯", "  suite du brouillon", "────────────────────────────"]
        #expect(ScreenPatterns.parse(lines: screen).inputBox == .draft(prefix: "suite du brouillon"))
        let placeholderThenText = ["────────────────────", "❯ Try \"fix lint errors\"", "  et ceci",
                                   "────────────────────"]
        #expect(ScreenPatterns.parse(lines: placeholderThenText).inputBox
                    == .draft(prefix: "Try \"fix lint errors\" et ceci"))
    }
}
