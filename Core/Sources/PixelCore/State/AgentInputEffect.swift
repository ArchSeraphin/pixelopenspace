import Foundation

/// Classes of keystrokes typed by the user in an agent's terminal (content never leaves the terminal).
public enum KeyClass: Equatable, Sendable {
    case printable, enter, escape, control, navigation
}

/// Everything that can change an agent's runtime state.
public enum AgentInput: Equatable, Sendable {
    case processStarted(pid: Int32, startedAt: Date, withInitialPrompt: Bool)
    case processExited(code: Int32?)
    case processFailedToStart(String)
    /// An accepted hook event (already routed to this agent) with its acceptance sequence number.
    case hook(HookEvent, seq: UInt64)
    case screen(ScreenFacts)
    case userInterrupt
    case userKeystroke(KeyClass)
    case outputActivity
    case bell
    /// 1 Hz clock.
    case tick
    case deliveryStarted(PendingDelivery)
    case deliveryAborted(DeliveryAbortReason)
    /// The user opened the agent window or its terminal.
    case acknowledged
    /// The user asked to close the session: the coming exit is not a crash.
    case closeRequested
}

/// Signals from an agent to the post-it lifecycle (`TaskLifecycle`, step 2b).
public enum AgentCardSignal: Equatable, Sendable {
    case deliveryConfirmed(promptID: String?)
    case turnCommitted(promptID: String?)
    case turnWaitingBackground
    case turnReopened(promptID: String?)
    case turnFailed
    case interrupted
    case sessionLost
    case deliveryFailed(DeliveryAbortReason)
}

public enum AgentNotification: Equatable, Sendable {
    case waiting(WaitReason)
    case turnDone
    case error(AgentError)
}

public enum SoundID: String, Equatable, Sendable {
    case alert, done, drop, ding, levelUp, error
}

/// Problems that concern the whole account, shown once for all agents.
public enum GlobalIssue: Equatable, Sendable {
    case quota(resetAt: Date?)
    case account(String)
}

public enum GlobalIssueKind: Equatable, Sendable {
    case quota, account
}

/// Side effects requested by the reducer, executed by the app layer.
public enum AgentEffect: Equatable, Sendable {
    case notify(AgentNotification)
    case playSound(SoundID)
    case card(AgentCardSignal)
    case pumpQueue(afterSeconds: Double)
    case setQueuePaused(Bool)
    case recordSession(SessionRef)
    case endSession(sessionID: String, reason: String?, at: Date)
    case updateSessionCwd(sessionID: String, cwd: String)
    case recordProcess(ProcessStamp)
    case raiseGlobalIssue(GlobalIssue)
    case clearGlobalIssue(GlobalIssueKind)
    /// VoiceOver announcement.
    case announce(String)
    /// Re-read the screen after a delay (after a keystroke, for instance).
    case resampleScreen(afterSeconds: Double)
    /// Something was missed: re-derive what can be derived (e.g. re-read the screen).
    case reconcile
    /// Short transient message for the user (toast), in French. The app prefixes the agent's name.
    case showMessage(String)
}

/// Timing parameters of the reducer (from `AppSettings`, overridable in tests).
public struct ReducerConfig: Equatable, Sendable {
    public var stopQuietWindow: TimeInterval = 3
    public var sendGrace: TimeInterval = 1.5
    public var doneToIdleAfter: TimeInterval = 600
    public var launchingSilentAfter: TimeInterval = 8
    public var launchingNoHookAfter: TimeInterval = 15
    public var staleNoHookAfter: TimeInterval = 600
    public var staleNoOutputAfter: TimeInterval = 120
    public var interruptVerifyQuiet: TimeInterval = 1
    public var interruptGiveUpAfter: TimeInterval = 3
    public var autoChainQueue: Bool = true

    public init() {}

    public init(settings: AppSettings) {
        self.init()
        stopQuietWindow = settings.stopQuietWindowSeconds
        sendGrace = settings.sendGraceSeconds
        autoChainQueue = settings.autoChainQueue
    }
}
