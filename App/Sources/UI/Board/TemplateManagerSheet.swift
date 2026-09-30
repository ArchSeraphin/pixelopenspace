import PixelCore
import SwiftUI

/// "Gérer les modèles" (mockup 6(l)): the prompt templates, each with the projects it is the default of; create,
/// duplicate, edit (name, body, variables), delete, and "Défaut du projet". Edits apply with "Enregistrer", when
/// another template is selected, or with "Terminé" (`.upsertTemplate`).
struct TemplateManagerSheet: View {
    var initialSelection: PromptTemplateID?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selection: PromptTemplateID?
    @State private var name = ""
    @State private var text = ""
    @State private var loadedID: PromptTemplateID?
    @State private var pendingDelete: PromptTemplate?
    @State private var prepared = false

    var body: some View {
        let templates = model.board.templates
        VStack(alignment: .leading, spacing: 14) {
            Text("Gérer les modèles")
                .font(.title2.weight(.semibold))
            HStack(alignment: .top, spacing: 14) {
                List(selection: $selection) {
                    ForEach(templates) { template in
                        TemplateRow(template: template, defaultOf: projects(defaulting: template.id))
                            .tag(template.id)
                    }
                }
                .frame(width: 250, height: 280)
                .accessibilityLabel("Modèles")
                templateEditor
            }
            HStack(spacing: 8) {
                Button {
                    create()
                } label: {
                    Label("Nouveau", systemImage: "plus")
                }
                Button("Dupliquer") { duplicate() }
                    .disabled(loadedID == nil)
                Button("Supprimer…", role: .destructive) {
                    pendingDelete = loadedID.flatMap { model.board.template($0) }
                }
                .disabled(loadedID == nil)
                Spacer()
                defaultMenu
            }
            HStack {
                Spacer()
                Button("Terminé") {
                    commitDraft()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720)
        .onAppear(perform: prepare)
        .onChange(of: selection) { _, newValue in
            commitDraft()
            load(newValue)
        }
        .confirmationDialog(deleteTitle, isPresented: isDeletePresented, titleVisibility: .visible,
                            presenting: pendingDelete) { template in
            Button("Supprimer le modèle", role: .destructive) {
                pendingDelete = nil
                delete(template)
            }
            Button("Annuler", role: .cancel) { pendingDelete = nil }
        } message: { template in
            Text(deleteMessage(template))
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private var templateEditor: some View {
        if loadedID != nil {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Nom du modèle", text: $name)
                    .accessibilityLabel("Nom du modèle")
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: 170)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    .accessibilityLabel("Corps du modèle")
                HStack(spacing: 4) {
                    Text("Variables :")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(PromptComposer.variables, id: \.self) { variable in
                        Button(variable) { text += variable }
                            .buttonStyle(.link)
                            .font(.caption.monospaced())
                            .help("Ajouter \(variable) à la fin du modèle")
                    }
                }
                HStack {
                    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Un modèle a besoin d'un nom.")
                            .font(.caption)
                            .foregroundStyle(StateStyle.tint(for: .error))
                    }
                    Spacer()
                    Button("Enregistrer") { commitDraft() }
                        .disabled(!isDirty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            Text("Choisis un modèle, ou crée-en un.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 280)
        }
    }

    /// "Défaut du projet ▾": a checkmark on each project whose default is the selected template.
    private var defaultMenu: some View {
        Menu("Défaut du projet") {
            if model.projects.isEmpty {
                Text("Aucun projet")
            }
            ForEach(model.projects) { project in
                Toggle(project.name, isOn: defaultBinding(project))
            }
        }
        .fixedSize()
        .disabled(loadedID == nil)
        .help("Le modèle utilisé par les post-its de ce projet qui n'en choisissent pas")
    }

    private func defaultBinding(_ project: Project) -> Binding<Bool> {
        let model = self.model
        let templateID = loadedID
        return Binding {
            templateID != nil && project.defaults.templateID == templateID
        } set: { isOn in
            guard let templateID else { return }
            model.setDefaultTemplate(isOn ? templateID : nil, forProject: project.id)
        }
    }

    // MARK: - Logic

    private var isDirty: Bool {
        guard let loadedID, let stored = model.board.template(loadedID) else { return false }
        return stored.name != name.trimmingCharacters(in: .whitespacesAndNewlines) || stored.body != text
    }

    private func projects(defaulting templateID: PromptTemplateID) -> [String] {
        model.projects.filter { $0.defaults.templateID == templateID }.map(\.name)
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        let first = initialSelection.flatMap { model.board.template($0)?.id } ?? model.board.templates.first?.id
        selection = first
        load(first)
    }

    private func load(_ templateID: PromptTemplateID?) {
        let template = templateID.flatMap { model.board.template($0) }
        loadedID = template?.id
        name = template?.name ?? ""
        text = template?.body ?? ""
    }

    /// Saves the template being edited when it changed and has a name.
    private func commitDraft() {
        guard isDirty, let loadedID else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.applyTask(.upsertTemplate(PromptTemplate(id: loadedID, name: trimmed, body: text)))
    }

    private func create() {
        commitDraft()
        let template = PromptTemplate(name: uniqueName("Nouveau modèle"), body: "{titre}\n\n{description}")
        model.applyTask(.upsertTemplate(template))
        selection = template.id
    }

    private func duplicate() {
        commitDraft()
        guard let loadedID, let source = model.board.template(loadedID) else { return }
        let copy = PromptTemplate(name: uniqueName("\(source.name) (copie)"), body: source.body)
        model.applyTask(.upsertTemplate(copy))
        selection = copy.id
    }

    private func delete(_ template: PromptTemplate) {
        model.deleteTemplate(template.id)
        loadedID = nil
        let next = model.board.templates.first?.id
        selection = next
        load(next)
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(model.board.templates.map(\.name))
        guard names.contains(base) else { return base }
        var index = 2
        while names.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    // MARK: - Delete confirmation

    private var isDeletePresented: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var deleteTitle: String {
        pendingDelete.map { "Supprimer le modèle \(CardPresentation.quoted($0.name)) ?" } ?? ""
    }

    private func deleteMessage(_ template: PromptTemplate) -> String {
        let users = model.board.cards.filter { $0.templateID == template.id }.count
        var parts: [String] = []
        switch users {
        case 0: parts.append("Aucun post-it ne l'utilise.")
        case 1: parts.append("1 post-it l'utilise : il prendra le modèle par défaut de son projet.")
        default: parts.append("\(users) post-its l'utilisent : ils prendront le modèle par défaut de leur projet.")
        }
        let projects = projects(defaulting: template.id)
        if !projects.isEmpty {
            parts.append("Il ne sera plus le modèle par défaut de \(projects.joined(separator: ", ")).")
        }
        return parts.joined(separator: " ")
    }
}

/// "Corriger un bug · défaut du projet API".
private struct TemplateRow: View {
    let template: PromptTemplate
    let defaultOf: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(template.name)
                .lineLimit(1)
            if !defaultOf.isEmpty {
                Text("défaut du projet \(defaultOf.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
