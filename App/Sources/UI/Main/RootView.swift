import AppKit
import PixelCore
import SwiftUI
import UniformTypeIdentifiers

/// The main window (mockup 6(b)): status bar and waiting tray, banners, projects sidebar, agent board and the
/// post-its board panel (⌘B), terminal panel. Performs the model's UI requests (sheets, Settings, terminal,
/// board), focus requests and quit sheet.
struct RootView: View {
    static let minimumPanelHeight: Double = 200
    static let minimumBoardHeight: Double = 180
    /// The agents keep at least this width when the board panel widens.
    static let minimumAgentsWidth: Double = 300

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @AppStorage("terminalPanelHeight") private var panelHeight: Double = 300
    @AppStorage("boardPanelVisible") private var isBoardVisible = true
    @AppStorage("boardPanelWidth") private var boardWidth: Double = 340
    @AppStorage("welcomeShown") private var welcomeShown = false
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var bindable = workbench
        // The split view is the window's root: its detail column then sits right under the toolbar. Nested below
        // other views, macOS 26 still reserved the toolbar's height at the top of the detail column and drew its
        // scroll edge effect there, over the first project header and the board panel's header.
        NavigationSplitView {
            ProjectSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            VStack(spacing: 0) {
                StatusBarView()
                WaitingTrayView()
                BannerStackView()
                Divider()
                GeometryReader { geometry in
                    let maxPanel = max(Self.minimumPanelHeight, Double(geometry.size.height) - Self.minimumBoardHeight)
                    VStack(spacing: 0) {
                        workArea
                            .taskConfirmation($bindable.pendingTask) { pending in
                                model.applyTask(pending.input)
                            }
                        if showsPanel {
                            PanelDivider(height: $panelHeight, range: Self.minimumPanelHeight...maxPanel)
                            TerminalPanelView()
                                .frame(height: min(max(panelHeight, Self.minimumPanelHeight), maxPanel))
                        }
                    }
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .overlay {
            if isDropTargeted { DropHighlight() }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .toolbar { toolbarContent }
        .navigationTitle("Pixel Open Space")
        .sheet(item: $bindable.activeSheet, onDismiss: sheetDismissed) { sheet in
            SheetContentView(sheet: sheet)
                .environment(model)
                .environment(workbench)
        }
        .confirmationDialog(confirmationTitle, isPresented: $bindable.isConfirmationPresented,
                            titleVisibility: .visible, presenting: workbench.confirmation) { confirmation in
            confirmationActions(confirmation)
        } message: { confirmation in
            Text(confirmationMessage(confirmation))
        }
        .focusedSceneValue(\.commandAvailability, CommandAvailability(model: model, workbench: workbench))
        .background(WindowReader { window in workbench.setMainWindow(window) })
        .onAppear(perform: appeared)
        .onDisappear { workbench.mainWindowDisappeared() }
        .onChange(of: model.uiRequest, initial: true) { _, request in
            handle(request)
        }
        .onChange(of: model.focusRequest, initial: true) { _, request in
            handleFocus(request)
        }
        .onChange(of: model.quitRequest, initial: true) { _, request in
            syncQuitSheet(request)
        }
    }

    // MARK: - Layout

    /// The agents, and the post-its board panel on their right.
    private var workArea: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                AgentBoardView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Over the agents, never over the board panel: its last cards stay visible.
                    .overlay(alignment: .bottomTrailing) {
                        ToastOverlay()
                    }
                if isBoardVisible {
                    let range = boardWidthRange(available: Double(geometry.size.width))
                    BoardPanelDivider(width: $boardWidth, range: range)
                    BoardPanelView()
                        .frame(width: min(max(boardWidth, range.lowerBound), range.upperBound))
                }
            }
        }
    }

    /// From the panel's minimum to what leaves the agents `minimumAgentsWidth`.
    private func boardWidthRange(available: Double) -> ClosedRange<Double> {
        let lower = BoardPanelView.minimumWidth
        return lower...max(lower, available - Self.minimumAgentsWidth)
    }

    private var showsPanel: Bool {
        workbench.isTerminalPanelVisible && model.selectedAgentID != nil
    }

    private var panelToggleTitle: String {
        workbench.isTerminalPanelVisible ? "Masquer le terminal" : "Afficher le terminal"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                workbench.commands.perform(.newProject)
            } label: {
                Label("Projet", systemImage: AppCommand.newProject.symbolName)
            }
            .help("Nouveau projet (⌥⌘N), ou dépose un dossier sur la fenêtre")
            Button {
                workbench.commands.perform(.newAgent)
            } label: {
                Label("Agent", systemImage: AppCommand.newAgent.symbolName)
            }
            .disabled(model.projects.isEmpty)
            .help("Nouvel agent dans le projet sélectionné (⇧⌘N)")
            Button {
                isBoardVisible.toggle()
            } label: {
                Label(isBoardVisible ? "Masquer le tableau" : "Afficher le tableau",
                      systemImage: AppCommand.toggleBoard.symbolName)
            }
            .help("Afficher ou masquer le tableau des post-its (⌘B)")
            Button {
                workbench.togglePanel()
            } label: {
                Label(panelToggleTitle, systemImage: AppCommand.toggleTerminalPanel.symbolName)
            }
            .help("Afficher ou masquer le terminal (⌥⌘T)")
            Button {
                openSettings()
            } label: {
                Label("Réglages", systemImage: AppCommand.showSettings.symbolName)
            }
            .help("Réglages (⌘,)")
        }
    }

    // MARK: - Lifecycle and requests

    private func appeared() {
        workbench.mainWindowAppeared()
        workbench.openWindowAction = openWindow
        if !welcomeShown {
            welcomeShown = true
            if workbench.activeSheet == nil { workbench.present(.claudeSetup) }
        }
    }

    private var isShowingQuitSheet: Bool {
        if case .quit = workbench.activeSheet { return true }
        return false
    }

    /// Performs a `UIRequest` of the model (menus, `CommandCenter`, launch failures), then consumes it.
    private func handle(_ pending: PendingUIRequest?) {
        guard let pending else { return }
        model.consumeUIRequest(pending.id)
        switch pending.request {
        case .newProject:
            presentSheet(.newProject(nil))
        case .newAgent(let projectID):
            presentSheet(model.projects.isEmpty ? .newProject(nil) : .newAgent(projectID))
        case .showSettings:
            openSettings()
        case .toggleTerminalPanel:
            workbench.togglePanel()
        case .openTerminal(let agentID):
            workbench.showTerminal(for: agentID, focus: true)
        case .claudeSetup:
            presentSheet(.claudeSetup)
        case .newCard:
            // The title field would take the focus behind an open sheet.
            guard workbench.activeSheet == nil else { return workbench.bringMainWindowForward() }
            isBoardVisible = true
            workbench.requestQuickAdd()
            workbench.bringMainWindowForward()
        case .pasteCards:
            guard workbench.activeSheet == nil else { return workbench.bringMainWindowForward() }
            isBoardVisible = true
            presentSheet(.pasteCards)
        case .manageTemplates:
            presentSheet(.templates)
        case .toggleBoard:
            isBoardVisible.toggle()
        }
    }

    /// Never replaces an open sheet: the quit sheet must be answered first, and another one may hold unsaved edits
    /// (post-it editor, templates). The request is dropped and the open sheet comes forward; the menus grey these
    /// commands out meanwhile (`WorkbenchState.isAvailable`).
    private func presentSheet(_ sheet: ActiveSheet) {
        guard workbench.activeSheet == nil else { return workbench.bringMainWindowForward() }
        workbench.present(sheet)
        workbench.bringMainWindowForward()
    }

    /// Notification click, ⌘', ⌥⌘→: select and show the agent; a waiting agent's terminal opens, ready for the answer.
    private func handleFocus(_ request: FocusRequest?) {
        guard let request else { return }
        model.consumeFocusRequest()
        let agentID = request.agentID
        workbench.reveal(agentID)
        let waits = !(model.runtime(for: agentID)?.pendingWaits.isEmpty ?? true)
        if waits, model.hasTerminal(agentID) {
            workbench.showTerminal(for: agentID, focus: true)
        }
        if !workbench.detachedAgents.contains(agentID) {
            workbench.bringMainWindowForward()
        }
    }

    private func syncQuitSheet(_ request: QuitRequest?) {
        if let request {
            workbench.present(.quit(request.id))
            workbench.bringMainWindowForward()
        } else if isShowingQuitSheet {
            workbench.dismissSheet()
        }
    }

    /// The quit sheet closed without an answer (Escape): the quit is cancelled.
    private func sheetDismissed() {
        guard model.quitRequest != nil, !isShowingQuitSheet else { return }
        model.respondToQuit(.cancel)
    }

    // MARK: - Confirmations (6(d))

    private var confirmationTitle: String {
        guard let confirmation = workbench.confirmation else { return "" }
        let name = model.agent(confirmation.agentID)?.name ?? "l'agent"
        switch confirmation {
        case .closeSession: return "Fermer la session de \(name) ?"
        case .remove: return "Retirer \(name) ?"
        case .sendOverDraft: return "Envoyer le post-it par-dessus la zone de saisie de \(name) ?"
        }
    }

    @ViewBuilder
    private func confirmationActions(_ confirmation: AgentConfirmation) -> some View {
        switch confirmation {
        case .closeSession:
            Button("Fermer la session", role: .destructive) { workbench.confirm(confirmation) }
        case .remove:
            Button("Retirer l'agent", role: .destructive) { workbench.confirm(confirmation) }
        case .sendOverDraft(let agentID, _):
            Button("C'est une suggestion : envoyer") { workbench.confirm(confirmation) }
            Button("Ouvrir le terminal") {
                workbench.confirmation = nil
                workbench.showTerminal(for: agentID, focus: true)
            }
        }
        Button("Annuler", role: .cancel) { workbench.confirmation = nil }
    }

    private func confirmationMessage(_ confirmation: AgentConfirmation) -> String {
        let name = model.agent(confirmation.agentID)?.name ?? "L'agent"
        switch confirmation {
        case .closeSession:
            let state = model.display(for: confirmation.agentID)?.title.lowercased() ?? "occupé"
            return "\(name) n'est pas au repos (\(state)). Fermer la session interrompt le tour en cours ; "
                + "la conversation pourra être reprise avec « Relancer »."
        case .remove:
            return "\(name) disparaît de l'app avec son historique de sessions. Les conversations restent dans "
                + "Claude Code et le dossier du projet n'est pas touché."
        case .sendOverDraft(_, let shown):
            return "La zone de saisie montre « \(shown) ». S'il s'agit d'une suggestion grisée de Claude Code, "
                + "elle s'efface à la première lettre et le post-it part normalement. S'il s'agit d'un texte que tu "
                + "as tapé, le post-it s'écrirait à sa suite : l'envoi s'arrêterait avant l'Entrée, les deux textes "
                + "resteraient mêlés dans le terminal et la file se mettrait en pause. Dans ce cas, vide d'abord la "
                + "zone de saisie dans le terminal."
        }
    }

    // MARK: - Dropping folders (6(m))

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        let workbench = self.workbench
        let collector = DroppedURLCollector(expected: fileProviders.count) { urls in
            workbench.addDroppedFolders(urls)
        }
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { @Sendable url, _ in
                collector.add(url)
            }
        }
        return true
    }
}

/// Dashed frame shown while a folder is dragged over the window.
private struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .background(Color.accentColor.opacity(0.06))
            .overlay {
                Label("Dépose le dossier pour créer un projet", systemImage: "folder.badge.plus")
                    .font(.title3.weight(.semibold))
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(6)
            .allowsHitTesting(false)
    }
}
