import Foundation

/// A check made during a delivery, right before a write (proposal 5.6, "Plan d'envoi").
public enum DeliveryGuard: Equatable, Sendable {
    /// Step 1, before anything is written: G1 to G4, with an empty input box.
    case beforeText
    /// Step 4, before the Enter: G1 to G4, with the input box showing the start of `prefix`.
    case beforeEnter(prefix: String)
    /// Step 7, before the one extra Enter when `UserPromptSubmit` did not come: the same checks as `beforeEnter`.
    case beforeRetryEnter(prefix: String)
}

/// One step of a delivery, run in order by the app's executor.
public enum DeliveryStep: Equatable, Sendable {
    /// Evaluate the guard on fresh inputs; an abort stops the delivery before the next write.
    case check(DeliveryGuard)
    /// Write these bytes to the PTY, in one write (after checking the process is still running).
    case write([UInt8])
    /// Wait until the previous writes have reached the PTY.
    case awaitWriteCompletion
    case sleep(milliseconds: Int)
    /// Wait, at most this many milliseconds, for the `UserPromptSubmit` that confirms the delivery.
    case expectPromptSubmit(within: Int)
}

public enum GuardVerdict: Equatable, Sendable {
    case pass
    /// The reason, in French, for the card and the log.
    case abort(String)
}

/// What a guard looks at, read by the executor just before the check.
public struct GuardInputs: Equatable, Sendable {
    public var runtime: AgentRuntime
    public var queuePaused: Bool
    public var hookSeqAtStart: UInt64
    /// Read from the hook server's per-agent atomic counter just before the check.
    public var hookSeqNow: UInt64
    public var screen: ScreenFacts
    /// When the screen was read.
    public var screenAt: Date
    public var lastOutputAt: Date?
    public var now: Date
    /// "Envoyer quand même": lifts only the empty-input-box part of G3 before the text. The app sets it only while
    /// the input box shows the text the user agreed to type over (`DispatchPolicy.draftOverrideHolds`).
    public var draftOverride: Bool

    public init(runtime: AgentRuntime, queuePaused: Bool, hookSeqAtStart: UInt64, hookSeqNow: UInt64,
                screen: ScreenFacts, screenAt: Date, lastOutputAt: Date?, now: Date, draftOverride: Bool = false) {
        self.runtime = runtime
        self.queuePaused = queuePaused
        self.hookSeqAtStart = hookSeqAtStart
        self.hookSeqNow = hookSeqNow
        self.screen = screen
        self.screenAt = screenAt
        self.lastOutputAt = lastOutputAt
        self.now = now
        self.draftOverride = draftOverride
    }
}

/// The guarded delivery of a prompt into an agent's PTY (proposal 5.6). Pure: it plans the writes and judges
/// the guards; the app's `TaskDispatcher` runs the steps and reads the inputs.
///
/// Plan: `check(.beforeText)`, the text typed (or, for a long text, the primer typed then the body in a
/// bracketed paste), `awaitWriteCompletion`, a delay that grows with the bytes written, `check(.beforeEnter)`,
/// the Enter alone in its own write, then `expectPromptSubmit`. The retry (`retrySteps`) is the executor's, once,
/// after the deadline.
///
/// Guards: a failed guard aborts, never "try anyway". The checks, in this order (the first failure gives the
/// reason):
/// - G1, state: live process, queue not paused, healthy hooks, no open wait, phase `idle` or `done` (the phase
///   left by `deliveryStarted`, which does not change it), no provisional `Stop`. `waitingBackground`,
///   `quotaPaused`, `error`, `offline` and a busy agent all fail.
/// - G2, nothing new: the hook server's counter has not moved since the delivery started. A `PreToolUse` or
///   `PermissionRequest` of a turn started on its own reaches it before the dialog is drawn.
/// - G3, screen: read at most `screenMaxAgeMs` away from `now` (either way: a reading stamped just after `now`
///   is fresh), recognised, no dialog, no usage-limit line, no spinner. Before the text, an empty input box
///   (a draft passes only with `draftOverride`); before an Enter, an input box whose visible text is the start
///   of our prefix, both normalised like `AgentStateMachine.normalizedPromptPrefix`. Anything more than our text
///   (a user draft kept by "Envoyer quand même", keystrokes) fails: the Enter would send it too.
/// - G4, calm: no PTY output for `quietMs`. The PTY's noise never blocks on its own (a TUI may redraw a status
///   line all the time): it only matters when G3 cannot vouch for the screen, and G3 has then already failed.
///   Its only trace is in G3's reason, which then says that the terminal was still writing (the screen may
///   have been read mid-redraw, or the delay was too short).
public enum DeliveryPlan {
    /// Typed before a bracketed paste: a collapsed paste reaches Claude as text the user may not have written,
    /// and the primer tells it to follow that text.
    public static let primer = "Réalise la tâche décrite dans le texte collé ci-dessous."
    public static let promptSubmitTimeoutMs = 3000
    public static let quietMs = 300
    public static let screenMaxAgeMs = 100

    /// `ESC[200~` and `ESC[201~`.
    static let pasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
    static let pasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
    /// Enter: a carriage return, alone in its own write.
    static let enter: [UInt8] = [0x0D]

    /// Short text: typed. Long text: primer typed, then ESC[200~ body ESC[201~ (only if `bracketedPaste`);
    /// long text without bracketed paste → nil ("trop long pour un envoi sûr").
    public static func make(_ prompt: SanitizedPrompt, bracketedPaste: Bool) -> [DeliveryStep]? {
        let writes: [[UInt8]]
        if prompt.isShort {
            // Line feeds stay line feeds: a line break in Claude Code's input box (spike S3.b).
            writes = [Array(prompt.text.utf8)]
        } else if bracketedPaste {
            writes = [Array(primer.utf8), pasteStart + Array(prompt.text.utf8) + pasteEnd]
        } else {
            return nil
        }
        let written = writes.reduce(0) { $0 + $1.count }
        return [.check(.beforeText)] + writes.map(DeliveryStep.write) + [
            .awaitWriteCompletion,
            .sleep(milliseconds: delayMs(forBytes: written)),
            .check(.beforeEnter(prefix: prefix(for: prompt))),
            .write(enter),
            .expectPromptSubmit(within: promptSubmitTimeoutMs),
        ]
    }

    /// Step 7, run by the executor once, when `UserPromptSubmit` did not come in time: one more guarded Enter,
    /// then the same wait.
    public static func retrySteps(prefix: String) -> [DeliveryStep] {
        [.check(.beforeRetryEnter(prefix: prefix)), .write(enter), .expectPromptSubmit(within: promptSubmitTimeoutMs)]
    }

    /// The prefix matched against UserPromptSubmit and looked for in the input box (primer for long texts).
    /// Normalised and cut like `PendingDelivery.prefix`.
    public static func prefix(for prompt: SanitizedPrompt) -> String {
        AgentStateMachine.normalizedPromptPrefix(prompt.isShort ? prompt.text : primer)
    }

    /// The pause between the last text write and the Enter, from the bytes written: 120 ms under 500 bytes,
    /// 250 ms under 2 KB, 500 ms under 16 KB, 1 s beyond (a key in the same chunk as the end of a paste loses
    /// the paste: anthropics/claude-code #91205).
    public static func delayMs(forBytes count: Int) -> Int {
        switch count {
        case ..<500: 120
        case ..<(2 * 1024): 250
        case ..<(16 * 1024): 500
        default: 1000
        }
    }

    /// Added to the reason of a guard that fails once text was typed (before an Enter): the text stays in the input
    /// box, never erased (no Ctrl+U), where it reads as a draft and blocks the next deliveries (5.6, step 4).
    public static let textLeftNotice = "texte laissé dans le terminal, vérifie-le"

    /// The detail of `DeliveryAbortReason.guardFailed` for a guard that failed with `reason`, after writing text or not.
    public static func abortDetail(_ reason: String, textWritten: Bool) -> String {
        textWritten ? reason + " · " + textLeftNotice : reason
    }

    public static func evaluate(_ check: DeliveryGuard, _ inputs: GuardInputs) -> GuardVerdict {
        if let reason = stateProblem(inputs) ?? newEventProblem(inputs) { return .abort(reason) }
        if let reason = screenProblem(check, inputs) {
            return .abort(isCalm(inputs) ? reason : reason + Reason.stillWriting)
        }
        return .pass
    }

    // MARK: - Guards

    /// G1.
    static func stateProblem(_ inputs: GuardInputs) -> String? {
        let r = inputs.runtime
        guard r.pid != nil else { return Reason.processGone }
        guard !inputs.queuePaused else { return Reason.queuePaused }
        switch r.hookHealth {
        case .healthy: break
        case .degraded: return Reason.hooksDegraded
        case .unknown: return Reason.hooksUnknown
        }
        guard r.pendingWaits.isEmpty else { return Reason.waiting }
        switch r.phase {
        case .idle, .done: break
        case .offline: return Reason.offline
        case .launching: return Reason.launching
        case .thinking, .working: return Reason.busy
        case .waitingBackground: return Reason.background
        case .quotaPaused: return Reason.quotaPaused
        case .error: return Reason.error
        }
        guard r.pendingStop == nil else { return Reason.provisionalStop }
        return nil
    }

    /// G2.
    static func newEventProblem(_ inputs: GuardInputs) -> String? {
        inputs.hookSeqNow == inputs.hookSeqAtStart ? nil : Reason.newHookEvent
    }

    /// G3.
    static func screenProblem(_ check: DeliveryGuard, _ inputs: GuardInputs) -> String? {
        let screen = inputs.screen
        guard abs(milliseconds(from: inputs.screenAt, to: inputs.now)) <= Double(screenMaxAgeMs) else {
            return Reason.staleScreen
        }
        guard screen.recognized else { return Reason.unrecognizedScreen }
        guard !screen.dialogVisible else { return Reason.dialog }
        guard screen.quotaLine == nil else { return Reason.quotaLine }
        guard !screen.spinnerVisible else { return Reason.spinner }
        switch (check, screen.inputBox) {
        case (_, .unknown):
            return Reason.noInputBox
        case (.beforeText, .empty):
            return nil
        case (.beforeText, .draft):
            return inputs.draftOverride ? nil : Reason.draft
        case (.beforeEnter, .empty), (.beforeRetryEnter, .empty):
            return Reason.textMissing
        case (.beforeEnter(let prefix), .draft(let shown)), (.beforeRetryEnter(let prefix), .draft(let shown)):
            return inputBox(shown, showsStartOf: prefix) ? nil : Reason.textMismatch
        }
    }

    /// G4.
    static func isCalm(_ inputs: GuardInputs) -> Bool {
        guard let last = inputs.lastOutputAt else { return true }
        return milliseconds(from: last, to: inputs.now) >= Double(quietMs)
    }

    /// The visible text of the input box (its first line, perhaps cut by the terminal's width or by
    /// `ScreenPatterns`) is a non-empty start of our prefix, both sides normalised.
    static func inputBox(_ shown: String, showsStartOf prefix: String) -> Bool {
        let visible = AgentStateMachine.normalizedPromptPrefix(shown, length: .max)
        let wanted = AgentStateMachine.normalizedPromptPrefix(prefix, length: .max)
        return !visible.isEmpty && wanted.hasPrefix(visible)
    }

    /// Whole milliseconds from `start` to `end` (negative if `end` is earlier), so that limits are exact.
    static func milliseconds(from start: Date, to end: Date) -> Double {
        (end.timeIntervalSince(start) * 1000).rounded()
    }

    // MARK: - Reasons

    /// Abort reasons, in French: shown on the card ("échec d'envoi") and logged.
    enum Reason {
        static let processGone = "processus arrêté"
        static let queuePaused = "file en pause"
        static let hooksDegraded = "mode dégradé : aucun hook reçu"
        static let hooksUnknown = "hooks pas encore reçus"
        static let waiting = "attend ta réponse"
        static let offline = "agent hors ligne"
        static let launching = "agent en cours de lancement"
        static let busy = "agent occupé"
        static let background = "tâches de fond en cours"
        static let quotaPaused = "limite d'usage atteinte"
        static let error = "agent en erreur"
        static let provisionalStop = "fin de tour pas encore confirmée"
        static let newHookEvent = "nouvel événement de Claude Code pendant l'envoi"
        static let staleScreen = "relevé d'écran trop ancien"
        static let unrecognizedScreen = "écran non reconnu"
        static let dialog = "un dialogue est affiché"
        static let quotaLine = "limite d'usage affichée"
        static let spinner = "Claude travaille à l'écran"
        static let noInputBox = "zone de saisie introuvable"
        static let draft = "brouillon dans la zone de saisie"
        static let textMissing = "texte envoyé absent de la zone de saisie"
        static let textMismatch = "la zone de saisie ne montre pas le texte envoyé"
        /// Appended to a G3 reason when the PTY wrote within `quietMs` (G4).
        static let stillWriting = " (le terminal écrit encore)"

        static let all = [
            processGone, queuePaused, hooksDegraded, hooksUnknown, waiting, offline, launching, busy, background,
            quotaPaused, error, provisionalStop, newHookEvent, staleScreen, unrecognizedScreen, dialog, quotaLine,
            spinner, noInputBox, draft, textMissing, textMismatch, stillWriting,
        ]
    }
}
