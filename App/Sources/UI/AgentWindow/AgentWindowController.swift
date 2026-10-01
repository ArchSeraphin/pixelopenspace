import AppKit
import Observation
import PixelCore
import SwiftUI

/// The agent windows (mockup 6(d), proposal 3.9): one `NSPanel` per agent at most, brought forward when it is asked
/// again, several agents at once, with the standard behaviour of a macOS window (move, resize, ⌘W, Mission
/// Control). A panel closes by itself when its agent is removed or its project archived, and follows a rename. Its
/// frame is remembered for the session (never in the preferences).
///
/// Created by the views that open agent windows (waiting tray, agent cards) when they appear: `prepare(model:
/// workbench:)` then registers the `agentWindow` hook of the snapshot harness (task 8, décision 14).
@MainActor
final class AgentWindowController: NSObject, NSWindowDelegate {
    static let shared = AgentWindowController()

    private var panels: [AgentID: AgentPanel] = [:]
    /// Panels that just closed, released on the next turn of the main actor.
    private var closing: [AgentPanel] = []
    /// Where each agent's panel was when it closed: it reopens there.
    private var frames: [AgentID: NSRect] = [:]
    private weak var model: AppModel?
    private weak var workbench: WorkbenchState?
    private var isObserving = false
    private var isHookRegistered = false

    private override init() {
        super.init()
    }

    /// Remembers the model and the workbench of the views that open agent windows, and registers the snapshot
    /// harness hook (only when the harness runs).
    func prepare(model: AppModel, workbench: WorkbenchState) {
        self.model = model
        self.workbench = workbench
        registerSnapshotHook()
    }

    /// Opens the agent's window, or brings it forward. Opening it means the user looked at the agent: its wait
    /// tones down (`acknowledge`, as when its terminal opens).
    func show(_ agentID: AgentID, model: AppModel, workbench: WorkbenchState) {
        prepare(model: model, workbench: workbench)
        guard let agent = model.agent(agentID), model.workspace.liveProject(agent.projectID) != nil else { return }
        let panel = panels[agentID] ?? makePanel(agentID, model: model, workbench: workbench)
        panel.title = Self.title(of: agentID, model: model)
        if SnapshotHooks.shared.isEnabled {
            // The harness: nothing shows, nothing takes the focus.
            IsolatedWindow.hideForSnapshot(panel)
            panel.orderFrontRegardless()
        } else {
            if panel.isMiniaturized { panel.deminiaturize(nil) }
            NSApplication.shared.activate()
            panel.makeKeyAndOrderFront(nil)
        }
        model.acknowledge(agentID)
        startObserving()
    }

    func close(_ agentID: AgentID) {
        panels[agentID]?.close()
    }

    func isShowing(_ agentID: AgentID) -> Bool {
        panels[agentID]?.isVisible ?? false
    }

    // MARK: Panels

    private func makePanel(_ agentID: AgentID, model: AppModel, workbench: WorkbenchState) -> AgentPanel {
        let panel = AgentPanel(agentID: agentID)
        panel.isHiddenForSnapshot = SnapshotHooks.shared.isEnabled
        panel.delegate = self
        // The window never follows the content's ideal size (the buttons wrap with the width, which would loop with
        // a window sized by its content): only its height is fitted, afterwards (`contentHeightChanged`).
        let hosting = NSHostingView(rootView: AgentWindowRoot(agentID: agentID, model: model, workbench: workbench))
        hosting.sizingOptions = [.minSize]
        panel.contentView = hosting
        let contentWidth = frames[agentID].map { panel.contentRect(forFrameRect: $0).width }
            ?? AgentWindowView.idealWidth
        panel.setContentSize(NSSize(width: contentWidth, height: 480))
        if let frame = frames[agentID] {
            panel.setFrameTopLeftPoint(NSPoint(x: frame.minX, y: frame.maxY))
        } else {
            place(panel)
        }
        panels[agentID] = panel
        return panel
    }

    /// A new panel: cascaded from the last one opened, or beside the main window, or centred.
    private func place(_ panel: NSPanel) {
        if let last = panels.values.filter(\.isVisible).max(by: { $0.windowNumber < $1.windowNumber }) {
            let topLeft = NSPoint(x: last.frame.minX, y: last.frame.maxY)
            panel.setFrameTopLeftPoint(panel.cascadeTopLeft(from: topLeft))
            return
        }
        if let main = NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first(where: { $0.isVisible }),
           let screen = main.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let x = min(max(main.frame.midX - panel.frame.width / 2, visible.minX), visible.maxX - panel.frame.width)
            let y = min(main.frame.maxY - 80, visible.maxY)
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: y))
            return
        }
        panel.center()
    }

    /// The content of an agent's window measures `height` points (it grows when the agent starts waiting, shrinks
    /// when the wait ends): the panel fits it, up to the screen's height, its top edge in place. Deferred out of the
    /// layout pass; the width never changes here, so the content's height does not depend on the result.
    func contentHeightChanged(_ agentID: AgentID, height: CGFloat) {
        guard height >= 1 else { return }
        Task { @MainActor [weak self] in
            guard let self, let panel = self.panels[agentID] else { return }
            Self.fit(panel, contentHeight: height)
        }
    }

    private static func fit(_ panel: NSPanel, contentHeight: CGFloat) {
        let frame = panel.frame
        let chrome = frame.height - panel.contentRect(forFrameRect: frame).height
        let available = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let target = min(max(contentHeight.rounded(.up), AgentWindowView.minimumHeight), available - chrome)
        guard abs(target + chrome - frame.height) >= 1 else { return }
        var fitted = frame
        fitted.size.height = target + chrome
        fitted.origin.y = frame.maxY - fitted.height
        panel.setFrame(fitted, display: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? AgentPanel else { return }
        frames[panel.agentID] = panel.frame
        if panels[panel.agentID] === panel {
            panels[panel.agentID] = nil
        }
        // Closed from its own content (⌘W, Escape): the panel and its SwiftUI view outlive the action that closed it.
        closing.append(panel)
        Task { @MainActor [weak self] in
            self?.closing.removeAll { $0 === panel }
        }
    }

    /// The panel's agent becomes the selection while its window is key: the menus (⌘T, ⌘., ⇧⌘R) then act on it too.
    func windowDidBecomeKey(_ notification: Notification) {
        guard let panel = notification.object as? AgentPanel, let model,
              model.selectedAgentID != panel.agentID, model.agent(panel.agentID) != nil else { return }
        model.select(agent: panel.agentID)
    }

    // MARK: Workspace changes

    /// While panels are open: closes those whose agent is gone (removed, or its project archived), renames the others.
    private func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        observeWorkspace()
    }

    private func observeWorkspace() {
        guard let model, !panels.isEmpty else {
            isObserving = false
            return
        }
        withObservationTracking {
            _ = model.workspace
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.workspaceChanged()
                self.observeWorkspace()
            }
        }
    }

    private func workspaceChanged() {
        guard let model else { return }
        for (agentID, panel) in panels {
            guard let agent = model.agent(agentID), model.workspace.liveProject(agent.projectID) != nil else {
                panel.close()
                continue
            }
            let title = Self.title(of: agentID, model: model)
            if panel.title != title { panel.title = title }
        }
    }

    /// "Nova · API".
    private static func title(of agentID: AgentID, model: AppModel) -> String {
        let names = model.names(of: agentID)
        return names.project.isEmpty ? names.agent : "\(names.agent) · \(names.project)"
    }

    // MARK: Snapshot harness

    /// `openAgentWindow("Nova")`: the window of the agent of that name (live projects only).
    private func registerSnapshotHook() {
        let hooks = SnapshotHooks.shared
        guard hooks.isEnabled, !isHookRegistered else { return }
        isHookRegistered = true
        hooks.register(.agentWindow, owner: "tâche 8") { [weak self] step in
            guard let self, case .openAgentWindow(let name) = step, let model = self.model,
                  let workbench = self.workbench,
                  let agent = model.agentsInOrder.first(where: { $0.name == name }) else { return false }
            self.show(agent.id, model: model, workbench: workbench)
            return self.isShowing(agent.id)
        }
    }
}

/// The panel of one agent: a standard, resizable window that stays when the app is in the background. Never key in
/// the snapshot harness.
final class AgentPanel: NSPanel {
    let agentID: AgentID
    var isHiddenForSnapshot = false

    init(agentID: AgentID) {
        self.agentID = agentID
        super.init(contentRect: NSRect(x: 0, y: 0, width: AgentWindowView.idealWidth, height: 480),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
        isFloatingPanel = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isRestorable = false
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        collectionBehavior = [.managed, .participatesInCycle, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { isHiddenForSnapshot ? false : super.canBecomeKey }
    override var canBecomeMain: Bool { false }
}

/// The panel's SwiftUI root, with the app's environments.
struct AgentWindowRoot: View {
    let agentID: AgentID
    let model: AppModel
    let workbench: WorkbenchState

    var body: some View {
        AgentWindowView(agentID: agentID)
            .environment(model)
            .environment(workbench)
    }
}
