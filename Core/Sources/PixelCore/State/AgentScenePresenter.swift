import Foundation

/// What the scene draws for one agent at its desk (3.7, derived states of 4.3): pose, overlay, screen and signs.
public struct AgentPresentation: Equatable, Sendable {
    public var kind: AgentStateKind
    /// Idle for longer than `AgentPresenter.asleepAfter`: never confused with offline.
    public var asleep: Bool
    /// `nil`: no avatar (offline, the jacket is on the chair).
    public var animation: CharacterAnimation?
    /// raiseHand: the avatar turns toward the viewer, whatever its row.
    public var facesViewer: Bool
    public var overlay: OverlayKind?
    /// With `.tool`, or the "?" of a waiting AskUserQuestion.
    public var toolIcon: ToolIcon?
    /// `ov.bang.halo` behind the "!".
    public var halo: Bool
    /// Screen content (row A) and monitor LED (row B).
    public var screen: ScreenState
    /// In `SceneBadge.allCases` order.
    public var badges: [SceneBadge]
    /// `agent.mini` beside the desk when > 0.
    public var subagents: Int
    public var jacketOnChair: Bool
    /// Desk lamp lit at night.
    public var deskLit: Bool
    /// Name plate shown even without hovering: waiting, error, offline (7.4.10, 6(q)).
    public var nameplateAlways: Bool
    /// The "OFF" plate.
    public var nameplateOff: Bool
    /// A starting agent has no overlay: the small "démarre" sign (`hud.state.launching`) stands above its post at ×1
    /// and closer, never in the overview (seen from behind, the standing pose reads like sitting).
    public var launchingSign: Bool
    /// 0…3, `AgentStateKind.urgency`.
    public var urgency: Int
    /// `AgentPresenter.accessibilityLabel` (tooltip, VoiceOver).
    public var label: String

    /// A seated agent with no overlay; `urgency` defaults to `kind.urgency`.
    public init(kind: AgentStateKind, asleep: Bool = false, animation: CharacterAnimation? = nil,
                facesViewer: Bool = false, overlay: OverlayKind? = nil, toolIcon: ToolIcon? = nil, halo: Bool = false,
                screen: ScreenState = .off, badges: [SceneBadge] = [], subagents: Int = 0, jacketOnChair: Bool = false,
                deskLit: Bool = true, nameplateAlways: Bool = false, nameplateOff: Bool = false,
                launchingSign: Bool = false, urgency: Int? = nil, label: String = "") {
        self.kind = kind
        self.asleep = asleep
        self.animation = animation
        self.facesViewer = facesViewer
        self.overlay = overlay
        self.toolIcon = toolIcon
        self.halo = halo
        self.screen = screen
        self.badges = badges
        self.subagents = subagents
        self.jacketOnChair = jacketOnChair
        self.deskLit = deskLit
        self.nameplateAlways = nameplateAlways
        self.nameplateOff = nameplateOff
        self.launchingSign = launchingSign
        self.urgency = urgency ?? kind.urgency
        self.label = label
    }

    /// The "!" of a wait or the storm of an error: the only signs the overview keeps (décision 2 of the first render),
    /// with the name plate of their agent.
    public var showsUrgentSign: Bool { overlay == .bang || overlay == .storm }
}

public struct ScenePresentationOptions: Hashable, Sendable {
    /// No halo pulsing behind the "!" (Reduce Motion).
    public var reduceMotion: Bool
    /// The agent's `--permission-mode`: `bypassPermissions` shows `ov.unsafe`.
    public var permissionMode: PermissionMode

    public init(reduceMotion: Bool = false, permissionMode: PermissionMode = .default) {
        self.reduceMotion = reduceMotion
        self.permissionMode = permissionMode
    }
}

extension AgentPresenter {
    /// Pure projection of the runtime state to the scene: an open wait first (the avatar stands and raises its hand
    /// toward the viewer under a "!"), otherwise the phase. Liveness signs (no news, draft, degraded mode,
    /// subagents) need a running process; `ov.unsafe` shows in every state but offline. `ov.external` is never
    /// produced here: every agent of the app is internal.
    public static func scene(_ r: AgentRuntime, now: Date, agentName: String, projectName: String,
                             options: ScenePresentationOptions = .init()) -> AgentPresentation {
        let kind = r.kind
        let label = accessibilityLabel(present(r, now: now), agentName: agentName, projectName: projectName, now: now)
        var p = AgentPresentation(kind: kind, label: label)

        if let wait = r.oldestWait {
            p.animation = .raiseHand
            p.facesViewer = true
            p.overlay = .bang
            if case .question = wait.reason { p.toolIcon = .question }
            p.halo = !options.reduceMotion && !r.acknowledgedWaiting
            p.screen = .waiting
            p.nameplateAlways = true
        } else {
            switch r.phase {
            case .offline:
                p.screen = .off
                p.jacketOnChair = true
                p.nameplateOff = true
                p.nameplateAlways = true
                p.deskLit = false
            case .launching:
                p.animation = .stand
                p.screen = .boot
                p.launchingSign = true
            case .idle:
                p.asleep = now.timeIntervalSince(r.phaseSince) > asleepAfter
                p.animation = p.asleep ? .sleep : .sitIdle
                p.overlay = p.asleep ? .zzz : nil
                p.screen = .idle
            case .thinking:
                p.animation = .think
                p.overlay = .dots
                p.screen = .thinking
            case .working(let tool):
                p.animation = .type
                p.overlay = .tool
                p.toolIcon = ToolIcon(tool)
                p.screen = .working
            case .done:
                p.animation = .sitIdle
                p.overlay = .check
                p.screen = .done
            case .waitingBackground:
                p.animation = .sitIdle
                p.overlay = .background
                p.screen = .background
            case .quotaPaused:
                // A clock, never the storm: the pause is not an error.
                p.animation = .sitIdle
                p.overlay = .quota
                p.screen = .quota
            case .error:
                p.animation = .cough
                p.overlay = .storm
                p.screen = .error
                p.nameplateAlways = true
            }
        }

        let running = r.pid != nil
        if running && r.stale { p.badges.append(.stale) }
        if running, case .draft? = r.screen?.inputBox, kind == .idle || kind == .done { p.badges.append(.draft) }
        if running && r.hookHealth == .degraded { p.badges.append(.degraded) }
        if options.permissionMode == .bypassPermissions && kind != .offline { p.badges.append(.unsafe) }
        p.subagents = running ? r.activeSubagents : 0
        return p
    }
}
