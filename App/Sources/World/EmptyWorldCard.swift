import SwiftUI

/// The empty world (mockup 6(r)): over the hall and its empty cork wall, a card that says how to create the first
/// island. Only its own frame takes the clicks: the scene keeps the pointer everywhere else.
struct EmptyWorldCard: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Dépose ici un dossier de code pour créer ton premier îlot, ou")
                .font(.title3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                workbench.commands.perform(.newProject)
            } label: {
                Label("Projet ⌥⌘N", systemImage: "plus")
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            if !model.claude.isUsable, model.claude.phase != .detecting {
                Button("Claude Code est introuvable : configurer…") {
                    workbench.present(.claudeSetup)
                }
                .buttonStyle(.link)
            }
        }
        .padding(28)
        .frame(maxWidth: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Monde vide")
    }
}
