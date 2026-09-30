import Foundation
import PixelCore

/// Where `claude` is and whether it can be used (proposal 3.1, welcome sheet 6(r)).
struct ClaudeStatus: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case detecting
        /// Found and `--version` read.
        case found
        /// An executable was found but `--version` failed: launching is allowed, the version is unknown.
        case versionUnknown
        case notFound
    }

    var phase: Phase
    /// Absolute path of the executable that will be launched.
    var path: String?
    var version: SemVer?
    /// French explanation when something went wrong (not found, `--version` failed, bad override).
    var error: String?
    /// Every candidate path, in search order (shown by the welcome sheet).
    var searched: [String]

    static let minimumVersion = ClaudeRequirements.minimumVersion
    static let detecting = ClaudeStatus(phase: .detecting, path: nil, version: nil, error: nil, searched: [])

    /// The version is known and at least `minimumVersion` (decision 20). Below: launching works, with a warning.
    var meetsMinimum: Bool {
        guard let version else { return false }
        return version >= Self.minimumVersion
    }

    /// A session can be launched.
    var isUsable: Bool {
        path != nil && (phase == .found || phase == .versionUnknown)
    }
}

/// Where the environment given to `claude` comes from.
enum EnvironmentSource: Equatable, Sendable {
    case pending
    /// Resolved from the user's login shell (its `PATH`, nvm, Herd, Homebrew…).
    case loginShell(String)
    /// The login shell failed; the app's own (launchd) environment is used, usually without the user's `PATH`.
    case appFallback(shell: String, reason: String)
}

/// Finds `claude` (proposal 3.1): resolves the login-shell environment once, then tries `ClaudeLocatorPlan`
/// candidates in order (settings override, login `PATH`, known install locations) and checks each executable with
/// `claude --version`.
@MainActor
final class ClaudeLocator {
    nonisolated static let shellTimeout: TimeInterval = 10
    nonisolated static let versionTimeout: TimeInterval = 5

    private let scratchDirectory: URL
    private let home: String

    /// The login shell's environment, once resolved (`nil` before).
    private(set) var environment: [String: String]?
    private(set) var environmentSource: EnvironmentSource = .pending
    private var environmentTask: Task<[String: String], Never>?

    /// `scratchDirectory` must be private (0700): the shell's environment transits there.
    init(scratchDirectory: URL, home: String) {
        self.scratchDirectory = scratchDirectory
        self.home = home
    }

    /// The login shell's environment, resolved on the first call only (up to 10 s), then cached.
    func resolveEnvironment() async -> [String: String] {
        if let environment { return environment }
        if let environmentTask { return await environmentTask.value }
        let scratch = scratchDirectory
        let task = Task { [weak self] () -> [String: String] in
            let (resolved, source) = await Self.loginShellEnvironment(scratchDirectory: scratch)
            self?.environment = resolved
            self?.environmentSource = source
            return resolved
        }
        environmentTask = task
        return await task.value
    }

    /// Searches for `claude` with the resolved environment. `override` is `AppSettings.claudePathOverride`.
    func locate(override: String?) async -> ClaudeStatus {
        let environment = await resolveEnvironment()
        let candidates = ClaudeLocatorPlan.candidates(override: override, pathEnv: environment["PATH"], home: home)
        let overridePath = override.flatMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : PathNormalizer.expandTilde(trimmed, home: home)
        }
        var status = await Self.probe(candidates, environment: EnvSanitizer.sanitize(environment),
                                      scratchDirectory: scratchDirectory)
        if let overridePath, status.path != overridePath {
            let problem = "Le chemin indiqué dans les réglages n'est pas utilisable : \(overridePath)"
            status.error = status.error.map { problem + "\n" + $0 } ?? problem
        }
        let foundPath = status.path ?? "-"
        let foundVersion = status.version?.description ?? "?"
        AppLog.locator.info("claude: \(foundPath, privacy: .public) \(foundVersion, privacy: .public)")
        return status
    }

    // MARK: - Off the main thread

    private nonisolated static func probe(_ candidates: [String], environment: [String: String],
                                          scratchDirectory: URL) async -> ClaudeStatus {
        var firstExecutable: String?
        var lastProblem: String?
        for path in candidates where isExecutableFile(path) {
            if firstExecutable == nil { firstExecutable = path }
            let outcome = await ProcessRunner.run(executable: path, arguments: ["--version"], environment: environment,
                                                  timeout: versionTimeout, scratchDirectory: scratchDirectory)
            let text = String(decoding: outcome.output, as: UTF8.self)
            if outcome.exitCode == 0, let version = SemVer(parsing: text) {
                return ClaudeStatus(phase: .found, path: path, version: version, error: nil, searched: candidates)
            }
            if outcome.timedOut {
                lastProblem = "\(path) --version ne répond pas (5 s)."
            } else if let launchError = outcome.launchError {
                lastProblem = "\(path) : \(launchError)"
            } else {
                let code = outcome.exitCode.map { String($0) } ?? "signal"
                lastProblem = "\(path) --version a échoué (code \(code))."
            }
        }
        if let firstExecutable {
            return ClaudeStatus(phase: .versionUnknown, path: firstExecutable, version: nil,
                                error: lastProblem ?? "Version de Claude Code illisible.", searched: candidates)
        }
        return ClaudeStatus(phase: .notFound, path: nil, version: nil,
                            error: "Claude Code est introuvable.", searched: candidates)
    }

    private nonisolated static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// Runs the user's shell as an interactive login shell (`LoginShellEnvironment`), with
    /// `PIXEL_RESOLVING_ENVIRONMENT=1` so that rc files can skip heavy work. Falls back to the app's environment.
    private nonisolated static func loginShellEnvironment(scratchDirectory: URL) async
        -> (environment: [String: String], source: EnvironmentSource) {
        let shell = userShell()
        let marker = "POS" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let command = LoginShellEnvironment.command(shell: shell, marker: marker)
        var base = ProcessInfo.processInfo.environment
        base[LoginShellEnvironment.resolvingFlag] = "1"
        let outcome = await ProcessRunner.run(executable: command.executable, arguments: command.arguments,
                                              environment: base, timeout: shellTimeout,
                                              scratchDirectory: scratchDirectory)
        if let parsed = LoginShellEnvironment.parse(outcome.output, marker: marker), !(parsed["PATH"] ?? "").isEmpty {
            return (parsed, .loginShell(command.executable))
        }
        let reason: String
        if outcome.timedOut {
            reason = "le shell n'a pas répondu en 10 s"
        } else if let launchError = outcome.launchError {
            reason = launchError
        } else {
            reason = "sortie du shell illisible"
        }
        AppLog.locator.error("login shell environment failed (\(shell, privacy: .public)): \(reason, privacy: .public)")
        return (ProcessInfo.processInfo.environment, .appFallback(shell: command.executable, reason: reason))
    }

    /// The account's shell (`pw_shell`), or `/bin/zsh`.
    private nonisolated static func userShell() -> String {
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let shell = String(cString: raw)
            if shell.hasPrefix("/") { return shell }
        }
        return LoginShellEnvironment.fallbackShell
    }
}
