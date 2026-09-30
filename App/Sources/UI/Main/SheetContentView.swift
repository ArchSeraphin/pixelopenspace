import PixelCore
import SwiftUI

/// The content of the main window's sheet.
struct SheetContentView: View {
    let sheet: ActiveSheet

    @Environment(AppModel.self) private var model

    var body: some View {
        switch sheet {
        case .newProject(let url):
            NewProjectSheet(initialFolder: url)
        case .newAgent(let projectID):
            NewAgentSheet(initialProjectID: projectID ?? model.selectedProjectID ?? model.projects.first?.id)
        case .claudeSetup:
            ClaudeSetupSheet()
        case .renameProject(let projectID):
            if let project = model.project(projectID) {
                RenameSheet(title: "Renommer le projet", fieldLabel: "Nom", initialName: project.name,
                            maxLength: NewProjectSheet.maxNameLength) { name in
                    model.renameProject(projectID, to: name)
                }
            } else {
                MissingItemSheet()
            }
        case .renameAgent(let agentID):
            if let agent = model.agent(agentID) {
                RenameSheet(title: "Renommer l'agent", fieldLabel: "Nom", initialName: agent.name,
                            maxLength: nil) { name in
                    model.renameAgent(agentID, to: name)
                }
            } else {
                MissingItemSheet()
            }
        case .quit:
            QuitSheet()
        case .cardEditor(let cardID):
            if model.board.card(cardID) != nil {
                CardEditorSheet(cardID: cardID)
            } else {
                MissingItemSheet()
            }
        case .pasteCards:
            PasteListSheet()
        case .templates:
            TemplateManagerSheet()
        case .resendCard(let cardID):
            if model.board.card(cardID) != nil {
                ResendPrecisionSheet(cardID: cardID)
            } else {
                MissingItemSheet()
            }
        }
    }
}

/// The project or agent went away while its sheet opened.
private struct MissingItemSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("Cet élément n'existe plus.")
            Button("Fermer") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
    }
}
