import AppKit
import PixelCore
import SwiftUI

/// Welcome sheet (mockup 6(r)): shown at the first launch, when Claude Code cannot be found, and from the banners.
struct ClaudeSetupSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bienvenue dans Pixel Open Space")
                .font(.title2.weight(.semibold))
            ClaudeStatusView()
            Divider()
            WelcomeStep(number: 3, title: "Connexion",
                        text: "Elle se fait dans le terminal au premier lancement d'un agent ; l'app ne voit ni ne "
                            + "stocke tes identifiants.")
            WelcomeStep(number: 4, title: "Premier dossier",
                        text: "Claude peut demander dans le terminal si tu fais confiance au dossier : la carte de "
                            + "l'agent affiche alors « regarde le terminal ».")
            WelcomeStep(number: 5, title: "Notifications",
                        text: "Demandées la première fois qu'un agent attendra, pour te prévenir même quand l'app est "
                            + "en arrière-plan.")
            HStack {
                Spacer()
                Button("Continuer") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600)
    }
}

/// Steps 1 and 2 of the welcome sheet: where `claude` is, its version against the minimum. Also used in Settings.
struct ClaudeStatusView: View {
    static let installGuide = URL(string: "https://code.claude.com/docs/en/setup")

    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.claude
        VStack(alignment: .leading, spacing: 12) {
            WelcomeStep(number: 1, title: "Claude Code", text: nil) {
                VStack(alignment: .leading, spacing: 6) {
                    executableLine(status)
                    if status.phase == .notFound, !status.searched.isEmpty {
                        Text("Cherché : " + status.searched.map { ProjectSectionView.abbreviated($0) }.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if let error = status.error, status.phase != .found {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    environmentLine
                    HStack {
                        Button("Indiquer le chemin…", action: choosePath)
                        if let url = Self.installGuide {
                            Link("Comment l'installer", destination: url)
                        }
                        Button("Réessayer") { model.redetectClaude() }
                            .disabled(status.phase == .detecting)
                    }
                    .controlSize(.small)
                }
            }
            WelcomeStep(number: 2, title: "Version", text: nil) {
                versionLine(status)
            }
        }
    }

    @ViewBuilder
    private func executableLine(_ status: ClaudeStatus) -> some View {
        switch status.phase {
        case .detecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Recherche en cours…")
            }
        case .found, .versionUnknown:
            Label(status.path ?? "", systemImage: "checkmark.circle.fill")
                .foregroundStyle(StateStyle.tint(for: .done))
                .textSelection(.enabled)
        case .notFound:
            Label("Introuvable", systemImage: "xmark.octagon.fill")
                .foregroundStyle(StateStyle.tint(for: .error))
        }
    }

    @ViewBuilder
    private func versionLine(_ status: ClaudeStatus) -> some View {
        let minimum = ClaudeStatus.minimumVersion.description
        if let version = status.version {
            if status.meetsMinimum {
                Label("\(version.description) (minimum \(minimum))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(StateStyle.tint(for: .done))
            } else {
                Label("\(version.description) : trop ancienne, minimum \(minimum). Mets Claude Code à jour (claude update).",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(StateStyle.tint(for: .waitingInput))
            }
        } else {
            Text("— (minimum \(minimum), lue avec claude --version)")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var environmentLine: some View {
        switch model.environmentSource {
        case .pending:
            EmptyView()
        case .loginShell(let shell):
            Text("Environnement (PATH…) lu dans ton shell de connexion : \(shell)")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .appFallback(let shell, let reason):
            Text("Le shell \(shell) n'a pas pu être lu (\(reason)) : environnement minimal de l'app.")
                .font(.caption)
                .foregroundStyle(StateStyle.tint(for: .waitingInput))
        }
    }

    private func choosePath() {
        guard let url = FilePickers.chooseClaudeExecutable(current: model.claude.path) else { return }
        model.setClaudePathOverride(url.path(percentEncoded: false))
    }
}

/// A numbered step of the welcome sheet.
private struct WelcomeStep<Content: View>: View {
    let number: Int
    let title: String
    let text: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number).")
                .font(.headline)
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                if let text {
                    Text(text)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content()
            }
        }
        .accessibilityElement(children: .contain)
    }
}

extension WelcomeStep where Content == EmptyView {
    init(number: Int, title: String, text: String?) {
        self.init(number: number, title: title, text: text) { EmptyView() }
    }
}
