import PixelCore
import SwiftUI

/// "Claude Code" tab (mockup 6(h)): executable (override + Détecter), default model and permission mode, launch
/// options, extra environment variables.
struct ClaudeCodeSettingsTab: View {
    @Binding var draft: AppSettings

    @Environment(AppModel.self) private var model

    @State private var pathText = ""
    @State private var modelText = ""
    @State private var prepared = false

    var body: some View {
        Form {
            Section("Exécutable") {
                LabeledContent("Chemin de claude") {
                    HStack {
                        TextField("Chemin de claude", text: $pathText, prompt: Text(model.claude.path ?? "détection automatique"))
                            .labelsHidden()
                            .onSubmit(applyPath)
                        Button("Choisir…", action: choosePath)
                        Button("Détecter", action: applyPath)
                            .disabled(model.claude.phase == .detecting)
                            .help("Chercher claude à nouveau (chemin indiqué, PATH de ton shell, emplacements connus)")
                    }
                }
                ClaudeDetectionSummary(status: model.claude)
            }
            Section("Nouveaux agents") {
                LabeledContent("Modèle par défaut") {
                    TextField("Modèle par défaut", text: $modelText, prompt: Text("défaut de Claude Code"))
                        .labelsHidden()
                        .frame(maxWidth: 220)
                }
                Picker("Permissions par défaut", selection: $draft.defaultPermissionMode) {
                    ForEach(PermissionMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                Text(PermissionModeInfo.summary(draft.defaultPermissionMode)
                    + ". Chaque projet peut avoir ses propres défauts.")
                    .font(.caption)
                    .foregroundStyle(PermissionModeInfo.isRisky(draft.defaultPermissionMode)
                        ? StateStyle.tint(for: .error) : Color.secondary)
            }
            Section {
                Toggle("Désactiver la vue agents dans les sessions intégrées", isOn: $draft.disableAgentViewInEmbedded)
                Toggle("Forcer le rendu classique (pas d'écran alternatif)", isOn: $draft.forceClassicRenderer)
                Toggle("Couper le trafic non essentiel de Claude Code", isOn: $draft.disableNonessentialTraffic)
            } header: {
                Text("Lancement")
            } footer: {
                Text("S'applique aux sessions lancées ensuite.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ExtraEnvironmentEditor(environment: $draft.extraEnv)
            } header: {
                Text("Variables en plus")
            } footer: {
                Text("Ajoutées à l'environnement de ton shell pour chaque session (ex. NODE_OPTIONS).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: prepare)
        .onChange(of: modelText) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.defaultModel = trimmed.isEmpty ? nil : trimmed
        }
        .onChange(of: draft.claudePathOverride) { _, newValue in
            if (newValue ?? "") != pathText { pathText = newValue ?? "" }
        }
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        pathText = model.settings.claudePathOverride ?? ""
        modelText = model.settings.defaultModel ?? ""
    }

    /// Applies the path typed (empty: automatic detection) and searches again.
    private func applyPath() {
        model.setClaudePathOverride(pathText)
    }

    private func choosePath() {
        guard let url = FilePickers.chooseClaudeExecutable(current: model.claude.path) else { return }
        pathText = url.path(percentEncoded: false)
        applyPath()
    }
}

/// "v2.1.240 ✓" / "introuvable", under the executable field.
private struct ClaudeDetectionSummary: View {
    let status: ClaudeStatus

    var body: some View {
        switch status.phase {
        case .detecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Recherche de Claude Code…")
                    .foregroundStyle(.secondary)
            }
        case .found, .versionUnknown:
            VStack(alignment: .leading, spacing: 2) {
                Label(foundText, systemImage: status.meetsMinimum ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(status.meetsMinimum ? StateStyle.tint(for: .done) : StateStyle.tint(for: .waitingInput))
                if let error = status.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        case .notFound:
            Label(status.error ?? "Claude Code est introuvable.", systemImage: "xmark.octagon.fill")
                .foregroundStyle(StateStyle.tint(for: .error))
        }
    }

    private var foundText: String {
        let path = status.path ?? ""
        let minimum = ClaudeStatus.minimumVersion.description
        guard let version = status.version else { return "\(path) · version inconnue (minimum \(minimum))" }
        if status.meetsMinimum { return "\(path) · v\(version.description)" }
        return "\(path) · v\(version.description) : trop ancienne (minimum \(minimum))"
    }
}
