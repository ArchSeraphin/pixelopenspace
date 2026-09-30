import PixelCore
import SwiftUI

/// "Nouveau projet" (mockup 6(m)): folder, name for the island sign (10 characters), color, agent defaults.
/// A folder already followed selects its project instead of creating a second one.
struct NewProjectSheet: View {
    static let maxNameLength = 10

    let initialFolder: URL?

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench
    @Environment(\.dismiss) private var dismiss

    @State private var folder: URL?
    @State private var name = ""
    @State private var hueIndex = 0
    @State private var defaultModel = ""
    @State private var permissionMode: PermissionMode = .default
    @State private var prepared = false
    /// Folder name the current sign text was derived from (a name typed by the user is kept).
    @State private var previousFolderName = ""

    var body: some View {
        let existing = folder.flatMap { model.liveProject(forFolder: $0) }
        VStack(alignment: .leading, spacing: 16) {
            Text("Nouveau projet")
                .font(.title2.weight(.semibold))
            Form {
                LabeledContent("Dossier") {
                    HStack {
                        Text(folder.map { ProjectSectionView.abbreviated($0.path(percentEncoded: false)) } ?? "Aucun dossier choisi")
                            .foregroundStyle(folder == nil ? Color.secondary : Color.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button("Choisir…", action: chooseFolder)
                    }
                }
                if let existing {
                    Label("Ce dossier est déjà suivi : projet « \(existing.name) ».", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Nom") {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Nom", text: $name, prompt: Text("API"))
                            .labelsHidden()
                            .frame(maxWidth: 180)
                        Text("Pancarte de l'îlot : \(name.count)/\(Self.maxNameLength) caractères")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Couleur") {
                    HueSwatchPicker(selection: $hueIndex)
                }
                LabeledContent("Modèle par défaut") {
                    TextField("Modèle par défaut", text: $defaultModel,
                              prompt: Text(model.settings.defaultModel ?? "défaut de Claude Code"))
                        .labelsHidden()
                        .frame(maxWidth: 220)
                }
                Picker("Permissions par défaut", selection: $permissionMode) {
                    ForEach(PermissionMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                Text(PermissionModeInfo.summary(permissionMode))
                    .font(.caption)
                    .foregroundStyle(PermissionModeInfo.isRisky(permissionMode) ? StateStyle.tint(for: .error)
                                                                                 : Color.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let existing {
                    Button("Ouvrir le projet") {
                        workbench.reveal(project: existing.id)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Créer", action: create)
                        .keyboardShortcut(.defaultAction)
                        .disabled(folder == nil)
                }
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear(perform: prepare)
        .onChange(of: name) { _, newValue in
            if newValue.count > Self.maxNameLength { name = String(newValue.prefix(Self.maxNameLength)) }
        }
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        hueIndex = ProjectHue.leastUsed(among: model.projects)
        defaultModel = model.settings.defaultModel ?? ""
        permissionMode = model.settings.defaultPermissionMode
        if let initialFolder {
            use(initialFolder)
        } else {
            // "+ Projet": the folder is what matters, ask for it at once; cancelling it cancels the sheet.
            Task { @MainActor in
                if let url = await FilePickers.chooseFolderFromRunLoop() {
                    use(url)
                } else {
                    dismiss()
                }
            }
        }
    }

    private func chooseFolder() {
        guard let url = FilePickers.chooseFolder(startingAt: folder) else { return }
        use(url)
    }

    private func use(_ url: URL) {
        folder = url
        let folderName = url.lastPathComponent
        if name.isEmpty || name == Self.signName(for: previousFolderName) {
            name = Self.signName(for: folderName)
        }
        previousFolderName = folderName
    }

    /// Default sign text: the folder's name, 10 characters at most.
    static func signName(for folderName: String) -> String {
        String(folderName.prefix(maxNameLength))
    }

    private func create() {
        guard let folder else { return }
        let trimmedModel = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = AgentDefaults(model: trimmedModel.isEmpty ? nil : trimmedModel, permissionMode: permissionMode)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let projectID = model.addProject(url: folder, name: trimmedName.isEmpty ? nil : trimmedName,
                                            hueIndex: hueIndex, defaults: defaults) {
            workbench.reveal(project: projectID)
            dismiss()
        }
    }
}

/// The 10 project colors (P0…P9), each with its name for VoiceOver and a check mark on the selected one.
struct HueSwatchPicker: View {
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ProjectHue.all, id: \.self) { hue in
                Button {
                    selection = hue
                } label: {
                    ZStack {
                        Circle()
                            .fill(ProjectHue.color(hue))
                            .frame(width: 20, height: 20)
                        if hue == selection {
                            Circle()
                                .strokeBorder(Color.primary, lineWidth: 2)
                                .frame(width: 26, height: 26)
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help(ProjectHue.name(hue))
                .accessibilityLabel("Couleur \(ProjectHue.name(hue))")
                .accessibilityAddTraits(hue == selection ? .isSelected : [])
            }
        }
    }
}
