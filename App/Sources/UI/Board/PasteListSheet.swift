import AppKit
import PixelCore
import SwiftUI

/// "Coller une liste" (⇧⌘V, mockup 6(c)): a text prefilled with the clipboard, one post-it per line
/// (`PasteImporter`: bullets and numbers removed, blank lines ignored, an indented line completes the details of
/// the card above), the target project, and "Créer n post-its".
struct PasteListSheet: View {
    static let previewLimit = 6

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var projectID: ProjectID?
    @State private var prepared = false

    var body: some View {
        let cards = PasteImporter.cards(from: text)
        VStack(alignment: .leading, spacing: 12) {
            Text("Coller une liste")
                .font(.title2.weight(.semibold))
            Text("Un post-it par ligne. Les puces (-, *, •, 1., 1), [ ]) sont retirées et les lignes vides ignorées ; "
                 + "une ligne en retrait complète la description du post-it du dessus.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 200)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                .accessibilityLabel("Liste à importer")
            HStack {
                Picker("Projet", selection: $projectID) {
                    Text("Aucun").tag(ProjectID?.none)
                    ForEach(model.projects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                .fixedSize()
                Spacer()
                Text(countText(cards.count))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if !cards.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(cards.prefix(Self.previewLimit).enumerated()), id: \.offset) { _, card in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "note.text")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(card.title)
                                .lineLimit(1)
                            if !card.details.isEmpty {
                                Text("+ description")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if cards.count > Self.previewLimit {
                        Text("… et \(cards.count - Self.previewLimit) de plus")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Aperçu : " + cards.prefix(Self.previewLimit).map(\.title).joined(separator: ", "))
            }
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(createTitle(cards.count)) { create() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(cards.isEmpty)
                    .help("Créer les post-its (⌘↩)")
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: prepare)
    }

    private func countText(_ count: Int) -> String {
        switch count {
        case 0: return "aucun post-it"
        case 1: return "1 post-it"
        default: return "\(count) post-its"
        }
    }

    private func createTitle(_ count: Int) -> String {
        count > 1 ? "Créer \(count) post-its" : "Créer 1 post-it"
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        text = NSPasteboard.general.string(forType: .string) ?? ""
        let candidate = model.boardFilter.projectID ?? model.selectedProjectID
        projectID = candidate.flatMap { model.project($0)?.id }
    }

    private func create() {
        let created = model.createCards(fromPasted: text, projectID: projectID)
        guard !created.isEmpty else { return }
        dismiss()
        model.showToast(created.count > 1 ? "\(created.count) post-its créés dans « À faire »."
                                          : "1 post-it créé dans « À faire ».")
    }
}
