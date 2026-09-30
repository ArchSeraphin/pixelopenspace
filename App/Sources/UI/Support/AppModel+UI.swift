import Foundation
import PixelCore

/// Read-only helpers for the views, built on `AppModel`'s public state (no new state, no side effect).
extension AppModel {
    /// Status-bar counters and waiting tray for the agents of live projects only (agents of archived projects are
    /// kept in the workspace but shown nowhere).
    var liveStatusSummary: StatusSummary {
        let liveIDs = Set(agentsInOrder.map(\.id))
        return StatusSummary.compute(runtimes.filter { liveIDs.contains($0.key) })
    }

    /// The agent has a terminal (running, or kept after its process ended).
    func hasTerminal(_ agentID: AgentID) -> Bool {
        sessions.host(for: agentID) != nil
    }

    /// The live project already open on this folder, if any (adding it again would only select it).
    func liveProject(forFolder url: URL) -> Project? {
        let path = PathNormalizer.standardize(PathNormalizer.normalize(url.path(percentEncoded: false),
                                                                       home: NSHomeDirectory()))
        return projects.first { PathNormalizer.standardize($0.path) == path }
    }

    /// Model shown for an agent: its own, the project's default, or Claude Code's.
    func effectiveModel(of agent: Agent) -> String? {
        if let model = agent.model, !model.isEmpty { return model }
        if let model = project(agent.projectID)?.defaults.model, !model.isEmpty { return model }
        return nil
    }

    /// Names already used by agents (a new name should differ).
    var agentNames: Set<String> {
        Set(workspace.agents.map(\.name))
    }

    /// Sets (or clears, with `nil`) the path of `claude` given by the user; the search starts again.
    func setClaudePathOverride(_ path: String?) {
        var updated = settings
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        updated.claudePathOverride = trimmed.isEmpty ? nil : trimmed
        if updated == settings {
            redetectClaude()
        } else {
            updateSettings(updated)
        }
    }
}
