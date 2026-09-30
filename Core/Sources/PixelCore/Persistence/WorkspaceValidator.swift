import Foundation

/// Repairs a loaded workspace so that the invariants of proposal 4.2 hold; each repair is reported (French,
/// shown in the load warning and the log). File order decides who keeps a contested slot or desk: the first
/// holder, i.e. the oldest, keeps it; the others get the lowest free one. Deterministic.
public enum WorkspaceValidator {
    public static func validate(_ input: Workspace) -> (workspace: Workspace, issues: [String]) {
        var w = input
        var issues: [String] = []

        // Unique project IDs.
        var projectIDs: Set<ProjectID> = []
        w.projects = w.projects.filter { project in
            guard projectIDs.insert(project.id).inserted else {
                issues.append("Projet « \(project.name) » en double (\(project.id)) : ignoré.")
                return false
            }
            return true
        }

        // Hues in 0...9.
        for i in w.projects.indices where !(0..<Workspace.projectHueCount).contains(w.projects[i].hueIndex) {
            let fixed = Workspace.clampedHue(w.projects[i].hueIndex)
            issues.append("Projet « \(w.projects[i].name) » : teinte \(w.projects[i].hueIndex) ramenée à \(fixed).")
            w.projects[i].hueIndex = fixed
        }

        // Unique, non-negative slots among live projects.
        var usedSlots: Set<Int> = []
        var needsSlot: [Int] = []
        for i in w.projects.indices where !w.projects[i].archived {
            if w.projects[i].slot >= 0, usedSlots.insert(w.projects[i].slot).inserted { continue }
            needsSlot.append(i)
        }
        for i in needsSlot {
            let old = w.projects[i].slot
            var slot = 0
            while usedSlots.contains(slot) { slot += 1 }
            usedSlots.insert(slot)
            w.projects[i].slot = slot
            issues.append("Projet « \(w.projects[i].name) » : emplacement \(old) déjà pris ou invalide, déplacé en \(slot).")
        }

        // Agents: unique IDs, known projects.
        let knownProjects = Set(w.projects.map(\.id))
        var agentIDs: Set<AgentID> = []
        w.agents = w.agents.filter { agent in
            guard agentIDs.insert(agent.id).inserted else {
                issues.append("Agent « \(agent.name) » en double (\(agent.id)) : ignoré.")
                return false
            }
            guard knownProjects.contains(agent.projectID) else {
                issues.append("Agent « \(agent.name) » : projet inconnu (\(agent.projectID)), retiré.")
                return false
            }
            return true
        }

        // Unique, non-negative desks inside each project.
        var usedDesks: [ProjectID: Set<Int>] = [:]
        var needsDesk: [Int] = []
        for i in w.agents.indices {
            let desk = w.agents[i].deskIndex
            if desk >= 0, usedDesks[w.agents[i].projectID, default: []].insert(desk).inserted { continue }
            needsDesk.append(i)
        }
        for i in needsDesk {
            let projectID = w.agents[i].projectID
            let old = w.agents[i].deskIndex
            var desk = 0
            while usedDesks[projectID, default: []].contains(desk) { desk += 1 }
            usedDesks[projectID, default: []].insert(desk)
            w.agents[i].deskIndex = desk
            issues.append("Agent « \(w.agents[i].name) » : poste \(old) déjà pris ou invalide, déplacé au poste \(desk).")
        }

        return (w, issues)
    }
}
