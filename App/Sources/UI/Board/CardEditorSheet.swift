import PixelCore
import SwiftUI

/// Post-it editor (mockup 6(l)): title, description, project (locked while assigned), priority, tags, template,
/// assignment, the prompt preview exactly as it will be typed (`PromptComposer` then `PromptSanitizer`, following
/// the fields being edited), and the history. The fields apply with "Enregistrer" (`.edit`, one per changed
/// field); "Donner à", "Retirer" and "Supprimer" apply at once, after a confirmation when the reducer asks for one.
struct CardEditorSheet: View {
    let cardID: TaskCardID

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var details = ""
    @State private var projectID: ProjectID?
    @State private var priority: Priority = .normal
    @State private var tags: [String] = []
    @State private var newTag = ""
    @State private var templateID: PromptTemplateID?
    @State private var loaded = false
    @State private var pendingTask: PendingTaskInput?
    @State private var showsTemplates = false
    @State private var errorMessage: String?

    var body: some View {
        if let card = model.board.card(cardID) {
            editor(card)
                .onAppear { load(card) }
                .onChange(of: card.projectID) { _, newValue in
                    // "Donner à" moved the card to its agent's project (C3).
                    projectID = newValue
                }
                .onChange(of: model.board.templates) { _, templates in
                    if let templateID, !templates.contains(where: { $0.id == templateID }) { self.templateID = nil }
                }
                .taskConfirmation($pendingTask) { pending in
                    perform(pending.input)
                }
                .sheet(isPresented: $showsTemplates) {
                    TemplateManagerSheet(initialSelection: templateID)
                        .environment(model)
                        .environment(workbench)
                }
        } else {
            MissingCardView()
        }
    }

    private func editor(_ card: TaskCard) -> some View {
        let isAssigned = card.assignee != nil
        let project = (isAssigned ? card.projectID : projectID).flatMap { model.project($0) }
        let preview = model.promptPreview(for: draft(of: card))
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                PriorityPin(priority: priority, size: 12)
                Text(project.map { "Post-it · \($0.name)" } ?? "Post-it")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text(card.column.title)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .accessibilityLabel("Colonne \(card.column.title)")
            }
            fields(card, isAssigned: isAssigned, project: project)
            Divider()
            previewSection(preview)
            Divider()
            historySection(card)
            HStack {
                Button("Supprimer", role: .destructive) {
                    request(.delete(card.id))
                }
                .help("Supprimer ce post-it du tableau")
                Spacer()
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(StateStyle.tint(for: .error))
                        .lineLimit(2)
                }
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Enregistrer") { save(card) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    // MARK: - Fields

    private func fields(_ card: TaskCard, isAssigned: Bool, project: Project?) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                label("Titre")
                TextField("Titre", text: $title)
                    .labelsHidden()
            }
            GridRow(alignment: .top) {
                label("Description")
                TextEditor(text: $details)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: 76)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    .accessibilityLabel("Description")
            }
            GridRow {
                label("Projet")
                HStack(spacing: 16) {
                    Picker("Projet", selection: projectBinding(card)) {
                        Text("Aucun").tag(ProjectID?.none)
                        ForEach(model.projects) { candidate in
                            Text(candidate.name).tag(Optional(candidate.id))
                        }
                        if let current = card.projectID, model.project(current) == nil {
                            Text("Projet inconnu").tag(Optional(current))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(isAssigned)
                    .help(isAssigned ? "Un post-it assigné suit le projet de son agent : retire-le d'abord de la file."
                                     : "Projet du post-it")
                    HStack(spacing: 6) {
                        Text("Priorité")
                        Picker("Priorité", selection: $priority) {
                            ForEach(Priority.allCases.reversed(), id: \.self) { value in
                                Text(value.title).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("Priorité")
                    }
                }
            }
            GridRow {
                label("Tags")
                tagsEditor
            }
            GridRow {
                label("Modèle")
                HStack {
                    Picker("Modèle", selection: $templateID) {
                        Text(noTemplateTitle(project)).tag(PromptTemplateID?.none)
                        ForEach(model.board.templates) { template in
                            Text(template.name).tag(Optional(template.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Button("Gérer les modèles…") { showsTemplates = true }
                }
            }
            GridRow {
                label("Assigné")
                assignmentRow(card)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private var tagsEditor: some View {
        HStack(spacing: 6) {
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tags, id: \.self) { tag in
                            Button {
                                tags.removeAll { $0 == tag }
                            } label: {
                                HStack(spacing: 3) {
                                    Text("#\(tag)")
                                    Image(systemName: "xmark")
                                        .font(.caption2.weight(.bold))
                                }
                                .font(.callout)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            }
                            .buttonStyle(.plain)
                            .help("Retirer #\(tag)")
                            .accessibilityLabel("Retirer le tag \(tag)")
                        }
                    }
                }
                .frame(maxWidth: 360)
                .fixedSize(horizontal: true, vertical: false)
            }
            TextField("+ tag", text: $newTag)
                .frame(width: 120)
                .onSubmit(addTags)
                .accessibilityLabel("Ajouter un tag")
            Spacer(minLength: 0)
        }
    }

    private func assignmentRow(_ card: TaskCard) -> some View {
        HStack(spacing: 8) {
            CardStatusLine(card: card)
            ForEach(CardPresentation.flags(of: card), id: \.self) { CardFlagLabel(flag: $0) }
            Spacer()
            if card.column == .todo {
                Menu("Donner à…") {
                    AssignMenuContent(card: card, model: model) { agentID in
                        request(.assign(card.id, to: agentID))
                    }
                }
                .fixedSize()
                if card.assignee != nil {
                    Button("Retirer") { request(.unassign(card.id)) }
                        .help("Retirer le post-it de la file de son agent")
                }
            }
        }
    }

    // MARK: - Preview and history

    private func previewSection(_ preview: SanitizedPrompt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("APERÇU DU PROMPT")
                    .font(.caption.weight(.bold))
                Text("(exactement ce qui sera tapé dans le terminal)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(verbatim: preview.isEmpty ? " " : preview.text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 56, maxHeight: 150)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            .accessibilityLabel("Aperçu du prompt")
            .accessibilityValue(preview.text)
            Text(preview.isEmpty ? "Le prompt est vide : rien ne serait tapé." : PromptSanitizer.summary(preview))
                .font(.caption)
                .foregroundStyle(.secondary)
            if preview.needsConfirmation {
                Label("Plus de 16 Ko : l'app demandera confirmation avant de l'envoyer.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(StateStyle.tint(for: .waitingInput))
            }
        }
    }

    private func historySection(_ card: TaskCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("HISTORIQUE")
                .font(.caption.weight(.bold))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(card.history.enumerated()), id: \.offset) { _, event in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(CardPresentation.shortDate(event.at, now: model.now))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 44, alignment: .leading)
                            Text(CardPresentation.eventText(event, model: model))
                        }
                        .font(.caption)
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 90)
            .defaultScrollAnchor(.bottom)
        }
    }

    // MARK: - Logic

    private func load(_ card: TaskCard) {
        guard !loaded else { return }
        loaded = true
        title = card.title
        details = card.details
        projectID = card.projectID
        priority = card.priority
        tags = card.tags
        templateID = card.templateID.flatMap { model.board.template($0)?.id }
    }

    /// The Picker shows the card's project while it is assigned (its agent's), the draft otherwise.
    private func projectBinding(_ card: TaskCard) -> Binding<ProjectID?> {
        Binding(get: { card.assignee != nil ? card.projectID : projectID }, set: { projectID = $0 })
    }

    /// "Défaut du projet (Corriger un bug)" or "Aucun (titre et description)".
    private func noTemplateTitle(_ project: Project?) -> String {
        if let name = project?.defaults.templateID.flatMap({ model.board.template($0)?.name }) {
            return "Défaut du projet (\(name))"
        }
        return "Aucun (titre et description)"
    }

    /// The stored card with the fields being edited (preview).
    private func draft(of card: TaskCard) -> TaskCard {
        var copy = card
        copy.title = title
        copy.details = details
        copy.priority = priority
        copy.tags = TaskBoardValidator.normalizedTags(tags)
        copy.templateID = templateID
        if card.assignee == nil { copy.projectID = projectID }
        return copy
    }

    /// "api, #bug ui": each word becomes a tag, normalized as the board stores them.
    private func addTags() {
        let words = newTag.split { $0 == "," || $0.isWhitespace }.map(String.init)
        tags = TaskBoardValidator.normalizedTags(tags + words)
        newTag = ""
    }

    private func save(_ card: TaskCard) {
        if !newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { addTags() }
        var inputs: [TaskInput] = []
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle != card.title { inputs.append(.edit(card.id, .title(trimmedTitle))) }
        if details != card.details { inputs.append(.edit(card.id, .details(details))) }
        if priority != card.priority { inputs.append(.edit(card.id, .priority(priority))) }
        let normalized = TaskBoardValidator.normalizedTags(tags)
        if normalized != card.tags { inputs.append(.edit(card.id, .tags(normalized))) }
        if templateID != card.templateID { inputs.append(.edit(card.id, .template(templateID))) }
        if card.assignee == nil, projectID != card.projectID { inputs.append(.edit(card.id, .project(projectID))) }
        var refusal: String?
        for input in inputs {
            for case .rejected(_, let message) in model.applyTask(input) {
                refusal = message
            }
        }
        if let refusal {
            errorMessage = refusal
        } else {
            dismiss()
        }
    }

    /// A lifecycle input from the editor: confirmed first when the reducer asks for it (sheet-local dialog).
    private func request(_ input: TaskInput) {
        if let kind = model.taskConfirmation(for: input) {
            pendingTask = PendingTaskInput(input: input, kind: kind)
        } else {
            perform(input)
        }
    }

    private func perform(_ input: TaskInput) {
        model.applyTask(input)
        if model.board.card(cardID) == nil { dismiss() }
    }
}

/// "Renvoyer avec une précision" (↺, C17): the precision goes to the head of the same agent's queue; the card
/// stays "À valider" until the agent receives it, then goes back to "En cours".
struct ResendPrecisionSheet: View {
    let cardID: TaskCardID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var precision = ""
    @State private var errorMessage: String?

    var body: some View {
        if let card = model.board.card(cardID) {
            let agent = card.assignee.map { CardPresentation.agentName($0, model: model) } ?? "l'agent"
            VStack(alignment: .leading, spacing: 12) {
                Text("Renvoyer avec une précision")
                    .font(.title2.weight(.semibold))
                Text("\(CardPresentation.quoted(card.title)) · \(agent)")
                    .font(.headline)
                Text("La précision part en tête de la file de \(agent). Le post-it reste « À valider » jusqu'à ce "
                     + "que \(agent) la reçoive, puis repasse « En cours ».")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $precision)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: 120)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    .accessibilityLabel("Précision")
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(StateStyle.tint(for: .error))
                }
                HStack {
                    Spacer()
                    Button("Annuler", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Renvoyer") { send() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(precision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Renvoyer (⌘↩)")
                }
            }
            .padding(20)
            .frame(width: 520)
        } else {
            MissingCardView()
        }
    }

    private func send() {
        let effects = model.applyTask(.resend(cardID, precision: precision, instructionID: InstructionID()))
        for case .rejected(_, let message) in effects {
            errorMessage = message
            return
        }
        dismiss()
    }
}

/// The post-it went away while its sheet was open.
struct MissingCardView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("Ce post-it n'existe plus.")
            Button("Fermer") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
    }
}
