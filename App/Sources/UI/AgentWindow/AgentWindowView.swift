import AppKit
import PixelCore
import SwiftUI

/// The agent window (mockups 6(d), 6(e), 6(e′); simple SwiftUI, the retro 9-slice skin comes at step 4): the header
/// (portrait, state and duration, post-it in progress, model, permission mode, session), what the agent waits for,
/// "Donner une consigne", its queue, and the buttons of 6(d), greyed with the reason in their tooltip.
///
/// Keyboard: ⌘W closes; ⌘T opens the terminal; ⌘. interrupts at once; Escape interrupts only while the agent thinks
/// or works, after a 1.5 s toast that can be cancelled (5.8), and closes the window otherwise.
struct AgentWindowView: View {
    static let minimumWidth: CGFloat = 560
    static let idealWidth: CGFloat = 640
    static let minimumHeight: CGFloat = 240
    /// Escape waits this long before sending the interruption (5.8).
    static let escapeDelay: Duration = .milliseconds(1500)

    let agentID: AgentID

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var pendingInterrupt: Task<Void, Never>?

    var body: some View {
        // The panel fits the content's height (`AgentWindowController.contentHeightChanged`); the scroll view only
        // serves when the screen is too short or the user made the window smaller.
        ScrollView(.vertical) {
            Group {
                if let agent = model.agent(agentID), let project = model.project(agent.projectID) {
                    content(agent: agent, project: project)
                } else {
                    Text("Cet agent n'existe plus.")
                        .foregroundStyle(.secondary)
                        .padding(24)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                AgentWindowController.shared.contentHeightChanged(agentID, height: height)
            }
        }
        .frame(minWidth: Self.minimumWidth, minHeight: Self.minimumHeight)
        .background(shortcuts)
        .overlay(alignment: .bottom) {
            if pendingInterrupt != nil {
                interruptToast
            }
        }
        .onChange(of: AgentActions(model: model, agentID: agentID).canInterrupt) { _, canInterrupt in
            // The turn ended (or a dialog opened) during the countdown: nothing left to interrupt.
            if !canInterrupt { cancelInterrupt() }
        }
        .onDisappear { cancelInterrupt() }
    }

    private func content(agent: Agent, project: Project) -> some View {
        let actions = AgentActions(model: model, agentID: agentID)
        let waits = !(model.runtime(for: agentID)?.pendingWaits.isEmpty ?? true)
        return VStack(alignment: .leading, spacing: 0) {
            AgentWindowHeader(agent: agent, project: project, frozen: isFrozen, escapeHint: escapeHint(actions))
            Divider()
            if waits {
                AgentWaitSection(agentID: agentID, canOpenTerminal: actions.canOpenTerminal, openTerminal: openTerminal)
                Divider()
            }
            AgentInstructionSection(agentID: agentID, agentName: agent.name)
            Divider()
            AgentQueueSection(agentID: agentID)
            Divider()
            AgentWindowButtons(agent: agent, openTerminal: openTerminal, interrupt: interruptNow)
        }
    }

    /// "Échap : interrompre" while the agent thinks or works (5.8), "Échap : fermer" otherwise.
    private func escapeHint(_ actions: AgentActions) -> String {
        if pendingInterrupt != nil { return "Échap : annuler l'interruption" }
        return actions.canInterrupt ? "Échap : interrompre" : "Échap : fermer"
    }

    /// The portrait stands still with Reduce Motion (the app's or macOS's) and in the snapshot harness.
    private var isFrozen: Bool {
        model.settings.reduceMotion || systemReduceMotion || SnapshotHooks.shared.isEnabled
    }

    // MARK: Keyboard

    /// ⌘W, Escape, ⌘T and ⌘. for the whole window, whatever has the focus. Always enabled, so that a greyed button
    /// never lets the key fall through to the main menu, whose commands act on the selected agent.
    private var shortcuts: some View {
        ZStack {
            Button("Fermer la fenêtre") { close() }
                .keyboardShortcut("w", modifiers: .command)
            Button("Échap") { escape() }
                .keyboardShortcut(.cancelAction)
            Button("Ouvrir le terminal") { openTerminal() }
                .keyboardShortcut("t", modifiers: .command)
            Button("Interrompre") { interruptNow() }
                .keyboardShortcut(".", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var interruptToast: some View {
        HStack(spacing: 10) {
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(StateStyle.tint(for: .error))
                .accessibilityHidden(true)
            Text("Interruption dans 1,5 s")
                .font(.callout.weight(.semibold))
            Button("Annuler") { cancelInterrupt() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
        .shadow(radius: 4, y: 1)
        .padding(.bottom, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Interruption dans une seconde et demie")
    }

    // MARK: Actions

    private func close() {
        cancelInterrupt()
        AgentWindowController.shared.close(agentID)
    }

    /// Escape (5.8): cancels a pending interruption; interrupts, after the toast, only while the agent thinks or
    /// works; closes the window otherwise, as everywhere on macOS.
    private func escape() {
        if pendingInterrupt != nil {
            cancelInterrupt()
            return
        }
        guard AgentActions(model: model, agentID: agentID).canInterrupt else {
            close()
            return
        }
        let model = self.model
        let agentID = self.agentID
        pendingInterrupt = Task { @MainActor in
            try? await Task.sleep(for: Self.escapeDelay)
            guard !Task.isCancelled else { return }
            pendingInterrupt = nil
            if AgentActions(model: model, agentID: agentID).canInterrupt {
                model.interrupt(agentID)
            }
        }
    }

    private func cancelInterrupt() {
        pendingInterrupt?.cancel()
        pendingInterrupt = nil
    }

    /// The button and ⌘. interrupt at once (5.8).
    private func interruptNow() {
        cancelInterrupt()
        guard AgentActions(model: model, agentID: agentID).canInterrupt else {
            NSSound.beep()
            return
        }
        model.interrupt(agentID)
    }

    /// The agent's terminal with the keyboard focus: its own window when detached, otherwise the main window's
    /// panel, brought forward (the agent window keeps the focus otherwise).
    private func openTerminal() {
        guard AgentActions(model: model, agentID: agentID).canOpenTerminal else {
            NSSound.beep()
            return
        }
        workbench.showTerminal(for: agentID, focus: true)
        guard !workbench.detachedAgents.contains(agentID) else { return }
        if workbench.isMainWindowOpen {
            workbench.bringMainWindowForward()
        } else if let openWindow = workbench.openWindowAction {
            NSApplication.shared.activate()
            openWindow(id: WindowID.main)
        }
    }
}

// MARK: - Header

/// "Nova · API", state and duration, post-it in progress, model, permission mode, session (6(d)).
private struct AgentWindowHeader: View {
    let agent: Agent
    let project: Project
    let frozen: Bool
    let escapeHint: String

    @Environment(AppModel.self) private var model

    var body: some View {
        let runtime = model.runtime(for: agent.id)
        let display = model.display(for: agent.id)
        let kind = display?.kind ?? .offline
        let animation = runtime.flatMap {
            AgentPresenter.scene($0, now: model.now, agentName: agent.name, projectName: project.name,
                                 options: ScenePresentationOptions(reduceMotion: frozen,
                                                                   permissionMode: agent.permissionMode)).animation
        }
        HStack(alignment: .top, spacing: 16) {
            AgentPortraitView(look: agent.look, projectHue: project.hueIndex, animation: animation, frozen: frozen)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ProjectHueSquare(hueIndex: project.hueIndex, size: 12)
                    Text("\(agent.name) · \(project.name)")
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Text(escapeHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                    row("État") {
                        Label {
                            Text(stateText(display))
                                .fontWeight(.bold)
                                .lineLimit(2)
                        } icon: {
                            Image(systemName: display?.symbolName ?? "power")
                        }
                        .foregroundStyle(StateStyle.tint(for: kind))
                    }
                    row("Depuis") {
                        Text(display.map { AgentWindowText.duration(model.now.timeIntervalSince($0.since)) } ?? "-")
                            .monospacedDigit()
                    }
                    row("Tâche") {
                        if let card = model.currentCard(of: agent.id) {
                            Text(card.title)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(card.title)
                        } else {
                            Text("aucune").foregroundStyle(.secondary)
                        }
                    }
                    row("Modèle") {
                        Text(model.effectiveModel(of: agent) ?? "modèle par défaut")
                    }
                    row("Permissions") {
                        permissionText
                    }
                    row("Session") {
                        sessionText(runtime)
                    }
                }
                .font(.callout)
                if let badges = display?.badges, !badges.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(badges, id: \.self) { badge in
                            Text(badge)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.accessibilityLabel(for: agent.id) ?? agent.name)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "TRAVAILLE : commande", "ATTEND TA RÉPONSE" (the wait itself is detailed below), "HORS LIGNE : session fermée".
    private func stateText(_ display: AgentStatusDisplay?) -> String {
        guard let display else { return "HORS LIGNE" }
        let title = display.title.uppercased()
        guard display.kind != .waitingInput, let detail = display.detail, !detail.isEmpty else { return title }
        return "\(title) : \(detail)"
    }

    /// "default · demande avant les actions sensibles", in red and with a warning for bypassPermissions.
    private var permissionText: some View {
        let mode = agent.permissionMode
        let risky = PermissionModeInfo.isRisky(mode)
        return Text("\(mode.rawValue) · \(PermissionModeInfo.summary(mode))")
            .foregroundStyle(risky ? StateStyle.tint(for: .error) : Color.primary)
            .lineLimit(1)
            .help(risky ? PermissionModeInfo.bypassWarning : PermissionModeInfo.summary(mode))
    }

    /// "7d2f1a3b… · 3 sessions", or "aucune".
    private func sessionText(_ runtime: AgentRuntime?) -> some View {
        let current = runtime?.currentSessionID ?? agent.sessions.last?.sessionID
        let count = agent.sessions.count
        let history = count > 1 ? "\(count) sessions" : count == 1 ? "1 session" : nil
        let text = [current.map(AgentWindowText.shortSession), history].compactMap { $0 }.joined(separator: " · ")
        return Text(text.isEmpty ? "aucune" : text)
            .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
            .help(current.map { "Session \($0)" } ?? "Aucune session encore")
    }
}

// MARK: - Instruction

/// "Donner une consigne" (5.6): sent at once by the guarded delivery when the agent is free, at the head of its queue
/// when it is busy.
private struct AgentInstructionSection: View {
    let agentID: AgentID
    let agentName: String

    @Environment(AppModel.self) private var model

    @State private var text = ""
    @State private var errorMessage: String?

    var body: some View {
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 8) {
            Text("Donner une consigne")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                TextField("Consigne pour \(agentName)", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                    .accessibilityLabel("Consigne pour \(agentName)")
                Button("Envoyer ↩", action: send)
                    .disabled(isEmpty)
                    .help("Donner la consigne (↩)")
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(StateStyle.tint(for: .error))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Donner une consigne")
    }

    /// Where the instruction goes, from the agent's state now (same rules as `AppModel.giveInstruction`).
    private var note: String? {
        var parts: [String] = []
        if let runtime = model.runtime(for: agentID), runtime.pid != nil {
            if !AppModel.isFreeForDelivery(runtime) { parts.append("Occupé : la consigne passera en tête de file.") }
        } else {
            parts.append("Pas de session en cours : la consigne attendra en tête de file.")
        }
        if model.agent(agentID)?.queuePaused == true {
            parts.append("File en pause : reprends-la pour que la consigne parte.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func send() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let message = model.giveInstruction(to: agentID, text: text) {
            errorMessage = message
            return
        }
        errorMessage = nil
        text = ""
    }
}

// MARK: - Buttons

/// The buttons of mockup 6(d), always shown, greyed with the reason in their tooltip when they do not apply now.
/// "Reprendre la file" sits in the queue section, beside "Mettre en pause".
private struct AgentWindowButtons: View {
    let agent: Agent
    let openTerminal: @MainActor () -> Void
    let interrupt: @MainActor () -> Void

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    var body: some View {
        let availability = AgentWindowAvailability(model: model, agent: agent)
        let actions = availability.actions
        AgentWindowFlowLayout(spacing: 8, lineSpacing: 8) {
            button("Terminal ⌘T", symbol: "terminal", availability.terminal) { openTerminal() }
            button("Interrompre ⌘.", symbol: "stop.circle", availability.interrupt) { interrupt() }
            button("Relancer la session", symbol: "arrow.clockwise", availability.relaunch) {
                workbench.reveal(agent.id)
                model.relaunch(agent.id)
            }
            button("Continuer la tâche", symbol: "arrow.uturn.forward", availability.continueTask) {
                if let card = availability.cardToDecide {
                    workbench.requestTask(.continueTask(card.id, instructionID: InstructionID()))
                }
            }
            button("Envoyer quand même…", symbol: "paperplane", availability.sendAnyway) {
                workbench.requestSendAnyway(agent.id)
            }
            button(actions.closeNeedsConfirmation ? "Fermer la session…" : "Fermer la session", symbol: "power",
                   availability.closeSession) {
                workbench.requestCloseSession(agent.id)
            }
            if actions.isOrphan {
                button("Terminer l'ancienne session", symbol: "xmark.circle",
                       .init(enabled: true, help: "Une session de \(agent.name) tourne encore hors de l'app : "
                             + "l'arrêter pour pouvoir relancer")) {
                    model.terminateOrphan(agent.id)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlSize(.regular)
        .labelStyle(.titleAndIcon)
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions")
    }

    private func button(_ title: String, symbol: String, _ state: AgentWindowAvailability.Item,
                        action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .disabled(!state.enabled)
        .help(state.help)
    }
}

/// What each button of the window offers now (table of mockup 6(d)), with its tooltip: what it does, or why it is
/// greyed out. Built on `AgentActions`, the same rules as the list's buttons and menus.
@MainActor
struct AgentWindowAvailability {
    struct Item {
        var enabled: Bool
        var help: String
    }

    let actions: AgentActions
    /// The stopped post-it "En cours" (interrupted, failed turn, lost session) that "Continuer la tâche" restarts.
    let cardToDecide: TaskCard?
    let terminal: Item
    let interrupt: Item
    let relaunch: Item
    let continueTask: Item
    let sendAnyway: Item
    let closeSession: Item

    init(model: AppModel, agent: Agent) {
        let actions = AgentActions(model: model, agentID: agent.id)
        self.actions = actions
        let runtime = actions.runtime
        let kind = runtime?.kind ?? .offline
        let name = agent.name

        terminal = actions.canOpenTerminal
            ? Item(enabled: true, help: "Ouvrir le terminal de \(name) (⌘T)")
            : Item(enabled: false, help: actions.isOffline ? "Hors ligne : relance d'abord la session"
                                                           : "Aucun terminal pour l'instant")

        interrupt = actions.canInterrupt
            ? Item(enabled: true, help: "Envoie Échap à Claude Code, sans délai (⌘.)")
            : Item(enabled: false, help: kind == .waitingInput
                ? "L'agent attend ta réponse : refuse dans le terminal plutôt qu'interrompre"
                : actions.interruptUnavailableReason)

        if actions.canRelaunch {
            relaunch = Item(enabled: true, help: "Reprendre la dernière conversation de \(name) (⇧⌘R)")
        } else if actions.isOrphan {
            relaunch = Item(enabled: false, help: "Une session de \(name) tourne encore hors de l'app : termine-la "
                            + "d'abord")
        } else if actions.isRunning {
            relaunch = Item(enabled: false, help: "La session tourne : rien à relancer")
        } else {
            relaunch = Item(enabled: false, help: "Rien à relancer")
        }

        let card = model.cardToDecide(of: agent.id)
        cardToDecide = card
        continueTask = Self.continueItem(card: card, runtime: runtime, kind: kind)

        if model.deliveryWaitCause(of: agent.id) == .draftInInputBox {
            sendAnyway = Item(enabled: true, help: "Un texte attend dans la zone de saisie de Claude Code : le post-it "
                              + "suivant l'écrase, après un avertissement")
        } else if kind == .waitingBackground {
            sendAnyway = Item(enabled: false, help: "Une tâche de fond tourne : la file repart quand elle se termine. "
                              + "Pour écrire à l'agent maintenant, ouvre le terminal")
        } else {
            sendAnyway = Item(enabled: false, help: "Seulement quand un brouillon bloque l'envoi du post-it suivant")
        }

        closeSession = actions.canClose
            ? Item(enabled: true, help: actions.closeNeedsConfirmation
                ? "Arrêter la session de \(name) : un tour, une attente ou une tâche de fond est en cours, l'app "
                    + "demandera confirmation"
                : "Arrêter la session de \(name)")
            : Item(enabled: false, help: "Aucune session en cours")
    }

    /// "Continuer la tâche" (C14): a stopped post-it and a running session; at rest, done or in error, or paused by
    /// the usage limit without automatic resume.
    private static func continueItem(card: TaskCard?, runtime: AgentRuntime?, kind: AgentStateKind) -> Item {
        guard let card else { return Item(enabled: false, help: "Aucun post-it interrompu à continuer") }
        let help = "Renvoie « Continue la tâche : \(card.title) » en tête de file"
        guard let runtime, runtime.pid != nil else {
            return Item(enabled: false, help: "Relance d'abord la session, puis continue « \(card.title) »")
        }
        switch runtime.phase {
        case .quotaPaused(_, let autoResume) where runtime.pendingWaits.isEmpty:
            return autoResume
                ? Item(enabled: false, help: "Claude Code reprendra seul après la limite d'usage")
                : Item(enabled: true, help: help)
        default:
            break
        }
        switch kind {
        case .idle, .done, .error:
            return Item(enabled: true, help: help)
        default:
            return Item(enabled: false, help: "L'agent est occupé : continue la tâche quand il sera au repos")
        }
    }
}

/// Buttons wrapping onto several lines when the window is narrow.
struct AgentWindowFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews, width: proposal.width)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat?) -> [Line] {
        let limit = width ?? .infinity
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            if !line.indices.isEmpty, needed > limit {
                lines.append(line)
                line = Line()
            }
            line.width = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
        }
        if !line.indices.isEmpty { lines.append(line) }
        return lines
    }
}

// MARK: - Texts

enum AgentWindowText {
    /// "42 s", "4 min 12 s", "2 min 05 s", "1 h 05 min": to the second, unlike the list's `DurationText.short`.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite && seconds > 0 ? Int(min(seconds, TimeInterval(Int.max / 2)).rounded(.down)) : 0
        if total < 60 { return "\(total) s" }
        if total < 3_600 { return "\(total / 60) min \(twoDigits(total % 60)) s" }
        return "\(total / 3_600) h \(twoDigits((total % 3_600) / 60)) min"
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// The first 8 characters of a session id, "7d2f1a3b…".
    static func shortSession(_ sessionID: String) -> String {
        sessionID.count > 8 ? String(sessionID.prefix(8)) + "…" : sessionID
    }
}
