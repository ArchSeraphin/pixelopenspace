import PixelCore
import SwiftUI

/// What the agent waits for (mockups 6(e) and 6(e′)), shown only while it waits: a permission (the tool and the
/// summary of `tool_input`, in a fixed-width font), a question of `AskUserQuestion` (header, text, options, one or
/// several answers), an MCP dialog (server and message), a notification, or a silent launch ("Regarde le
/// terminal"). Everything comes from the hooks; the answer is given in the terminal ("Refuser (Échap)" and the
/// option buttons read on the screen come at step 5, décision 7).
struct AgentWaitSection: View {
    let agentID: AgentID
    let canOpenTerminal: Bool
    let openTerminal: @MainActor () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        if let runtime = model.runtime(for: agentID), let oldest = runtime.oldestWait {
            let waits = Self.sorted(runtime)
            let name = model.names(of: agentID).agent
            VStack(alignment: .leading, spacing: 12) {
                header(name: name, oldest: oldest, count: waits.count)
                ForEach(Array(waits.enumerated()), id: \.offset) { index, wait in
                    if index > 0 { Divider() }
                    AgentWaitDetail(wait: wait)
                }
                footer
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StateStyle.tint(for: .waitingInput).opacity(0.10))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Attente")
        }
    }

    /// "(!) NOVA ATTEND TA RÉPONSE · depuis 42 s", "(?) SOL TE POSE UNE QUESTION".
    private func header(name: String, oldest: PendingWait, count: Int) -> some View {
        let isQuestion: Bool = {
            if case .question = oldest.reason { return true }
            return false
        }()
        let title = isQuestion ? "\(name) te pose une question" : "\(name) attend ta réponse"
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: AgentPresenter.symbolName(for: oldest.reason))
                .font(.title2)
                .foregroundStyle(StateStyle.tint(for: .waitingInput))
                .accessibilityHidden(true)
            Text(title.uppercased())
                .font(.headline)
                .foregroundStyle(StateStyle.tint(for: .waitingInput))
                .accessibilityAddTraits(.isHeader)
            if count > 1 {
                Text("· \(count) attentes")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text("depuis \(AgentWindowText.duration(model.now.timeIntervalSince(oldest.since)))")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("L'app ne répond jamais à ta place.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                openTerminal()
            } label: {
                Label("Ouvrir le terminal ⌘T", systemImage: "terminal")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canOpenTerminal)
            .help("Réponds dans le terminal de l'agent : c'est la voie sûre")
        }
    }

    /// Oldest first; waits opened at the same instant by their text (a dictionary has no order).
    static func sorted(_ runtime: AgentRuntime) -> [PendingWait] {
        runtime.pendingWaits.values.sorted { lhs, rhs in
            if lhs.since != rhs.since { return lhs.since < rhs.since }
            return AgentPresenter.describe(lhs.reason) < AgentPresenter.describe(rhs.reason)
        }
    }
}

/// One wait, by its reason.
private struct AgentWaitDetail: View {
    let wait: PendingWait

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
            if wait.subagentID != nil {
                Label("Demandé par un sous-agent", systemImage: "person.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch wait.reason {
        case .permission(let tool, let summary):
            Text("Claude veut utiliser l'outil : \(tool)")
                .font(.body.weight(.medium))
            if summary.isEmpty {
                Text("Le hook n'a pas donné de détail : regarde le terminal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                AgentWaitBox(text: summary, monospaced: true)
                    .accessibilityLabel("Détail : \(summary)")
            }
        case .question(let questions):
            if questions.isEmpty {
                Text("Claude pose une question : regarde le terminal.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                        AgentQuestionView(question: question)
                    }
                }
                Text("Question et options lues dans le hook. Réponds dans le terminal : des boutons arriveront quand "
                     + "les touches de ce dialogue auront été vérifiées.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .elicitation(let server, let message):
            Text(server.map { "Dialogue MCP du serveur « \($0) »" } ?? "Dialogue MCP")
                .font(.body.weight(.medium))
            if message.isEmpty {
                Text("Le serveur n'a pas donné de message : regarde le terminal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                AgentWaitBox(text: message, monospaced: false)
            }
        case .notification:
            Text("Claude Code signale : \(AgentPresenter.describe(wait.reason))")
                .font(.body.weight(.medium))
            Text("Le détail est dans le terminal.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .terminal:
            Text("Regarde le terminal")
                .font(.body.weight(.medium))
            Text("Lancement silencieux : Claude Code attend quelque chose qui ne passe pas par les hooks (dossier de "
                 + "confiance, connexion…).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A question of `AskUserQuestion` (6(e′)): header, one or several answers, the question, its options.
private struct AgentQuestionView: View {
    let question: AskedQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(question.header.isEmpty ? "Question" : question.header)
                    .font(.body.weight(.semibold))
                Spacer(minLength: 8)
                Text(question.multiSelect ? "(plusieurs réponses)" : "(une seule réponse)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !question.question.isEmpty {
                Text("« \(question.question) »")
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                    Label(option, systemImage: question.multiSelect ? "square" : "circle")
                        .padding(.leading, 6)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Options : " + question.options.joined(separator: ", "))
        }
    }
}

/// The summary of a tool call or an MCP message, selectable, in a text box.
private struct AgentWaitBox: View {
    let text: String
    let monospaced: Bool

    var body: some View {
        Text(text)
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .textSelection(.enabled)
            .lineLimit(8)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
    }
}
