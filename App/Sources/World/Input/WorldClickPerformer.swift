import AppKit
import Foundation
import PixelCore

/// What the click rules of the scene ask for (`ClickAction`, 3.9), done with the app's usual intents: the same
/// selection, agent window, terminal, sheets and confirmations as the list view and the menus. `wakeAt` is the
/// input controller's (a timer); everything else is here.
@MainActor
final class WorldClickPerformer {
    private weak var view: WorldView?
    private let stage: WorldStage
    private let model: AppModel
    private weak var workbench: WorkbenchState?
    private let newAgentPopover = NewAgentPopover()

    init(view: WorldView, stage: WorldStage, model: AppModel, workbench: WorkbenchState) {
        self.view = view
        self.stage = stage
        self.model = model
        self.workbench = workbench
    }

    func perform(_ action: ClickAction, event: NSEvent?) {
        switch action {
        case .select(let agentID):
            model.select(agent: agentID)
        case .clearSelection:
            model.select(agent: nil)
        case .openAgentWindow(let agentID):
            openAgentWindow(agentID)
        case .openTerminal(let agentID):
            openTerminal(agentID)
        case .offerNewAgent(let projectID, let deskIndex):
            offerNewAgent(projectID, deskIndex: deskIndex)
        case .centerIsland(let projectID, let part):
            stage.camera.fly(to: .island(projectID, part: part))
        case .contextMenu(let target):
            showContextMenu(for: target, event: event)
        case .wakeAt:
            break
        }
    }

    // MARK: Intents

    /// Selects the agent and opens its window (6(d)), or brings it forward.
    func openAgentWindow(_ agentID: AgentID) {
        guard let workbench else { return }
        model.select(agent: agentID)
        AgentWindowController.shared.show(agentID, model: model, workbench: workbench)
    }

    /// The agent's terminal with the keyboard focus (`WorkbenchState.showTerminal`), without moving the camera: a
    /// double-click on an agent never centres (3.9), whereas showing a terminal reveals its agent, which flies there.
    func openTerminal(_ agentID: AgentID) {
        guard let workbench else { return }
        let camera = stage.camera
        let pose = camera.pose
        workbench.showTerminal(for: agentID, focus: true)
        if camera.isPlaced && workbench.mainView == .scene {
            // Same zoom, same snapped centre: the pose comes back to the pixel.
            camera.center(on: .point(pose.center))
        }
    }

    /// "Nouvel agent ici ?" anchored on the free desk; never a creation without the user's "Créer" (3.9).
    func offerNewAgent(_ projectID: ProjectID, deskIndex: Int) {
        guard let view, let project = model.workspace.liveProject(projectID),
              let rect = stage.viewRect(of: .freeDesk(projectID, deskIndex: deskIndex)) else { return }
        let model = self.model
        newAgentPopover.show(projectName: project.name, relativeTo: rect, of: view) {
            _ = model.addAgent(projectID: projectID, deskIndex: deskIndex)
        }
    }

    func closePopover() {
        newAgentPopover.close()
    }

    /// Whether a command of the menus applies now (`WorkbenchState.isAvailable`).
    func isAvailable(_ command: AppCommand) -> Bool {
        workbench?.isAvailable(command) ?? false
    }

    // MARK: Context menu

    private func showContextMenu(for target: SceneHitTarget?, event: NSEvent?) {
        guard let view, let workbench else { return }
        let menu = WorldContextMenu.menu(for: target, model: model, workbench: workbench, stage: stage, performer: self)
        if let event {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            let location = view.window?.mouseLocationOutsideOfEventStream ?? .zero
            menu.popUp(positioning: nil, at: view.convert(location, from: nil), in: view)
        }
    }
}

extension WorldStage {
    /// The frame, in the view's points (AppKit, origin at the bottom-left corner), of everything the plan draws for
    /// a target: an agent (avatar, signs, plate), a free desk (desk, chair, screen)…; nil when the plan has none.
    func viewRect(of target: SceneHitTarget) -> CGRect? {
        guard let plan, camera.isPlaced else { return nil }
        var box: SceneBox?
        for node in plan.nodes where node.target == target && node.width > 0 && node.height > 0 {
            // Décision 16: the anchor is in pixels from the image's top-left corner, the position in texels, y up.
            let minX = Double(node.position.x - node.anchor.x), maxY = Double(node.position.y + node.anchor.y)
            let nodeBox = SceneBox(minX: minX, minY: maxY - Double(node.height), maxX: minX + Double(node.width),
                                   maxY: maxY)
            box = box.map {
                SceneBox(minX: min($0.minX, nodeBox.minX), minY: min($0.minY, nodeBox.minY),
                         maxX: max($0.maxX, nodeBox.maxX), maxY: max($0.maxY, nodeBox.maxY))
            } ?? nodeBox
        }
        guard let box else { return nil }
        let low = camera.viewPoint(of: SceneVector(box.minX, box.minY))
        let high = camera.viewPoint(of: SceneVector(box.maxX, box.maxY))
        return CGRect(x: low.x, y: low.y, width: high.x - low.x, height: high.y - low.y)
    }
}
