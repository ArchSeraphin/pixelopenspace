import SwiftUI

/// No project yet (mockup 6(r)): a drop zone for a code folder, or "+ Projet ⌥⌘N".
struct EmptyWorkspaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Dépose ici un dossier de code pour créer ton premier projet")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                Button {
                    workbench.commands.perform(.newProject)
                } label: {
                    Label("Projet ⌥⌘N", systemImage: "plus")
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(36)
            .frame(maxWidth: 520)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            )
            if !model.claude.isUsable, model.claude.phase != .detecting {
                Button("Claude Code est introuvable : configurer…") {
                    workbench.present(.claudeSetup)
                }
                .buttonStyle(.link)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
