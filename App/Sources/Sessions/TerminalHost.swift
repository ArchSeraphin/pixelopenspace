import AppKit
import Foundation
import PixelCore
import SwiftTerm

/// What a terminal reports to the model. Carries no business state: the reducer turns it into `AgentInput`.
enum TerminalEvent: Equatable, Sendable {
    case exited(code: Int32?)
    case failedToStart(String)
    /// PTY output happened (throttled: leading edge, then at most once per second while it continues).
    case output
    case keystroke(KeyClass)
    case bell
}

/// Owns one agent's `AgentTerminalView` and its `claude` process (proposal 3.1). Retained by `SessionManager` for the
/// life of the process (`processDelegate` is weak), whether or not a window shows the view.
@MainActor
final class TerminalHost: LocalProcessTerminalViewDelegate {
    static let initialColumns = 120
    static let initialRows = 36

    let agentID: AgentID
    let view: AgentTerminalView
    var onEvent: (@MainActor (TerminalEvent) -> Void)?

    /// pid of the running `claude` (also its process group: the PTY child is a session leader).
    private(set) var pid: Int32?
    private(set) var startedAt: Date?
    private(set) var exitCode: Int32?
    private(set) var hasExited = false
    private var reportedStartFailure = false
    private let activity = ActivityGate()

    init(agentID: AgentID, prefs: TerminalPrefs) {
        self.agentID = agentID
        let options = TerminalOptions(cols: Self.initialColumns, rows: Self.initialRows,
                                      scrollback: min(max(prefs.scrollback, 100), 100_000))
        view = AgentTerminalView(agentID: agentID, font: Self.font(for: prefs), options: options)
        view.optionAsMetaKey = prefs.optionAsMeta
        // Visual only: sessions in the background must not beep; attention goes through notifications.
        view.bellStyle = .visual
        view.processDelegate = self
        view.onKeystroke = { [weak self] keyClass in
            self?.onEvent?(.keystroke(keyClass))
        }
        view.bellRelay.setHandler { [weak self] in
            Task { @MainActor in self?.onEvent?(.bell) }
        }
        let gate = activity
        view.setProcessOutputHandler { [weak self] in
            guard gate.shouldReport() else { return }
            Task { @MainActor in self?.reportOutput() }
        }
    }

    static func font(for prefs: TerminalPrefs) -> NSFont {
        let size = CGFloat(min(max(prefs.fontSize, 8), 36))
        if let name = prefs.fontName, !name.isEmpty, let font = NSFont(name: name, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: - Process

    /// Starts `claude` as planned. Returns its pid, or `nil` when the PTY could not be created (reported once).
    func start(_ plan: LaunchPlan) -> Int32? {
        view.startProcess(executable: plan.executable, args: plan.args, environment: plan.environmentArray,
                          execName: ClaudeLocatorPlan.executableName, currentDirectory: plan.cwd)
        let childPID = view.process.shellPid
        guard childPID > 0 else {
            reportedStartFailure = true
            hasExited = true
            return nil
        }
        pid = childPID
        startedAt = Date()
        return childPID
    }

    var isRunning: Bool { pid != nil }

    /// Writes bytes to the PTY, as if typed.
    func write(_ bytes: [UInt8]) {
        guard pid != nil, !bytes.isEmpty else { return }
        view.send(data: bytes[...])
    }

    /// Sends `signal` to the process group, and to the process itself in case it left the group.
    func sendSignal(_ signalNumber: Int32) {
        guard let pid, pid > 1 else { return }
        if kill(-pid, signalNumber) != 0 {
            kill(pid, signalNumber)
        }
    }

    /// The live screen lines, for `ScreenPatterns`.
    func visibleLines() -> [String] {
        view.liveScreenLines()
    }

    /// DEC mode 2004, for pasting a multi-line prompt safely (step 2b).
    var bracketedPasteMode: Bool {
        view.terminalStateSnapshot().bracketedPasteMode
    }

    /// Releases the view's UI resources once the process is gone and the host is dropped. SwiftTerm may ask for a
    /// retry while the GPU still uses the view.
    func tearDown() {
        view.processDelegate = nil
        view.onKeystroke = nil
        view.bellRelay.setHandler(nil)
        view.setProcessOutputHandler(nil)
        view.removeFromSuperview()
        Self.closeUI(of: view, attempt: 0)
    }

    private static func closeUI(of view: AgentTerminalView, attempt: Int) {
        guard !view.updateUiClosed(), attempt < 50 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            closeUI(of: view, attempt: attempt + 1)
        }
    }

    private func reportOutput() {
        onEvent?(.output)
        // Trailing edge: while output continues, report again every second.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            if self.activity.rearm() { self.reportOutput() }
        }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        guard !hasExited else { return }
        hasExited = true
        pid = nil
        self.exitCode = exitCode
        let agent = agentID.description
        let status = exitCode.map { String($0) } ?? "signal"
        AppLog.sessions.info("agent \(agent, privacy: .public) exited: \(status, privacy: .public)")
        onEvent?(.exited(code: exitCode))
    }

    func processFailedToStart(source: SwiftTerm.TerminalView, error: LocalProcessError) {
        pid = nil
        hasExited = true
        guard !reportedStartFailure else { return }
        reportedStartFailure = true
        onEvent?(.failedToStart(String(describing: error)))
    }
}

/// Throttles PTY activity reports from SwiftTerm's parse thread: the first output after a quiet period is reported at
/// once; output during the following second only marks the gate, and `rearm()` reports it at the end of the second.
final class ActivityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = true
    private var dirty = false

    /// Parse thread: `true` when this output must be reported now.
    func shouldReport() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if armed {
            armed = false
            return true
        }
        dirty = true
        return false
    }

    /// One second after a report: `true` if output happened meanwhile (report it, stay disarmed), otherwise re-arms.
    func rearm() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if dirty {
            dirty = false
            return true
        }
        armed = true
        return false
    }
}
