import AppKit
import Foundation
import Observation
import PixelCore
import SwiftUI

/// Scene identifiers (`openWindow(id:)`).
enum WindowID {
    /// The single main window (`Window` scene).
    static let main = "main"
    /// A detached terminal, one window per agent (`WindowGroup(for: AgentID.self)`).
    static let terminal = "terminal"
}

/// The sheet shown by the main window. One at a time: presenting another one replaces it.
enum ActiveSheet: Identifiable, Equatable {
    /// "Nouveau projet" (mockup 6(m)), with the folder already chosen or dropped.
    case newProject(URL?)
    /// "Nouvel agent" (mockup 6(n)) for this project, or the one picked in the sheet.
    case newAgent(ProjectID?)
    /// Welcome and Claude Code status (mockup 6(r)).
    case claudeSetup
    case renameProject(ProjectID)
    case renameAgent(AgentID)
    /// Quit sheet (mockup 6(p)) for `AppModel.quitRequest` with this id.
    case quit(UUID)
    /// Post-it editor (mockup 6(l)).
    case cardEditor(TaskCardID)
    /// "Coller une liste": one post-it per line, prefilled with the clipboard.
    case pasteCards
    /// "Gérer les modèles" (mockup 6(l)).
    case templates
    /// "Renvoyer avec une précision" (↺, C17) for a card of "À valider".
    case resendCard(TaskCardID)
    /// "Donner une consigne…" to an agent (proposal 5.6).
    case giveInstruction(AgentID)

    var id: String {
        switch self {
        case .newProject: return "newProject"
        case .newAgent: return "newAgent"
        case .claudeSetup: return "claudeSetup"
        case .renameProject(let projectID): return "renameProject-\(projectID)"
        case .renameAgent(let agentID): return "renameAgent-\(agentID)"
        case .quit(let requestID): return "quit-\(requestID)"
        case .cardEditor(let cardID): return "cardEditor-\(cardID)"
        case .pasteCards: return "pasteCards"
        case .templates: return "templates"
        case .resendCard(let cardID): return "resendCard-\(cardID)"
        case .giveInstruction(let agentID): return "giveInstruction-\(agentID)"
        }
    }
}

/// An agent action that needs a confirmation dialog (6(d): closing a busy session, removing an agent).
enum AgentConfirmation: Equatable {
    case closeSession(AgentID)
    case remove(AgentID)

    var agentID: AgentID {
        switch self {
        case .closeSession(let agentID), .remove(let agentID): return agentID
        }
    }
}

/// A board input that waits for the user's confirmation (`TaskLifecycle.confirmation(for:)`: C3, C18 from
/// "À faire" or "En cours", C20 from "En cours").
struct PendingTaskInput: Equatable {
    let input: TaskInput
    let kind: ConfirmationKind
}

/// "Scroll the board to this card or section". A new `id` each time, so the same target can be asked twice.
struct ScrollRequest: Equatable {
    enum Target: Equatable {
        case agent(AgentID)
        case project(ProjectID)
    }

    let id: UUID
    let target: Target
}

/// UI-only state of the windows (never persisted, never read by the model): sheets, terminal panel, filter,
/// detached terminals, scroll and focus requests. Model state stays in `AppModel`.
@MainActor
@Observable
final class WorkbenchState {
    @ObservationIgnored let model: AppModel
    @ObservationIgnored let commands: CommandCenter
    @ObservationIgnored let presenter: TerminalPresenter

    var activeSheet: ActiveSheet?
    /// Confirmation dialog of the main window.
    var confirmation: AgentConfirmation?
    /// Board input waiting for a confirmation dialog (assign across projects, done without review, delete a card
    /// in progress).
    var pendingTask: PendingTaskInput?
    /// Changes when ⌘N asks for the title field at the top of "À faire".
    private(set) var quickAddRequest: UUID?
    /// The terminal panel under the board (shown for the selected agent).
    var isTerminalPanelVisible = true
    /// Status-bar filter: only agents in this state are shown on the board.
    var stateFilter: AgentStateKind?
    /// Agents whose terminal is shown in its own window.
    private(set) var detachedAgents: Set<AgentID> = []
    /// Changes when the panel's terminal must take the keyboard focus.
    private(set) var panelFocusToken: UUID?
    private(set) var scrollRequest: ScrollRequest?

    /// Whether the main window's content is on screen (`RootView` appeared and not disappeared).
    @ObservationIgnored private(set) var isMainWindowOpen = false
    @ObservationIgnored private weak var mainWindow: NSWindow?
    /// The last `openWindow` action seen by a view, to reopen the main window when it is closed.
    @ObservationIgnored var openWindowAction: OpenWindowAction?
    @ObservationIgnored private var isWatchingRequests = false

    private static var sharedInstance: WorkbenchState?

    /// The app's single instance, wired to the environment's model, commands and terminal presenter. It tells the
    /// notifications which agents the user can see.
    static func shared(for environment: AppEnvironment) -> WorkbenchState {
        if let sharedInstance { return sharedInstance }
        let instance = WorkbenchState(model: environment.model, commands: environment.commands,
                                      presenter: environment.presenter)
        sharedInstance = instance
        environment.notifications.isAgentVisible = { [weak instance] agentID in
            instance?.isAgentVisible(agentID) ?? false
        }
        return instance
    }

    init(model: AppModel, commands: CommandCenter, presenter: TerminalPresenter) {
        self.model = model
        self.commands = commands
        self.presenter = presenter
    }

    // MARK: - Main window

    func mainWindowAppeared() {
        isMainWindowOpen = true
    }

    func mainWindowDisappeared() {
        isMainWindowOpen = false
    }

    func setMainWindow(_ window: NSWindow?) {
        mainWindow = window
    }

    /// Whether the user can see the agent now ("tour terminé" with the app in front, proposal 3.12): its terminal in
    /// a window on screen, or its card on the board of the main window on screen (not hidden by the state filter).
    func isAgentVisible(_ agentID: AgentID) -> Bool {
        if let window = presenter.window(showing: agentID), Self.isOnScreen(window) { return true }
        guard isMainWindowOpen, let window = mainWindow, Self.isOnScreen(window) else { return false }
        if let filter = stateFilter, model.runtime(for: agentID)?.kind != filter { return false }
        return true
    }

    private static func isOnScreen(_ window: NSWindow) -> Bool {
        window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    /// Brings the main window in front (it may be miniaturized or behind a terminal window).
    func bringMainWindowForward() {
        NSApplication.shared.activate()
        guard isMainWindowOpen, let window = mainWindow else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Reopens the main window when the model asks for something only it can show (notification click, quit sheet,
    /// a sheet asked from the menu) while it is closed: the app keeps running without windows (proposal 2.5).
    func startWatchingRequests() {
        guard !isWatchingRequests else { return }
        isWatchingRequests = true
        observeRequests()
    }

    private func observeRequests() {
        let model = self.model
        withObservationTracking {
            _ = model.focusRequest
            _ = model.uiRequest
            _ = model.quitRequest
        } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.requestsChanged()
                self.observeRequests()
            }
        }
    }

    private func requestsChanged() {
        guard !isMainWindowOpen else { return }
        guard model.focusRequest != nil || model.uiRequest != nil || model.quitRequest != nil else { return }
        NSApplication.shared.activate()
        if let openWindow = openWindowAction { openWindow(id: WindowID.main) }
    }

    // MARK: - Sheets

    func present(_ sheet: ActiveSheet) {
        activeSheet = sheet
    }

    func dismissSheet() {
        activeSheet = nil
    }

    // MARK: - Confirmations

    /// For `.confirmationDialog(isPresented:)` (through `@Bindable`).
    var isConfirmationPresented: Bool {
        get { confirmation != nil }
        set { if !newValue { confirmation = nil } }
    }

    /// "Fermer la session": at once when the agent is at rest, after a confirmation when it is busy.
    func requestCloseSession(_ agentID: AgentID) {
        let actions = AgentActions(model: model, agentID: agentID)
        guard actions.canClose else { return }
        if actions.closeNeedsConfirmation {
            askConfirmation(.closeSession(agentID))
        } else {
            model.closeSession(agentID)
        }
    }

    /// "Retirer l'agent": always confirmed.
    func requestRemove(_ agentID: AgentID) {
        guard AgentActions(model: model, agentID: agentID).canRemove else { return }
        askConfirmation(.remove(agentID))
    }

    func confirm(_ confirmation: AgentConfirmation) {
        self.confirmation = nil
        switch confirmation {
        case .closeSession(let agentID): model.closeSession(agentID)
        case .remove(let agentID): model.removeAgent(agentID)
        }
    }

    private func askConfirmation(_ confirmation: AgentConfirmation) {
        self.confirmation = confirmation
        if !isMainWindowOpen, let openWindow = openWindowAction {
            openWindow(id: WindowID.main)
        } else {
            bringMainWindowForward()
        }
    }

    // MARK: - Cork board

    /// Applies a board input (context menu, drop), after the main window's confirmation dialog
    /// (`.taskConfirmation`) when the reducer asks for one. A refusal shows as a toast (the reducer's message).
    func requestTask(_ input: TaskInput) {
        if let kind = model.taskConfirmation(for: input) {
            pendingTask = PendingTaskInput(input: input, kind: kind)
        } else {
            model.applyTask(input)
        }
    }

    /// ⌘N: the board panel shows the title field at the top of "À faire".
    func requestQuickAdd() {
        quickAddRequest = UUID()
    }

    /// The board panel showed the title field.
    func consumeQuickAdd() {
        quickAddRequest = nil
    }

    func editCard(_ cardID: TaskCardID) {
        guard model.board.card(cardID) != nil, activeSheet.map(Self.isQuit) != true else { return }
        present(.cardEditor(cardID))
    }

    private static func isQuit(_ sheet: ActiveSheet) -> Bool {
        if case .quit = sheet { return true }
        return false
    }

    // MARK: - Board

    /// Status-bar counter clicked: filters the board on that state, or removes the filter.
    func toggleFilter(_ kind: AgentStateKind) {
        stateFilter = stateFilter == kind ? nil : kind
    }

    func scroll(to target: ScrollRequest.Target) {
        scrollRequest = ScrollRequest(id: UUID(), target: target)
    }

    /// Selects the agent and scrolls the board to its card (removing a filter that would hide it).
    func reveal(_ agentID: AgentID) {
        model.select(agent: agentID)
        if let filter = stateFilter, model.runtime(for: agentID)?.kind != filter {
            stateFilter = nil
        }
        scroll(to: .agent(agentID))
    }

    func reveal(project projectID: ProjectID) {
        model.select(project: projectID)
        scroll(to: .project(projectID))
    }

    // MARK: - Projects

    /// Folders dropped on the window (6(m)): one folder opens "Nouveau projet" prefilled (or selects the project
    /// already open on it); several folders are added at once with the defaults.
    func addDroppedFolders(_ urls: [URL]) {
        let folders = urls.filter { AppModel.isDirectory($0.path(percentEncoded: false)) }
        guard !folders.isEmpty else {
            model.showToast("Dépose un dossier (pas un fichier) pour créer un projet.", style: .warning)
            return
        }
        if folders.count == 1, let url = folders.first {
            if let existing = model.liveProject(forFolder: url) {
                reveal(project: existing.id)
                model.showToast("Ce dossier est déjà suivi : projet « \(existing.name) ».")
            } else if case .quit = activeSheet {
                return
            } else {
                present(.newProject(url))
            }
            return
        }
        for url in folders {
            model.addProject(url: url)
        }
    }

    // MARK: - Terminals

    /// Shows the agent's terminal: its own window when detached, otherwise the panel. Selecting and showing it
    /// acknowledges the agent (the presenter reports it; acknowledged here too for a terminal already on screen).
    func showTerminal(for agentID: AgentID, focus: Bool) {
        reveal(agentID)
        if detachedAgents.contains(agentID), let openWindow = openWindowAction {
            openWindow(id: WindowID.terminal, value: agentID)
        } else {
            isTerminalPanelVisible = true
            if focus { panelFocusToken = UUID() }
        }
        model.acknowledge(agentID)
    }

    /// Waiting tray row clicked: select, open the terminal with the keyboard focus, acknowledge.
    func openWaitingAgent(_ agentID: AgentID) {
        showTerminal(for: agentID, focus: true)
    }

    /// "Détacher": the terminal moves to its own window (the same SwiftTerm view, the process is untouched).
    func detach(_ agentID: AgentID, using openWindow: OpenWindowAction) {
        detachedAgents.insert(agentID)
        openWindow(id: WindowID.terminal, value: agentID)
    }

    /// A detached terminal window shows this agent (opened, or restored at launch).
    func terminalWindowOpened(_ agentID: AgentID) {
        detachedAgents.insert(agentID)
    }

    /// The detached window closed or was docked: the panel shows the terminal again.
    func terminalWindowClosed(_ agentID: AgentID) {
        detachedAgents.remove(agentID)
    }

    func togglePanel() {
        isTerminalPanelVisible.toggle()
    }

    func focusPanelTerminal() {
        panelFocusToken = UUID()
    }
}
