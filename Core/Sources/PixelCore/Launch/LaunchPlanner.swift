import Foundation
import PixelIPC

/// How a session starts (proposal 5.1).
public enum LaunchMode: Equatable, Sendable {
    /// A fresh conversation, optionally with the first post-it as the positional prompt.
    case new(initialPrompt: String?)
    /// `--resume <id>`, launched in the session's recorded folder.
    case resume(sessionID: String)
    /// `--continue`: only for an agent without known history ("most recent conversation of the folder" is
    /// ambiguous with several agents in one folder).
    case continueLast
    /// `--resume <id> --fork-session`: same context, new session id ("Dupliquer l'agent").
    case fork(fromSessionID: String)
}

/// Launch switches from `AppSettings`.
public struct LaunchOptions: Equatable, Sendable {
    /// `CLAUDE_CODE_DISABLE_AGENT_VIEW=1` (decision 11): `←` on an empty prompt must not move the session
    /// out of our PTY.
    public var disableAgentView: Bool
    /// `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1`: classic main-screen renderer.
    public var forceClassicRenderer: Bool
    /// `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` (decision 15).
    public var disableNonessentialTraffic: Bool
    /// Added last. Cannot set the app's routing variables (`PIXEL_*`, except `PIXEL_HOOK_DEBUG`).
    public var extraEnv: [String: String]

    public init(disableAgentView: Bool = true, forceClassicRenderer: Bool = false,
                disableNonessentialTraffic: Bool = false, extraEnv: [String: String] = [:]) {
        self.disableAgentView = disableAgentView
        self.forceClassicRenderer = forceClassicRenderer
        self.disableNonessentialTraffic = disableNonessentialTraffic
        self.extraEnv = extraEnv
    }

    public init(settings: AppSettings) {
        self.init(disableAgentView: settings.disableAgentViewInEmbedded,
                  forceClassicRenderer: settings.forceClassicRenderer,
                  disableNonessentialTraffic: settings.disableNonessentialTraffic,
                  extraEnv: settings.extraEnv)
    }
}

/// Everything `LaunchPlanner` needs; gathered by the app (`SessionManager`).
public struct LaunchRequest: Equatable, Sendable {
    public var agent: Agent
    public var project: Project
    public var mode: LaunchMode
    /// Absolute path found by `ClaudeLocator`.
    public var claudeExecutable: String
    /// Environment of the login shell (`LoginShellEnvironment`), or the app's own as a fallback.
    public var baseEnvironment: [String: String]
    /// `run/hooks-settings.json`, passed to `--settings`.
    public var hookSettingsPath: String
    public var hookSocketPath: String
    public var hookToken: String
    /// UUID passed to `--session-id`, with `.new` only; `nil` lets Claude Code choose.
    public var newSessionID: String?
    public var options: LaunchOptions
    /// Launch here instead of the derived folder (e.g. the session's folder is gone: fork in the project folder).
    public var workingDirectoryOverride: String?

    public init(agent: Agent, project: Project, mode: LaunchMode, claudeExecutable: String,
                baseEnvironment: [String: String], hookSettingsPath: String, hookSocketPath: String, hookToken: String,
                newSessionID: String? = nil, options: LaunchOptions = LaunchOptions(),
                workingDirectoryOverride: String? = nil) {
        self.agent = agent
        self.project = project
        self.mode = mode
        self.claudeExecutable = claudeExecutable
        self.baseEnvironment = baseEnvironment
        self.hookSettingsPath = hookSettingsPath
        self.hookSocketPath = hookSocketPath
        self.hookToken = hookToken
        self.newSessionID = newSessionID
        self.options = options
        self.workingDirectoryOverride = workingDirectoryOverride
    }
}

/// What `SessionManager` passes to `startProcess`: executable, argv (without argv[0]), environment, folder.
/// `claude` is exec'd directly, without a shell: no quoting involved.
public struct LaunchPlan: Equatable, Sendable {
    public var executable: String
    public var args: [String]
    public var environment: [String: String]
    public var cwd: String
    /// Variables set on purpose on top of the inherited environment (options, `extraEnv`):
    /// the ones "Copier la commande" shows.
    public var explicitEnvironmentKeys: [String]

    public init(executable: String, args: [String], environment: [String: String], cwd: String,
                explicitEnvironmentKeys: [String] = []) {
        self.executable = executable
        self.args = args
        self.environment = environment
        self.cwd = cwd
        self.explicitEnvironmentKeys = explicitEnvironmentKeys
    }

    /// "KEY=value" entries sorted by key, as `startProcess(environment:)` expects.
    public var environmentArray: [String] {
        environment.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }
    }
}

public enum LaunchError: Error, Equatable, Sendable {
    case emptyExecutable
    case relativeExecutable(String)
    case emptyProjectPath
    case relativeWorkingDirectory(String)
    /// Empty `--resume` / `--fork-session` id.
    case emptySessionID
    /// A resume id that would read as an option, or a `newSessionID` that is not a UUID.
    case invalidSessionID(String)
    /// Settings path, socket path or token missing: the session would run without state tracking.
    case missingHookSetup

    /// French text for the error banner.
    public var message: String {
        switch self {
        case .emptyExecutable: return "Chemin de claude introuvable."
        case .relativeExecutable(let p): return "Le chemin de claude doit être absolu : \(p)"
        case .emptyProjectPath: return "Le projet n'a pas de dossier."
        case .relativeWorkingDirectory(let p): return "Le dossier de lancement doit être absolu : \(p)"
        case .emptySessionID: return "Aucune session à reprendre."
        case .invalidSessionID(let id): return "Identifiant de session invalide : \(id)"
        case .missingHookSetup: return "Les hooks de l'app ne sont pas prêts."
        }
    }
}

/// Builds the exact command line of an embedded session (proposal 2.2, 3.1, 5.1). Pure.
public enum LaunchPlanner {
    public static let term = "xterm-256color"
    public static let colorTerm = "truecolor"
    public static let defaultLang = "fr_FR.UTF-8"
    /// Used only when the inherited environment has no `PATH` at all.
    public static let fallbackPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    /// Prefix that keeps a prompt from being read as an option, a subcommand or an input-mode character.
    public static let promptPrefix = "Tâche : "
    /// First characters with a meaning of their own in Claude Code's prompt (proposal 5.6, step 4;
    /// interactive-mode.md): `!` shell mode (run without approval), `/` command, `?` help, `@` path completion;
    /// `-` an option in argv.
    public static let promptLeadCharacters: Set<Character> = ["-", "!", "/", "?", "@"]
    /// Shown instead of an `extraEnv` value that looks secret in "Copier la commande".
    public static let maskedValue = "<masqué>"
    /// Upper-cased fragments of variable names whose value is not copied to the clipboard.
    static let secretNameFragments = ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL", "AUTH", "PRIVATE"]

    // Documented in https://code.claude.com/docs/en/env-vars.md.
    public static let envDisableAgentView = "CLAUDE_CODE_DISABLE_AGENT_VIEW"
    public static let envDisableNonessentialTraffic = "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
    public static let envDisableAlternateScreen = "CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN"

    /// Variables of the app itself that `extraEnv` may set.
    public static let userSettablePixelKeys: Set<String> = [HookWire.envDebug]

    /// Arguments, in order: `--settings <path>`, [`--session-id <uuid>` (`.new`)], `--name <slug>`,
    /// [`--model <m>`], `--permission-mode <mode>`, [`--worktree <name>`],
    /// [`--resume <id>` | `--continue` | `--resume <id> --fork-session`], [initial prompt, last].
    ///
    /// Folder: `.resume` / `.fork` run in the recorded `SessionRef.cwd` (the `SessionStart` folder, see
    /// `Workspace.apply(_:agent:)` for `CwdChanged`) when known, otherwise in the project folder. `--worktree` is
    /// not passed on `.resume` (Claude Code re-enters the session's worktree by itself,
    /// https://code.claude.com/docs/en/worktrees.md); whenever it is passed, the session starts from the project
    /// folder, where the worktree is created or reopened.
    public static func plan(_ r: LaunchRequest) throws -> LaunchPlan {
        let executable = r.claudeExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !executable.isEmpty else { throw LaunchError.emptyExecutable }
        guard executable.hasPrefix("/") else { throw LaunchError.relativeExecutable(executable) }
        guard !r.project.path.isEmpty else { throw LaunchError.emptyProjectPath }
        guard r.project.path.hasPrefix("/") else { throw LaunchError.relativeWorkingDirectory(r.project.path) }
        guard !r.hookSettingsPath.isEmpty, !r.hookSocketPath.isEmpty, !r.hookToken.isEmpty else {
            throw LaunchError.missingHookSetup
        }

        let worktree = nonEmpty(r.agent.worktree)
        var args = ["--settings", r.hookSettingsPath]
        if case .new = r.mode, let raw = r.newSessionID {
            guard let uuid = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) else {
                throw LaunchError.invalidSessionID(raw)
            }
            args += ["--session-id", uuid.uuidString.lowercased()]
        }
        args += ["--name", sessionName(project: r.project, agent: r.agent)]
        if let model = nonEmpty(r.agent.model) ?? nonEmpty(r.project.defaults.model) {
            args += ["--model", model]
        }
        args += ["--permission-mode", r.agent.permissionMode.rawValue]

        var cwd = r.project.path
        switch r.mode {
        case .new(let prompt):
            if let worktree { args += ["--worktree", worktree] }
            if let prompt = positionalPrompt(prompt) { args.append(prompt) }
        case .resume(let id):
            let id = try validSessionID(id)
            args += ["--resume", id]
            cwd = recordedCwd(of: id, in: r.agent) ?? r.project.path
        case .continueLast:
            if let worktree { args += ["--worktree", worktree] }
            args.append("--continue")
        case .fork(let id):
            let id = try validSessionID(id)
            if let worktree {
                args += ["--worktree", worktree]
            } else {
                cwd = recordedCwd(of: id, in: r.agent) ?? r.project.path
            }
            args += ["--resume", id, "--fork-session"]
        }
        if let override = nonEmpty(r.workingDirectoryOverride) {
            guard override.hasPrefix("/") else { throw LaunchError.relativeWorkingDirectory(override) }
            cwd = override
        }

        let (environment, explicitKeys) = environment(for: r)
        return LaunchPlan(executable: executable, args: args, environment: environment, cwd: cwd,
                          explicitEnvironmentKeys: explicitKeys)
    }

    /// Shell equivalent for "Copier la commande" (proposal 5.1): `cd <cwd> && [VAR=value…] <claude> <args>`.
    /// Only the variables set on purpose are shown; never the app's `PIXEL_*` variables, so never the token
    /// (a pasted command then reports as an external session instead of impersonating the agent). The command
    /// ends up in terminals and bug reports: values that look secret (`isSecret`) read `<masqué>`.
    public static func displayCommand(_ p: LaunchPlan) -> String {
        let keys = Array(Set(p.explicitEnvironmentKeys))
            .filter { !$0.hasPrefix("PIXEL_") && p.environment[$0] != nil }
            .sorted()
        func shown(_ key: String) -> String {
            let value = p.environment[key]!
            return isSecret(name: key, value: value) ? maskedValue : value
        }
        var words = ["cd", ShellQuote.quote(p.cwd), "&&"]
        if keys.contains(where: { !isShellIdentifier($0) }) {
            words.append("env")
            words += keys.map { ShellQuote.quote($0 + "=" + shown($0)) }
        } else {
            words += keys.map { $0 + "=" + ShellQuote.quote(shown($0)) }
        }
        words.append(ShellQuote.quote(p.executable))
        words += p.args.map(ShellQuote.quote)
        var command = words.joined(separator: " ")
        if let token = p.environment[HookWire.envToken], !token.isEmpty {
            command = command.replacingOccurrences(of: token, with: "<jeton>")
        }
        return command
    }

    /// A variable whose value should not be shown: its name contains KEY, TOKEN, SECRET, PASSWORD, CREDENTIAL,
    /// AUTH… (`ANTHROPIC_API_KEY`, `GITHUB_TOKEN`), or its value is a URL with a password (`postgres://u:p@host`).
    public static func isSecret(name: String, value: String) -> Bool {
        let upper = name.uppercased()
        if secretNameFragments.contains(where: { upper.contains($0) }) { return true }
        // scheme://user:password@host
        guard let scheme = value.range(of: "://") else { return false }
        let authority = value[scheme.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard let at = authority.lastIndex(of: "@") else { return false }
        return authority[..<at].contains(":")
    }

    /// `--name`: ASCII slug "<project>-<agent>", at most 40 characters ("api-nova"). Accents are folded.
    public static func sessionName(project: Project, agent: Agent) -> String {
        let maxLength = 40
        let agentPart = trimmedDashes(String(slug(agent.name, fallback: "agent").prefix(20)))
        let projectPart = trimmedDashes(String(slug(project.name, fallback: "projet").prefix(maxLength - 1 - agentPart.count)))
        return projectPart + "-" + agentPart
    }

    // MARK: - Pieces

    static func environment(for r: LaunchRequest) -> ([String: String], [String]) {
        var env = EnvSanitizer.sanitize(r.baseEnvironment)
        env["TERM"] = term
        env["COLORTERM"] = colorTerm
        if (env["LANG"] ?? "").isEmpty { env["LANG"] = defaultLang }
        if (env["PATH"] ?? "").isEmpty { env["PATH"] = fallbackPath }
        env[HookWire.envAgentID] = r.agent.id.description
        env[HookWire.envToken] = r.hookToken
        env[HookWire.envSocket] = r.hookSocketPath

        var explicit: [String] = []
        func set(_ key: String, _ value: String) {
            env[key] = value
            if !explicit.contains(key) { explicit.append(key) }
        }
        if r.options.disableAgentView { set(envDisableAgentView, "1") }
        if r.options.disableNonessentialTraffic { set(envDisableNonessentialTraffic, "1") }
        if r.options.forceClassicRenderer { set(envDisableAlternateScreen, "1") }
        for (key, value) in r.options.extraEnv.sorted(by: { $0.key < $1.key }) {
            guard EnvSanitizer.isValidEntry(name: key, value: value) else { continue }
            if key.hasPrefix("PIXEL_"), !userSettablePixelKeys.contains(key) { continue }
            set(key, value)
        }
        return (env, explicit)
    }

    /// The positional prompt, or `nil` when blank. NUL cannot cross `execve` and is dropped. Gets `promptPrefix`:
    /// a prompt starting with one of `promptLeadCharacters` ("-" would be read as an option; "/logout" would run
    /// the command, "!rm …" a shell command without approval), and a single word, which could be taken for a
    /// subcommand ("update", "doctor"…) or a mistyped one.
    static func positionalPrompt(_ prompt: String?) -> String? {
        guard let prompt else { return nil }
        let cleaned = prompt.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = cleaned.first else { return nil }
        if promptLeadCharacters.contains(first) || !cleaned.contains(where: { $0.isWhitespace }) {
            return promptPrefix + cleaned
        }
        return cleaned
    }

    static func validSessionID(_ id: String) throws -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LaunchError.emptySessionID }
        guard !trimmed.hasPrefix("-"), !trimmed.contains("\0") else { throw LaunchError.invalidSessionID(id) }
        return trimmed
    }

    /// Folder of the last matching `SessionRef`, when recorded and absolute.
    static func recordedCwd(of sessionID: String, in agent: Agent) -> String? {
        guard let ref = agent.sessions.last(where: { $0.sessionID == sessionID }) else { return nil }
        let cwd = ref.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        return cwd.hasPrefix("/") ? cwd : nil
    }

    static func slug(_ text: String, fallback: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars {
            if scalar.properties.generalCategory == .nonspacingMark { continue }
            let folded: String
            switch scalar {
            case "œ", "Œ": folded = "oe"
            case "æ", "Æ": folded = "ae"
            case "ß": folded = "ss"
            default: folded = String(scalar)
            }
            for s in folded.unicodeScalars {
                let v = s.value
                let isAlnum = (48...57).contains(v) || (65...90).contains(v) || (97...122).contains(v)
                guard isAlnum else {
                    pendingDash = true
                    continue
                }
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append((65...90).contains(v) ? Unicode.Scalar(v + 32)! : s)
            }
        }
        return out.isEmpty ? fallback : out
    }

    private static func trimmedDashes(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func isShellIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || (first.isASCII && first.properties.isAlphabetic) else {
            return false
        }
        return name.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil)) }
    }
}
