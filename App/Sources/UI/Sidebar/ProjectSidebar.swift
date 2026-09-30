import AppKit
import PixelCore
import SwiftUI

/// Projects in sidebar order (⌘1…⌘9): colored square, name, number of agents; context menu (6(m)): rename,
/// color, move up/down, archive. Selecting a project scrolls the board to it. A folder can also be dropped on
/// the window to add a project.
struct ProjectSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    @State private var selection: ProjectID?
    @State private var projectToArchive: ProjectID?
    @State private var showsArchiveDialog = false

    var body: some View {
        let projects = model.projects
        List(selection: $selection) {
            Section("Projets") {
                ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                    ProjectRow(project: project, number: index + 1)
                        .tag(project.id)
                        .contextMenu {
                            ProjectContextMenu(project: project, index: index, count: projects.count,
                                               model: model, workbench: workbench,
                                               onArchive: {
                                                   projectToArchive = project.id
                                                   showsArchiveDialog = true
                                               })
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                workbench.commands.perform(.newProject)
            } label: {
                Label("Projet", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .help("Nouveau projet (⌥⌘N) — ou dépose un dossier sur la fenêtre")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .onAppear { selection = model.selectedProjectID }
        .onChange(of: selection) { _, newValue in
            // A click in the list; changes that come from the model are already equal.
            guard let newValue, newValue != model.selectedProjectID else { return }
            workbench.reveal(project: newValue)
        }
        .onChange(of: model.selectedProjectID) { _, newValue in
            if selection != newValue { selection = newValue }
        }
        .confirmationDialog(archiveTitle, isPresented: $showsArchiveDialog, titleVisibility: .visible) {
            Button("Archiver", role: .destructive) {
                if let projectID = projectToArchive { model.archiveProject(projectID) }
                projectToArchive = nil
            }
            Button("Annuler", role: .cancel) { projectToArchive = nil }
        } message: {
            Text("Le projet disparaît de la liste et libère son îlot. Ses agents sont gardés ; leurs sessions doivent "
                + "être fermées. Le dossier n'est jamais touché.")
        }
    }

    private var archiveTitle: String {
        let name = projectToArchive.flatMap { model.project($0)?.name } ?? ""
        return "Archiver le projet « \(name) » ?"
    }
}

/// One project of the sidebar.
private struct ProjectRow: View {
    let project: Project
    let number: Int

    @Environment(AppModel.self) private var model

    var body: some View {
        let agents = model.agents(in: project.id)
        let waiting = agents.filter { !(model.runtime(for: $0.id)?.pendingWaits.isEmpty ?? true) }.count
        HStack(spacing: 8) {
            ProjectHueSquare(hueIndex: project.hueIndex, size: 12)
            Text(project.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            if waiting > 0 {
                Label("\(waiting)", systemImage: "exclamationmark.bubble.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(StateStyle.tint(for: .waitingInput))
            }
            Text("\(agents.count)")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .help(project.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(agentCount: agents.count, waiting: waiting))
    }

    private func accessibilityText(agentCount: Int, waiting: Int) -> String {
        var text = "Projet \(project.name), \(agentCount) \(agentCount > 1 ? "agents" : "agent")"
        if waiting > 0 { text += ", \(waiting) en attente" }
        if number <= 9 { text += ", Commande \(number)" }
        return text
    }
}

/// Context menu of a project (6(m)): Renommer, Couleur, Monter / Descendre, Nouvel agent, Archiver.
private struct ProjectContextMenu: View {
    let project: Project
    let index: Int
    let count: Int
    let model: AppModel
    let workbench: WorkbenchState
    let onArchive: @MainActor () -> Void

    var body: some View {
        Button("Nouvel agent…") {
            workbench.present(.newAgent(project.id))
        }
        Button("Renommer…") {
            workbench.present(.renameProject(project.id))
        }
        Menu("Couleur") {
            ForEach(ProjectHue.all, id: \.self) { hue in
                Button {
                    model.setProjectHue(project.id, to: hue)
                } label: {
                    if hue == project.hueIndex {
                        Label(ProjectHue.name(hue), systemImage: "checkmark")
                    } else {
                        Text(ProjectHue.name(hue))
                    }
                }
            }
        }
        Divider()
        Button("Monter") { model.moveProject(project.id, by: -1) }
            .disabled(index == 0)
        Button("Descendre") { model.moveProject(project.id, by: 1) }
            .disabled(index >= count - 1)
        Divider()
        Button("Afficher dans le Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
        }
        Button("Archiver…", action: onArchive)
    }
}
