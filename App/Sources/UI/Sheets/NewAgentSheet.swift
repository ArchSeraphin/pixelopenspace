import PixelCore
import SwiftUI

/// "Nouvel agent" (mockup 6(n)): name, model, permission mode (bypassPermissions only with an explicit
/// acknowledgement), optional worktree; "Lancer" creates the agent and starts its session.
struct NewAgentSheet: View {
    let initialProjectID: ProjectID?

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench
    @Environment(\.dismiss) private var dismiss

    @State private var projectID: ProjectID?
    @State private var name = ""
    @State private var agentModel = ""
    @State private var permissionMode: PermissionMode = .default
    @State private var riskAcknowledged = false
    @State private var usesWorktree = false
    @State private var worktreeName = ""
    @State private var worktreeEdited = false
    @State private var prepared = false

    var body: some View {
        let project = projectID.flatMap { model.project($0) }
        VStack(alignment: .leading, spacing: 16) {
            Text(project.map { "Nouvel agent · \($0.name)" } ?? "Nouvel agent")
                .font(.title2.weight(.semibold))
            Form {
                if model.projects.count > 1 {
                    Picker("Projet", selection: $projectID) {
                        ForEach(model.projects) { candidate in
                            Text(candidate.name).tag(Optional(candidate.id))
                        }
                    }
                }
                LabeledContent("Nom") {
                    HStack {
                        TextField("Nom", text: $name)
                            .labelsHidden()
                            .frame(maxWidth: 180)
                        Button {
                            name = Self.generatedName(avoiding: model.agentNames.union([name]))
                        } label: {
                            Label("Autre nom", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .help("Proposer un autre nom")
                    }
                }
                LabeledContent("Modèle") {
                    TextField("Modèle", text: $agentModel, prompt: Text(modelPrompt(for: project)))
                        .labelsHidden()
                        .frame(maxWidth: 220)
                }
                permissionSection
                worktreeSection
            }
            .formStyle(.grouped)
            if !model.claude.isUsable, model.claude.phase != .detecting {
                Label("Claude Code est introuvable : l'agent sera créé, sa session ne pourra pas démarrer.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(StateStyle.tint(for: .error))
            }
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Lancer", action: launch)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canLaunch)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: prepare)
        .onChange(of: projectID) { _, newValue in
            if let project = newValue.flatMap({ model.project($0) }) {
                permissionMode = project.defaults.permissionMode
            }
        }
        .onChange(of: name) { _, newValue in
            if !worktreeEdited { worktreeName = Self.worktreeSlug(newValue) }
        }
        .onChange(of: permissionMode) { _, _ in
            riskAcknowledged = false
        }
    }

    // MARK: - Sections

    private var permissionSection: some View {
        Section {
            Picker("Permissions", selection: $permissionMode) {
                ForEach(PermissionMode.allCases, id: \.self) { mode in
                    Text("\(mode.rawValue) — \(PermissionModeInfo.summary(mode))").tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            if PermissionModeInfo.isRisky(permissionMode) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(PermissionModeInfo.bypassWarning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(StateStyle.tint(for: .error))
                        .fontWeight(.semibold)
                    Toggle("Je comprends le risque pour cet agent.", isOn: $riskAcknowledged)
                }
            }
        }
    }

    private var worktreeSection: some View {
        Section {
            Toggle(isOn: $usesWorktree) {
                Text("Travailler dans une copie isolée (git worktree)")
            }
            if usesWorktree {
                LabeledContent("Nom du worktree") {
                    TextField("Nom du worktree", text: $worktreeName)
                        .labelsHidden()
                        .frame(maxWidth: 180)
                        .onChange(of: worktreeName) { _, newValue in
                            if newValue != Self.worktreeSlug(name) { worktreeEdited = true }
                        }
                }
                Text("Claude Code crée <dossier>/.claude/worktrees/\(worktreeSlugToUse) (--worktree).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Logic

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var worktreeSlugToUse: String {
        let slug = Self.worktreeSlug(worktreeName)
        return slug.isEmpty ? Self.worktreeSlug(trimmedName) : slug
    }

    private var canLaunch: Bool {
        guard projectID.flatMap({ model.project($0) }) != nil, !trimmedName.isEmpty else { return false }
        if PermissionModeInfo.isRisky(permissionMode), !riskAcknowledged { return false }
        if usesWorktree, worktreeSlugToUse.isEmpty { return false }
        return true
    }

    private func modelPrompt(for project: Project?) -> String {
        if let projectModel = project?.defaults.model, !projectModel.isEmpty { return "\(projectModel) (défaut du projet)" }
        return "défaut de Claude Code"
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        projectID = initialProjectID ?? model.projects.first?.id
        if let project = projectID.flatMap({ model.project($0) }) {
            permissionMode = project.defaults.permissionMode
        }
        name = Self.generatedName(avoiding: model.agentNames)
        worktreeName = Self.worktreeSlug(name)
    }

    private func launch() {
        guard canLaunch, let projectID else { return }
        let trimmedModel = agentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let agentID = model.addAgent(projectID: projectID, name: trimmedName,
                                     model: trimmedModel.isEmpty ? nil : trimmedModel,
                                     permissionMode: permissionMode,
                                     worktree: usesWorktree ? worktreeSlugToUse : nil)
        guard let agentID else { return }
        dismiss()
        workbench.showTerminal(for: agentID, focus: true)
    }

    // MARK: - Helpers

    static func generatedName(avoiding names: Set<String>) -> String {
        NameGenerator.name(seed: UInt64.random(in: 0...UInt64.max), avoiding: names)
    }

    /// A worktree name safe for a folder and a branch: lowercase ASCII letters, digits, "-" and "_".
    static func worktreeSlug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .lowercased()
        var slug = ""
        var lastWasDash = false
        for scalar in folded.unicodeScalars {
            let isAllowed = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") || scalar == "_"
            if isAllowed {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return String(slug.prefix(40))
    }
}
