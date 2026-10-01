import Foundation
import PixelCore

/// One shot of a scenario: its steps, run in order, then the captures, named `<kind>-<scenario>-<shot>.png`.
struct SnapshotShot: Sendable {
    var name: String
    var steps: [SnapshotStep]

    init(_ name: String, _ steps: [SnapshotStep]) {
        self.name = name
        self.steps = steps
    }
}

/// A scenario of the snapshot harness (`--scenario`): steps run once, then its shots. The window is 1440 × 900 pt
/// unless `--size` says otherwise; agents, projects and post-its are those of `Showcase.appWorkspace()`.
struct SnapshotScenario: Identifiable, Sendable {
    /// Lower-case identifiers of the command line, in the order of `all`.
    enum ID: String, CaseIterable, Sendable {
        case overview, zooms, fractional, list, empty, select, navigation
        case agentWindow = "agentwindow"
        case dragdrop, board, arrival, demo, selftest
    }

    /// What the model shows during the scenario.
    enum Distribution: Sendable {
        /// `Showcase.appWorkspace()`: 20 agents on 6 projects.
        case showcase
        /// `Showcase.emptyWorkspace()` (first launch, 6(r)); the showcase comes back afterwards.
        case empty
    }

    /// What the scenario captures besides the windows.
    enum Kind: Sendable {
        /// Windows, and the scene (or its reference) for the shots where the scene is on screen.
        case windows
        /// The demo mode's window and panel, without interaction.
        case demo
        /// No window: checks the comparison tool.
        case selftest
    }

    var id: ID
    var distribution: Distribution = .showcase
    var kind: Kind = .windows
    /// Steps run once, before the first shot.
    var setup: [SnapshotStep] = []
    var shots: [SnapshotShot]

    static func scenario(_ id: ID) -> SnapshotScenario {
        switch id {
        case .overview:
            return SnapshotScenario(id: id, shots: [
                SnapshotShot("tout-voir", [.listView(false), .board(.side), .fitAll]),
            ])
        case .zooms:
            return SnapshotScenario(id: id, setup: [.listView(false), .board(.hidden), .focusIsland("API")], shots: [
                SnapshotShot("ensemble", [.zoom(.overview)]),
                SnapshotShot("x1", [.zoom(.x1)]),
                SnapshotShot("x2", [.zoom(.x2)]),
                SnapshotShot("x3", [.zoom(.x3)]),
            ])
        case .fractional:
            return SnapshotScenario(id: id, setup: [.listView(false), .board(.hidden), .zoom(.x2), .focusAgent("Nova")],
                                    shots: [
                                        SnapshotShot("d1", [.cameraNudge(dx: 0.25, dy: 0)]),
                                        SnapshotShot("d2", [.cameraNudge(dx: 0.5, dy: 0.5)]),
                                        SnapshotShot("d3", [.cameraNudge(dx: 0.75, dy: 0.25)]),
                                        SnapshotShot("d4", [.cameraNudge(dx: 1.5, dy: 0.75)]),
                                        SnapshotShot("x3", [.zoom(.x3), .cameraNudge(dx: 0.33, dy: 0.66)]),
                                    ])
        case .list:
            return SnapshotScenario(id: id, shots: [SnapshotShot("liste", [.listView(true), .board(.side)])])
        case .empty:
            return SnapshotScenario(id: id, distribution: .empty, shots: [
                SnapshotShot("monde-vide", [.listView(false)]),
                SnapshotShot("liste-vide", [.listView(true)]),
            ])
        case .select:
            return SnapshotScenario(id: id, setup: [.listView(false), .zoom(.x2), .focusAgent("Nova")], shots: [
                SnapshotShot("selection", [.select("Nova")]),
                SnapshotShot("survol-agent", [.hover(.agent("Bip"))]),
                SnapshotShot("survol-poste", [.hover(.freeDesk(project: "API", deskIndex: 5))]),
            ])
        case .navigation:
            return SnapshotScenario(id: id, setup: [.listView(false), .board(.side)], shots: [
                SnapshotShot("loin", [.zoom(.x3), .focusIsland("DOCS")]),
                SnapshotShot("hall", [.zoom(.x1), .focusHall]),
            ])
        case .agentWindow:
            return SnapshotScenario(id: id, shots: [
                SnapshotShot("nova", [.openAgentWindow("Nova")]),
                SnapshotShot("sol", [.openAgentWindow("Sol")]),
                SnapshotShot("brume", [.openAgentWindow("Brume")]),
            ])
        case .dragdrop:
            let card = "Pagination /users"
            return SnapshotScenario(id: id, setup: [.listView(false), .board(.side), .zoom(.x2), .focusIsland("API")],
                                    shots: [
                                        SnapshotShot("bip", [.dragHover(card: card, over: .agent("Bip"))]),
                                        SnapshotShot("sol-autre-projet", [.dragHover(card: card, over: .agent("Sol"))]),
                                        SnapshotShot("kiwi-hors-ligne", [.dragHover(card: card, over: .agent("Kiwi"))]),
                                        SnapshotShot("ilot", [.dragHover(card: card, over: .island("API"))]),
                                        SnapshotShot("poste-libre", [.dragHover(card: card,
                                                                                over: .freeDesk(project: "API", deskIndex: 5))]),
                                        SnapshotShot("fleche", [.dragHover(card: card, over: .edgeArrow(agent: "Ivo"))]),
                                        SnapshotShot("plateau", [.dragHover(card: card, over: .trayRow(agent: "Sol"))]),
                                        SnapshotShot("mini-carte", [.dragHover(card: card, over: .minimap(agent: "Ivo"))]),
                                    ])
        case .board:
            return SnapshotScenario(id: id, shots: [SnapshotShot("plein-ecran", [.board(.full)])])
        case .arrival:
            return SnapshotScenario(id: id, setup: [.listView(false), .zoom(.x2), .focusIsland("DATA")], shots: [
                SnapshotShot("brume-0", [.arrival(agent: "Brume", progress: 0)]),
                SnapshotShot("brume-40", [.arrival(agent: "Brume", progress: 0.4)]),
                SnapshotShot("brume-80", [.arrival(agent: "Brume", progress: 0.8)]),
                SnapshotShot("brume-100", [.arrival(agent: "Brume", progress: 1)]),
                SnapshotShot("chute-mobile", [.focusIsland("MOBILE"), .islandDrop(project: "MOBILE", progress: 0.5)]),
            ])
        case .demo:
            return SnapshotScenario(id: id, kind: .demo, shots: [SnapshotShot("demo", [])])
        case .selftest:
            return SnapshotScenario(id: id, kind: .selftest, shots: [])
        }
    }
}

/// What the steps run so far left on screen, as the harness understands them: whether the scene is shown (and
/// its reference worth writing), and at which zoom. The scene starts shown at the overview (6(q)).
struct SnapshotViewState: Sendable {
    var listView = false
    var board: SnapshotBoardMode = .side
    var zoom: SceneZoom = .overview

    mutating func apply(_ step: SnapshotStep) {
        switch step {
        case .listView(let on): listView = on
        case .board(let mode): board = mode
        case .zoom(let zoom): self.zoom = zoom
        // "Tout voir" on the simulated world: the overview (6(q)).
        case .fitAll: zoom = .overview
        default: break
        }
    }

    /// The scene is on screen: not the list, not under the full-screen board.
    var showsScene: Bool { !listView && board != .full }
}
