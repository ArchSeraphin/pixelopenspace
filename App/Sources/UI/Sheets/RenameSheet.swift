import SwiftUI

/// "Renommer…" for a project or an agent.
struct RenameSheet: View {
    let title: String
    let fieldLabel: String
    let initialName: String
    /// Characters kept (the island sign shows 10), `nil` for no limit.
    let maxLength: Int?
    let onRename: @MainActor (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
            LabeledContent(fieldLabel) {
                TextField(fieldLabel, text: $name)
                    .labelsHidden()
                    .frame(minWidth: 220)
                    .onSubmit(rename)
            }
            if let maxLength {
                Text("\(name.count)/\(maxLength) caractères (pancarte de l'îlot)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Renommer", action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { name = initialName }
        .onChange(of: name) { _, newValue in
            if let maxLength, newValue.count > maxLength {
                name = String(newValue.prefix(maxLength))
            }
        }
    }

    private func rename() {
        guard !trimmed.isEmpty else { return }
        onRename(trimmed)
        dismiss()
    }
}
