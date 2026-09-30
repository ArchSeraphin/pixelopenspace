import AppKit
import Foundation
import PixelCore
import SwiftTerm

/// The terminal of one agent: SwiftTerm's `LocalProcessTerminalView` running `claude` in a PTY.
///
/// Created detached (frame `.zero`) with its final options (120×36, scrollback, font) before the process starts:
/// changing them afterwards resets the terminal. Lives as long as the process, shown or not (`TerminalPresenter`).
///
/// User input does not go through `send(source:data:)` in this SwiftTerm version (keystrokes are written straight to
/// the PTY, and `keyDown` is not overridable), so keystrokes are observed by `KeystrokeMonitor` ahead of the view,
/// and pastes here.
final class AgentTerminalView: LocalProcessTerminalView {
    let agentID: AgentID
    /// Called on the main actor for each user keystroke or paste (the content never leaves the terminal).
    var onKeystroke: (@MainActor (KeyClass) -> Void)?
    /// Bells (BEL) from the program, relayed from SwiftTerm's parse thread.
    nonisolated let bellRelay = CallbackRelay()

    init(agentID: AgentID, font: NSFont, options: TerminalOptions) {
        self.agentID = agentID
        super.init(frame: .zero, font: font, options: options)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func paste(_ sender: Any) {
        super.paste(sender)
        onKeystroke?(.printable)
    }

    /// Runs on the parse thread for every BEL; SwiftTerm then applies `bellStyle` on the main thread.
    nonisolated override func bell(source: SwiftTerm.Terminal) {
        super.bell(source: source)
        bellRelay.fire()
    }

    /// The live screen as text lines, top to bottom. When the user has scrolled back, the viewport shows history,
    /// so the last screenful of the buffer is read instead.
    func liveScreenLines() -> [String] {
        let snapshot = terminalStateSnapshot()
        guard canScroll, scrollPosition < 1 else {
            return snapshot.visibleRows.map(\.text)
        }
        let text = String(decoding: getBufferAsData(), as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return Array(lines.suffix(snapshot.dimensions.rows))
    }
}

/// A thread-safe, throttled callback slot: `fire()` from any thread calls the handler at most once per `interval`.
final class CallbackRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var lastFired: UInt64 = 0
    private let intervalNanos: UInt64

    init(interval: TimeInterval = 1) {
        intervalNanos = UInt64(max(0, interval) * 1_000_000_000)
    }

    func setHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func fire() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard let handler, lastFired == 0 || now &- lastFired >= intervalNanos else {
            lock.unlock()
            return
        }
        lastFired = now
        lock.unlock()
        handler()
    }
}
