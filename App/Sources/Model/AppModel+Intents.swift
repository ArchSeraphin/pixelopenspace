import AppKit
import Foundation
import PixelCore

/// What the UI (menus, buttons, sheets, `CommandCenter`) may ask about projects, agents, selection and settings.
/// Session intents are in `AppModel+Sessions.swift`. French toasts explain every refusal.
extension AppModel {
    // MARK: - Projects

    /// Adds the folder as a project, or selects the live project already open on it (proposal 6(m)).
    /// `defaults`: agent defaults of the project; `nil` → the app's default model and permission mode.
    @discardableResult
    func addProject(url: URL, name: String? = nil, hueIndex: Int? = nil, defaults: AgentDefaults? = nil) -> ProjectID? {
        let home = NSHomeDirectory()
        let path = PathNormalizer.normalize(url.path(percentEncoded: false), home: home)
        guard Self.isDirectory(path) else {
            showToast("Ce n'est pas un dossier : \(path)", style: .error)
            return nil
        }
        var updated = workspace
        let knownIDs = Set(updated.projects.map(\.id))
        let projectDefaults = defaults ?? AgentDefaults(model: settings.defaultModel,
                                                        permissionMode: settings.defaultPermissionMode)
        let id = updated.addProject(path: path, name: name, hueIndex: hueIndex, defaults: projectDefaults, now: Date())
        if knownIDs.contains(id) {
            let existing = workspace.project(id)?.name ?? path
            showToast("Ce dossier est déjà suivi : projet « \(existing) ».")
        } else {
            commit(updated)
        }
        select(project: id)
        return id
    }

    func renameProject(_ id: ProjectID, to name: String) {
        var updated = workspace
        if updated.renameProject(id, to: name) { commit(updated) }
    }

    func setProjectHue(_ id: ProjectID, to hueIndex: Int) {
        var updated = workspace
        if updated.setProjectHue(id, to: hueIndex) { commit(updated) }
    }

    /// Sidebar order (⌘1…⌘9); the island never moves.
    func moveProject(_ id: ProjectID, toOrder order: Int) {
        var updated = workspace
        if updated.moveProject(id, toOrder: order) { commit(updated) }
    }

    /// Moves a project up (-1) or down (+1) in the sidebar.
    func moveProject(_ id: ProjectID, by offset: Int) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        moveProject(id, toOrder: index + offset)
    }

    /// "Défaut du projet" (template manager, mockup 6(l)): the template the project's cards use when they have
    /// none; `nil` = none.
    func setDefaultTemplate(_ templateID: PromptTemplateID?, forProject projectID: ProjectID) {
        if let templateID, board.template(templateID) == nil {
            showToast("Ce modèle n'existe plus.", style: .warning)
            return
        }
        var updated = workspace
        if updated.setProjectTemplate(projectID, to: templateID) { commit(updated) }
    }

    /// Deletes a prompt template: the cards using it fall back to their project's default, and no project keeps it
    /// as its default.
    func deleteTemplate(_ templateID: PromptTemplateID) {
        applyTask(.deleteTemplate(templateID))
        var updated = workspace
        if updated.forgetTemplate(templateID) { commit(updated) }
    }

    /// Archives a project (its slot becomes free). Its agents must all be offline.
    @discardableResult
    func archiveProject(_ id: ProjectID) -> Bool {
        let running = workspace.agents(in: id).filter { runtimes[$0.id]?.pid != nil }
        guard running.isEmpty else {
            let names = running.map(\.name).joined(separator: ", ")
            showToast("Ferme d'abord les sessions de ce projet (\(names)).", style: .warning)
            return false
        }
        var updated = workspace
        guard updated.archiveProject(id) else { return false }
        commit(updated)
        if selectedProjectID == id {
            selectedProjectID = nil
            selectedAgentID = nil
        }
        return true
    }

    // MARK: - Agents

    /// Adds an agent at the first free desk and, with `launch`, starts a new session (proposal 6(n)). `nil`
    /// arguments take the project's defaults. `initialPrompt` is passed as the positional prompt.
    @discardableResult
    func addAgent(projectID: ProjectID, name: String? = nil, model: String? = nil,
                  permissionMode: PermissionMode? = nil, worktree: String? = nil, launch: Bool = true,
                  initialPrompt: String? = nil) -> AgentID? {
        var updated = workspace
        guard let id = updated.addAgent(to: projectID, name: name, permissionMode: permissionMode, model: model,
                                        worktree: worktree, now: Date()) else {
            showToast("Impossible d'ajouter un agent à ce projet.", style: .error)
            return nil
        }
        commit(updated)
        storeRuntime(AgentRuntime(phase: .offline(.notStarted), phaseSince: Date()), for: id)
        select(agent: id)
        if launch {
            self.launch(id, mode: .new(initialPrompt: initialPrompt))
        }
        return id
    }

    func renameAgent(_ id: AgentID, to name: String) {
        var updated = workspace
        if updated.renameAgent(id, to: name) { commit(updated) }
    }

    /// Removes an offline agent (its session history goes with it; the conversations stay in Claude Code). Its
    /// post-its stay on the board, unassigned (`.agentRemoved`); its queued instructions go.
    @discardableResult
    func removeAgent(_ id: AgentID) -> Bool {
        guard runtimes[id]?.pid == nil, !sessions.isRunning(id) else {
            showToast("Ferme d'abord la session de \(names(of: id).agent).", style: .warning, agentID: id)
            return false
        }
        var updated = workspace
        guard updated.removeAgent(id) else { return false }
        commit(updated)
        applyTask(.agentRemoved(id))
        dispatcher.forget(id)
        forgetRuntime(id)
        sessions.discard(id)
        notifications.withdraw(agentID: id)
        if selectedAgentID == id { selectedAgentID = nil }
        updateDockBadge()
        return true
    }

    // MARK: - Queues (step 2b-2)

    /// "Reprendre la file" (and C9, C14, "Remettre à faire" from the relaunch): the queue paused by an interruption, a
    /// failed delivery or a session lost at launch goes on. Not while the agent's card of "En cours" is stopped
    /// (interrupted, failed turn, lost session, `cardToDecide`): the user settles it first (4.3b), or the next
    /// post-it would start beside it.
    func resumeQueue(_ agentID: AgentID) {
        guard let agent = workspace.agent(agentID) else { return }
        if agent.queuePaused, let card = cardToDecide(of: agentID) {
            showToast("\(agent.name) : \(Self.decideFirstText(card)), puis reprends la file.", style: .warning,
                      agentID: agentID)
            return
        }
        setQueuePaused(false, for: agentID)
        dispatcher.queueResumed(agentID)
    }

    /// "Envoyer quand même", once the user was warned about `shown` (the text of the input box, meant to be a grey
    /// suggestion of Claude Code): the next delivery goes despite that text, while the box still shows it; it lifts
    /// nothing else (no state, event or dialog guard, and the Enter still needs our text alone in the box).
    func sendAnyway(_ agentID: AgentID, over shown: String) {
        dispatcher.sendAnyway(agentID, over: shown)
    }

    /// "Envoyer" on a text of 16 KB or more (proposal 5.6: the app asks before sending).
    func confirmLargeDelivery(_ agentID: AgentID) {
        dispatcher.confirmLargeDelivery(agentID)
    }

    /// "Donner une consigne…" (5.6): sent at once by the same guarded delivery when the agent is free, put at the
    /// head of its queue when it is busy. Returns the refusal's message, if any.
    @discardableResult
    func giveInstruction(to agentID: AgentID, text: String) -> String? {
        let busy = runtimes[agentID].map { !Self.isFreeForDelivery($0) } ?? true
        let effects = applyTask(.giveInstruction(agent: agentID, text: text, instructionID: InstructionID(),
                                                 atHead: busy))
        for case .rejected(_, let message) in effects { return message }
        return nil
    }

    /// At rest, nothing pending: an instruction would go now rather than after the turn.
    static func isFreeForDelivery(_ runtime: AgentRuntime) -> Bool {
        guard runtime.pid != nil, runtime.pendingStop == nil, runtime.pendingDelivery == nil else { return false }
        return runtime.kind == .idle || runtime.kind == .done
    }

    /// "Lancer un nouvel agent avec ce post-it" (3.6, when no agent of the project runs): a new agent of the card's
    /// project, started with the card's prompt as its positional prompt. The card joins its queue and its delivery
    /// is recorded at the launch, so that the prompt's `UserPromptSubmit` moves it to "En cours" (T30b).
    func launchNewAgent(with cardID: TaskCardID) {
        guard let card = board.card(cardID), card.column == .todo else { return }
        guard let projectID = dispatchProject(for: card) else {
            showToast("Choisis d'abord le projet de ce post-it.", style: .warning)
            return
        }
        guard let agentID = addAgent(projectID: projectID, launch: false) else { return }
        applyTask(.assign(cardID, to: agentID))
        guard board.card(cardID)?.assignee == agentID, let prompt = promptPreview(for: cardID), !prompt.isEmpty else {
            return
        }
        dispatcher.expectPositionalLaunch(agentID, item: .card(cardID), text: prompt.text)
        launch(agentID, mode: .new(initialPrompt: prompt.text))
    }

    // MARK: - Selection and navigation

    func select(agent id: AgentID?) {
        selectedAgentID = id
        if let id, let agent = workspace.agent(id) { selectedProjectID = agent.projectID }
    }

    func select(project id: ProjectID?) {
        selectedProjectID = id
        if let agentID = selectedAgentID, workspace.agent(agentID)?.projectID != id { selectedAgentID = nil }
    }

    /// Selects the agent and asks the UI to bring it into view (notification click, waiting tray).
    func requestFocus(_ agentID: AgentID) {
        guard workspace.agent(agentID) != nil else { return }
        select(agent: agentID)
        focusRequest = FocusRequest(id: UUID(), agentID: agentID)
    }

    /// ⌘': the next waiting agent in tray order (oldest wait first), cycling.
    func nextWaitingAgent() {
        guard let next = StatusSummary.nextWaiting(after: selectedAgentID, in: statusSummary) else {
            showToast("Aucun agent n'attend.")
            return
        }
        requestFocus(next)
    }

    /// ⇧⌘': the previous waiting agent, cycling.
    func previousWaitingAgent() {
        let ids = statusSummary.waiting.map(\.agentID)
        guard !ids.isEmpty else {
            showToast("Aucun agent n'attend.")
            return
        }
        guard let current = selectedAgentID, let index = ids.firstIndex(of: current) else {
            requestFocus(ids[ids.count - 1])
            return
        }
        requestFocus(ids[(index - 1 + ids.count) % ids.count])
    }

    /// ⌥⌘→ / ⌥⌘←: next or previous agent in sidebar order, any state.
    func selectAdjacentAgent(offset: Int) {
        let ids = agentsInOrder.map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = selectedAgentID, let index = ids.firstIndex(of: current) else {
            requestFocus(offset >= 0 ? ids[0] : ids[ids.count - 1])
            return
        }
        let count = ids.count
        requestFocus(ids[((index + offset) % count + count) % count])
    }

    /// ⌘1…⌘9.
    func selectProject(number: Int) {
        let list = projects
        guard number >= 1, number <= list.count else { return }
        select(project: list[number - 1].id)
    }

    // MARK: - Settings and Claude Code

    func updateSettings(_ newSettings: AppSettings) {
        let old = settings
        guard newSettings != old else { return }
        commitSettings(newSettings)
        reducerConfig = ReducerConfig(settings: newSettings)
        notifications.prefs = newSettings.notifications
        sessions.terminalPrefs = newSettings.terminal
        if newSettings.claudePathOverride != old.claudePathOverride { redetectClaude() }
    }

    /// Searches for `claude` again (settings changed, "Réessayer" on the welcome sheet).
    func redetectClaude() {
        detectionTask?.cancel()
        claude = .detecting
        let override = settings.claudePathOverride
        detectionTask = Task { [weak self] in
            guard let self else { return }
            let status = await self.locator.locate(override: override)
            guard !Task.isCancelled else { return }
            self.claude = status
            self.environmentSource = self.locator.environmentSource
        }
    }

    /// Brings the other running copy of the app to the front, then quits this one (proposal 3.2).
    func activateOtherInstanceAndQuit() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let bundleID = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
               .first(where: { $0.processIdentifier != ownPID }) {
            _ = other.activate(from: NSRunningApplication.current, options: [])
        }
        quitApproved = true
        requestTermination()
    }
}
