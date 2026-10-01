import AppKit
import Foundation
import Observation
import PixelCore

/// The mouse, the trackpad and the keyboard in the open space (3.9, "Caméra et souris" and "Résolution des clics"):
/// it turns the events of its `WorldView` into camera moves (`WorldCamera`), the core's click rules (`ClickResolver`,
/// on the target `SceneHitTester` finds under the pointer) and the hover of the scene. No rule lives here: what a
/// click does is the resolver's, what an action does is `WorldClickPerformer`'s.
///
/// - Trackpad: two fingers pan; a pinch zooms one step around the pointer when `PinchAccumulator` crosses its
///   threshold, never to a fractional scale.
/// - Mouse: the wheel zooms one step per notch around the pointer; ⇧ + wheel (or a tilted wheel) pans sideways; a
///   drag that starts on the bare floor (nothing, the hall, a rug) pans once it has gone past `dragThreshold`; so does
///   the middle button, or any drag while Space is held. A drag from an agent or a desk never pans.
/// - Hover: the agent or free desk under the pointer goes to `WorldInteractionState.hovered` (the plan draws its name
///   plate or `floor.hover`); after `hoverDelay` at rest, its `HoverCardView`.
/// - Keyboard, focus in the scene: arrows pan by `CameraMath.keyboardStep` (⇧: ×4), ⌘= zooms in (alias of ⌘+), ↩ or
///   Space released without a drag opens the selected agent's window, Escape deselects.
///
/// Every input asks the view for 60 frames per second (`noteInteraction`). Registers the `hover` step of the snapshot
/// harness (décision 14).
@MainActor
final class WorldInputController {
    static let snapshotOwner = "tâche 9"
    /// Points a press on the floor travels before it pans (3.9).
    static let dragThreshold = 3.0
    /// Seconds the pointer rests on an agent or a desk before its card shows.
    static let hoverDelay: TimeInterval = 0.3
    /// View points per line of a wheel turned with ⇧, or tilted.
    static let wheelPanStep = 40.0

    private weak var view: WorldView?
    private let stage: WorldStage
    private let model: AppModel
    private let performer: WorldClickPerformer
    private let hoverCard = HoverCardView()

    private var resolver = ClickResolver(doubleClickInterval: NSEvent.doubleClickInterval)
    /// The plan the tester was built from: it keeps the character frames it composed, one tester per plan.
    private var tester: (plan: WorldScenePlan, hitTester: SceneHitTester)?
    private var press: Press?
    private var pinch = PinchAccumulator()
    /// The window of a clicked agent waits for this timer (`ClickAction.wakeAt`).
    private var wakeTimer: Timer?
    private var hoverTimer: Timer?
    /// Space is held (keyboard focus in the scene); `spaceDragged`: it served a drag meanwhile.
    private var spaceHeld = false
    private var spaceDragged = false
    /// The camera's pose the hover was found at: once the camera moves (flight, zoom, menu, harness), the target
    /// under the pointer is another one and the card's place is wrong.
    private var hoverPose: CameraPose?

    /// A button held down in the scene.
    private struct Press {
        enum Kind {
            /// On an agent, a desk, a sign, the cork wall…: the click went to the resolver at once; a drag does
            /// nothing.
            case click
            /// On the bare floor: a click when the button comes up without a drag, a pan otherwise.
            case floor(SceneHitTarget?, clickCount: Int, time: Double)
            case pan
        }

        var kind: Kind
        let start: CGPoint
        var last: CGPoint
    }

    init(view: WorldView, stage: WorldStage, model: AppModel, workbench: WorkbenchState) {
        self.view = view
        self.stage = stage
        self.model = model
        performer = WorldClickPerformer(view: view, stage: stage, model: model, workbench: workbench)
        hoverCard.install(in: view)
        registerSnapshotHook()
        observeCamera()
    }

    // MARK: Mouse buttons

    func mouseDown(_ event: NSEvent) {
        guard let view else { return }
        view.window?.makeFirstResponder(view)
        if event.modifierFlags.contains(.control) { return rightMouseDown(event) }
        interacted(hideHover: true)
        let point = viewPoint(of: event)
        if spaceHeld {
            spaceDragged = true
            beginPan(at: point)
            return
        }
        let target = target(at: point)
        switch target {
        case nil, .floor?, .islandFloor?:
            press = Press(kind: .floor(target, clickCount: event.clickCount, time: Self.now), start: point, last: point)
        default:
            press = Press(kind: .click, start: point, last: point)
            perform(resolver.handle(.down(target, clickCount: event.clickCount, time: Self.now)), event: event)
        }
    }

    /// Left button (and middle button) drags.
    func mouseDragged(_ event: NSEvent) {
        guard var press else { return }
        let point = viewPoint(of: event)
        switch press.kind {
        case .click:
            return
        case .floor:
            guard hypot(point.x - press.start.x, point.y - press.start.y) > Self.dragThreshold else { return }
            press.kind = .pan
            NSCursor.closedHand.set()
            fallthrough
        case .pan:
            // The content follows the pointer: the camera moves the other way.
            stage.camera.pan(byViewPoints: SceneVector(press.last.x - point.x, press.last.y - point.y))
            press.last = point
            interacted(hideHover: true)
        }
        self.press = press
    }

    func mouseUp(_ event: NSEvent) {
        guard let press else { return }
        self.press = nil
        switch press.kind {
        case .click:
            break
        case .floor(let target, let clickCount, let time):
            perform(resolver.handle(.down(target, clickCount: clickCount, time: time)), event: event)
        case .pan:
            (spaceHeld ? NSCursor.openHand : NSCursor.arrow).set()
        }
        interacted(hideHover: false)
    }

    func rightMouseDown(_ event: NSEvent) {
        press = nil
        interacted(hideHover: true)
        perform(resolver.handle(.rightDown(target(at: viewPoint(of: event)))), event: event)
    }

    /// The middle button pans, whatever is under the pointer.
    func otherMouseDown(_ event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        interacted(hideHover: true)
        beginPan(at: viewPoint(of: event))
    }

    private func beginPan(at point: CGPoint) {
        press = Press(kind: .pan, start: point, last: point)
        NSCursor.closedHand.set()
    }

    // MARK: Wheel and trackpad

    func scrollWheel(_ event: NSEvent) {
        interacted(hideHover: true)
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            // Two fingers: the content follows them, as in a scroll view. Fingers resting without a move (no delta)
            // leave a flight in progress alone.
            if dx != 0 || dy != 0 { stage.camera.pan(byViewPoints: SceneVector(-dx, dy)) }
            return
        }
        if event.modifierFlags.contains(.shift) || (dx != 0 && dy == 0) {
            let lines = dx != 0 ? dx : dy
            stage.camera.pan(byViewPoints: SceneVector(-lines * Self.wheelPanStep, 0))
            return
        }
        guard dy != 0 else { return }
        // One step per notch; the wheel turned away from the user zooms in, whatever the scrolling direction setting.
        let away = (event.isDirectionInvertedFromDevice ? -dy : dy) > 0
        let about = vector(viewPoint(of: event))
        if away { stage.camera.zoomIn(about: about) } else { stage.camera.zoomOut(about: about) }
    }

    func magnify(_ event: NSEvent) {
        interacted(hideHover: true)
        if event.phase == .began || event.phase == .mayBegin { pinch.reset() }
        let step = pinch.add(event.magnification)
        let about = vector(viewPoint(of: event))
        if step > 0 { stage.camera.zoomIn(about: about) } else if step < 0 { stage.camera.zoomOut(about: about) }
        if event.phase == .ended || event.phase == .cancelled { pinch.reset() }
    }

    // MARK: Hover

    func mouseMoved(_ event: NSEvent) {
        view?.noteInteraction()
        let point = viewPoint(of: event)
        let target = Self.hoverable(target(at: point))
        hoverPose = stage.camera.pose
        if stage.interaction.hovered != target {
            stage.interaction.hovered = target
            hoverCard.hide()
        }
        hoverTimer?.invalidate()
        hoverTimer = nil
        guard let target, !hoverCard.isShowing else { return }
        // The card waits for the pointer to rest: every move starts the delay again.
        hoverTimer = Self.timer(after: Self.hoverDelay) { [weak self] in
            guard let self, self.stage.interaction.hovered == target else { return }
            self.hoverCard.show(target, model: self.model, near: point)
        }
    }

    func mouseExited(_ event: NSEvent) {
        clearHover()
    }

    /// Only agents and free desks show something when hovered (3.9).
    private static func hoverable(_ target: SceneHitTarget?) -> SceneHitTarget? {
        switch target {
        case .agent?, .freeDesk?: return target
        default: return nil
        }
    }

    private func clearHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverCard.hide()
        if stage.interaction.hovered != nil { stage.interaction.hovered = nil }
    }

    /// The camera moved without the pointer (a flight, a zoom command, a resize, the harness): the hover and the
    /// popover anchored on a desk go; the next move of the pointer finds its target again.
    private func observeCamera() {
        let camera = stage.camera
        withObservationTracking {
            _ = camera.pose
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.cameraMoved()
                self.observeCamera()
            }
        }
    }

    private func cameraMoved() {
        let pose = stage.camera.pose
        guard pose != hoverPose else { return }
        hoverPose = pose
        clearHover()
        performer.closePopover()
    }

    // MARK: Keyboard

    /// Virtual key codes (Carbon's `kVK_…`), the same on every keyboard layout.
    private enum Key {
        static let returnKey: UInt16 = 36, space: UInt16 = 49, escape: UInt16 = 53, keypadEnter: UInt16 = 76
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    }

    /// Whether the key was the scene's (focus in the scene). Keys with ⌘, ⌥ or ⌃ belong to the menus.
    func keyDown(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        let step = CameraMath.keyboardStep * (event.modifierFlags.contains(.shift) ? CameraMath.keyboardFastFactor : 1)
        switch event.keyCode {
        case Key.left: stage.camera.pan(byViewPoints: SceneVector(-step, 0))
        case Key.right: stage.camera.pan(byViewPoints: SceneVector(step, 0))
        case Key.down: stage.camera.pan(byViewPoints: SceneVector(0, -step))
        case Key.up: stage.camera.pan(byViewPoints: SceneVector(0, step))
        case Key.returnKey, Key.keypadEnter:
            openSelectedAgentWindow()
        case Key.space:
            if !event.isARepeat && !spaceHeld {
                spaceHeld = true
                spaceDragged = false
                if press == nil { NSCursor.openHand.set() }
            }
        case Key.escape:
            model.select(agent: nil)
        default:
            return false
        }
        interacted(hideHover: event.keyCode != Key.space)
        return true
    }

    func keyUp(_ event: NSEvent) -> Bool {
        guard event.keyCode == Key.space, spaceHeld else { return false }
        spaceHeld = false
        if press == nil { NSCursor.arrow.set() }
        if !spaceDragged { openSelectedAgentWindow() }
        view?.noteInteraction()
        return true
    }

    /// ⌘=: zoom in, the alias of the menu's ⌘+, while the scene has the keyboard focus.
    func performKeyEquivalent(_ event: NSEvent) -> Bool {
        guard let view, view.window?.firstResponder === view,
              event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
              event.charactersIgnoringModifiers == "=", performer.isAvailable(.zoomIn) else { return false }
        interacted(hideHover: true)
        stage.camera.zoomIn(about: nil)
        return true
    }

    /// The scene lost the keyboard focus: a held Space is forgotten.
    func focusLost() {
        guard spaceHeld else { return }
        spaceHeld = false
        if press == nil { NSCursor.arrow.set() }
    }

    private func openSelectedAgentWindow() {
        guard let agentID = model.selectedAgentID, model.agent(agentID) != nil else {
            NSSound.beep()
            return
        }
        performer.openAgentWindow(agentID)
    }

    // MARK: View

    /// The view left its window (list view, window closed): nothing stays pending.
    func viewLeftWindow() {
        press = nil
        spaceHeld = false
        wakeTimer?.invalidate()
        wakeTimer = nil
        clearHover()
        performer.closePopover()
    }

    // MARK: Clicks

    /// The resolver's actions; `wakeAt` arms the timer that lets an agent's window open.
    private func perform(_ actions: [ClickAction], event: NSEvent?) {
        for action in actions {
            if case .wakeAt(let time) = action {
                wake(at: time)
            } else {
                performer.perform(action, event: event)
            }
        }
    }

    private func wake(at time: Double) {
        wakeTimer?.invalidate()
        wakeTimer = Self.timer(after: max(0, time - Self.now)) { [weak self] in
            guard let self else { return }
            self.wakeTimer = nil
            self.perform(self.resolver.handle(.timer(time: Self.now)), event: nil)
        }
    }

    // MARK: Helpers

    /// The resolver's clock: seconds since the system started.
    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    /// 60 frames per second for a moment; the camera is about to move: the hover and the popover go.
    private func interacted(hideHover: Bool) {
        view?.noteInteraction()
        guard hideHover else { return }
        clearHover()
        performer.closePopover()
    }

    /// The event's location in the view's points, origin at the bottom-left corner (the camera's view frame).
    private func viewPoint(of event: NSEvent) -> CGPoint {
        guard let view else { return .zero }
        let point = view.convert(event.locationInWindow, from: nil)
        return view.isFlipped ? CGPoint(x: point.x, y: view.bounds.height - point.y) : point
    }

    private func vector(_ point: CGPoint) -> SceneVector {
        SceneVector(Double(point.x), Double(point.y))
    }

    /// What is under a view point: the core's hit test on the plan the scene shows (opaque texels first, then the
    /// floor's tiles); nil outside the world or before the first plan.
    private func target(at point: CGPoint) -> SceneHitTarget? {
        guard let plan = stage.plan, stage.camera.isPlaced else { return nil }
        var hitTester = tester.flatMap { $0.plan == plan ? $0.hitTester : nil } ?? SceneHitTester(plan: plan)
        // Held once only while it composes frames into its cache (no copy of the cache).
        tester = nil
        let found = hitTester.target(at: stage.camera.scenePoint(atView: vector(point)))
        tester = (plan, hitTester)
        return found
    }

    private static func timer(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        // Common modes: the timer also fires while a menu or a drag tracks the mouse.
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: Snapshot harness

    /// `hover`: the hovered target and its card, on the named agent or free desk, as if the pointer rested on it.
    private func registerSnapshotHook() {
        let hooks = SnapshotHooks.shared
        guard hooks.isEnabled else { return }
        hooks.register(.hover, owner: Self.snapshotOwner) { [weak self] step in
            guard let self, case .hover(let hover) = step else { return false }
            return self.snapshotHover(hover)
        }
    }

    private func snapshotHover(_ hover: SnapshotHover) -> Bool {
        guard view?.window != nil else { return false }
        stage.settle()
        let target: SceneHitTarget?
        switch hover {
        case .agent(let name):
            guard let id = stage.agentID(named: name, in: model) else { return false }
            target = .agent(id)
        case .freeDesk(let project, let deskIndex):
            guard let id = stage.projectID(named: project, in: model) else { return false }
            target = .freeDesk(id, deskIndex: deskIndex)
        case .none:
            target = nil
        }
        clearHover()
        guard let target else {
            stage.settle()
            return true
        }
        stage.interaction.hovered = target
        stage.settle()
        hoverPose = stage.camera.pose
        guard let rect = stage.viewRect(of: target) else { return false }
        hoverCard.show(target, model: model, near: CGPoint(x: rect.midX, y: rect.midY))
        return true
    }
}
