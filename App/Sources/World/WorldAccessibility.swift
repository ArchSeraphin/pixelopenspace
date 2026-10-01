import AppKit
import Foundation
import PixelCore

/// The open space for VoiceOver (7.9). The scene is a SpriteKit view, without SwiftUI's accessibility children: the
/// `WorldView` gets, by `setAccessibilityChildren`, the scene's group ("Open space, 20 agents. Vue Liste : ⌘L": the
/// list view stays the main path) with one element per island ("Îlot API, 5 agents dont 1 en attente"), each holding
/// one button per agent (its label from `AgentPresenter.accessibilityLabel`; "appuyer" opens the agent's window; the
/// focus flies the camera to it), and the custom rotor "Agents en attente" (tray order).
///
/// Frames are worked out when VoiceOver asks for them, from the camera and the plan, again at most every
/// `refreshInterval` seconds (nothing is computed while nobody asks); an agent out of view takes the frame of its
/// edge arrow, or a spot on the view's edge toward it. Labels are read from the model when asked.
@MainActor
final class WorldAccessibility: NSObject {
    /// At most 5 recomputations of the frames per second.
    static let refreshInterval: TimeInterval = 0.2
    /// Side, in points, of the frame given to an agent or an island out of view (an edge arrow's size).
    static let edgeSpotSize: CGFloat = 32

    private weak var hud: WorldHUD?
    private weak var model: AppModel?
    private weak var workbench: WorkbenchState?
    private weak var stage: WorldStage?
    private weak var view: WorldView?

    private var islandElements: [ProjectID: WorldIslandElement] = [:]
    private var agentElements: [AgentID: WorldAgentElement] = [:]
    /// The projects and their agents the elements were built for, in order.
    private var structure: [Structure] = []
    private lazy var waitingRotor = NSAccessibilityCustomRotor(label: "Agents en attente", itemSearchDelegate: self)
    /// The open space as a group, the only child of the view: SpriteKit's view keeps "SKView" as its own label and
    /// stays in the tree whatever it is told (`setAccessibilityLabel`, `setAccessibilityElement(false)`: tried on
    /// macOS 26), so this group carries the scene's label, its rotor and its islands.
    private lazy var sceneElement = WorldSceneElement(owner: self)

    private struct Structure: Equatable {
        var projectID: ProjectID
        var agents: [AgentID]
    }

    /// Frames in the view's points (origin bottom-left), and when they were worked out.
    private var agentFrames: [AgentID: NSRect] = [:]
    private var islandFrames: [ProjectID: NSRect] = [:]
    private var framesTime: TimeInterval = -.infinity

    func configure(hud: WorldHUD, model: AppModel, workbench: WorkbenchState) {
        self.hud = hud
        self.model = model
        self.workbench = workbench
    }

    /// The stage's view gets the scene element, its rotor and its islands; the elements follow the workspace (built
    /// again only when its projects or agents change, so that VoiceOver keeps its place).
    func update(stage: WorldStage) {
        self.stage = stage
        guard let model, let view = stage.view else { return }
        if view !== self.view {
            self.view = view
            structure = []
            sceneElement.setAccessibilityParent(view)
            sceneElement.setAccessibilityCustomRotors([waitingRotor])
            view.setAccessibilityCustomRotors([waitingRotor])
            view.setAccessibilityChildren([sceneElement])
        }
        let current = model.projects.map { Structure(projectID: $0.id, agents: model.agents(in: $0.id).map(\.id)) }
        guard current != structure else { return }
        structure = current
        rebuild()
    }

    private func rebuild() {
        var islands: [WorldIslandElement] = []
        var keptIslands: [ProjectID: WorldIslandElement] = [:]
        var keptAgents: [AgentID: WorldAgentElement] = [:]
        for entry in structure {
            let island = islandElements[entry.projectID] ?? WorldIslandElement(projectID: entry.projectID, owner: self)
            island.setAccessibilityParent(sceneElement)
            var children: [WorldAgentElement] = []
            for agentID in entry.agents {
                let element = agentElements[agentID] ?? WorldAgentElement(agentID: agentID, owner: self)
                element.setAccessibilityParent(island)
                children.append(element)
                keptAgents[agentID] = element
            }
            island.setAccessibilityChildren(children)
            islands.append(island)
            keptIslands[entry.projectID] = island
        }
        islandElements = keptIslands
        agentElements = keptAgents
        framesTime = -.infinity
        sceneElement.setAccessibilityChildren(islands)
    }

    // MARK: Scene

    /// "Open space, 20 agents. Vue Liste : ⌘L" (VoiceOver reads it from the model when it lands on the scene).
    var viewLabel: String {
        Self.viewLabel(agentCount: model?.agentsInOrder.count ?? 0)
    }

    /// The whole view, on screen.
    func screenFrameOfView() -> NSRect {
        guard let view, view.window != nil else { return .zero }
        return NSAccessibility.screenRect(fromView: view, rect: view.bounds)
    }

    // MARK: Labels

    /// "Open space, 20 agents. Vue Liste : ⌘L".
    static func viewLabel(agentCount: Int) -> String {
        "Open space, \(agentCount) \(agentCount > 1 ? "agents" : "agent"). Vue Liste : ⌘L"
    }

    /// "Îlot API, 5 agents dont 1 en attente", "Îlot DOCS, 1 agent", "Îlot SITE, aucun agent".
    static func islandLabel(name: String, agentCount: Int, waitingCount: Int) -> String {
        var label = "Îlot \(name), "
        switch agentCount {
        case 0: label += "aucun agent"
        case 1: label += "1 agent"
        default: label += "\(agentCount) agents"
        }
        if waitingCount > 0 { label += " dont \(waitingCount) en attente" }
        return label
    }

    func label(ofIsland projectID: ProjectID) -> String? {
        guard let model, let project = model.project(projectID) else { return nil }
        let agents = model.agents(in: projectID)
        let waiting = agents.filter { model.runtime(for: $0.id)?.kind == .waitingInput }.count
        return Self.islandLabel(name: project.name, agentCount: agents.count, waitingCount: waiting)
    }

    func label(ofAgent agentID: AgentID) -> String? {
        model?.accessibilityLabel(for: agentID) ?? model?.agent(agentID)?.name
    }

    // MARK: Actions

    /// "Appuyer": the agent's window (as a click on the agent).
    func press(_ agentID: AgentID) -> Bool {
        guard let model, let workbench, model.agent(agentID) != nil else { return false }
        model.select(agent: agentID)
        AgentWindowController.shared.show(agentID, model: model, workbench: workbench)
        return true
    }

    /// VoiceOver's focus on an agent: the camera flies there (the selection stays as it is).
    func focus(_ agentID: AgentID) {
        guard let stage else { return }
        stage.camera.fly(to: .agent(agentID))
        stage.view?.noteInteraction()
    }

    // MARK: Frames

    func screenFrame(ofAgent agentID: AgentID) -> NSRect {
        refreshFramesIfStale()
        return screenRect(agentFrames[agentID])
    }

    func screenFrame(ofIsland projectID: ProjectID) -> NSRect {
        refreshFramesIfStale()
        return screenRect(islandFrames[projectID])
    }

    private func screenRect(_ rect: NSRect?) -> NSRect {
        guard let rect, let view, view.window != nil else { return .zero }
        return NSAccessibility.screenRect(fromView: view, rect: rect)
    }

    private func refreshFramesIfStale() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - framesTime >= Self.refreshInterval else { return }
        framesTime = now
        computeFrames()
    }

    /// Each agent: the box of the plan's nodes a click on it hits, on screen, cut to the view; out of view, its edge
    /// arrow, or a spot on the edge toward its seat. Each island: the box of its rugs, likewise.
    private func computeFrames() {
        agentFrames = [:]
        islandFrames = [:]
        guard let stage, let plan = stage.plan, let model, let hud, stage.camera.isPlaced else { return }
        let camera = stage.camera
        let bounds = NSRect(x: 0, y: 0, width: camera.view.width, height: camera.view.height)
        var boxes: [AgentID: SceneBox] = [:]
        for node in plan.nodes {
            guard case .agent(let id)? = node.target else { continue }
            let minX = Double(node.position.x - node.anchor.x), maxY = Double(node.position.y + node.anchor.y)
            let box = SceneBox(minX: minX, minY: maxY - Double(node.height), maxX: minX + Double(node.width), maxY: maxY)
            boxes[id] = boxes[id].map { Self.union($0, box) } ?? box
        }
        var arrows: [AgentID: EdgeArrow] = [:]
        for arrow in hud.edgeArrows(model: model) { arrows[arrow.id] = arrow }
        for (agentID, seat) in plan.agentSeats {
            let point = SceneVector(Double(seat.x), Double(seat.y))
            let box = boxes[agentID] ?? SceneBox(minX: point.x - 16, minY: point.y - 8, maxX: point.x + 16, maxY: point.y + 48)
            let visible = viewRect(of: box, camera: camera).intersection(bounds)
            if visible.width >= 1, visible.height >= 1 {
                agentFrames[agentID] = visible
            } else if let arrow = arrows[agentID] {
                agentFrames[agentID] = Self.spot(at: CGPoint(x: arrow.position.x, y: arrow.position.y))
            } else {
                agentFrames[agentID] = edgeSpot(toward: point, camera: camera, bounds: bounds)
            }
        }
        var rugs: [ProjectID: SceneBox] = [:]
        for island in plan.islands {
            let box = Self.sceneBox(of: island.rug)
            rugs[island.projectID] = rugs[island.projectID].map { Self.union($0, box) } ?? box
        }
        for (projectID, box) in rugs {
            let visible = viewRect(of: box, camera: camera).intersection(bounds)
            islandFrames[projectID] = visible.width >= 1 && visible.height >= 1
                ? visible : edgeSpot(toward: box.center, camera: camera, bounds: bounds)
        }
    }

    private func viewRect(of box: SceneBox, camera: WorldCamera) -> NSRect {
        let a = camera.viewPoint(of: SceneVector(box.minX, box.minY))
        let b = camera.viewPoint(of: SceneVector(box.maxX, box.maxY))
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// A spot of `edgeSpotSize` on the view's edge, toward a scene point out of view.
    private func edgeSpot(toward point: SceneVector, camera: WorldCamera, bounds: NSRect) -> NSRect {
        let p = camera.viewPoint(of: point)
        let half = Double(Self.edgeSpotSize / 2)
        let x = min(max(p.x, bounds.minX + half), max(bounds.maxX - half, bounds.minX + half))
        let y = min(max(p.y, bounds.minY + half), max(bounds.maxY - half, bounds.minY + half))
        return Self.spot(at: CGPoint(x: x, y: y))
    }

    private static func spot(at center: CGPoint) -> NSRect {
        NSRect(x: center.x - edgeSpotSize / 2, y: center.y - edgeSpotSize / 2, width: edgeSpotSize,
               height: edgeSpotSize)
    }

    /// The box of a rect of tiles' diamond, in scene texels (décision 16).
    private static func sceneBox(of rect: GridRect) -> SceneBox {
        let corners = [rect.origin, GridPoint(rect.end.i, rect.origin.j), rect.end, GridPoint(rect.origin.i, rect.end.j)]
            .map(IsoMath.toScene)
        return SceneBox(minX: Double(corners.map(\.x).min() ?? 0), minY: Double(corners.map(\.y).min() ?? 0),
                        maxX: Double(corners.map(\.x).max() ?? 0), maxY: Double(corners.map(\.y).max() ?? 0))
    }

    private static func union(_ a: SceneBox, _ b: SceneBox) -> SceneBox {
        SceneBox(minX: min(a.minX, b.minX), minY: min(a.minY, b.minY), maxX: max(a.maxX, b.maxX),
                 maxY: max(a.maxY, b.maxY))
    }
}

// MARK: - Rotor "Agents en attente"

extension WorldAccessibility: @preconcurrency NSAccessibilityCustomRotorItemSearchDelegate {
    /// The waiting agents in the tray's order (oldest wait first); the camera flies to the one found.
    func rotor(_ rotor: NSAccessibilityCustomRotor,
               resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters)
        -> NSAccessibilityCustomRotor.ItemResult? {
        guard let model else { return nil }
        let ids = model.liveStatusSummary.waiting.map(\.agentID).filter { agentElements[$0] != nil }
        guard !ids.isEmpty else { return nil }
        let forward = searchParameters.searchDirection == .next
        let current = (searchParameters.currentItem?.targetElement as? WorldAgentElement)?.agentID
        let index: Int
        if let current, let position = ids.firstIndex(of: current) {
            index = forward ? position + 1 : position - 1
            guard ids.indices.contains(index) else { return nil }
        } else {
            index = forward ? 0 : ids.count - 1
        }
        guard let element = agentElements[ids[index]] else { return nil }
        focus(ids[index])
        return NSAccessibilityCustomRotor.ItemResult(targetElement: element)
    }
}

// MARK: - Elements

/// The open space for VoiceOver: "Open space, 20 agents. Vue Liste : ⌘L", over the whole view, a group of islands.
final class WorldSceneElement: NSAccessibilityElement, NSAccessibilityGroup {
    private weak var owner: WorldAccessibility?

    init(owner: WorldAccessibility) {
        self.owner = owner
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func isAccessibilityElement() -> Bool { true }

    /// Not optional: `NSAccessibilityElementProtocol` asks for a string.
    override func accessibilityIdentifier() -> String { "world-scene" }

    // AppKit asks on the main thread. Only the owner (main actor, so Sendable) goes into the closures.

    override func accessibilityLabel() -> String? {
        let owner = owner
        return MainActor.assumeIsolated { owner?.viewLabel }
    }

    override func accessibilityFrame() -> NSRect {
        let owner = owner
        return MainActor.assumeIsolated { owner?.screenFrameOfView() ?? .zero }
    }
}

/// An island of the open space for VoiceOver: a group of its agents.
final class WorldIslandElement: NSAccessibilityElement, NSAccessibilityGroup {
    let projectID: ProjectID
    private weak var owner: WorldAccessibility?

    init(projectID: ProjectID, owner: WorldAccessibility) {
        self.projectID = projectID
        self.owner = owner
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func isAccessibilityElement() -> Bool { true }

    /// Not optional: `NSAccessibilityElementProtocol` asks for a string.
    override func accessibilityIdentifier() -> String { "world-island-\(projectID)" }

    // AppKit asks on the main thread. Only the owner (main actor, so Sendable) and the id go into the closures.

    override func accessibilityLabel() -> String? {
        let owner = owner, id = projectID
        return MainActor.assumeIsolated { owner?.label(ofIsland: id) }
    }

    override func accessibilityFrame() -> NSRect {
        let owner = owner, id = projectID
        return MainActor.assumeIsolated { owner?.screenFrame(ofIsland: id) ?? .zero }
    }
}

/// An agent of the open space for VoiceOver: a button that opens its window.
final class WorldAgentElement: NSAccessibilityElement, NSAccessibilityButton {
    let agentID: AgentID
    private weak var owner: WorldAccessibility?

    init(agentID: AgentID, owner: WorldAccessibility) {
        self.agentID = agentID
        self.owner = owner
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func isAccessibilityElement() -> Bool { true }

    /// Not optional: `NSAccessibilityElementProtocol` asks for a string.
    override func accessibilityIdentifier() -> String { "world-agent-\(agentID)" }

    // AppKit asks on the main thread. Only the owner (main actor, so Sendable) and the id go into the closures.

    override func accessibilityLabel() -> String? {
        let owner = owner, id = agentID
        return MainActor.assumeIsolated { owner?.label(ofAgent: id) }
    }

    override func accessibilityHelp() -> String? {
        "Ouvre la fenêtre de l'agent"
    }

    override func accessibilityFrame() -> NSRect {
        let owner = owner, id = agentID
        return MainActor.assumeIsolated { owner?.screenFrame(ofAgent: id) ?? .zero }
    }

    override func accessibilityPerformPress() -> Bool {
        let owner = owner, id = agentID
        return MainActor.assumeIsolated { owner?.press(id) ?? false }
    }

    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        super.setAccessibilityFocused(accessibilityFocused)
        guard accessibilityFocused else { return }
        let owner = owner, id = agentID
        MainActor.assumeIsolated { owner?.focus(id) }
    }
}
