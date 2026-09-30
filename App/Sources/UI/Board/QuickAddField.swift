import PixelCore
import SwiftUI

/// ⌘N (mockup 6(c)): a title field at the top of "À faire". Return creates the post-it (project: the board's
/// project filter, else the selected project) and leaves the field empty for the next one; Escape, or Return on
/// an empty field, closes it. Goal: a post-it in less than 5 seconds.
///
/// The new post-it lands at the end of "À faire", often below the fold: `created` lets the board scroll to it and
/// highlight it; `resumedTyping` (first letter of the next title) brings the field back into view.
struct QuickAddField: View {
    @Binding var isPresented: Bool
    /// Changes when ⌘N is pressed again while the field is shown: it takes the focus back.
    let focusToken: UUID?
    /// A post-it was created, and the board's filters show it.
    var created: (TaskCardID) -> Void = { _ in }
    /// The first letter of a title typed after `created`.
    var resumedTyping: () -> Void = {}

    @Environment(AppModel.self) private var model

    @State private var title = ""
    @State private var showedCreatedCard = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Titre du post-it", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(create)
                .onExitCommand(perform: close)
                .accessibilityLabel("Titre du nouveau post-it")
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.bottom, 2)
        .onAppear(perform: takeFocus)
        .onChange(of: focusToken) { _, _ in takeFocus() }
        .onChange(of: isFocused) { _, focused in
            if !focused, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { close() }
        }
        .onChange(of: title) { old, new in
            guard showedCreatedCard, old.isEmpty, !new.isEmpty else { return }
            showedCreatedCard = false
            resumedTyping()
        }
    }

    private var targetProjectID: ProjectID? {
        let candidate = model.boardFilter.projectID ?? model.selectedProjectID
        return candidate.flatMap { model.project($0)?.id }
    }

    /// "Entrée crée le post-it (projet API) · Échap annule".
    private var hint: String {
        let project = targetProjectID.flatMap { model.project($0)?.name }.map { " (projet \($0))" } ?? " (sans projet)"
        return "Entrée crée le post-it\(project) · Échap annule"
    }

    private func takeFocus() {
        Task { @MainActor in isFocused = true }
    }

    private func create() {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            close()
            return
        }
        guard let cardID = model.createCard(title: text, projectID: targetProjectID) else { return }
        title = ""
        isFocused = true
        let shown = model.filteredBoard[.todo]?.contains { $0.id == cardID } ?? false
        if shown {
            showedCreatedCard = true
            created(cardID)
        } else {
            model.showToast("Post-it créé, mais masqué par les filtres du tableau.")
        }
    }

    private func close() {
        title = ""
        isPresented = false
    }
}
