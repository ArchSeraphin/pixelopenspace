import PixelCore
import SwiftUI

/// The agent's queue (mockup 6(d), "File de post-its"): the post-it in progress, then its instructions and queued
/// post-its in delivery order (`AppModel.queue(of:)`). A queued post-it moves up or down among the post-its
/// (`.reorderQueue`, the instructions always go first) or leaves the queue (`.unassign`); "Mettre en pause" stops
/// the deliveries, "Reprendre la file" restarts them once the stopped post-it is decided (4.3b).
struct AgentQueueSection: View {
    /// Beyond this many items, the list scrolls.
    static let visibleItems = 6

    let agentID: AgentID

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    var body: some View {
        let queue = model.queue(of: agentID)
        let cardIDs = queue.compactMap { item -> TaskCardID? in
            if case .card(let id) = item { return id }
            return nil
        }
        let current = model.currentCard(of: agentID)
        let paused = model.agent(agentID)?.queuePaused ?? false
        VStack(alignment: .leading, spacing: 8) {
            header(count: queue.count, paused: paused)
            if let current {
                currentRow(current)
            }
            if queue.isEmpty {
                Text(current == nil ? "File vide." : "Rien d'autre dans la file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if queue.count > Self.visibleItems {
                ScrollView {
                    rows(queue, cardIDs: cardIDs)
                }
                .frame(height: CGFloat(Self.visibleItems) * 28)
            } else {
                rows(queue, cardIDs: cardIDs)
            }
            status(paused: paused, empty: queue.isEmpty)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File de post-its")
    }

    // MARK: Header and status

    private func header(count: Int, paused: Bool) -> some View {
        let toDecide = paused ? model.cardToDecide(of: agentID) : nil
        return HStack(alignment: .firstTextBaseline) {
            Text("File de post-its")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if count > 0 {
                Text("· \(count)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if paused {
                Button {
                    model.resumeQueue(agentID)
                } label: {
                    Label("Reprendre la file", systemImage: "play.fill")
                }
                .disabled(toDecide != nil)
                .help(toDecide.map { "Pour reprendre la file, " + AppModel.decideFirstText($0) }
                      ?? "Les post-its et consignes repartent, dans l'ordre")
            } else {
                Button {
                    model.setQueuePaused(true, for: agentID)
                } label: {
                    Label("Mettre en pause", systemImage: "pause.fill")
                }
                .help("Plus rien ne part vers l'agent tant que la file est en pause")
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func status(paused: Bool, empty: Bool) -> some View {
        if paused {
            Label("En pause : rien ne part sans toi.", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(StateStyle.tint(for: .waitingInput))
        } else if !empty, let cause = model.deliveryWaitCause(of: agentID) {
            Text("Prochain envoi retenu : \(cause.label).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Rows

    /// "▸ ◉ Refonte du header · en cours".
    private func currentRow(_ card: TaskCard) -> some View {
        let flags = CardPresentation.flags(of: card).map(CardPresentation.flagText)
        let state = flags.isEmpty ? "en cours" : "en cours (\(flags.joined(separator: ", ")))"
        return HStack(spacing: 8) {
            Image(systemName: "play.fill")
                .font(.caption)
                .foregroundStyle(StateStyle.tint(for: .working))
                .accessibilityHidden(true)
            hueDot(card.projectID)
            Text(card.title)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(state)
                .font(.callout)
                .foregroundStyle(flags.isEmpty ? Color.secondary : StateStyle.tint(for: .waitingInput))
        }
        .frame(minHeight: 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Post-it en cours : \(card.title), \(state)")
    }

    private func rows(_ queue: [QueueItem], cardIDs: [TaskCardID]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(queue.enumerated()), id: \.element) { index, item in
                switch item {
                case .instruction(let id):
                    instructionRow(id, position: index + 1)
                case .card(let id):
                    cardRow(id, position: index + 1, cardIDs: cardIDs)
                }
            }
        }
    }

    private func instructionRow(_ id: InstructionID, position: Int) -> some View {
        let instruction = model.board.instructions.first { $0.id == id }
        let text = instruction?.text ?? "consigne"
        let sending = instruction?.delivery?.isPending == true
        return HStack(spacing: 8) {
            Text("\(position).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
            Image(systemName: "text.bubble")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Consigne : « \(text) »")
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if sending {
                Text("envoi en cours")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 24)
        .help(text)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(position), consigne : \(text)" + (sending ? ", envoi en cours" : ""))
    }

    private func cardRow(_ id: TaskCardID, position: Int, cardIDs: [TaskCardID]) -> some View {
        let card = model.board.card(id)
        let title = card?.title ?? "post-it"
        let sending = card?.delivery?.isPending == true
        let moves = Self.moves(of: id, in: cardIDs)
        return HStack(spacing: 8) {
            Text("\(position).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
            hueDot(card?.projectID)
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if sending {
                Text("envoi en cours")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Button("↑") {
                    if let after = moves.up { workbench.requestTask(.reorderQueue(id, after: after)) }
                }
                .disabled(moves.up == nil || sending)
                .help("Monter dans la file")
                .accessibilityLabel("Monter « \(title) »")
                Button("↓") {
                    if let after = moves.down { workbench.requestTask(.reorderQueue(id, after: after)) }
                }
                .disabled(moves.down == nil || sending)
                .help("Descendre dans la file")
                .accessibilityLabel("Descendre « \(title) »")
                Button("Retirer") {
                    workbench.requestTask(.unassign(id))
                }
                .disabled(sending)
                .help("Retirer de la file : le post-it reste dans « À faire », sans agent")
                .accessibilityLabel("Retirer « \(title) » de la file")
            }
            .controlSize(.small)
        }
        .frame(minHeight: 24)
        .help(title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(position), post-it : \(title)" + (sending ? ", envoi en cours" : ""))
    }

    private func hueDot(_ projectID: ProjectID?) -> some View {
        let hue = projectID.flatMap { model.project($0)?.hueIndex }
        return Circle()
            .fill(hue.map(ProjectHue.color) ?? Color.secondary.opacity(0.4))
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
    }

    /// Where `.reorderQueue` puts a queued post-it to move it one place up or down among the agent's post-its
    /// (`after`: the post-it it then follows; `.some(nil)` = the head of the post-its, after the instructions).
    /// nil when it cannot move that way.
    static func moves(of id: TaskCardID, in cardIDs: [TaskCardID]) -> (up: TaskCardID??, down: TaskCardID??) {
        guard let index = cardIDs.firstIndex(of: id) else { return (nil, nil) }
        let up: TaskCardID?? = index == 0 ? nil : .some(index >= 2 ? cardIDs[index - 2] : nil)
        let down: TaskCardID?? = index + 1 < cardIDs.count ? .some(cardIDs[index + 1]) : nil
        return (up, down)
    }
}
