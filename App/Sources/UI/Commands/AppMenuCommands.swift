import PixelCore
import SwiftUI

/// Menus built from `AppCommand` (proposal 3.16). Every item runs through `CommandCenter.perform(_:)`, except the
/// two that need a confirmation dialog first (closing a busy session, removing an agent).
///
/// "Nouveau post-it" takes ⌘N: the standard "New Window" item is replaced by the "Fichier" commands.
/// "Réglages…" (⌘,) comes from the `Settings` scene.
struct AppMenuCommands: Commands {
    let workbench: WorkbenchState

    @FocusedValue(\.commandAvailability) private var availability: CommandAvailability?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            ForEach(AppCommand.commands(in: .file)) { command in
                commandButton(command)
            }
        }
        CommandGroup(after: .appSettings) {
            ForEach(AppCommand.commands(in: .app).filter { $0 != .showSettings }) { command in
                commandButton(command)
            }
        }
        SidebarCommands()
        CommandGroup(after: .sidebar) {
            ForEach(AppCommand.commands(in: .view)) { command in
                commandButton(command)
            }
        }
        CommandMenu("Agent") {
            ForEach(AppCommand.commands(in: .agent)) { command in
                commandButton(command)
            }
        }
        CommandMenu("Aller") {
            ForEach(AppCommand.commands(in: .go)) { command in
                commandButton(command)
            }
            Divider()
            projectButtons
        }
    }

    private func commandButton(_ command: AppCommand) -> some View {
        Button(command.title) {
            run(command)
        }
        .keyboardShortcut(command.keyboardShortcut)
        .disabled(!isEnabled(command))
    }

    /// "Aller au projet n · Nom" (⌘1…⌘9).
    private var projectButtons: some View {
        let names = availability?.projectNames ?? workbench.model.projects.map(\.name)
        let numbered = Array(names.prefix(AppCommand.projectShortcutNumbers.count).enumerated())
        return ForEach(numbered, id: \.offset) { index, name in
            let number = index + 1
            Button("\(AppCommand.selectProjectTitle(number)) · \(name)") {
                selectProject(number: number)
            }
            .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
        }
    }

    private func isEnabled(_ command: AppCommand) -> Bool {
        availability?.isEnabled(command) ?? workbench.isAvailable(command)
    }

    private func run(_ command: AppCommand) {
        let model = workbench.model
        // A menu shortcut can outrun the greying out: never replace an open sheet.
        guard workbench.isAvailable(command) else { return }
        switch command {
        case .closeSession:
            if let agentID = model.selectedAgentID { workbench.requestCloseSession(agentID) }
        case .removeAgent:
            if let agentID = model.selectedAgentID { workbench.requestRemove(agentID) }
        default:
            workbench.commands.perform(command)
        }
    }

    private func selectProject(number: Int) {
        workbench.commands.selectProject(number: number)
        if let projectID = workbench.model.selectedProjectID {
            workbench.scroll(to: .project(projectID))
        }
    }
}
