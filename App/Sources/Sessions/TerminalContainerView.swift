import AppKit
import PixelCore

/// The NSView a SwiftUI `NSViewRepresentable` returns to show an agent's terminal (panel, detached window…).
///
/// It hosts the agent's existing `AgentTerminalView` when `TerminalPresenter` grants it, and a placeholder
/// otherwise. It never owns the process: removing the container only detaches the view. Layout passes smaller than
/// `minimumTerminalSize` are ignored (the terminal keeps its size), to avoid a storm of PTY resizes (SIGWINCH) while
/// SwiftUI settles or animates.
final class TerminalContainerView: NSView {
    static let minimumTerminalSize = NSSize(width: 320, height: 160)

    enum Placeholder: Equatable {
        /// The terminal is shown by another container.
        case elsewhere
        /// The agent has no terminal (never launched).
        case noSession
    }

    /// The agent this container asked for (via `TerminalPresenter.attach`).
    var agentID: AgentID?
    weak var presenter: TerminalPresenter?

    private(set) weak var terminalView: AgentTerminalView?
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let claimButton = NSButton(title: "Afficher ici", target: nil, action: nil)
    private let placeholderStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        placeholderLabel.alignment = .center
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.lineBreakMode = .byWordWrapping
        claimButton.target = self
        claimButton.action = #selector(claim(_:))
        placeholderStack.orientation = .vertical
        placeholderStack.alignment = .centerX
        placeholderStack.spacing = 8
        placeholderStack.addArrangedSubview(placeholderLabel)
        placeholderStack.addArrangedSubview(claimButton)
        placeholderStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderStack)
        NSLayoutConstraint.activate([
            placeholderStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholderStack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
        showPlaceholder(.noSession)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var isFlipped: Bool { true }

    // MARK: - Called by TerminalPresenter

    func install(_ view: AgentTerminalView) {
        if terminalView !== view {
            terminalView?.removeFromSuperview()
            view.removeFromSuperview()
            addSubview(view)
            terminalView = view
        }
        placeholderStack.isHidden = true
        view.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func removeTerminal() {
        if let view = terminalView, view.superview === self {
            view.removeFromSuperview()
        }
        terminalView = nil
    }

    func showPlaceholder(_ placeholder: Placeholder) {
        removeTerminal()
        switch placeholder {
        case .elsewhere:
            placeholderLabel.stringValue = "Terminal ouvert dans une autre fenêtre"
            claimButton.isHidden = false
        case .noSession:
            placeholderLabel.stringValue = "Aucune session en cours pour cet agent"
            claimButton.isHidden = true
        }
        placeholderStack.isHidden = false
    }

    // MARK: - For the UI

    /// Gives keyboard focus to the terminal, when this container shows it.
    func focusTerminal() {
        guard let terminalView, let window else { return }
        _ = window.makeFirstResponder(terminalView)
    }

    /// Detaches from the presenter (for `dismantleNSView`). The process keeps running.
    func detachFromPresenter() {
        presenter?.detach(self)
    }

    @objc private func claim(_ sender: Any?) {
        presenter?.claim(self)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        guard let terminalView else { return }
        let size = bounds.size
        guard size.width >= Self.minimumTerminalSize.width, size.height >= Self.minimumTerminalSize.height else {
            return
        }
        let target = NSRect(origin: .zero, size: size)
        if terminalView.frame != target {
            terminalView.frame = target
        }
    }
}
