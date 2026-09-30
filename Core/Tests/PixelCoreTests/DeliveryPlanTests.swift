import Foundation
import Testing
@testable import PixelCore

/// Proposal 5.6, "Plan d'envoi" and "Gardes": the byte plan of a delivery, then one test per condition of each
/// guard (G1 state, G2 nothing new, G3 screen, G4 calm).
@Suite struct DeliveryPlanTests {
    static let t0 = Date(timeIntervalSince1970: 3_000_000)
    static let text = "Réponds juste OK."
    static let prefix = AgentStateMachine.normalizedPromptPrefix(text)
    static let guards: [DeliveryGuard] = [.beforeText, .beforeEnter(prefix: prefix), .beforeRetryEnter(prefix: prefix)]
    static let enterGuards: [DeliveryGuard] = [.beforeEnter(prefix: prefix), .beforeRetryEnter(prefix: prefix)]

    static let pasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
    static let pasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]

    /// 12 lines of 100 characters: over 800 characters, so pasted, not typed.
    static let longText = (1...12).map { "Ligne \($0) : " + String(repeating: "x", count: 90) }.joined(separator: "\n")

    private func sanitize(_ raw: String) -> SanitizedPrompt { PromptSanitizer.sanitize(raw) }

    // MARK: - Inputs

    /// A live agent, free, with healthy hooks.
    private func free(_ phase: AgentPhase = .idle) -> AgentRuntime {
        var r = AgentRuntime(phase: phase, phaseSince: Self.t0)
        r.pid = 4242
        r.hookHealth = .healthy
        return r
    }

    /// Everything the guard wants: a free agent, no new hook event, a screen read 50 ms ago that shows the input
    /// box (empty before the text, showing our text before the Enter), no PTY output for a second.
    private func ready(for check: DeliveryGuard) -> GuardInputs {
        let box: InputBoxState = check == .beforeText ? .empty : .draft(prefix: Self.text)
        return GuardInputs(runtime: free(), queuePaused: false, hookSeqAtStart: 7, hookSeqNow: 7,
                           screen: ScreenFacts(inputBox: box, recognized: true), screenAt: Self.t0,
                           lastOutputAt: Self.t0 - 1, now: Self.t0 + 0.05)
    }

    private func evaluate(_ check: DeliveryGuard, _ change: (inout GuardInputs) -> Void) -> GuardVerdict {
        var inputs = ready(for: check)
        change(&inputs)
        return DeliveryPlan.evaluate(check, inputs)
    }

    // MARK: - Constants

    @Test func constants() {
        #expect(DeliveryPlan.primer == "Réalise la tâche décrite dans le texte collé ci-dessous.")
        #expect(DeliveryPlan.promptSubmitTimeoutMs == 3000)
        #expect(DeliveryPlan.quietMs == 300)
        #expect(DeliveryPlan.screenMaxAgeMs == 100)
    }

    // MARK: - Plan

    @Test func shortPromptIsTypedThenEnteredSeparately() throws {
        let plan = try #require(DeliveryPlan.make(sanitize(Self.text), bracketedPaste: false))
        #expect(plan == [
            .check(.beforeText),
            .write(Array(Self.text.utf8)),
            .awaitWriteCompletion,
            .sleep(milliseconds: 120),
            .check(.beforeEnter(prefix: Self.text)),
            .write([0x0D]),
            .expectPromptSubmit(within: 3000),
        ])
    }

    @Test func shortPromptIsTypedEvenWithBracketedPaste() throws {
        let plan = try #require(DeliveryPlan.make(sanitize(Self.text), bracketedPaste: true))
        #expect(plan == DeliveryPlan.make(sanitize(Self.text), bracketedPaste: false))
        #expect(!plan.contains(.write(Self.pasteStart)))
    }

    @Test func lineFeedsStayLineFeeds() throws {
        let prompt = sanitize("Ligne 1 : réponds juste OK.\r\nLigne 2 : rien d'autre.")
        #expect(prompt.isShort)
        let plan = try #require(DeliveryPlan.make(prompt, bracketedPaste: false))
        #expect(plan[1] == .write(Array("Ligne 1 : réponds juste OK.\nLigne 2 : rien d'autre.".utf8)))
        #expect(plan[4] == .check(.beforeEnter(prefix: "Ligne 1 : réponds juste OK. Ligne 2 : ri")))
    }

    @Test func longPromptIsPrimerThenBracketedPaste() throws {
        let prompt = sanitize(Self.longText)
        #expect(!prompt.isShort)
        let plan = try #require(DeliveryPlan.make(prompt, bracketedPaste: true))
        let paste = Self.pasteStart + Array(Self.longText.utf8) + Self.pasteEnd
        #expect(plan == [
            .check(.beforeText),
            .write(Array(DeliveryPlan.primer.utf8)),
            .write(paste),
            .awaitWriteCompletion,
            .sleep(milliseconds: 250),
            .check(.beforeEnter(prefix: "Réalise la tâche décrite dans le texte c")),
            .write([0x0D]),
            .expectPromptSubmit(within: 3000),
        ])
    }

    @Test func longPromptWithoutBracketedPasteIsRefused() {
        #expect(DeliveryPlan.make(sanitize(Self.longText), bracketedPaste: false) == nil)
    }

    @Test func planNeverRetriesOnItsOwn() throws {
        for (text, paste) in [(Self.text, false), (Self.longText, true)] {
            let plan = try #require(DeliveryPlan.make(sanitize(text), bracketedPaste: paste))
            #expect(plan.filter { $0 == .write([0x0D]) }.count == 1)
            #expect(!plan.contains { if case .check(.beforeRetryEnter) = $0 { true } else { false } })
        }
    }

    @Test func retryIsOneGuardedEnter() {
        #expect(DeliveryPlan.retrySteps(prefix: Self.prefix) == [
            .check(.beforeRetryEnter(prefix: Self.prefix)),
            .write([0x0D]),
            .expectPromptSubmit(within: 3000),
        ])
    }

    /// Global constraint: no arrows, Ctrl+C, Ctrl+D, Ctrl+U or navigation key. The only control bytes written are
    /// the line feeds of the text, the paste markers' ESC, and the Enter, alone in its own write.
    @Test func writesHoldOnlyTextPasteMarkersAndEnter() throws {
        let hostile = "!rm -rf /\u{1B}[201~\u{3}\u{4}\u{15}\u{1B}[A\ttab\r\nfin"
        for (raw, paste) in [(hostile, false), (hostile + "\n" + Self.longText, true)] {
            let plan = try #require(DeliveryPlan.make(sanitize(raw), bracketedPaste: paste))
            for case .write(let bytes) in plan {
                if bytes == [0x0D] { continue }
                var body = bytes
                if body.starts(with: Self.pasteStart) {
                    #expect(Array(body.suffix(Self.pasteEnd.count)) == Self.pasteEnd)
                    body = Array(body.dropFirst(Self.pasteStart.count).dropLast(Self.pasteEnd.count))
                }
                #expect(!body.contains { $0 < 0x20 && $0 != 0x0A })
                #expect(!body.contains(0x7F))
            }
        }
    }

    @Test func emptyPromptNeverGetsItsEnter() throws {
        let plan = try #require(DeliveryPlan.make(sanitize("  \n"), bracketedPaste: false))
        guard case .check(let enterGuard) = plan[4] else {
            Issue.record("step 4 is not a guard")
            return
        }
        // Nothing was typed: the input box stays empty, and the guard before the Enter aborts.
        #expect(evaluate(enterGuard) { $0.screen.inputBox = .empty } == .abort("texte envoyé absent de la zone de saisie"))
    }

    // MARK: - Delay

    @Test func delayThresholds() {
        #expect(DeliveryPlan.delayMs(forBytes: 0) == 120)
        #expect(DeliveryPlan.delayMs(forBytes: 499) == 120)
        #expect(DeliveryPlan.delayMs(forBytes: 500) == 250)
        #expect(DeliveryPlan.delayMs(forBytes: 2047) == 250)
        #expect(DeliveryPlan.delayMs(forBytes: 2048) == 500)
        #expect(DeliveryPlan.delayMs(forBytes: 16_383) == 500)
        #expect(DeliveryPlan.delayMs(forBytes: 16_384) == 1000)
        #expect(DeliveryPlan.delayMs(forBytes: 1_000_000) == 1000)
    }

    /// The delay counts the bytes written before the Enter, not the characters: 300 "é" are 600 bytes.
    @Test func delayCountsBytesWritten() throws {
        let under = try #require(DeliveryPlan.make(sanitize(String(repeating: "é", count: 249)), bracketedPaste: false))
        #expect(under[3] == .sleep(milliseconds: 120))
        let over = try #require(DeliveryPlan.make(sanitize(String(repeating: "é", count: 300)), bracketedPaste: false))
        #expect(over[3] == .sleep(milliseconds: 250))
        // Primer (60 bytes), markers (12) and body (11 900) together are still under 16 KB.
        let big = String(repeating: "y", count: 11_900)
        let pasted = try #require(DeliveryPlan.make(sanitize(big), bracketedPaste: true))
        #expect(pasted[4] == .sleep(milliseconds: 500))
    }

    // MARK: - Prefix

    @Test func prefixOfShortPromptIsItsNormalisedHead() {
        #expect(DeliveryPlan.prefix(for: sanitize(Self.text)) == Self.text)
        let long = sanitize("Corrige   le bug\ndu parseur quand la ligne dépasse quarante caractères")
        #expect(DeliveryPlan.prefix(for: long) == "Corrige le bug du parseur quand la ligne")
        #expect(DeliveryPlan.prefix(for: long).count == AgentStateMachine.deliveryPrefixLength)
    }

    @Test func prefixOfLongPromptIsThePrimer() {
        #expect(DeliveryPlan.prefix(for: sanitize(Self.longText)) == "Réalise la tâche décrite dans le texte c")
    }

    /// The prefix goes into `PendingDelivery.prefix`: it must match the prompt Claude Code reports (spike S3.c).
    @Test func prefixMatchesTheSubmittedPrompt() {
        let reported = DeliveryPlan.primer + "\n\n<pasted_content id=\"2f9a\">\nLigne 01 du texte collé"
        #expect(AgentStateMachine.prompt(reported, matchesDeliveryPrefix: DeliveryPlan.prefix(for: sanitize(Self.longText))))
        let twoLines = "Ligne 1 : réponds juste OK.\nLigne 2 : rien d'autre."
        #expect(AgentStateMachine.prompt(twoLines, matchesDeliveryPrefix: DeliveryPlan.prefix(for: sanitize(twoLines))))
    }

    // MARK: - All clear

    @Test(arguments: guards)
    func passesWhenEverythingIsClear(check: DeliveryGuard) {
        #expect(DeliveryPlan.evaluate(check, ready(for: check)) == .pass)
    }

    @Test(arguments: guards)
    func confirmedDoneIsFree(check: DeliveryGuard) {
        #expect(evaluate(check) { $0.runtime.phase = .done } == .pass)
    }

    /// Step 0 records the delivery in the state machine before the first guard: its runtime must still pass.
    @Test(arguments: guards)
    func runtimeAfterDeliveryStartedPasses(check: DeliveryGuard) {
        let delivery = PendingDelivery(itemID: "card-1", prefix: Self.prefix, startedAt: Self.t0, hookSeqAtStart: 7)
        let (started, _) = AgentStateMachine.reduce(free(), .deliveryStarted(delivery), now: Self.t0)
        #expect(started.pendingDelivery == delivery)
        #expect(evaluate(check) { $0.runtime = started } == .pass)
    }

    // MARK: - G1: state

    @Test(arguments: guards)
    func processGoneAbortsEveryGuard(check: DeliveryGuard) {
        #expect(evaluate(check) { $0.runtime.pid = nil } == .abort("processus arrêté"))
    }

    @Test(arguments: guards)
    func pausedQueueAborts(check: DeliveryGuard) {
        #expect(evaluate(check) { $0.queuePaused = true } == .abort("file en pause"))
    }

    @Test(arguments: guards)
    func degradedHooksAbort(check: DeliveryGuard) {
        #expect(evaluate(check) { $0.runtime.hookHealth = .degraded } == .abort("mode dégradé : aucun hook reçu"))
        #expect(evaluate(check) { $0.runtime.hookHealth = .unknown(since: Self.t0) } == .abort("hooks pas encore reçus"))
    }

    @Test(arguments: guards)
    func openWaitAborts(check: DeliveryGuard) {
        let wait = PendingWait(reason: .permission(tool: "Bash", summary: "ls"), subagentID: nil, since: Self.t0)
        #expect(evaluate(check) { $0.runtime.pendingWaits[.tool(toolUseID: "t1")] = wait } == .abort("attend ta réponse"))
    }

    @Test(arguments: guards)
    func provisionalStopAborts(check: DeliveryGuard) {
        let stop = PendingStop(at: Self.t0, promptID: "P1", stopHookActive: false, backgroundTasks: 0, sessionCrons: 0)
        let verdict = evaluate(check) {
            $0.runtime.phase = .done
            $0.runtime.pendingStop = stop
        }
        #expect(verdict == .abort("fin de tour pas encore confirmée"))
    }

    @Test(arguments: guards)
    func busyOrUnavailablePhasesAbort(check: DeliveryGuard) {
        let cases: [(AgentPhase, String)] = [
            (.offline(.exited), "agent hors ligne"),
            (.launching, "agent en cours de lancement"),
            (.thinking, "agent occupé"),
            (.working(.bash), "agent occupé"),
            (.waitingBackground(tasks: 1, crons: 0), "tâches de fond en cours"),
            (.quotaPaused(resetAt: nil, autoResume: true), "limite d'usage atteinte"),
            (.error(.api("overloaded")), "agent en erreur"),
        ]
        for (phase, reason) in cases {
            #expect(evaluate(check) { $0.runtime.phase = phase } == .abort(reason))
        }
    }

    // MARK: - G2: nothing new

    @Test func newHookEventAbortsBeforeText() {
        #expect(evaluate(.beforeText) { $0.hookSeqNow = 8 } == .abort("nouvel événement de Claude Code pendant l'envoi"))
    }

    /// Review focus 1: a turn started on its own (background task, cron) between the text and the Enter. Its
    /// `PreToolUse` or `PermissionRequest` reaches the counter before the dialog is drawn: no Enter.
    @Test(arguments: enterGuards)
    func beforeEnterAbortsOnNewHookEvent(check: DeliveryGuard) {
        #expect(evaluate(check) { $0.hookSeqNow = 8 } == .abort("nouvel événement de Claude Code pendant l'envoi"))
    }

    @Test(arguments: guards)
    func counterGoingBackwardsAborts(check: DeliveryGuard) {
        #expect(evaluate(check) { $0.hookSeqNow = 6 } == .abort("nouvel événement de Claude Code pendant l'envoi"))
    }

    // MARK: - G3: screen

    @Test(arguments: guards)
    func screenOlderThan100msAborts(check: DeliveryGuard) {
        #expect(evaluate(check) { $0.now = Self.t0 + 0.1 } == .pass)
        #expect(evaluate(check) { $0.now = Self.t0 + 0.101 } == .abort("relevé d'écran trop ancien"))
    }

    /// A reading stamped a little after `now` (the caller took `now` first) is fresh; a far one is not.
    @Test(arguments: guards)
    func screenStampedAfterNowCountsItsDistance(check: DeliveryGuard) {
        #expect(evaluate(check) { $0.now = Self.t0 - 0.02 } == .pass)
        #expect(evaluate(check) { $0.now = Self.t0 - 0.5 } == .abort("relevé d'écran trop ancien"))
    }

    /// Review focus 3: another Claude Code version, an unknown fullscreen renderer. "Envoyer quand même" does not
    /// lift it.
    @Test(arguments: guards)
    func unrecognizedScreenAborts(check: DeliveryGuard) {
        let unknown = ScreenFacts(inputBox: .unknown, recognized: false)
        #expect(evaluate(check) { $0.screen = unknown } == .abort("écran non reconnu"))
        let verdict = evaluate(check) {
            $0.screen = unknown
            $0.draftOverride = true
        }
        #expect(verdict == .abort("écran non reconnu"))
    }

    @Test func dialogAbortsBeforeText() {
        #expect(evaluate(.beforeText) { $0.screen.dialogVisible = true } == .abort("un dialogue est affiché"))
    }

    /// Review focus 1, the screen side: a dialog is drawn over the input box after the text. No Enter, which would
    /// pick the highlighted option.
    @Test(arguments: enterGuards)
    func beforeEnterAbortsOnDialog(check: DeliveryGuard) {
        #expect(evaluate(check) { $0.screen.dialogVisible = true } == .abort("un dialogue est affiché"))
        let dialogOnly = ScreenFacts(inputBox: .unknown, dialogVisible: true, recognized: true)
        #expect(evaluate(check) { $0.screen = dialogOnly } == .abort("un dialogue est affiché"))
    }

    @Test(arguments: guards)
    func quotaLineAborts(check: DeliveryGuard) {
        let verdict = evaluate(check) { $0.screen.quotaLine = "Claude usage limit reached. Your limit will reset at 5pm" }
        #expect(verdict == .abort("limite d'usage affichée"))
    }

    @Test(arguments: guards)
    func spinnerAborts(check: DeliveryGuard) {
        #expect(evaluate(check) { $0.screen.spinnerVisible = true } == .abort("Claude travaille à l'écran"))
    }

    @Test(arguments: guards)
    func missingInputBoxAborts(check: DeliveryGuard) {
        #expect(evaluate(check) { $0.screen.inputBox = .unknown } == .abort("zone de saisie introuvable"))
    }

    @Test func draftBlocksBeforeText() {
        let verdict = evaluate(.beforeText) { $0.screen.inputBox = .draft(prefix: "je tapais ça") }
        #expect(verdict == .abort("brouillon dans la zone de saisie"))
    }

    /// "Envoyer quand même" lifts only the empty-input-box part of G3, before the text.
    @Test func draftOverrideLiftsOnlyTheDraft() {
        let draft = InputBoxState.draft(prefix: "run the tests")
        #expect(evaluate(.beforeText) {
            $0.screen.inputBox = draft
            $0.draftOverride = true
        } == .pass)
        let others: [(String, (inout GuardInputs) -> Void)] = [
            ("processus arrêté", { $0.runtime.pid = nil }),
            ("mode dégradé : aucun hook reçu", { $0.runtime.hookHealth = .degraded }),
            ("agent occupé", { $0.runtime.phase = .thinking }),
            ("nouvel événement de Claude Code pendant l'envoi", { $0.hookSeqNow = 8 }),
            ("un dialogue est affiché", { $0.screen.dialogVisible = true }),
            ("Claude travaille à l'écran", { $0.screen.spinnerVisible = true }),
            ("limite d'usage affichée", { $0.screen.quotaLine = "usage limit reached" }),
            ("relevé d'écran trop ancien", { $0.now = Self.t0 + 1 }),
        ]
        for (reason, change) in others {
            let verdict = evaluate(.beforeText) {
                $0.screen.inputBox = draft
                $0.draftOverride = true
                change(&$0)
            }
            #expect(verdict == .abort(reason))
        }
    }

    @Test(arguments: enterGuards)
    func beforeEnterNeedsOurTextInTheInputBox(check: DeliveryGuard) {
        #expect(evaluate(check) { $0.screen.inputBox = .empty } == .abort("texte envoyé absent de la zone de saisie"))
        let other = evaluate(check) { $0.screen.inputBox = .draft(prefix: "autre chose") }
        #expect(other == .abort("la zone de saisie ne montre pas le texte envoyé"))
    }

    /// A user draft kept by "Envoyer quand même" comes before our text: the Enter would send both, so no Enter.
    @Test(arguments: enterGuards)
    func draftOverrideDoesNotLiftThePrefixCheck(check: DeliveryGuard) {
        let verdict = evaluate(check) {
            $0.screen.inputBox = .draft(prefix: "je tapais ça" + Self.text)
            $0.draftOverride = true
        }
        #expect(verdict == .abort("la zone de saisie ne montre pas le texte envoyé"))
    }

    /// The input box shows only its first line (multi-line text, capture S3.b), or a first line cut by the
    /// terminal's width; the pasted text shows the primer glued to "[Pasted text #1 +12 lines]" (capture S3.c).
    @Test func beforeEnterAcceptsTheVisibleStartOfOurText() {
        let twoLines = DeliveryGuard.beforeEnter(prefix: DeliveryPlan.prefix(for: sanitize(
            "Ligne 1 : réponds juste OK.\nLigne 2 : rien d'autre.")))
        #expect(evaluate(twoLines) { $0.screen.inputBox = .draft(prefix: "Ligne 1 : réponds juste OK.") } == .pass)
        #expect(evaluate(.beforeEnter(prefix: Self.prefix)) { $0.screen.inputBox = .draft(prefix: "Réponds ju") } == .pass)

        let pasted = DeliveryGuard.beforeEnter(prefix: DeliveryPlan.prefix(for: sanitize(Self.longText)))
        let shown = String("Réalise la tâche décrite dans le texte collé ci-dessous.[Pasted text #1 +12 lines]".prefix(40))
        #expect(evaluate(pasted) { $0.screen.inputBox = .draft(prefix: shown) } == .pass)
    }

    /// Spaces are compared normalised on both sides, like the `UserPromptSubmit` match.
    @Test func beforeEnterNormalisesSpaces() {
        let check = DeliveryGuard.beforeEnter(prefix: "Corrige  le\nbug")
        #expect(evaluate(check) { $0.screen.inputBox = .draft(prefix: "Corrige le  bug") } == .pass)
    }

    /// Something after our whole text is not ours: the Enter would send it too.
    @Test func beforeEnterRefusesMoreThanOurText() {
        let check = DeliveryGuard.beforeEnter(prefix: "OK")
        #expect(evaluate(check) { $0.screen.inputBox = .draft(prefix: "OK") } == .pass)
        let verdict = evaluate(check) { $0.screen.inputBox = .draft(prefix: "OK et ceci") }
        #expect(verdict == .abort("la zone de saisie ne montre pas le texte envoyé"))
    }

    // MARK: - G4: calm

    /// A TUI that redraws a status line all the time: the PTY's noise never blocks on its own.
    @Test(arguments: guards)
    func noisyTerminalDoesNotBlockOnItsOwn(check: DeliveryGuard) {
        #expect(evaluate(check) { $0.lastOutputAt = $0.now - 0.01 } == .pass)
        #expect(evaluate(check) { $0.lastOutputAt = nil } == .pass)
    }

    /// When G3 fails while the PTY still writes, the reason says so (the screen may have been read mid-redraw).
    @Test(arguments: guards)
    func noisyTerminalIsNamedWhenTheScreenFails(check: DeliveryGuard) {
        let noisy = evaluate(check) {
            $0.screen.spinnerVisible = true
            $0.lastOutputAt = $0.now - 0.299
        }
        #expect(noisy == .abort("Claude travaille à l'écran (le terminal écrit encore)"))
        let calm = evaluate(check) {
            $0.screen.spinnerVisible = true
            $0.lastOutputAt = $0.now - 0.3
        }
        #expect(calm == .abort("Claude travaille à l'écran"))
    }

    // MARK: - Reasons

    @Test func reasonsAreFrenchWithoutEmDash() {
        for reason in DeliveryPlan.Reason.all {
            #expect(!reason.isEmpty)
            #expect(!reason.contains("\u{2014}"))
        }
    }
}
