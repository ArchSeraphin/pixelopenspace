import AppKit
import Foundation
import PixelCore
import SpriteKit

/// The SpriteKit view of the open space. It reports its size and backing scale to the camera and keeps the energy
/// budget of 3.9: 30 frames per second at rest, 60 for a second after an interaction or during a flight, 15 when
/// the app is not active, paused when the window is hidden or the view out of a window. The snapshot harness turns
/// the budget off (`isCaptureMode`).
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

    private var interactionUntil: TimeInterval = 0
    private var interactionTimer: Timer?
    /// The still image shown over the Metal drawing while the harness draws the window.
    private var stillView: NSImageView?

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

    // MARK: Snapshots

    /// Shows `image` (pixels of the whole view) over the Metal drawing, which `cacheDisplay` cannot read; returns
    /// the undo.
    func showStill(_ image: CGImage) -> @MainActor () -> Void {
        stillView?.removeFromSuperview()
        let still = NSImageView(frame: bounds)
        still.image = NSImage(cgImage: image, size: bounds.size)
        still.imageScaling = .scaleAxesIndependently
        still.autoresizingMask = [.width, .height]
        addSubview(still)
        stillView = still
        return { [weak self, weak still] in
            still?.removeFromSuperview()
            if self?.stillView === still { self?.stillView = nil }
        }
    }
}
