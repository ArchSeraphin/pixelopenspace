import AppKit
import Foundation
import PixelCore
import SpriteKit

/// The SpriteKit view of the open space. It reports its size and backing scale to the camera and keeps the energy
/// budget of 3.9: 30 frames per second at rest, 60 for a second after an interaction or during a flight, 15 when
/// the app is not active, paused when the window is hidden or the view out of a window. The snapshot harness turns
/// the budget off (`isCaptureMode`).
///
/// The mouse, the trackpad and the keyboard go to its `WorldInputController` (3.9, "Caméra et souris"), which turns
/// them into camera moves and intents; the view itself only routes the events. It takes the keyboard focus on a click.
final class WorldView: SKView {
    static let restFPS = 30
    static let interactionFPS = 60
    static let inactiveFPS = 15
    /// How long an interaction keeps 60 frames per second.
    static let interactionHold: TimeInterval = 1

    weak var stage: WorldStage?
    /// Snapshots: never paused by the window's state, the drawing is read offscreen.
    var isCaptureMode = false {
        didSet { updateEnergy() }
    }
    /// Gestures, clicks, hover and keys; created by `connectInput`, once the stage is attached.
    private(set) var input: WorldInputController?

    private var interactionUntil: TimeInterval = 0
    private var interactionTimer: Timer?
    /// The still image shown over the Metal drawing while the harness draws the window.
    private var stillView: NSImageView?
    /// `mouseMoved` and `mouseExited` over the whole visible rect (hover, 3.9).
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        ignoresSiblingOrder = true
        allowsTransparency = false
        shouldCullNonVisibleNodes = true
        preferredFramesPerSecond = Self.restFPS
        // Selector-based: removed with the view.
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            center.addObserver(self, selector: #selector(energyConditionsChanged(_:)), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: Geometry

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindow()
        reportMetrics()
        updateEnergy()
        if window == nil { input?.viewLeftWindow() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportMetrics()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportMetrics()
    }

    /// Size in points and backing scale (1 or 2), for the camera.
    private func reportMetrics() {
        guard let window, bounds.width > 0, bounds.height > 0 else { return }
        let scale = max(1, Int(window.backingScaleFactor.rounded()))
        stage?.camera.updateView(ViewMetrics(width: Double(bounds.width), height: Double(bounds.height),
                                             backingScale: scale))
        (scene as? WorldScene)?.syncCamera()
    }

    private weak var observedWindow: NSWindow?

    private func observeWindow() {
        let center = NotificationCenter.default
        let names: [NSNotification.Name] = [NSWindow.didChangeOcclusionStateNotification,
                                             NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
        if let observedWindow {
            for name in names { center.removeObserver(self, name: name, object: observedWindow) }
        }
        observedWindow = window
        guard let window else { return }
        for name in names {
            center.addObserver(self, selector: #selector(energyConditionsChanged(_:)), name: name, object: window)
        }
    }

    @objc private func energyConditionsChanged(_ notification: Notification) {
        updateEnergy()
    }

    // MARK: Energy

    /// 60 frames per second for the next second (gestures, keyboard, drags).
    func noteInteraction() {
        interactionUntil = ProcessInfo.processInfo.systemUptime + Self.interactionHold
        updateEnergy()
        interactionTimer?.invalidate()
        interactionTimer = Timer.scheduledTimer(withTimeInterval: Self.interactionHold + 0.05, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.updateEnergy() }
        }
    }

    /// Pause and frame rate from the window, the app and the camera.
    func updateEnergy() {
        if isCaptureMode {
            if isPaused { isPaused = false }
            return
        }
        guard let window else {
            if !isPaused { isPaused = true }
            return
        }
        let hidden = !window.isVisible || window.isMiniaturized || !window.occlusionState.contains(.visible)
        if isPaused != hidden { isPaused = hidden }
        guard !hidden else { return }
        let interacting = ProcessInfo.processInfo.systemUptime < interactionUntil || (stage?.camera.isFlying ?? false)
        let fps = interacting ? Self.interactionFPS : (NSApplication.shared.isActive ? Self.restFPS : Self.inactiveFPS)
        if preferredFramesPerSecond != fps { preferredFramesPerSecond = fps }
    }

    // MARK: Input (3.9, "Caméra et souris")

    /// Gives the view its input controller (`WorldViewRepresentable`, after `WorldStage.attach`): the controller
    /// needs the model and the workbench, which only the SwiftUI side knows. Once per view.
    func connectInput(model: AppModel, workbench: WorkbenchState) {
        guard input == nil, let stage else { return }
        input = WorldInputController(view: self, stage: stage, model: model, workbench: workbench)
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        input?.focusLost()
        return super.resignFirstResponder()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverArea == nil else { return }
        // `.inVisibleRect`: the rect follows the view's size by itself.
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp,
                                                         .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    // Every event goes to the controller; the SpriteKit scene never receives one (SKView would forward them to it).

    override func mouseDown(with event: NSEvent) {
        if let input { input.mouseDown(event) } else { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        if let input { input.mouseDragged(event) } else { super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if let input { input.mouseUp(event) } else { super.mouseUp(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let input { input.rightMouseDown(event) } else { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if input == nil { super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        if let input { input.otherMouseDown(event) } else { super.otherMouseDown(with: event) }
    }

    override func otherMouseDragged(with event: NSEvent) {
        if let input { input.mouseDragged(event) } else { super.otherMouseDragged(with: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if let input { input.mouseUp(event) } else { super.otherMouseUp(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        if let input { input.mouseMoved(event) } else { super.mouseMoved(with: event) }
    }

    override func mouseEntered(with event: NSEvent) {
        if input == nil { super.mouseEntered(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        if let input { input.mouseExited(event) } else { super.mouseExited(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        if let input { input.scrollWheel(event) } else { super.scrollWheel(with: event) }
    }

    override func magnify(with event: NSEvent) {
        if let input { input.magnify(event) } else { super.magnify(with: event) }
    }

    /// The controller opens its own context menu (`ClickResolver`), on a right click or a Control-click.
    override func menu(for event: NSEvent) -> NSMenu? {
        input == nil ? super.menu(for: event) : nil
    }

    override func keyDown(with event: NSEvent) {
        if input?.keyDown(event) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if input?.keyUp(event) != true { super.keyUp(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if input?.performKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Accessibility (7.9)

    /// SpriteKit's view labels itself "SKView" and ignores `setAccessibilityLabel`: the scene's label replaces it
    /// here (`WorldAccessibility` gives the view its children and its rotor).
    override func accessibilityLabel() -> String? {
        WorldHUD.shared.accessibility.viewLabel
    }

    // MARK: Snapshots

    /// Shows `image` (pixels of the whole view) over the Metal drawing, which `cacheDisplay` cannot read; returns
    /// the undo. Under the view's other subviews (the hover card), as the Metal drawing is.
    func showStill(_ image: CGImage) -> @MainActor () -> Void {
        stillView?.removeFromSuperview()
        let still = NSImageView(frame: bounds)
        still.image = NSImage(cgImage: image, size: bounds.size)
        still.imageScaling = .scaleAxesIndependently
        still.autoresizingMask = [.width, .height]
        addSubview(still, positioned: .below, relativeTo: nil)
        stillView = still
        return { [weak self, weak still] in
            still?.removeFromSuperview()
            if self?.stillView === still { self?.stillView = nil }
        }
    }
}
