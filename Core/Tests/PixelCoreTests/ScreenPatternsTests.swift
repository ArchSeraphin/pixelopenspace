import Foundation
import Testing
@testable import PixelCore

/// Screens in `Fixtures/screens/`: synthetic ones (provisional, to be replaced by captures from spikes S3 and S7)
/// and captures of Claude Code 2.1.285 (`trust-folder`, `fullscreen-offer`, `*-named-rule`).
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

    @Test func versionIsProvisional() {
        #expect(ScreenPatterns.version == 1)
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
