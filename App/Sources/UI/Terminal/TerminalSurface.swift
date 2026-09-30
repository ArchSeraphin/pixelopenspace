import AppKit
import PixelCore
import SwiftUI

/// Shows an agent's terminal (panel or detached window). The SwiftTerm view itself belongs to the agent's
/// `TerminalHost`: `TerminalPresenter` lends it to one container at a time, so the process never depends on a view
/// being shown and is never restarted by a re-parenting (proposal 3.1).
struct TerminalSurface: NSViewRepresentable {
    let agentID: AgentID
    let presenter: TerminalPresenter
    /// When this changes, the terminal takes the keyboard focus.
    var focusToken: UUID?

    final class Coordinator {
        var appliedFocusToken: UUID?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView(frame: .zero)
        container.setAccessibilityLabel("Terminal de l'agent")
        presenter.attach(agentID, to: container)
        return container
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        // Idempotent for the same agent; switches the container to another agent otherwise.
        presenter.attach(agentID, to: container)
        guard let token = focusToken, context.coordinator.appliedFocusToken != token else { return }
        context.coordinator.appliedFocusToken = token
        // After this update: the container may only now be entering its window.
        Task { @MainActor in
            container.focusTerminal()
        }
    }

    static func dismantleNSView(_ container: TerminalContainerView, coordinator: Coordinator) {
        container.detachFromPresenter()
    }
}

/// Reports the `NSWindow` hosting a SwiftUI view (to bring a miniaturized main window forward).
struct WindowReader: NSViewRepresentable {
    let onChange: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView(frame: .zero)
        view.onWindowChange = onChange
        return view
    }

    func updateNSView(_ view: WindowReaderView, context: Context) {
        view.onWindowChange = onChange
    }
}

final class WindowReaderView: NSView {
    var onWindowChange: (@MainActor (NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
