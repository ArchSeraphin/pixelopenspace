import AppKit
import Foundation
import Observation
import PixelCore
import PixelIPC

/// The single source of truth of the app (proposal 2.1, 3.18): workspace, settings, agents' runtime state,
/// global issues, hook and Claude Code status, selection and transient UI state.
///
/// The UI only reads these properties and calls the intents (`AppModel+Intents.swift`, `AppModel+Sessions.swift`,
/// `AppModel+Tasks.swift`, `AppModel+Quit.swift`).
/// Runtime state changes only through `AgentStateMachine.reduce` (`dispatch`, `AppModel+Engine.swift`), whose
/// effects are executed here: workspace writes, notifications, global issues, screen readings, toasts.
/// The cork board changes only through `TaskLifecycle.reduce` (`applyTask`, `AppModel+Tasks.swift`).
@MainActor
@Observable
final class AppModel {
    // MARK: - State (read by the UI, written by AppModel only)

    /// Projects and agents, persisted (`state/workspace.json`).
    private(set) var workspace: Workspace
    /// Persisted (`state/settings.json`); changed with `updateSettings(_:)`.
    private(set) var settings: AppSettings
    /// Post-its, queued instructions and prompt templates, persisted (`state/tasks.json`); changed with
    /// `applyTask(_:)`.
    private(set) var board: TaskBoardState
    /// What the board panel shows (project, tags, text); not persisted.
    var boardFilter = BoardFilter()
    /// Runtime state of every agent of the workspace.
    private(set) var runtimes: [AgentID: AgentRuntime] = [:]
    /// Account-wide problems (usage limit, signed out): one banner and one notification for all agents.
    private(set) var globalIssues: [GlobalIssueKind: GlobalIssue] = [:]
    var hookServerState: HookServerState = .stopped
    /// Where `claude` is, its version, and whether it meets `ClaudeStatus.minimumVersion`.
    var claude: ClaudeStatus = .detecting
    /// Where the environment given to `claude` comes from (login shell, or the app's fallback).
    var environmentSource: EnvironmentSource = .pending
    var selectedProjectID: ProjectID?
    var selectedAgentID: AgentID?
    /// Set when an agent must be brought into view; the UI reveals it, then calls `consumeFocusRequest()`.
    var focusRequest: FocusRequest?
    /// Set when the UI must open a sheet or window; the UI handles it, then calls `consumeUIRequest(_:)`.
    var uiRequest: PendingUIRequest?
    /// Transient messages, oldest first; each one expires after `toastLifetime`.
    var toasts: [Toast] = []
    /// Problems found while loading the files (repairs, file set aside, newer format): one banner at launch.
    var loadWarnings: [String]
    /// Set when the user quits while agents are busy: the UI shows the quit sheet (mockup 6(p)).
    var quitRequest: QuitRequest?
    /// "Attendre la fin des tours" chosen: the app quits by itself once no agent is busy.
    var isWaitingForTurnsToQuit = false
    /// The banner "n sessions peuvent être relancées" was answered ("Tout relancer", the sheet) or put off
    /// ("Plus tard"): it stays hidden until the next launch of the app.
    var isRelaunchOfferDismissed = false
    /// What the relaunch banner and sheet last read on disk and in the processes (`relaunchCandidates`). Read again
    /// at launch, when the banner or the sheet appears, on "Actualiser", around a relaunch, when an orphan exits, and
    /// at most every `relaunchProbeInterval` otherwise (`tick`); never on a render. Nil when nothing was read, or
    /// no agent is left to relaunch.
    var relaunchProbe: RelaunchProbe?
    /// macOS notifications were refused (the Dock badge still counts waiting agents).
    var notificationsDenied = false
    /// Clock of the time-dependent texts ("depuis 2 min", asleep after 10 min): advanced every second.
    var now = Date()
    /// Hook → screen latency of the last 500 accepted hook events (Réglages › Avancé); written by `receive(_:)` only.
    var hookLatency = LatencyWindow()

    // MARK: - Services

    let sessions: SessionManager
    let hookServer: HookServer
    let notifications: NotificationBridge
    let persistence: PersistenceStore
    let locator: ClaudeLocator
    /// Delivers the head of each agent's queue into its terminal (step 2b-2); observed for its notices.
    let dispatcher = TaskDispatcher()

    // MARK: - Bookkeeping (not observed)

    @ObservationIgnored var reducerConfig: ReducerConfig
    @ObservationIgnored var deduplicator = HookDeduplicator()
    /// Sequence number of the last accepted hook event (all agents).
    @ObservationIgnored var hookSeq: UInt64 = 0
    @ObservationIgnored var saveVersion: UInt64 = 0
    @ObservationIgnored var screenSampleTasks: [AgentID: Task<Void, Never>] = [:]
    @ObservationIgnored var detectionTask: Task<Void, Never>?
    @ObservationIgnored var clockTask: Task<Void, Never>?
    @ObservationIgnored var hookTask: Task<Void, Never>?
    @ObservationIgnored var lastBadgeCount = -1
    @ObservationIgnored var started = false
    @ObservationIgnored var quitApproved = false
    @ObservationIgnored var quitForcefully = false
    @ObservationIgnored var quitInProgress = false
    /// Agents launched with `--resume`, and when: a quick failure before any hook means "cannot resume".
    @ObservationIgnored var resumeAttempts: [AgentID: Date] = [:]
    /// Agents whose last resume failed: the next relaunch starts a new session.
    @ObservationIgnored var failedResumes: Set<AgentID> = []
    /// "Continuer la tâche" chosen in the relaunch sheet: the agent's card, continued once its session has started
    /// (`settlePendingContinuation`), dropped if the process ends first.
    @ObservationIgnored var pendingContinuations: [AgentID: TaskCardID] = [:]
    /// When `relaunchProbe` was last read.
    @ObservationIgnored var relaunchProbedAt: Date?
    /// VoiceOver announcements of the agents (7.9): an agent that starts waiting or falls into an error joins the
    /// open batch, posted as one sentence, waits first, `AnnouncementBatcher.window` seconds after it opened.
    @ObservationIgnored var announcementBatcher = AnnouncementBatcher()
    /// The batcher's clock: seconds since this instant (continuous, as `Task.sleep`).
    @ObservationIgnored let announcementEpoch = ContinuousClock.now

    static let toastLifetime: TimeInterval = 6
    static let maxToasts = 4

    init(workspace: LoadedFile<Workspace>, settings: LoadedFile<AppSettings>, board: LoadedFile<TaskBoardState>,
         extraWarnings: [String], sessions: SessionManager, hookServer: HookServer,
         notifications: NotificationBridge, persistence: PersistenceStore, locator: ClaudeLocator) {
        self.workspace = workspace.value
        self.settings = settings.value
        self.board = board.value
        loadWarnings = extraWarnings + settings.warnings + workspace.warnings + board.warnings
        reducerConfig = ReducerConfig(settings: settings.value)
        self.sessions = sessions
        self.hookServer = hookServer
        self.notifications = notifications
        self.persistence = persistence
        self.locator = locator

        let launchDate = Date()
        var initial: [AgentID: AgentRuntime] = [:]
        for agent in workspace.value.agents {
            initial[agent.id] = AgentRuntime(phase: .offline(Self.offlineReason(for: agent)), phaseSince: launchDate)
        }
        runtimes = initial

        dispatcher.model = self
        sessions.onEvent = { [weak self] agentID, event in
            self?.handleTerminalEvent(agentID, event)
        }
        notifications.onOpenAgent = { [weak self] agentID in
            self?.requestFocus(agentID)
        }
        notifications.onWillRequestAuthorization = { [weak self] in
            self?.showToast("Pixel Open Space te prévient par une notification quand un agent attend ta réponse.")
        }
        notifications.onAuthorizationChange = { [weak self] denied in
            self?.notificationsDenied = denied
        }
    }

    /// Starts the hook server, the hook and clock loops, and the search for `claude`. Called once, at launch.
    func start() {
        guard !started else { return }
        started = true
        sessions.start()
        hookServerState = hookServer.start()
        // After the hook server: another copy of the app owning the state files makes this one read-only.
        markLostSessions()
        refreshRelaunchProbe()
        startHookLoop()
        startClock()
        redetectClaude()
        updateDockBadge()
    }

    /// The turns of the previous run are lost (proposal 2.5, C13): the card "En cours" of each agent, all offline at
    /// launch, gets `sessionLost` (`RelaunchPlanner.lostTurns`). It stays in "En cours", flagged, and the agent's
    /// queue is paused: once the agent is relaunched, its next post-it must not start beside the lost card (4.3b).
    /// Nothing is sent until the user chooses: "Remettre à faire" from the relaunch resumes the queue, "Continuer la
    /// tâche" too (C14); a card decided from its menu leaves "Reprendre la file" to the user. Flagging twice changes
    /// nothing. Not in a copy of the app that does not own the state files (`isPersistenceSuspended`): the other
    /// copy's sessions may still run.
    private func markLostSessions() {
        guard !isPersistenceSuspended else { return }
        for agentID in RelaunchPlanner.lostTurns(workspace: workspace, runtimes: runtimes, board: board) {
            applyTask(.agentSignal(agentID, .sessionLost))
            setQueuePaused(true, for: agentID)
        }
    }

    /// After an app crash, an agent's last `claude` may still run (same pid, same start time): never resume its
    /// session from here while it lives (proposal 2.5).
    private static func offlineReason(for agent: Agent) -> OfflineReason {
        if let stamp = agent.lastProcess, isAlive(stamp) {
            return .orphanElsewhere
        }
        return agent.sessions.isEmpty ? .notStarted : .appRelaunched
    }

    // MARK: - Derived state

    var projects: [Project] { workspace.projectsInOrder }

    func project(_ id: ProjectID) -> Project? { workspace.project(id) }

    func agent(_ id: AgentID) -> Agent? { workspace.agent(id) }

    /// Agents of a project, by desk.
    func agents(in projectID: ProjectID) -> [Agent] { workspace.agents(in: projectID) }

    /// Every agent of the live projects, in sidebar order (for ⌥⌘→ / ⌥⌘←).
    var agentsInOrder: [Agent] { projects.flatMap { workspace.agents(in: $0.id) } }

    func runtime(for id: AgentID) -> AgentRuntime? { runtimes[id] }

    /// What the list, the tray and tooltips show for each agent, at `now`.
    var displays: [AgentID: AgentStatusDisplay] {
        let date = now
        return runtimes.mapValues { AgentPresenter.present($0, now: date) }
    }

    func display(for id: AgentID) -> AgentStatusDisplay? {
        runtimes[id].map { AgentPresenter.present($0, now: now) }
    }

    /// VoiceOver label: "Nova, projet API, attend ta réponse : Bash : rm -rf dist, depuis 42 secondes".
    func accessibilityLabel(for id: AgentID) -> String? {
        guard let agent = workspace.agent(id), let display = display(for: id) else { return nil }
        let projectName = workspace.project(agent.projectID)?.name ?? ""
        return AgentPresenter.accessibilityLabel(display, agentName: agent.name, projectName: projectName, now: now)
    }

    /// Status-bar counters and waiting tray.
    var statusSummary: StatusSummary { StatusSummary.compute(runtimes) }

    var waitingCount: Int { runtimes.values.filter { !$0.pendingWaits.isEmpty }.count }

    /// The global issue to show in the banner: account problems first, then the usage limit.
    var activeGlobalIssue: GlobalIssue? { globalIssues[.account] ?? globalIssues[.quota] }

    var hookStatus: HookStatus {
        var running = 0
        var healthy = 0
        var degraded: [AgentID] = []
        for agent in agentsInOrder {
            guard let runtime = runtimes[agent.id], runtime.pid != nil else { continue }
            running += 1
            switch runtime.hookHealth {
            case .healthy: healthy += 1
            case .degraded: degraded.append(agent.id)
            case .unknown: break
            }
        }
        var problem: String?
        switch hookServerState {
        case .anotherInstance:
            problem = "Une autre copie de Pixel Open Space est ouverte : utilise-la. Ici, aucune session ne peut "
                + "être lancée et rien n'est enregistré."
        case .failed(let message):
            problem = message
        case .helperMissing(let path):
            problem = "pixel-hook est absent de l'app (\(path)) : les états seront approximatifs."
        case .running, .stopped:
            if !degraded.isEmpty {
                let names = degraded.compactMap { workspace.agent($0)?.name }.joined(separator: ", ")
                problem = "Mode dégradé · \(names) : aucun hook depuis le lancement (politique gérée ?). "
                    + "États approximatifs."
            }
        }
        return HookStatus(server: hookServerState, runningAgents: running, healthyAgents: healthy,
                          degradedAgents: degraded, problem: problem)
    }

    // MARK: - Store primitives (the only writers of the persisted state)

    /// Another copy of the app owns the socket, and the state files: this one never writes them (two writers would
    /// lose updates). The hooks banner says so.
    var isPersistenceSuspended: Bool { hookServerState == .anotherInstance }

    /// No new delivery may start: the app waits for the turns to end before quitting ("Rien de nouveau ne sera envoyé
    /// aux agents"), or the quit is approved (the termination runs on the next run-loop turn) or in progress. The
    /// dispatcher passes it to `DispatchPolicy` (`quitPending`).
    var isQuitPending: Bool { isWaitingForTurnsToQuit || quitApproved || quitInProgress }

    /// Replaces the workspace and schedules its save.
    func commit(_ newWorkspace: Workspace) {
        guard newWorkspace != workspace else { return }
        workspace = newWorkspace
        guard !isPersistenceSuspended else { return }
        saveVersion += 1
        let version = saveVersion
        let store = persistence
        Task { await store.scheduleSave(newWorkspace, version: version) }
    }

    func commitSettings(_ newSettings: AppSettings) {
        guard newSettings != settings else { return }
        settings = newSettings
        guard !isPersistenceSuspended else { return }
        saveVersion += 1
        let version = saveVersion
        let store = persistence
        Task { await store.scheduleSave(newSettings, version: version) }
    }

    /// Replaces the board and schedules its save. The board changes through `applyTask(_:)`, which calls this.
    func commitBoard(_ newBoard: TaskBoardState) {
        guard newBoard != board else { return }
        board = newBoard
        guard !isPersistenceSuspended else { return }
        saveVersion += 1
        let version = saveVersion
        let store = persistence
        Task { await store.scheduleSave(newBoard, version: version) }
    }

    /// Writes an agent's queue pause (`Agent.queuePaused`, as the reducer's `setQueuePaused` effect does).
    func setQueuePaused(_ paused: Bool, for id: AgentID) {
        var updated = workspace
        if updated.apply(.setQueuePaused(paused), agent: id) { commit(updated) }
    }

    func storeRuntime(_ runtime: AgentRuntime, for id: AgentID) {
        if runtimes[id] != runtime { runtimes[id] = runtime }
    }

    func forgetRuntime(_ id: AgentID) {
        runtimes[id] = nil
        screenSampleTasks.removeValue(forKey: id)?.cancel()
    }

    func setGlobalIssue(_ issue: GlobalIssue?, kind: GlobalIssueKind) {
        globalIssues[kind] = issue
    }

    /// Writes everything pending now (quit).
    func flushPersistence() async {
        guard !isPersistenceSuspended else { return }
        saveVersion += 1
        await persistence.scheduleSave(workspace, version: saveVersion)
        saveVersion += 1
        await persistence.scheduleSave(settings, version: saveVersion)
        saveVersion += 1
        await persistence.scheduleSave(board, version: saveVersion)
        await persistence.flush()
    }

    // MARK: - Transient UI state

    func showToast(_ text: String, style: Toast.Style = .info, agentID: AgentID? = nil) {
        let date = Date()
        toasts.append(Toast(id: UUID(), text: text, style: style, agentID: agentID, createdAt: date))
        if toasts.count > Self.maxToasts { toasts.removeFirst(toasts.count - Self.maxToasts) }
    }

    func dismissToast(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    func expireToasts(at date: Date) {
        guard toasts.contains(where: { date.timeIntervalSince($0.createdAt) >= Self.toastLifetime }) else { return }
        toasts.removeAll { date.timeIntervalSince($0.createdAt) >= Self.toastLifetime }
    }

    func post(_ request: UIRequest) {
        uiRequest = PendingUIRequest(id: UUID(), request: request)
    }

    /// The UI handled `id` (a newer request is kept).
    func consumeUIRequest(_ id: UUID) {
        if uiRequest?.id == id { uiRequest = nil }
    }

    func consumeFocusRequest() {
        focusRequest = nil
    }

    func dismissLoadWarnings() {
        loadWarnings = []
    }

    func updateDockBadge() {
        let count = waitingCount
        guard count != lastBadgeCount else { return }
        lastBadgeCount = count
        DockBadge.update(waiting: count)
    }

    /// Posts a VoiceOver announcement now (the batched sentence of `queueAnnouncement`).
    func announce(_ text: String) {
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// An agent starts waiting (effect `announce`) or falls into an error: it joins the open batch of announcements,
    /// or opens one, posted `AnnouncementBatcher.window` seconds later as one sentence ("3 agents attendent ta
    /// réponse ; Zéphyr est en erreur"), so that with 20 agents VoiceOver is not drowned (7.9).
    func queueAnnouncement(_ kind: AnnouncementKind, for agentID: AgentID) {
        let name = names(of: agentID).agent
        guard let due = announcementBatcher.add(kind, agentName: name, time: announcementTime()) else { return }
        let deadline = announcementEpoch + .seconds(due)
        Task { [weak self] in
            // Never cancelled: the batch opened here is flushed only here.
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard let self else { return }
            if let text = self.announcementBatcher.flush(time: max(due, self.announcementTime())) {
                self.announce(text)
            }
        }
    }

    /// Seconds since `announcementEpoch`.
    private func announcementTime() -> Double {
        let elapsed = (ContinuousClock.now - announcementEpoch).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    /// "Nova" / "API" for texts, with fallbacks.
    func names(of agentID: AgentID) -> (agent: String, project: String) {
        guard let agent = workspace.agent(agentID) else { return ("Agent", "") }
        return (agent.name, workspace.project(agent.projectID)?.name ?? "")
    }
}
