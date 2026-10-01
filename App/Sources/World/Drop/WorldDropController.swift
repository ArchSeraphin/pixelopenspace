import AppKit
import Foundation
import Observation
import PixelCore
import SwiftUI
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// A post-it of the board being dragged (`UTType.pixelTaskCard`, the same data as `CardDragPayload`).
    static let pixelTaskCard = NSPasteboard.PasteboardType(UTType.pixelTaskCard.identifier)
}

/// A post-it of the board dragged onto the open space (3.9, "Glisser-déposer", 6(k), décision 9). The scene's
/// `WorldView` is the AppKit destination: it registers the post-it's type and hands every step of the drag here.
///
/// - Hover: the target under the pointer (`SceneHitTester`) and the core's decision (`DropResolver.decide`): the
///   plan marks it (`WorldInteractionState.dropTarget`: the ring `floor.dropTarget` under an agent or a free desk,
///   the rug of an island), a bubble near the pointer says what a drop does (`DropFeedbackView`, out of the HUD's
///   controls), the operation is a copy or none.
/// - Near an edge of the scene the camera glides toward it (`AutoScroll`), at every frame while the drag lasts.
/// - Drop: the decision's action (`DropIntents`), then the post-it flies to the desk (`PostitFlight`).
/// - The edge arrows and the minimap are drawn over the scene: held over one of them, the post-it is the control's
///   (`DropHUDController`, as when SwiftUI gives it the drag), never the scene's below.
///
/// The card: for a drag of this app, the one the board announced (`WorkbenchState.draggedCard`: SwiftUI may only
/// give its pasteboard data once dropped); otherwise (another copy of the app), the drag's pasteboard. Registers the
/// `dragHover` step of the snapshot harness (décision 14).
@MainActor
final class WorldDropController {
    static let snapshotOwner = "tâche 12"
    /// Points kept between a target the harness holds a post-it over and the edges of the view: closer, the camera
    /// centres it first, as a real drag would have scrolled.
    static let snapshotMargin: CGFloat = 48

    private weak var view: WorldView?
    private let stage: WorldStage
    private let model: AppModel
    private weak var workbench: WorkbenchState?
    private let feedback = DropFeedbackView()
    private let flight: PostitFlight

    /// The plan the tester was built from: it keeps the character frames it composed, one tester per plan.
    private var tester: (plan: WorldScenePlan, hitTester: SceneHitTester)?
    /// The drag inside the view.
    private var session: Session?
    private var scrollTimer: Timer?
    private var lastScroll: TimeInterval?
    /// Snapshots: the hover posed last (a newer one, or its end, makes the older watchers stale), and the watcher of
    /// the preferences the harness writes when a scenario starts. Static: the hover outlives this view (⌘L, the
    /// full-screen board).
    private static var snapshotGeneration = 0
    private static var snapshotDefaultsObserver: NSObjectProtocol?

    private struct Session {
        var card: TaskCardID?
        /// The pointer, in the view's points (origin bottom-left).
        var point: CGPoint
        var decision: DropDecision
        /// The edge arrow or minimap dot under the pointer.
        var control: DropHUDSpot?
    }

    init(view: WorldView, stage: WorldStage, model: AppModel, workbench: WorkbenchState) {
        self.view = view
        self.stage = stage
        self.model = model
        self.workbench = workbench
        flight = PostitFlight(stage: stage)
        feedback.install(in: view)
        registerSnapshotHook()
    }

    // MARK: AppKit destination

    func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        session = Session(card: cardID(from: info, readingPasteboard: false), point: viewPoint(of: info),
                          decision: .nothing)
        return update()
    }

    func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        if session == nil {
            session = Session(card: nil, point: .zero, decision: .nothing)
        }
        if session?.card == nil { session?.card = cardID(from: info, readingPasteboard: false) }
        session?.point = viewPoint(of: info)
        return update()
    }

    func draggingExited() {
        endSession()
    }

    /// The drop: the decision where the post-it is let go, done; the post-it flies to its desk.
    func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        let point = viewPoint(of: info)
        defer { endSession() }
        guard let workbench, let cardID = cardID(from: info, readingPasteboard: true),
              let card = model.board.card(cardID) else { return false }
        let control = self.control(at: point)
        if control.over {
            // Let go over an edge arrow or a minimap dot: the post-it goes to its agent, as on the agent itself.
            guard let spot = control.spot else { return false }
            let decision = DropResolver.decide(card: card, over: .agent(spot.agentID), context: dropContext)
            guard decision.accepted else { return false }
            DropIntents.perform(decision.action, model: model, workbench: workbench)
            workbench.endCardDrag()
            return true
        }
        let decision = DropResolver.decide(card: card, over: target(at: point), context: dropContext)
        guard decision.accepted else { return false }
        let outcome = DropIntents.perform(decision.action, model: model, workbench: workbench)
        if let outcome, stage.camera.isPlaced {
            flight.fly(from: stage.camera.scenePoint(atView: SceneVector(Double(point.x), Double(point.y))),
                       to: outcome)
        }
        workbench.endCardDrag()
        return true
    }

    /// The drag ended (dropped anywhere, cancelled) or the view left its window.
    func draggingEnded() {
        endSession()
    }

    func viewLeftWindow() {
        endSession()
        flight.cancelAll()
    }

    // MARK: Hover

    /// The decision at the session's point: the scene's mark, the bubble, the operation; the automatic scrolling.
    private func update() -> NSDragOperation {
        guard var session, let workbench else { return [] }
        let control = self.control(at: session.point)
        if let old = session.control, old != control.spot {
            DropHUDController.shared.leave(owns: { $0 == old }, workbench: workbench)
        }
        session.control = control.spot
        if control.over {
            // No scene under the control: no mark of the scene's own, no bubble, no glide (an arrow sits at the edge).
            if let highlight = session.decision.highlight, stage.interaction.dropTarget == highlight {
                stage.interaction.dropTarget = nil
            }
            session.decision = .nothing
            self.session = session
            feedback.hide()
            stopScrolling()
            view?.noteInteraction()
            guard let spot = control.spot else { return [] }
            let proposal = DropHUDController.shared.hover(spot, owns: { $0 == spot }, model: model, workbench: workbench)
            return proposal.operation == .copy ? .copy : []
        }
        let card = session.card.flatMap { model.board.card($0) }
        let decision = card.map { DropResolver.decide(card: $0, over: target(at: session.point), context: dropContext) }
            ?? .nothing
        session.decision = decision
        self.session = session
        show(decision, at: session.point)
        updateScrolling()
        view?.noteInteraction()
        return decision.accepted ? .copy : []
    }

    private func show(_ decision: DropDecision, at point: CGPoint) {
        if stage.interaction.dropTarget != decision.highlight { stage.interaction.dropTarget = decision.highlight }
        if decision.feedback.isEmpty {
            feedback.hide()
        } else {
            // Out of the minimap and the edge arrows, drawn over the scene's view.
            feedback.show(decision.feedback, accepted: decision.accepted, near: point,
                          avoiding: DropBubbleLayout.hudFrames(stage: stage, model: model))
        }
    }

    /// No drag in the view: no mark (unless another control put its own), no bubble, no scrolling.
    private func endSession() {
        if let highlight = session?.decision.highlight, stage.interaction.dropTarget == highlight {
            stage.interaction.dropTarget = nil
        }
        if let control = session?.control, let workbench {
            DropHUDController.shared.leave(owns: { $0 == control }, workbench: workbench)
        }
        session = nil
        feedback.hide()
        stopScrolling()
    }

    // MARK: Automatic scrolling (3.9)

    private func updateScrolling() {
        guard let session, velocity(at: session.point) != SceneVector(0, 0) else { return stopScrolling() }
        guard scrollTimer == nil else { return }
        lastScroll = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / Double(WorldView.interactionFPS), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollStep() }
        }
        // Common modes: the drag tracks the mouse in its own run-loop mode.
        RunLoop.main.add(timer, forMode: .common)
        scrollTimer = timer
    }

    /// One frame of the glide: the camera moves by the velocity times the frame's duration, then the target under
    /// the pointer (which did not move) is looked for again.
    private func scrollStep() {
        guard let session else { return stopScrolling() }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(max(now - (lastScroll ?? now), 0), 0.1)
        lastScroll = now
        let speed = velocity(at: session.point)
        guard speed != SceneVector(0, 0) else { return stopScrolling() }
        stage.camera.pan(byViewPoints: SceneVector(speed.x * elapsed, speed.y * elapsed))
        _ = update()
    }

    private func velocity(at point: CGPoint) -> SceneVector {
        guard stage.camera.isPlaced else { return SceneVector(0, 0) }
        return AutoScroll.velocity(pointer: SceneVector(Double(point.x), Double(point.y)), view: stage.camera.view)
    }

    private func stopScrolling() {
        scrollTimer?.invalidate()
        scrollTimer = nil
        lastScroll = nil
    }

    // MARK: Helpers

    private var dropContext: DropContext {
        DropContext(workspace: model.workspace, runtimes: model.runtimes, board: model.board, home: NSHomeDirectory())
    }

    /// The dragged card: the board's (a drag of this app), else the pasteboard's when `readingPasteboard` (a drop,
    /// or another copy of the app) and only for a card of this board.
    private func cardID(from info: NSDraggingInfo, readingPasteboard: Bool) -> TaskCardID? {
        if info.draggingSource != nil, let card = workbench?.draggedCard { return card }
        guard readingPasteboard || info.draggingSource == nil else { return workbench?.draggedCard }
        if let data = info.draggingPasteboard.data(forType: .pixelTaskCard),
           let text = String(data: data, encoding: .utf8),
           let id = TaskCardID(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           model.board.card(id) != nil {
            return id
        }
        return workbench?.draggedCard
    }

    /// The edge arrow or the minimap under a view point (origin bottom-left): `over` when the point is on one of them,
    /// and the agent it stands for (none between the minimap's dots).
    private func control(at point: CGPoint) -> (over: Bool, spot: DropHUDSpot?) {
        guard let view, stage.camera.isPlaced else { return (false, nil) }
        let topLeft = CGPoint(x: point.x, y: view.bounds.height - point.y)
        if let agent = EdgeArrowsView.agent(at: topLeft, arrows: WorldHUD.shared.edgeArrows(model: model), model: model,
                                            viewHeight: view.bounds.height) {
            return (true, .edgeArrow(agent))
        }
        let minimap = MinimapView.dropSpot(at: topLeft, stage: stage, model: model)
        return (minimap.overMap, minimap.agentID.map(DropHUDSpot.minimapDot))
    }

    /// The pointer in the view's points, origin at the bottom-left corner (the camera's view frame).
    private func viewPoint(of info: NSDraggingInfo) -> CGPoint {
        guard let view else { return .zero }
        let point = view.convert(info.draggingLocation, from: nil)
        return view.isFlipped ? CGPoint(x: point.x, y: view.bounds.height - point.y) : point
    }

    /// What is under a view point: the core's hit test on the plan the scene shows; nil outside the world or before
    /// the first plan.
    private func target(at point: CGPoint) -> SceneHitTarget? {
        guard let plan = stage.plan, stage.camera.isPlaced else { return nil }
        var hitTester = tester.flatMap { $0.plan == plan ? $0.hitTester : nil } ?? SceneHitTester(plan: plan)
        // Held once only while it composes frames into its cache (no copy of the cache).
        tester = nil
        let found = hitTester.target(at: stage.camera.scenePoint(atView: SceneVector(Double(point.x), Double(point.y))))
        tester = (plan, hitTester)
        return found
    }

    // MARK: Snapshot harness

    /// `dragHover(card, spot)`: the hover of a post-it held over a spot, without a drag session: the scene's mark and
    /// the bubble near the target, or the highlight of a row of the tray, an edge arrow or a dot of the minimap. It
    /// lasts until the harness changes the model or the view (the next scenario).
    private func registerSnapshotHook() {
        let hooks = SnapshotHooks.shared
        guard hooks.isEnabled else { return }
        hooks.register(.dragHover, owner: Self.snapshotOwner) { [weak self] step in
            guard let self, case .dragHover(let title, let spot) = step else { return false }
            return self.snapshotDragHover(title: title, over: spot)
        }
    }

    private func snapshotDragHover(title: String, over spot: SnapshotDropSpot) -> Bool {
        guard let view, view.window != nil, let workbench, stage.camera.isPlaced else { return false }
        stage.settle()
        Self.endSnapshotHover(stage: stage, workbench: workbench)
        guard let card = model.board.cards.first(where: { $0.title == title }) else { return false }
        let target: SceneHitTarget
        let hud: DropHUDSpot?
        switch spot {
        case .agent(let name):
            guard let id = stage.agentID(named: name, in: model) else { return false }
            (target, hud) = (.agent(id), nil)
        case .island(let name):
            guard let id = stage.projectID(named: name, in: model) else { return false }
            (target, hud) = (.islandFloor(id, part: 0), nil)
        case .freeDesk(let name, let deskIndex):
            guard let id = stage.projectID(named: name, in: model) else { return false }
            (target, hud) = (.freeDesk(id, deskIndex: deskIndex), nil)
        case .edgeArrow(let name):
            guard let id = stage.agentID(named: name, in: model),
                  WorldHUD.shared.edgeArrows(model: model).contains(where: { $0.id == id }) else { return false }
            (target, hud) = (.agent(id), .edgeArrow(id))
        case .trayRow(let name):
            guard let id = stage.agentID(named: name, in: model),
                  model.liveStatusSummary.waiting.contains(where: { $0.agentID == id }) else { return false }
            (target, hud) = (.agent(id), .trayRow(id))
        case .minimap(let name):
            guard let id = stage.agentID(named: name, in: model), stage.camera.needsMinimap else { return false }
            (target, hud) = (.agent(id), .minimapDot(id))
        }
        let decision = DropResolver.decide(card: card, over: target, context: dropContext)
        if let hud {
            // The control is highlighted with the decision's words; the scene marks the agent (seen once the
            // camera flies there).
            workbench.dropHUDHover = DropHUDHover(spot: hud, feedback: decision.feedback, accepted: decision.accepted)
            stage.interaction.dropTarget = decision.highlight
            stage.settle()
        } else {
            guard let point = snapshotPointer(on: target, in: view) else { return false }
            stage.interaction.dropTarget = decision.highlight
            stage.settle()
            show(decision, at: point)
        }
        Self.watchSnapshotHover(stage: stage, model: model, workbench: workbench)
        return true
    }

    /// Where the pointer rests on a target of the scene, in the view's points; the camera centres the target first
    /// when it is not well inside the view.
    private func snapshotPointer(on target: SceneHitTarget, in view: WorldView) -> CGPoint? {
        let inner = view.bounds.insetBy(dx: Self.snapshotMargin, dy: Self.snapshotMargin)
        func point() -> CGPoint? {
            if case .islandFloor(let project, let part) = target {
                guard let centre = stage.scenePoint(for: .island(project, part: part)) else { return nil }
                let p = stage.camera.viewPoint(of: centre)
                return CGPoint(x: p.x, y: p.y)
            }
            guard let rect = stage.viewRect(of: target) else { return nil }
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        guard let first = point() else { return nil }
        if inner.contains(first) { return first }
        let centre = stage.camera.scenePoint(atView: SceneVector(Double(first.x), Double(first.y)))
        stage.camera.center(on: .point(centre))
        stage.settle()
        return point()
    }

    /// The bubble of the current view goes, with the session it showed.
    func hideFeedback() {
        session = nil
        feedback.hide()
    }

    /// No posed hover: no highlight, no mark, no bubble.
    private static func endSnapshotHover(stage: WorldStage?, workbench: WorkbenchState?) {
        snapshotGeneration += 1
        if let observer = snapshotDefaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            snapshotDefaultsObserver = nil
        }
        if workbench?.dropHUDHover != nil { workbench?.dropHUDHover = nil }
        if stage?.interaction.dropTarget != nil { stage?.interaction.dropTarget = nil }
        stage?.view?.drop?.hideFeedback()
    }

    /// The posed hover ends when the harness moves on: the model, the view mode, the board, the camera change, or the
    /// preferences are written (a scenario starts).
    private static func watchSnapshotHover(stage: WorldStage, model: AppModel, workbench: WorkbenchState) {
        let mine = snapshotGeneration
        let camera = stage.camera
        withObservationTracking {
            _ = model.workspace
            _ = model.board
            _ = model.selectedAgentID
            _ = workbench.mainView
            _ = workbench.boardMode
            _ = camera.pose
        } onChange: { [weak stage, weak workbench] in
            Task { @MainActor [weak stage, weak workbench] in
                guard mine == snapshotGeneration else { return }
                endSnapshotHover(stage: stage, workbench: workbench)
            }
        }
        snapshotDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak stage, weak workbench] _ in
            MainActor.assumeIsolated {
                guard mine == snapshotGeneration else { return }
                endSnapshotHover(stage: stage, workbench: workbench)
            }
        }
    }
}

// MARK: - Drop actions

/// What a drop on the scene, a row of the waiting tray, an edge arrow or a dot of the minimap does (`DropAction`),
/// with the app's usual intents: the board's assignment (and its confirmation across projects, C3), a new agent
/// launched with the post-it as its first prompt.
@MainActor
enum DropIntents {
    /// Where the post-it went, for its flight: the agent and its desk; `isNew` for an agent created by the drop (it
    /// arrives by the elevator: no `grab`). Nil when nothing was done yet (the confirmation C3 is asked first) or
    /// nothing could be done.
    struct Outcome: Equatable {
        var agentID: AgentID
        var projectID: ProjectID
        var deskIndex: Int
        var hueIndex: Int
        var isNew: Bool
    }

    @discardableResult
    static func perform(_ action: DropAction, model: AppModel, workbench: WorkbenchState) -> Outcome? {
        switch action {
        case .assign(let cardID, let agentID):
            return assign(cardID, to: agentID, model: model, workbench: workbench)
        case .assignOffline(let cardID, let agentID):
            guard let outcome = assign(cardID, to: agentID, model: model, workbench: workbench) else { return nil }
            let name = model.agent(agentID)?.name ?? "L'agent"
            let title = model.board.card(cardID).map { CardPresentation.quoted($0.title) } ?? "Le post-it"
            model.showToast("\(name) est hors ligne : \(title) partira quand sa session sera relancée. "
                            + "Relance-la depuis sa fenêtre (Relancer la session).", agentID: agentID)
            return outcome
        case .launchNewAgent(let cardID, let projectID, let deskIndex):
            guard let agentID = model.launchNewAgent(with: cardID, in: projectID, deskIndex: deskIndex) else {
                return nil
            }
            return outcome(agentID, isNew: true, model: model)
        case .firstFreeAgent(let cardID, let projectID):
            if let agentID = model.firstFreeAgent(in: projectID) {
                return assign(cardID, to: agentID, model: model, workbench: workbench)
            }
            guard let agentID = model.launchNewAgent(with: cardID, in: projectID) else { return nil }
            return outcome(agentID, isNew: true, model: model)
        case .none:
            return nil
        }
    }

    /// The board's assignment (`WorkbenchState.requestTask`): at once, or after the confirmation across projects.
    private static func assign(_ cardID: TaskCardID, to agentID: AgentID, model: AppModel,
                               workbench: WorkbenchState) -> Outcome? {
        workbench.requestTask(.assign(cardID, to: agentID))
        guard workbench.pendingTask == nil, model.board.card(cardID)?.assignee == agentID else { return nil }
        return outcome(agentID, isNew: false, model: model)
    }

    private static func outcome(_ agentID: AgentID, isNew: Bool, model: AppModel) -> Outcome? {
        guard let agent = model.agent(agentID), let project = model.workspace.liveProject(agent.projectID) else {
            return nil
        }
        return Outcome(agentID: agentID, projectID: project.id, deskIndex: agent.deskIndex,
                       hueIndex: project.hueIndex, isNew: isNew)
    }
}

// MARK: - Small controls as drop targets

/// The drops on the small controls of the window that stand for an agent (3.9): a row of the waiting tray, an edge
/// arrow, a dot of the minimap. Held there, the post-it shows the agent's decision (the control highlighted, the
/// scene's mark under the agent); after `flyDelay` the camera flies to the agent while the drag goes on; let go
/// there, the post-it goes to that agent, as on the agent itself. One drag at a time: one instance.
@MainActor
final class DropHUDController {
    static let shared = DropHUDController()
    /// Seconds a post-it rests on a control before the camera flies to its agent.
    static let flyDelay: TimeInterval = 0.5

    private var flyTimer: Timer?
    private var timedSpot: DropHUDSpot?

    private init() {}

    /// The post-it is over `spot` (nil: over the control, but on none of its agents).
    func hover(_ spot: DropHUDSpot?, owns: (DropHUDSpot) -> Bool, model: AppModel,
               workbench: WorkbenchState) -> DropProposal {
        guard let spot else {
            leave(owns: owns, workbench: workbench)
            return DropProposal(operation: .cancel)
        }
        let agentID = spot.agentID
        var accepted = true
        var text = "Donner à \(model.agent(agentID)?.name ?? "cet agent")"
        var highlight: SceneHitTarget? = .agent(agentID)
        if let card = workbench.draggedCard.flatMap({ model.board.card($0) }) {
            let decision = DropResolver.decide(card: card, over: .agent(agentID), context: Self.context(model))
            (accepted, text, highlight) = (decision.accepted, decision.feedback, decision.highlight)
        }
        let hover = DropHUDHover(spot: spot, feedback: text, accepted: accepted)
        if workbench.dropHUDHover != hover { workbench.dropHUDHover = hover }
        if let stage = workbench.worldStage, stage.interaction.dropTarget != highlight {
            stage.interaction.dropTarget = highlight
        }
        armFlight(spot, model: model, workbench: workbench)
        return DropProposal(operation: accepted ? .copy : .forbidden)
    }

    /// The post-it left the control.
    func leave(owns: (DropHUDSpot) -> Bool, workbench: WorkbenchState) {
        guard let hover = workbench.dropHUDHover, owns(hover.spot) else { return }
        workbench.dropHUDHover = nil
        if let stage = workbench.worldStage, stage.interaction.dropTarget == .agent(hover.spot.agentID) {
            stage.interaction.dropTarget = nil
        }
        if timedSpot == hover.spot { cancelFlight() }
    }

    /// Let go over `spot`: the agent's decision, done.
    func drop(_ spot: DropHUDSpot, info: DropInfo, model: AppModel, workbench: WorkbenchState) -> Bool {
        let owns: (DropHUDSpot) -> Bool = { $0 == spot }
        defer { leave(owns: owns, workbench: workbench) }
        if let cardID = workbench.draggedCard {
            return perform(cardID, on: spot.agentID, model: model, workbench: workbench)
        }
        // A post-it of another copy of the app: its id comes with the drop.
        guard let provider = info.itemProviders(for: [.pixelTaskCard]).first else { return false }
        let agentID = spot.agentID
        _ = provider.loadTransferable(type: CardDragPayload.self) { result in
            guard case .success(let payload) = result else { return }
            Task { @MainActor in
                _ = DropHUDController.shared.perform(payload.cardID, on: agentID, model: model, workbench: workbench)
            }
        }
        return true
    }

    @discardableResult
    private func perform(_ cardID: TaskCardID, on agentID: AgentID, model: AppModel,
                         workbench: WorkbenchState) -> Bool {
        guard let card = model.board.card(cardID) else { return false }
        let decision = DropResolver.decide(card: card, over: .agent(agentID), context: Self.context(model))
        guard decision.accepted else {
            if !decision.feedback.isEmpty { model.showToast(decision.feedback, style: .warning) }
            return false
        }
        DropIntents.perform(decision.action, model: model, workbench: workbench)
        workbench.endCardDrag()
        return true
    }

    /// After `flyDelay` on the same spot, the camera flies to the agent (the open space on screen only); the drag
    /// goes on.
    private func armFlight(_ spot: DropHUDSpot, model: AppModel, workbench: WorkbenchState) {
        guard timedSpot != spot else { return }
        cancelFlight()
        timedSpot = spot
        let timer = Timer(timeInterval: Self.flyDelay, repeats: false) { [weak self, weak workbench] _ in
            MainActor.assumeIsolated {
                guard let self, let workbench, self.timedSpot == spot else { return }
                self.flyTimer = nil
                guard workbench.dropHUDHover?.spot == spot, workbench.mainView == .scene,
                      let stage = workbench.worldStage, stage.view?.window != nil else { return }
                // No selection: it would open the terminal panel under the drag.
                stage.camera.fly(to: .agent(spot.agentID))
                stage.view?.noteInteraction()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        flyTimer = timer
    }

    private func cancelFlight() {
        flyTimer?.invalidate()
        flyTimer = nil
        timedSpot = nil
    }

    private static func context(_ model: AppModel) -> DropContext {
        DropContext(workspace: model.workspace, runtimes: model.runtimes, board: model.board, home: NSHomeDirectory())
    }
}

/// The SwiftUI destination of a small control (`DropHUDController`): `spot` finds the agent under a location of the
/// control, `owns` tells the control's spots (a control only clears its own highlight).
struct HUDDropDelegate: DropDelegate {
    let model: AppModel
    let workbench: WorkbenchState
    let spot: (CGPoint) -> DropHUDSpot?
    let owns: (DropHUDSpot) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.pixelTaskCard])
    }

    func dropEntered(info: DropInfo) {
        _ = DropHUDController.shared.hover(spot(info.location), owns: owns, model: model, workbench: workbench)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropHUDController.shared.hover(spot(info.location), owns: owns, model: model, workbench: workbench)
    }

    func dropExited(info: DropInfo) {
        DropHUDController.shared.leave(owns: owns, workbench: workbench)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let spot = spot(info.location) ?? workbench.dropHUDHover.flatMap({ owns($0.spot) ? $0.spot : nil })
        else { return false }
        return DropHUDController.shared.drop(spot, info: info, model: model, workbench: workbench)
    }
}

extension View {
    /// This control stands for one agent as a drop target of a dragged post-it (a row of the tray, an edge arrow).
    func agentDropTarget(_ spot: DropHUDSpot, model: AppModel, workbench: WorkbenchState) -> some View {
        onDrop(of: [.pixelTaskCard], delegate: HUDDropDelegate(model: model, workbench: workbench, spot: { _ in spot },
                                                              owns: { $0 == spot }))
    }
}

// MARK: - Drag source

/// The board's side of a post-it's drag (décision 9): the same type and data as `CardDragPayload`, so that the board's
/// sections and the agent cards of the list keep receiving it, and the scene told which card it is at once.
@MainActor
enum CardDragSource {
    static func itemProvider(for cardID: TaskCardID, workbench: WorkbenchState) -> NSItemProvider {
        workbench.beginCardDrag(cardID)
        let provider = NSItemProvider()
        provider.register(CardDragPayload(cardID: cardID))
        return provider
    }
}
