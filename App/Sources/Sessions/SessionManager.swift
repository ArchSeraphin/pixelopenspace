import AppKit
import Foundation
import PixelCore

/// Why a launch could not start a process.
enum SessionLaunchError: Error, Equatable, Sendable {
    case alreadyRunning
    case missingDirectory(String)
    case spawnFailed

    /// French text for the toast and the agent's error state.
    var message: String {
        switch self {
        case .alreadyRunning: return "Une session tourne déjà pour cet agent."
        case .missingDirectory(let path): return "Dossier introuvable : \(path)"
        case .spawnFailed: return "Impossible de créer le terminal (PTY)."
        }
    }
}

/// Life cycle of the `claude` processes (proposal 3.1): one `TerminalHost` per agent that ran, kept after the process
/// exits so that its last screen stays readable, replaced at the next launch.
@MainActor
final class SessionManager {
    /// Grace period between SIGTERM and SIGKILL when closing one session.
    static let closeGrace: Duration = .seconds(5)

    let presenter: TerminalPresenter
    /// Terminal options for the next terminals (font and scrollback cannot change once a process runs).
    var terminalPrefs: TerminalPrefs {
        didSet {
            for host in hosts.values { host.view.optionAsMetaKey = terminalPrefs.optionAsMeta }
        }
    }
    /// Events of every terminal, tagged with the agent.
    var onEvent: (@MainActor (AgentID, TerminalEvent) -> Void)?

    private(set) var hosts: [AgentID: TerminalHost] = [:]
    private let keystrokes = KeystrokeMonitor()

    init(presenter: TerminalPresenter, terminalPrefs: TerminalPrefs) {
        self.presenter = presenter
        self.terminalPrefs = terminalPrefs
        presenter.viewProvider = { [weak self] agentID in
            self?.hosts[agentID]?.view
        }
    }

    /// Once the application has finished launching: installs the keystroke monitor.
    func start() {
        keystrokes.install()
    }

    func host(for agentID: AgentID) -> TerminalHost? {
        hosts[agentID]
    }

    func isRunning(_ agentID: AgentID) -> Bool {
        hosts[agentID]?.isRunning ?? false
    }

    var runningAgents: [AgentID] {
        hosts.values.filter { $0.isRunning }.map { $0.agentID }
    }

    /// Starts `plan` in a fresh terminal for `agentID`. The previous terminal of the agent (exited) is released.
    /// Returns the pid; the caller reduces `.processStarted` at once, before any hook is handled.
    func launch(plan: LaunchPlan, agentID: AgentID) -> Result<Int32, SessionLaunchError> {
        if let existing = hosts[agentID], existing.isRunning { return .failure(.alreadyRunning) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: plan.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(.missingDirectory(plan.cwd))
        }
        if let old = hosts.removeValue(forKey: agentID) {
            old.tearDown()
        }
        let host = TerminalHost(agentID: agentID, prefs: terminalPrefs)
        host.onEvent = { [weak self] event in
            self?.onEvent?(agentID, event)
        }
        hosts[agentID] = host
        guard let pid = host.start(plan) else {
            presenter.refresh(agentID)
            return .failure(.spawnFailed)
        }
        AppLog.sessions.info("agent \(agentID.description, privacy: .public) started pid \(pid)")
        presenter.refresh(agentID)
        return .success(pid)
    }

    /// Writes bytes to the agent's PTY. `false` when no process runs.
    @discardableResult
    func write(bytes: [UInt8], to agentID: AgentID) -> Bool {
        guard let host = hosts[agentID], host.isRunning else { return false }
        host.write(bytes)
        return true
    }

    /// The live screen of a running agent, for `ScreenPatterns.parse`.
    func sampleVisibleLines(_ agentID: AgentID) -> [String]? {
        guard let host = hosts[agentID], host.isRunning else { return nil }
        return host.visibleLines()
    }

    /// SIGTERM to the process group, then SIGKILL after `closeGrace` if it still runs (`force`: after 1 s).
    /// Reduce `.closeRequested` first, so that the exit reads as a close, not a crash.
    func close(_ agentID: AgentID, force: Bool) {
        guard let host = hosts[agentID], let pid = host.pid else { return }
        host.sendSignal(SIGTERM)
        let grace: Duration = force ? .seconds(1) : Self.closeGrace
        Task { @MainActor [weak host] in
            try? await Task.sleep(for: grace)
            guard let host, host.pid == pid else { return }
            AppLog.sessions.info("agent \(agentID.description, privacy: .public) ignored SIGTERM: SIGKILL")
            host.sendSignal(SIGKILL)
        }
    }

    /// Closes every running session: SIGTERM, then SIGKILL for those still running after `grace`. Returns once all
    /// processes are gone, or one second after the SIGKILL.
    func terminateAll(grace: Duration) async {
        let running = hosts.values.filter { $0.isRunning }
        guard !running.isEmpty else { return }
        for host in running { host.sendSignal(SIGTERM) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: grace)
        while clock.now < deadline, hosts.values.contains(where: { $0.isRunning }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let survivors = hosts.values.filter { $0.isRunning }
        guard !survivors.isEmpty else { return }
        for host in survivors { host.sendSignal(SIGKILL) }
        let killDeadline = clock.now.advanced(by: .seconds(1))
        while clock.now < killDeadline, hosts.values.contains(where: { $0.isRunning }) {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Forgets an agent's terminal (agent removed). Only for an agent whose process is gone.
    func discard(_ agentID: AgentID) {
        guard let host = hosts[agentID], !host.isRunning else { return }
        hosts[agentID] = nil
        host.tearDown()
        presenter.refresh(agentID)
    }
}
