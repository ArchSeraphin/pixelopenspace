import PixelCore
import SwiftUI

/// The agent cards grouped by project (mockup 6(b)): one section per live project, cards in an adaptive grid.
/// The status-bar filter keeps only the agents in one state. Empty workspace: the welcome drop zone (6(r)).
struct AgentBoardView: View {
    nonisolated static let cardMinimumWidth: CGFloat = 260

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    var body: some View {
        if model.projects.isEmpty {
            EmptyWorkspaceView()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let filter = workbench.stateFilter {
                            FilterChip(kind: filter)
                        }
                        ForEach(model.projects) { project in
                            ProjectSectionView(project: project, filter: workbench.stateFilter)
                                .id(project.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: workbench.scrollRequest) { _, request in
                    guard let request else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        switch request.target {
                        case .agent(let agentID): proxy.scrollTo(agentID, anchor: .center)
                        case .project(let projectID): proxy.scrollTo(projectID, anchor: .top)
                        }
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

/// "Filtre : en attente ✕" above the board while a status-bar counter is active.
private struct FilterChip: View {
    let kind: AgentStateKind

    @Environment(WorkbenchState.self) private var workbench

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: StateStyle.symbolName(for: kind))
                .foregroundStyle(StateStyle.tint(for: kind))
                .accessibilityHidden(true)
            Text("Filtre : \(StateStyle.filterName(for: kind))")
            Button {
                workbench.stateFilter = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Afficher tous les agents")
            .accessibilityLabel("Retirer le filtre")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(StateStyle.tint(for: kind).opacity(0.15)))
    }
}
