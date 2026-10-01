import AppKit
import Foundation
import PixelCore

/// The native context menu of the scene (3.9: right click or Control-click), with the commands of the menus and of
/// the list view for what is under the pointer:
/// - an agent: its window, its terminal, an instruction, interrupt, relaunch, close, rename, remove (greyed out as
///   `AgentActions` says, with the reason as a tooltip; closing and removing ask through `WorkbenchState`);
/// - a free desk: a new agent there (the same popover as a click);
/// - an island (its rug or its sign): a new agent in that project, centre the island, rename the project;
/// - anywhere else: "Tout voir" and the list view.
@MainActor
enum WorldContextMenu {
    static func menu(for target: SceneHitTarget?, model: AppModel, workbench: WorkbenchState, stage: WorldStage,
                     performer: WorldClickPerformer) -> NSMenu {
        let menu = NSMenu(title: "Open space")
        // The items say themselves whether they apply.
        menu.autoenablesItems = false
        let items: [NSMenuItem]
        switch target {
        case .agent(let agentID)?:
            items = agentItems(agentID, model: model, workbench: workbench, performer: performer)
        case .freeDesk(let projectID, let deskIndex)?:
            items = [ActionMenuItem("Nouvel agent ici…") { performer.offerNewAgent(projectID, deskIndex: deskIndex) }]
        case .islandFloor(let projectID, let part)?, .islandSign(let projectID, let part)?:
            items = islandItems(projectID, part: part, model: model, workbench: workbench, stage: stage)
        case .floor?, .corkWall?, .elevator?, .hallProp?, nil:
            items = sceneItems(workbench: workbench)
        }
        for item in items { menu.addItem(item) }
        return menu
    }

    private static func agentItems(_ agentID: AgentID, model: AppModel, workbench: WorkbenchState,
                                   performer: WorldClickPerformer) -> [NSMenuItem] {
        let actions = AgentActions(model: model, agentID: agentID)
        return [
            ActionMenuItem("Ouvrir la fenêtre de l'agent") { performer.openAgentWindow(agentID) },
            ActionMenuItem("Ouvrir le terminal", key: "t", enabled: actions.canOpenTerminal,
                           unavailable: "Aucun terminal : la session est hors ligne") {
                performer.openTerminal(agentID)
            },
            .separator(),
            ActionMenuItem("Donner une consigne…") { workbench.present(.giveInstruction(agentID)) },
            ActionMenuItem("Interrompre", key: ".", enabled: actions.canInterrupt,
                           unavailable: actions.interruptUnavailableReason) {
                model.interrupt(agentID)
            },
            ActionMenuItem("Relancer la session", enabled: actions.canRelaunch,
                           unavailable: "Seulement hors ligne, ou en erreur une fois la session arrêtée") {
                model.relaunch(agentID)
            },
            ActionMenuItem("Fermer la session…", enabled: actions.canClose, unavailable: "Aucune session en cours") {
                workbench.requestCloseSession(agentID)
            },
            .separator(),
            ActionMenuItem("Renommer…") { workbench.present(.renameAgent(agentID)) },
            ActionMenuItem("Retirer l'agent…", enabled: actions.canRemove,
                           unavailable: "Ferme d'abord la session de l'agent") {
                workbench.requestRemove(agentID)
            },
        ]
    }

    private static func islandItems(_ projectID: ProjectID, part: Int, model: AppModel, workbench: WorkbenchState,
                                    stage: WorldStage) -> [NSMenuItem] {
        let name = model.workspace.project(projectID)?.name ?? "ce projet"
        return [
            ActionMenuItem("Nouvel agent dans \(name)…", enabled: workbench.activeSheet == nil) {
                workbench.present(.newAgent(projectID))
            },
            ActionMenuItem("Centrer l'îlot") { stage.camera.fly(to: .island(projectID, part: part)) },
            .separator(),
            ActionMenuItem("Renommer le projet…", enabled: workbench.activeSheet == nil) {
                workbench.present(.renameProject(projectID))
            },
        ]
    }

    private static func sceneItems(workbench: WorkbenchState) -> [NSMenuItem] {
        [
            ActionMenuItem("Tout voir", key: "0", enabled: workbench.isAvailable(.fitAll)) {
                workbench.commands.perform(.fitAll)
            },
            ActionMenuItem("Vue Liste", key: "l", enabled: workbench.isAvailable(.toggleListView)) {
                workbench.commands.perform(.toggleListView)
            },
        ]
    }
}

/// A menu item that runs a closure (it is its own target). Its shortcut, with ⌘, is the one of the same command in
/// the menus: shown as a reminder.
@MainActor
private final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, key: String = "", enabled: Bool = true, unavailable: String? = nil,
         handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(ActionMenuItem.run), keyEquivalent: key)
        target = self
        isEnabled = enabled
        if !enabled, let unavailable { toolTip = unavailable }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func run() {
        handler()
    }
}
