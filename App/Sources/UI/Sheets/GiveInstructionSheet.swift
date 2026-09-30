import PixelCore
import SwiftUI

/// "Donner une consigne…" (proposal 5.6, "Consigne ad hoc"): a free text for one agent. A free agent receives it at
/// once, by the same guarded delivery as the post-its; a busy one gets it at the head of its queue, after its turn.
struct GiveInstructionSheet: View {
    let agentID: AgentID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var errorMessage: String?

    var body: some View {
        let name = model.agent(agentID)?.name ?? "l'agent"
        VStack(alignment: .leading, spacing: 12) {
            Text("Donner une consigne")
                .font(.title2.weight(.semibold))
            Text(name)
                .font(.headline)
            Text(explanation(name))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 140)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                .accessibilityLabel("Consigne")
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(StateStyle.tint(for: .error))
            }
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Donner") { send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Donner la consigne (⌘↩)")
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    /// Where the instruction goes, from the agent's state now.
    private func explanation(_ name: String) -> String {
        let paused = model.agent(agentID)?.queuePaused ?? false
        var text: String
        if let runtime = model.runtime(for: agentID), runtime.pid != nil {
            text = AppModel.isFreeForDelivery(runtime)
                ? "\(name) est libre : la consigne part tout de suite dans son terminal, avec les mêmes vérifications "
                    + "que les post-its."
                : "\(name) est occupé : la consigne passe en tête de sa file et part quand ce tour sera fini."
        } else {
            text = "\(name) n'a pas de session en cours : la consigne attend en tête de sa file."
        }
        if paused { text += " Sa file est en pause : reprends-la pour que la consigne parte." }
        return text
    }

    private func send() {
        if let message = model.giveInstruction(to: agentID, text: text) {
            errorMessage = message
            return
        }
        dismiss()
    }
}
