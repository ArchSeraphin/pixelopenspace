import PixelCore
import SwiftUI

/// Filters of the board panel (mockups 6(b), 6(c)): project (all or one), tags (cumulative, all required), text
/// search (`FuzzyMatcher`: "pagi" finds "Pagination", "deploiement" finds "Déploiement"), and "+ Post-it" (⌘N).
/// The filter lives in `AppModel.boardFilter` (not persisted).
struct BoardFilterBar: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    var body: some View {
        @Bindable var bindable = model
        let selectedTags = model.boardFilter.tags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                projectPicker
                tagsMenu
                Spacer(minLength: 0)
                Button {
                    workbench.commands.perform(.newCard)
                } label: {
                    Label("Post-it", systemImage: "plus")
                }
                .controlSize(.small)
                .help("Nouveau post-it (⌘N)")
                .accessibilityLabel("Nouveau post-it")
            }
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Chercher…", text: $bindable.boardFilter.text)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Chercher un post-it")
                if !model.boardFilter.text.isEmpty {
                    Button {
                        model.boardFilter.text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Effacer la recherche")
                    .accessibilityLabel("Effacer la recherche")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            if !selectedTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(selectedTags, id: \.self) { tag in
                            Button {
                                model.boardFilter.tags.remove(tag)
                            } label: {
                                HStack(spacing: 3) {
                                    Text("#\(tag)")
                                    Image(systemName: "xmark")
                                        .font(.caption2.weight(.bold))
                                }
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            }
                            .buttonStyle(.plain)
                            .help("Retirer le filtre #\(tag)")
                            .accessibilityLabel("Retirer le filtre de tag \(tag)")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .onChange(of: model.projects) { _, projects in
            // An archived project leaves the filter: its cards would stay hidden behind an invisible choice.
            if let projectID = model.boardFilter.projectID, !projects.contains(where: { $0.id == projectID }) {
                model.boardFilter.projectID = nil
            }
        }
    }

    private var projectPicker: some View {
        @Bindable var bindable = model
        return Picker("Projet", selection: $bindable.boardFilter.projectID) {
            Text("Tous les projets").tag(ProjectID?.none)
            ForEach(model.projects) { project in
                Text(project.name).tag(Optional(project.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        .help("N'afficher que les post-its d'un projet")
        .accessibilityLabel("Projet affiché")
    }

    private var tagsMenu: some View {
        let tags = BoardQuery.allTags(model.board)
        let selected = model.boardFilter.tags
        return Menu {
            if tags.isEmpty {
                Text("Aucun tag sur le tableau")
            }
            ForEach(tags, id: \.self) { tag in
                Toggle("#\(tag)", isOn: tagBinding(tag))
            }
            if !selected.isEmpty {
                Divider()
                Button("Retirer les filtres de tags") {
                    model.boardFilter.tags = []
                }
            }
        } label: {
            Label(selected.isEmpty ? "Tags" : "Tags (\(selected.count))", systemImage: "number")
        }
        .menuStyle(.button)
        .fixedSize()
        .controlSize(.small)
        .help("N'afficher que les post-its portant tous ces tags")
    }

    private func tagBinding(_ tag: String) -> Binding<Bool> {
        let model = self.model
        return Binding {
            model.boardFilter.tags.contains(tag)
        } set: { isOn in
            if isOn {
                model.boardFilter.tags.insert(tag)
            } else {
                model.boardFilter.tags.remove(tag)
            }
        }
    }
}
