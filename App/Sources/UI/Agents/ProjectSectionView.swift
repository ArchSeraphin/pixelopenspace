import PixelCore
import SwiftUI

/// One project on the board: "API · ~/dev/api [+ Agent]", then its agent cards.
struct ProjectSectionView: View {
    let project: Project
    /// Status-bar filter: only agents in this state.
    let filter: AgentStateKind?

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    private let columns = [GridItem(.adaptive(minimum: AgentBoardView.cardMinimumWidth), spacing: 12, alignment: .top)]

    var body: some View {
        let allAgents = model.agents(in: project.id)
        let agents = filter.map { kind in allAgents.filter { model.runtime(for: $0.id)?.kind == kind } } ?? allAgents
        if filter == nil || !agents.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                header(agentCount: allAgents.count)
                if agents.isEmpty {
                    Text("Aucun agent dans ce projet.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(agents) { agent in
                            AgentCardView(agent: agent, project: project)
                                .id(agent.id)
                        }
                    }
                }
            }
        }
    }

    private func header(agentCount: Int) -> some View {
        let isSelected = model.selectedProjectID == project.id
        return HStack(spacing: 8) {
            ProjectHueSquare(hueIndex: project.hueIndex, size: 12)
            Text(project.name.uppercased())
                .font(.headline)
            Text("· \(Self.abbreviated(project.path))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(project.path)
            Spacer(minLength: 8)
            Button {
                workbench.present(.newAgent(project.id))
            } label: {
                Label("Agent", systemImage: "plus")
            }
            .controlSize(.small)
            .help("Nouvel agent dans \(project.name)")
            .accessibilityLabel("Nouvel agent dans \(project.name)")
        }
        .padding(.bottom, 2)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isSelected ? ProjectHue.color(project.hueIndex) : Color.primary.opacity(0.1))
                .frame(height: isSelected ? 2 : 1)
                .offset(y: 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Projet \(project.name), \(agentCount) \(agentCount > 1 ? "agents" : "agent")")
        .accessibilityAddTraits(.isHeader)
    }

    /// "~/dev/api".
    nonisolated static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
