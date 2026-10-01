import CoreGraphics
import Foundation
import PixelCore

// How features plug into a shot of the snapshot harness (step 3, décision 14). The harness defines the whole
// vocabulary of steps up front; each feature registers the hook of its step in its own files, when it is created and
// only when the harness is active (`SnapshotHooks.shared.isEnabled`). A step without a hook is reported as
// "non prise en charge" and the shot is taken anyway: no later task needs to change the harness files.
//
// Who registers what (contract of the step 3 plan, task 1):
// | Kind                                                        | Task | Harness fallback without a hook           |
// | listView, zoom, fitAll, focus, cameraNudge, registerScene   | 7    | none                                      |
// | agentWindow                                                 | 8    | none                                      |
// | hover                                                       | 9    | none                                      |
// | arrival, islandDrop                                         | 11   | none                                      |
// | dragHover, board                                            | 12   | board(.hidden / .side): `boardPanelVisible` |
// | select                                                      | harness | `model.select(agent:)`                 |

/// Where the post-its board stands: hidden, beside the scene (6(k)), or full screen (6(c)).
enum SnapshotBoardMode: String, Sendable {
    case hidden, side, full
}

/// What the pointer rests on. Agents and projects are named as in `Showcase.appWorkspace()`.
enum SnapshotHover: Hashable, Sendable {
    case agent(String)
    case freeDesk(project: String, deskIndex: Int)
    case none
}

/// Where a dragged post-it is held (table of drop targets, 3.9).
enum SnapshotDropSpot: Hashable, Sendable {
    case agent(String)
    case island(String)
    case freeDesk(project: String, deskIndex: Int)
    case edgeArrow(agent: String)
    case trayRow(agent: String)
    case minimap(agent: String)
}

/// One step of a shot. Names are the agents, projects and post-it titles of `Showcase.appWorkspace()`.
enum SnapshotStep: Hashable, Sendable {
    /// true: the list view (⌘L); false: the scene.
    case listView(Bool)
    case board(SnapshotBoardMode)
    /// One of the zooms at rest; the camera keeps its centre.
    case zoom(SceneZoom)
    /// ⌘0, "Tout voir".
    case fitAll
    case focusIsland(String)
    case focusAgent(String)
    /// The hall: the elevator and the cork wall.
    case focusHall
    /// Moves the camera by (dx, dy) texels from where it is (scene axes: x to the right, y up), without snapping
    /// the request: the scene must snap it to the physical pixels itself (7.3, rule 2).
    case cameraNudge(dx: Double, dy: Double)
    /// nil deselects.
    case select(String?)
    case hover(SnapshotHover)
    case openAgentWindow(String)
    /// A post-it (title) dragged and held over a spot, the drop not done.
    case dragHover(card: String, over: SnapshotDropSpot)
    /// An agent arriving by the elevator, frozen at `progress` (0…1) of its walk.
    case arrival(agent: String, progress: Double)
    /// The furniture of a new island falling, frozen at `progress` (0…1).
    case islandDrop(project: String, progress: Double)

    enum Kind: String, CaseIterable, Sendable {
        case listView, board, zoom, fitAll, focus, cameraNudge, select, hover, agentWindow, dragHover, arrival, islandDrop

        /// The task that registers this hook (contract above), as the report names it.
        var contractOwner: String {
            switch self {
            case .listView, .zoom, .fitAll, .focus, .cameraNudge: return "tâche 7"
            case .agentWindow: return "tâche 8"
            case .hover: return "tâche 9"
            case .arrival, .islandDrop: return "tâche 11"
            case .dragHover, .board: return "tâche 12"
            case .select: return "banc"
            }
        }
    }

    var kind: Kind {
        switch self {
        case .listView: return .listView
        case .board: return .board
        case .zoom: return .zoom
        case .fitAll: return .fitAll
        case .focusIsland, .focusAgent, .focusHall: return .focus
        case .cameraNudge: return .cameraNudge
        case .select: return .select
        case .hover: return .hover
        case .openAgentWindow: return .agentWindow
        case .dragHover: return .dragHover
        case .arrival: return .arrival
        case .islandDrop: return .islandDrop
        }
    }
}

extension SnapshotStep: CustomStringConvertible {
    /// As written in the scenarios: `zoom(.x2)`, `focusAgent("Nova")`, `dragHover("Pagination /users", .agent("Bip"))`.
    var description: String {
        switch self {
        case .listView(let on): return "listView(\(on))"
        case .board(let mode): return "board(.\(mode.rawValue))"
        case .zoom(let zoom): return "zoom(.\(zoom.snapshotName))"
        case .fitAll: return "fitAll"
        case .focusIsland(let project): return "focusIsland(\"\(project)\")"
        case .focusAgent(let agent): return "focusAgent(\"\(agent)\")"
        case .focusHall: return "focusHall"
        case .cameraNudge(let dx, let dy): return "cameraNudge(\(Self.number(dx)), \(Self.number(dy)))"
        case .select(let agent): return agent.map { "select(\"\($0)\")" } ?? "select(nil)"
        case .hover(let hover): return "hover(\(hover))"
        case .openAgentWindow(let agent): return "openAgentWindow(\"\(agent)\")"
        case .dragHover(let card, let spot): return "dragHover(\"\(card)\", \(spot))"
        case .arrival(let agent, let progress): return "arrival(\"\(agent)\", \(Self.number(progress)))"
        case .islandDrop(let project, let progress): return "islandDrop(\"\(project)\", \(Self.number(progress)))"
        }
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

extension SnapshotHover: CustomStringConvertible {
    var description: String {
        switch self {
        case .agent(let name): return ".agent(\"\(name)\")"
        case .freeDesk(let project, let desk): return ".freeDesk(\"\(project)\", \(desk))"
        case .none: return ".none"
        }
    }
}

extension SnapshotDropSpot: CustomStringConvertible {
    var description: String {
        switch self {
        case .agent(let name): return ".agent(\"\(name)\")"
        case .island(let project): return ".island(\"\(project)\")"
        case .freeDesk(let project, let desk): return ".freeDesk(\"\(project)\", \(desk))"
        case .edgeArrow(let agent): return ".edgeArrow(\"\(agent)\")"
        case .trayRow(let agent): return ".trayRow(\"\(agent)\")"
        case .minimap(let agent): return ".minimap(\"\(agent)\")"
        }
    }
}

extension SceneZoom {
    /// "overview", "x1", "x2", "x3", as the steps are written in the report.
    var snapshotName: String {
        switch self {
        case .overview: return "overview"
        case .x1: return "x1"
        case .x2: return "x2"
        case .x3: return "x3"
        }
    }
}

/// What the scene shows, for the window shot and the comparison with the software reference.
struct SceneCapture {
    /// The SKView's drawing, HUD hidden, one pixel per physical pixel. Read without colour conversion: its values
    /// must be the reference's (sRGB) values.
    var image: CGImage
    /// What the scene was planned from.
    var input: SceneInput
    var overview: Bool
    /// Texels of the reference canvas (whole world, `SceneCompositor.render` without crop) the image covers.
    var visibleCanvasRect: PixelRect
    /// 1 (overview on Retina), 2, 4 or 6 on Retina.
    var pixelsPerTexel: Int
    /// nodes, atlasPages, dynamicPages, composedTextures, backgroundTiles.
    var stats: [String: Int]
}

/// The scene (task 7) as the harness sees it.
@MainActor
protocol SceneCaptureProviding: AnyObject {
    func captureScene() async -> SceneCapture?
    /// Shows `image` in place of the Metal drawing while the runner draws the window (cacheDisplay cannot read it),
    /// under the SwiftUI overlays; returns the undo.
    func showStill(_ image: CGImage) -> @MainActor () -> Void
}

/// The registry of the harness hooks. Empty and disabled in a normal launch.
@MainActor
final class SnapshotHooks {
    typealias Handler = @MainActor (SnapshotStep) async -> Bool

    static let shared = SnapshotHooks()

    /// Set by the harness before any window or feature is created.
    private(set) var isEnabled = false
    private var handlers: [SnapshotStep.Kind: (owner: String, handler: Handler)] = [:]
    private weak var provider: (any SceneCaptureProviding)?

    private init() {}

    func enable() {
        isEnabled = true
    }

    /// Features register in their own files when they are created, only when `isEnabled` (owner: "tâche 7"…). The
    /// handler performs the step and returns false when it could not (unknown name…). A second registration of the
    /// same kind replaces the first (a feature created again).
    func register(_ kind: SnapshotStep.Kind, owner: String, _ handler: @escaping Handler) {
        guard isEnabled else { return }
        handlers[kind] = (owner, handler)
    }

    /// Held weakly.
    func registerScene(_ provider: any SceneCaptureProviding) {
        guard isEnabled else { return }
        self.provider = provider
    }

    func handler(for kind: SnapshotStep.Kind) -> Handler? {
        handlers[kind]?.handler
    }

    /// Who registered the hook of `kind`, nil without a hook.
    func owner(of kind: SnapshotStep.Kind) -> String? {
        handlers[kind]?.owner
    }

    var sceneProvider: (any SceneCaptureProviding)? {
        provider
    }
}
