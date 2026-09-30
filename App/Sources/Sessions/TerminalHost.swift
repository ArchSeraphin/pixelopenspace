import AppKit
import Foundation
import PixelCore
import PixelIPC
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
        // forkpty leaves the pty master (and SwiftTerm's dup of it) inheritable: the gate keeps this `claude` from
        // receiving the other agents' terminals, and the next ones from receiving this one.
        SpawnGate.run {
            view.startProcess(executable: plan.executable, args: plan.args, environment: plan.environmentArray,
                              execName: ClaudeLocatorPlan.executableName, currentDirectory: plan.cwd)
        }
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

    /// Writes bytes to the PTY in one write and waits until all of them reached it (SwiftTerm's
    /// `LocalProcess.send(data:completion:)`), for `timeout` at most: a child that stops reading its input would
    /// otherwise hold the delivery forever. The write starts before the first suspension: no other main-actor job
    /// runs between the caller's last check and the write. After `.timedOut` the bytes may still arrive later.
    func writeAndWait(_ bytes: [UInt8], timeout: Duration) async -> PTYWriteOutcome {
        guard pid != nil, !hasExited, let process = view.process else { return .failed }
        guard !bytes.isEmpty else { return .written }
        let expected = bytes.count
        return await withCheckedContinuation { continuation in
            let once = OneShotContinuation(continuation)
            let timer = Task {
                try? await Task.sleep(for: timeout)
                once.resume(.timedOut)
            }
            process.send(data: bytes[...]) { result in
                switch result {
                case .success(let written): once.resume(written == expected ? .written : .failed)
                case .failure: once.resume(.failed)
                }
                timer.cancel()
            }
        }
    }

    /// Last PTY output, to the chunk (guard G4 of a delivery); `.output` events are throttled to one per second.
    var lastOutputAt: Date? { activity.lastOutputAt }

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

/// How a PTY write awaited by `TerminalHost.writeAndWait` ended.
enum PTYWriteOutcome: Equatable, Sendable {
    case written
    /// No process, or the write failed.
    case failed
    /// Not written within the timeout (the child does not read its input).
    case timedOut
}

/// Resumes a continuation once, whichever of several callbacks (write completion, timer) comes first.
final class OneShotContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// Throttles PTY activity reports from SwiftTerm's parse thread: the first output after a quiet period is reported at
/// once; output during the following second only marks the gate, and `rearm()` reports it at the end of the second.
/// It also keeps the time of the last output, unthrottled.
final class ActivityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = true
    private var dirty = false
    private var lastOutput: Date?

    /// Time of the last output seen by `shouldReport()`.
    var lastOutputAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return lastOutput
    }

    /// Parse thread: `true` when this output must be reported now.
    func shouldReport() -> Bool {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        lastOutput = now
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
