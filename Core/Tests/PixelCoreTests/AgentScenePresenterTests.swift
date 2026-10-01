import Foundation
import Testing
@testable import PixelCore

@Suite struct AgentScenePresenterTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_845_200)

    static func runtime(_ phase: AgentPhase, pid: Int32? = 4242, since: Date = t0) -> AgentRuntime {
        var r = AgentRuntime(phase: phase, phaseSince: since)
        r.pid = pid
        r.hookHealth = .healthy
        return r
    }

    static func waiting(_ reason: WaitReason, key: WaitKey = .tool(toolUseID: "t1"),
                        phase: AgentPhase = .working(.bash)) -> AgentRuntime {
        var r = runtime(phase)
        r.pendingWaits[key] = PendingWait(reason: reason, subagentID: nil, since: t0 + 1)
        return r
    }

    static func scene(_ r: AgentRuntime, after seconds: TimeInterval = 5,
                      options: ScenePresentationOptions = .init()) -> AgentPresentation {
        AgentPresenter.scene(r, now: t0 + seconds, agentName: "Nova", projectName: "API", options: options)
    }

    /// The fields every seated, non-offline agent shares.
    static func expectSeatedDefaults(_ p: AgentPresentation, _ comment: Comment) {
        #expect(!p.jacketOnChair && !p.nameplateOff && p.deskLit, comment)
        #expect(p.urgency == p.kind.urgency, comment)
    }

    static let question = AskedQuestion(header: "Base", question: "Quelle base de données ?", options: ["SQLite"],
                                        multiSelect: false)

    // MARK: - One test per row of the table

    @Test(arguments: [
        WaitReason.permission(tool: "Bash", summary: "rm -rf dist"),
        .notification(type: "permission_prompt"),
        .elicitation(server: "github", message: "Choisis un dépôt"),
        .terminal,
    ])
    func openWait(reason: WaitReason) {
        let p = Self.scene(Self.waiting(reason))
        #expect(p.kind == .waitingInput)
        #expect(p.animation == .raiseHand && p.facesViewer)
        #expect(p.overlay == .bang && p.toolIcon == nil)
        #expect(p.screen == .waiting)
        #expect(p.halo && p.nameplateAlways && !p.asleep)
        #expect(p.urgency == 3)
        Self.expectSeatedDefaults(p, "\(reason)")
    }

    @Test func questionWait() {
        let p = Self.scene(Self.waiting(.question([Self.question]), phase: .thinking))
        #expect(p.kind == .waitingInput)
        #expect(p.animation == .raiseHand && p.facesViewer)
        #expect(p.overlay == .bang && p.toolIcon == .question)
        #expect(p.screen == .waiting)
        #expect(p.halo && p.nameplateAlways)
        Self.expectSeatedDefaults(p, "question")
    }

    @Test func thinking() {
        let p = Self.scene(Self.runtime(.thinking))
        #expect(p.kind == .thinking)
        #expect(p.animation == .think && !p.facesViewer)
        #expect(p.overlay == .dots && p.toolIcon == nil)
        #expect(p.screen == .thinking)
        #expect(!p.halo && !p.nameplateAlways && !p.asleep)
        Self.expectSeatedDefaults(p, "thinking")
    }

    @Test(arguments: [ToolKind.read, .edit, .bash, .search, .web, .subagent, .question, .mcp("github"), .other("Foo")])
    func working(tool: ToolKind) {
        let p = Self.scene(Self.runtime(.working(tool)))
        #expect(p.kind == .working)
        #expect(p.animation == .type && !p.facesViewer)
        #expect(p.overlay == .tool && p.toolIcon == ToolIcon(tool))
        #expect(p.screen == .working)
        #expect(!p.halo && !p.nameplateAlways)
        Self.expectSeatedDefaults(p, "\(tool)")
    }

    @Test func idleAwake() {
        for seconds in [0.0, 5, 599, AgentPresenter.asleepAfter] {
            let p = Self.scene(Self.runtime(.idle), after: seconds)
            #expect(p.kind == .idle && !p.asleep, "\(seconds) s")
            #expect(p.animation == .sitIdle && p.overlay == nil && p.toolIcon == nil, "\(seconds) s")
            #expect(p.screen == .idle, "\(seconds) s")
            Self.expectSeatedDefaults(p, "\(seconds) s")
        }
    }

    @Test func idleAsleep() {
        for seconds in [AgentPresenter.asleepAfter + 1, 3_600] {
            let p = Self.scene(Self.runtime(.idle), after: seconds)
            #expect(p.kind == .idle && p.asleep, "\(seconds) s")
            #expect(p.animation == .sleep && p.overlay == .zzz && p.toolIcon == nil, "\(seconds) s")
            #expect(p.screen == .idle, "\(seconds) s")
            // Asleep is never offline: the jacket stays on the agent and the lamp is lit at night.
            Self.expectSeatedDefaults(p, "\(seconds) s")
            #expect(!p.nameplateAlways)
        }
    }

    @Test func done() {
        let p = Self.scene(Self.runtime(.done), after: 3_600)
        #expect(p.kind == .done)
        #expect(p.animation == .sitIdle && p.overlay == .check && p.toolIcon == nil)
        #expect(p.screen == .done && !p.asleep)
        Self.expectSeatedDefaults(p, "done")
    }

    @Test func waitingBackground() {
        let p = Self.scene(Self.runtime(.waitingBackground(tasks: 2, crons: 0)))
        #expect(p.kind == .waitingBackground)
        #expect(p.animation == .sitIdle && p.overlay == .background && p.toolIcon == nil)
        #expect(p.screen == .background)
        Self.expectSeatedDefaults(p, "background")
    }

    @Test func quotaPaused() {
        for phase in [AgentPhase.quotaPaused(resetAt: Self.t0 + 2_400, autoResume: true),
                      .quotaPaused(resetAt: nil, autoResume: false)] {
            let p = Self.scene(Self.runtime(phase))
            #expect(p.kind == .quotaPaused)
            #expect(p.animation == .sitIdle && p.overlay == .quota && p.toolIcon == nil)
            #expect(p.overlay != .storm)
            #expect(p.screen == .quota && !p.nameplateAlways)
            Self.expectSeatedDefaults(p, "\(phase)")
        }
    }

    @Test(arguments: [AgentError.api("overloaded"), .account("authentication_failed"), .crashed(1), .crashed(nil),
                      .launchFailed("introuvable")])
    func errorState(error: AgentError) {
        let p = Self.scene(Self.runtime(.error(error)))
        #expect(p.kind == .error)
        #expect(p.animation == .cough && p.overlay == .storm && p.toolIcon == nil)
        #expect(p.screen == .error)
        #expect(p.nameplateAlways && !p.halo)
        Self.expectSeatedDefaults(p, "\(error)")
    }

    @Test func launching() {
        let p = Self.scene(Self.runtime(.launching))
        #expect(p.kind == .launching)
        #expect(p.animation == .stand && p.overlay == nil && p.toolIcon == nil)
        #expect(p.screen == .boot)
        #expect(!p.nameplateAlways)
        // No overlay, but the small "démarre" sign above the post (seen from behind, standing reads as sitting).
        #expect(p.launchingSign)
        Self.expectSeatedDefaults(p, "launching")
        // A wait opened while launching: the "!" replaces the sign.
        let waiting = Self.scene(Self.waiting(.terminal, phase: .launching))
        #expect(waiting.overlay == .bang && !waiting.launchingSign)
    }

    @Test func urgentSignsAndLaunchingSign() {
        let runtimes: [AgentRuntime] = [
            Self.waiting(.terminal), Self.waiting(.question([Self.question])), Self.runtime(.thinking),
            Self.runtime(.working(.read)), Self.runtime(.idle), Self.runtime(.idle, since: Self.t0 - 3_600),
            Self.runtime(.done), Self.runtime(.waitingBackground(tasks: 0, crons: 1)),
            Self.runtime(.quotaPaused(resetAt: nil, autoResume: true)), Self.runtime(.error(.crashed(2))),
            Self.runtime(.launching), Self.runtime(.offline(.notStarted), pid: nil),
        ]
        for r in runtimes {
            let p = Self.scene(r)
            // The overview keeps the "!" of a wait and the storm of an error, nothing else (décision 2).
            #expect(p.showsUrgentSign == (p.kind == .waitingInput || p.kind == .error), "\(r.phase)")
            #expect(p.showsUrgentSign == (p.overlay == .bang || p.overlay == .storm), "\(r.phase)")
            #expect(p.launchingSign == (p.kind == .launching), "\(r.phase)")
        }
    }

    @Test(arguments: [OfflineReason.notStarted, .closedByUser, .appRelaunched, .exited, .orphanElsewhere])
    func offline(reason: OfflineReason) {
        let p = Self.scene(Self.runtime(.offline(reason), pid: nil), after: 3_600)
        #expect(p.kind == .offline)
        #expect(p.animation == nil && !p.facesViewer)
        #expect(p.overlay == nil && p.toolIcon == nil && !p.halo)
        #expect(p.screen == .off)
        #expect(p.jacketOnChair && p.nameplateOff && p.nameplateAlways && !p.deskLit)
        // Offline is never "asleep", however long ago.
        #expect(!p.asleep)
        #expect(p.badges.isEmpty && p.subagents == 0 && p.urgency == 0)
    }

    // MARK: - Badges, halo, label

    @Test func badges() {
        // stale and degraded need a running process.
        var stale = Self.runtime(.thinking)
        stale.stale = true
        #expect(Self.scene(stale).badges == [.stale])
        stale.pid = nil
        #expect(Self.scene(stale).badges.isEmpty)

        var degraded = Self.runtime(.launching)
        degraded.hookHealth = .degraded
        #expect(Self.scene(degraded).badges == [.degraded])
        degraded.pid = nil
        #expect(Self.scene(degraded).badges.isEmpty)

        // draft: text in the input box while idle or done (the queue waits for it).
        for phase in [AgentPhase.idle, .done] {
            var draft = Self.runtime(phase)
            draft.screen = ScreenFacts(inputBox: .draft(prefix: "corrige"), recognized: true)
            #expect(Self.scene(draft).badges == [.draft], "\(phase)")
            draft.pid = nil
            #expect(Self.scene(draft).badges.isEmpty, "\(phase)")
        }
        for phase in [AgentPhase.thinking, .working(.edit), .launching] {
            var busy = Self.runtime(phase)
            busy.screen = ScreenFacts(inputBox: .draft(prefix: "corrige"), recognized: true)
            #expect(Self.scene(busy).badges.isEmpty, "\(phase)")
        }
        var waitingDraft = Self.waiting(.permission(tool: "Bash", summary: "ls"), phase: .idle)
        waitingDraft.screen = ScreenFacts(inputBox: .draft(prefix: "x"), recognized: true)
        #expect(Self.scene(waitingDraft).badges.isEmpty)
        var empty = Self.runtime(.idle)
        empty.screen = ScreenFacts(inputBox: .empty, recognized: true)
        #expect(Self.scene(empty).badges.isEmpty)

        // unsafe: bypassPermissions, in every state but offline, with or without a process.
        let bypass = ScenePresentationOptions(permissionMode: .bypassPermissions)
        #expect(Self.scene(Self.runtime(.working(.bash)), options: bypass).badges == [.unsafe])
        #expect(Self.scene(Self.runtime(.launching, pid: nil), options: bypass).badges == [.unsafe])
        #expect(Self.scene(Self.runtime(.error(.crashed(nil)), pid: nil), options: bypass).badges == [.unsafe])
        #expect(Self.scene(Self.runtime(.offline(.exited), pid: nil), options: bypass).badges.isEmpty)
        for mode in PermissionMode.allCases where mode != .bypassPermissions {
            let options = ScenePresentationOptions(permissionMode: mode)
            #expect(Self.scene(Self.runtime(.working(.bash)), options: options).badges.isEmpty, "\(mode)")
        }

        // All at once, in SceneBadge.allCases order; external is never produced for an agent of the app.
        var all = Self.runtime(.idle)
        all.stale = true
        all.hookHealth = .degraded
        all.screen = ScreenFacts(inputBox: .draft(prefix: "y"), recognized: true)
        #expect(Self.scene(all, options: bypass).badges == [.stale, .draft, .degraded, .unsafe])

        // Subagents beside the desk only while a process runs.
        var busy = Self.runtime(.working(.subagent))
        busy.activeSubagentIDs = ["a1", "a2"]
        #expect(Self.scene(busy).subagents == 2)
        busy.pid = nil
        #expect(Self.scene(busy).subagents == 0)
    }

    @Test func haloRules() {
        let r = Self.waiting(.permission(tool: "Bash", summary: "rm -rf dist"))
        #expect(Self.scene(r).halo)
        #expect(!Self.scene(r, options: ScenePresentationOptions(reduceMotion: true)).halo)
        var acknowledged = r
        acknowledged.acknowledgedWaiting = true
        #expect(!Self.scene(acknowledged).halo)
        // Still waiting: the "!" stays, only the halo goes.
        #expect(Self.scene(acknowledged).overlay == .bang)
        // Never without a wait.
        for phase in [AgentPhase.thinking, .working(.bash), .idle, .done, .error(.api("overloaded")), .launching] {
            #expect(!Self.scene(Self.runtime(phase)).halo, "\(phase)")
        }
    }

    @Test func labelMatchesAccessibilityLabel() {
        let r = Self.waiting(.permission(tool: "Bash", summary: "rm -rf dist"))
        let now = Self.t0 + 43
        let p = AgentPresenter.scene(r, now: now, agentName: "Nova", projectName: "API")
        #expect(p.label == "Nova, projet API, attend ta réponse : Bash : rm -rf dist, depuis 42 secondes")
        let runtimes = [r, Self.runtime(.idle), Self.runtime(.offline(.closedByUser), pid: nil),
                        Self.runtime(.working(.mcp("github"))), Self.runtime(.error(.api("overloaded")))]
        for runtime in runtimes {
            let label = AgentPresenter.scene(runtime, now: now, agentName: "Bip", projectName: "INFRA").label
            #expect(label == AgentPresenter.accessibilityLabel(AgentPresenter.present(runtime, now: now),
                                                               agentName: "Bip", projectName: "INFRA", now: now))
        }
    }

    @Test func urgencyAndKindFollowTheState() {
        let runtimes: [AgentRuntime] = [
            Self.waiting(.terminal), Self.runtime(.thinking), Self.runtime(.working(.read)), Self.runtime(.idle),
            Self.runtime(.done), Self.runtime(.waitingBackground(tasks: 0, crons: 1)),
            Self.runtime(.quotaPaused(resetAt: nil, autoResume: true)), Self.runtime(.error(.crashed(2))),
            Self.runtime(.launching), Self.runtime(.offline(.notStarted), pid: nil),
        ]
        let presentations = runtimes.map { Self.scene($0) }
        #expect(Set(presentations.map(\.kind)) == Set(AgentStateKind.allCases))
        for (r, p) in zip(runtimes, presentations) {
            #expect(p.kind == r.kind)
            #expect(p.urgency == r.kind.urgency)
        }
        // Only a waiting agent faces the viewer.
        #expect(presentations.filter(\.facesViewer).map(\.kind) == [.waitingInput])
    }
}
