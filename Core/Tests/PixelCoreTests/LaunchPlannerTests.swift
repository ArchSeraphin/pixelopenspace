import Foundation
import Testing
@testable import PixelCore
import PixelIPC

/// Shared fixtures: the user's real layout (native installer, Herd's node with spaces in PATH).
enum LaunchFixtures {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    static let claude = "/Users/seraphin/.local/bin/claude"
    static let settingsPath = "/Users/seraphin/Library/Application Support/PixelOpenSpace/run/hooks-settings.json"
    static let socketPath = "/Users/seraphin/Library/Application Support/PixelOpenSpace/run/hook.sock"
    static let token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    static let herdNode = "/Users/seraphin/Library/Application Support/Herd/config/nvm/versions/node/v24.18.0/bin"
    static let path = "/Users/seraphin/.local/bin:\(herdNode):/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    static let sessionUUID = "3F0C7E9A-5B1D-4C62-9E0F-2A7D1B8C4E55"

    static let baseEnvironment: [String: String] = [
        "PATH": path,
        "HOME": "/Users/seraphin",
        "USER": "seraphin",
        "SHELL": "/bin/zsh",
        "LANG": "fr_FR.UTF-8",
        "TERM": "xterm-kitty",
        "TERM_PROGRAM": "ghostty",
        "CLAUDECODE": "1",
        "PWD": "/Users/seraphin",
        "SHLVL": "2",
        "PIXEL_RESOLVING_ENVIRONMENT": "1",
    ]

    static func project(path: String = "/Users/seraphin/Projets/pixel demo", name: String = "API",
                        model: String? = nil) -> Project {
        Project(name: name, path: path, hueIndex: 0, order: 0, slot: 0, defaults: AgentDefaults(model: model), createdAt: t0)
    }

    static func agent(_ project: Project, name: String = "Nova", model: String? = nil, mode: PermissionMode = .default,
                      worktree: String? = nil, sessions: [SessionRef] = []) -> Agent {
        Agent(projectID: project.id, name: name, deskIndex: 0, model: model, permissionMode: mode, worktree: worktree,
              sessions: sessions, createdAt: t0)
    }

    static func request(_ mode: LaunchMode, agent: Agent? = nil, project: Project? = nil, newSessionID: String? = nil,
                        options: LaunchOptions = LaunchOptions(), base: [String: String] = baseEnvironment) -> LaunchRequest {
        let p = project ?? self.project()
        return LaunchRequest(agent: agent ?? self.agent(p), project: p, mode: mode, claudeExecutable: claude,
                             baseEnvironment: base, hookSettingsPath: settingsPath, hookSocketPath: socketPath,
                             hookToken: token, newSessionID: newSessionID, options: options)
    }
}

@Suite struct LaunchPlannerTests {
    typealias F = LaunchFixtures

    // MARK: - Arguments

    @Test func newSessionArgumentsInDocumentedOrder() throws {
        let p = F.project(model: "sonnet")
        let a = F.agent(p, mode: .acceptEdits, worktree: "nova")
        let plan = try LaunchPlanner.plan(F.request(.new(initialPrompt: "Corrige le bug suivant"), agent: a, project: p,
                                                    newSessionID: F.sessionUUID))
        #expect(plan.executable == F.claude)
        #expect(plan.args == [
            "--settings", F.settingsPath,
            "--session-id", F.sessionUUID.lowercased(),
            "--name", "api-nova",
            "--model", "sonnet",
            "--permission-mode", "acceptEdits",
            "--worktree", "nova",
            "Corrige le bug suivant",
        ])
        #expect(plan.cwd == p.path)
    }

    @Test func minimalNewSession() throws {
        let plan = try LaunchPlanner.plan(F.request(.new(initialPrompt: nil)))
        #expect(plan.args == ["--settings", F.settingsPath, "--name", "api-nova", "--permission-mode", "default"])
    }

    @Test func agentModelOverridesProjectDefault() throws {
        let p = F.project(model: "sonnet")
        let plan = try LaunchPlanner.plan(F.request(.new(initialPrompt: nil), agent: F.agent(p, model: " opus "), project: p))
        let i = try #require(plan.args.firstIndex(of: "--model"))
        #expect(plan.args[i + 1] == "opus")
        let blank = try LaunchPlanner.plan(F.request(.new(initialPrompt: nil), agent: F.agent(p, model: "  "), project: p))
        #expect(blank.args.contains("sonnet"))
    }

    @Test func sessionIDOnlyForNewSessions() throws {
        let resume = try LaunchPlanner.plan(F.request(.resume(sessionID: "abc"), newSessionID: F.sessionUUID))
        #expect(!resume.args.contains("--session-id"))
        #expect(throws: LaunchError.invalidSessionID("not-a-uuid")) {
            try LaunchPlanner.plan(F.request(.new(initialPrompt: nil), newSessionID: "not-a-uuid"))
        }
    }

    @Test func resumeContinueAndForkFlags() throws {
        let resume = try LaunchPlanner.plan(F.request(.resume(sessionID: " s-1 ")))
        #expect(Array(resume.args.suffix(2)) == ["--resume", "s-1"])
        let cont = try LaunchPlanner.plan(F.request(.continueLast))
        #expect(cont.args.last == "--continue")
        #expect(!cont.args.contains("--resume"))
        let fork = try LaunchPlanner.plan(F.request(.fork(fromSessionID: "s-1")))
        #expect(Array(fork.args.suffix(3)) == ["--resume", "s-1", "--fork-session"])
    }

    @Test func worktreeIsNotPassedOnResume() throws {
        let p = F.project()
        let a = F.agent(p, worktree: "nova")
        #expect(!(try LaunchPlanner.plan(F.request(.resume(sessionID: "s"), agent: a, project: p)).args.contains("--worktree")))
        let cont = try LaunchPlanner.plan(F.request(.continueLast, agent: a, project: p))
        #expect(Array(cont.args.suffix(3)) == ["--worktree", "nova", "--continue"])
        let fork = try LaunchPlanner.plan(F.request(.fork(fromSessionID: "s"), agent: a, project: p))
        #expect(Array(fork.args.suffix(5)) == ["--worktree", "nova", "--resume", "s", "--fork-session"])
    }

    @Test func settingsComeFirstAndPermissionModeIsAlwaysPassed() throws {
        for mode in PermissionMode.allCases {
            let p = F.project()
            let plan = try LaunchPlanner.plan(F.request(.continueLast, agent: F.agent(p, mode: mode), project: p))
            #expect(Array(plan.args.prefix(2)) == ["--settings", F.settingsPath])
            let i = try #require(plan.args.firstIndex(of: "--permission-mode"))
            #expect(plan.args[i + 1] == mode.rawValue)
        }
    }

    // MARK: - Initial prompt

    @Test func promptIsLastAndProtected() throws {
        func prompt(_ text: String?) throws -> String? {
            let plan = try LaunchPlanner.plan(F.request(.new(initialPrompt: text)))
            return plan.args.count > 6 ? plan.args.last : nil
        }
        #expect(try prompt("  Corrige le bug\nsuivant  ") == "Corrige le bug\nsuivant")
        #expect(try prompt("--help moi") == "Tâche : --help moi")
        #expect(try prompt("-v est cassé") == "Tâche : -v est cassé")
        #expect(try prompt("update") == "Tâche : update")
        #expect(try prompt("doctor") == "Tâche : doctor")
        // Proposal 5.6, step 4: a slash command, shell mode (run without approval), help or path completion.
        #expect(try prompt("/logout puis relance") == "Tâche : /logout puis relance")
        #expect(try prompt("  /goal finir la migration") == "Tâche : /goal finir la migration")
        #expect(try prompt("!rm -rf build") == "Tâche : !rm -rf build")
        #expect(try prompt("? quelles commandes") == "Tâche : ? quelles commandes")
        #expect(try prompt("@src/app.ts relis ce fichier") == "Tâche : @src/app.ts relis ce fichier")
        #expect(try prompt("Relis @src/app.ts puis /goal") == "Relis @src/app.ts puis /goal")
        #expect(try prompt("a\0b c") == "ab c")
        #expect(try prompt("   \n ") == nil)
        #expect(try prompt(nil) == nil)
    }

    // MARK: - Working directory

    @Test func resumeRunsInTheRecordedFolder() throws {
        let p = F.project()
        let worktree = p.path + "/.claude/worktrees/nova"
        let sessions = [
            SessionRef(sessionID: "old", cwd: "/Users/seraphin/ailleurs", startedAt: F.t0, source: .startup),
            SessionRef(sessionID: "s1", cwd: worktree, startedAt: F.t0, source: .startup),
            SessionRef(sessionID: "empty", cwd: "", startedAt: F.t0, source: .startup),
            SessionRef(sessionID: "relative", cwd: "src", startedAt: F.t0, source: .startup),
        ]
        let a = F.agent(p, sessions: sessions)
        #expect(try LaunchPlanner.plan(F.request(.resume(sessionID: "s1"), agent: a, project: p)).cwd == worktree)
        #expect(try LaunchPlanner.plan(F.request(.fork(fromSessionID: "old"), agent: a, project: p)).cwd == "/Users/seraphin/ailleurs")
        #expect(try LaunchPlanner.plan(F.request(.resume(sessionID: "empty"), agent: a, project: p)).cwd == p.path)
        #expect(try LaunchPlanner.plan(F.request(.resume(sessionID: "relative"), agent: a, project: p)).cwd == p.path)
        #expect(try LaunchPlanner.plan(F.request(.resume(sessionID: "unknown"), agent: a, project: p)).cwd == p.path)
        #expect(try LaunchPlanner.plan(F.request(.continueLast, agent: a, project: p)).cwd == p.path)
        #expect(try LaunchPlanner.plan(F.request(.new(initialPrompt: nil), agent: a, project: p)).cwd == p.path)
    }

    @Test func forkWithWorktreeStartsFromTheProject() throws {
        let p = F.project()
        let a = F.agent(p, worktree: "copie",
                        sessions: [SessionRef(sessionID: "s1", cwd: "/elsewhere", startedAt: F.t0, source: .startup)])
        #expect(try LaunchPlanner.plan(F.request(.fork(fromSessionID: "s1"), agent: a, project: p)).cwd == p.path)
    }

    @Test func workingDirectoryOverride() throws {
        var r = F.request(.fork(fromSessionID: "s1"))
        r.workingDirectoryOverride = "/Users/seraphin/Projets/autre"
        #expect(try LaunchPlanner.plan(r).cwd == "/Users/seraphin/Projets/autre")
        r.workingDirectoryOverride = "relatif"
        #expect(throws: LaunchError.relativeWorkingDirectory("relatif")) { try LaunchPlanner.plan(r) }
    }

    // MARK: - Validation

    @Test func invalidRequestsThrow() {
        var r = F.request(.new(initialPrompt: nil))
        r.claudeExecutable = "  "
        #expect(throws: LaunchError.emptyExecutable) { try LaunchPlanner.plan(r) }
        r.claudeExecutable = "claude"
        #expect(throws: LaunchError.relativeExecutable("claude")) { try LaunchPlanner.plan(r) }

        r = F.request(.new(initialPrompt: nil), project: F.project(path: ""))
        #expect(throws: LaunchError.emptyProjectPath) { try LaunchPlanner.plan(r) }
        r = F.request(.new(initialPrompt: nil), project: F.project(path: "dev/api"))
        #expect(throws: LaunchError.relativeWorkingDirectory("dev/api")) { try LaunchPlanner.plan(r) }

        #expect(throws: LaunchError.emptySessionID) { try LaunchPlanner.plan(F.request(.resume(sessionID: " "))) }
        #expect(throws: LaunchError.emptySessionID) { try LaunchPlanner.plan(F.request(.fork(fromSessionID: ""))) }
        #expect(throws: LaunchError.invalidSessionID("--help")) { try LaunchPlanner.plan(F.request(.resume(sessionID: "--help"))) }

        r = F.request(.continueLast)
        r.hookToken = ""
        #expect(throws: LaunchError.missingHookSetup) { try LaunchPlanner.plan(r) }
        #expect(!LaunchError.missingHookSetup.message.isEmpty)
    }

    // MARK: - Environment

    @Test func environmentIsSanitizedAndCompleted() throws {
        let r = F.request(.new(initialPrompt: nil))
        let env = try LaunchPlanner.plan(r).environment
        #expect(env["PATH"] == F.path)
        #expect(env["HOME"] == "/Users/seraphin")
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["LANG"] == "fr_FR.UTF-8")
        #expect(env[HookWire.envAgentID] == r.agent.id.description)
        #expect(env[HookWire.envToken] == F.token)
        #expect(env[HookWire.envSocket] == F.socketPath)
        #expect(env["CLAUDE_CODE_DISABLE_AGENT_VIEW"] == "1")
        for removed in ["TERM_PROGRAM", "CLAUDECODE", "PWD", "SHLVL", LoginShellEnvironment.resolvingFlag] {
            #expect(env[removed] == nil)
        }
        #expect(env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == nil)
        #expect(env["CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN"] == nil)
    }

    @Test func langAndPathDefaults() throws {
        let env = try LaunchPlanner.plan(F.request(.continueLast, base: ["LANG": "", "HOME": "/Users/seraphin"])).environment
        #expect(env["LANG"] == "fr_FR.UTF-8")
        #expect(env["PATH"] == LaunchPlanner.fallbackPath)
        let english = try LaunchPlanner.plan(F.request(.continueLast, base: ["LANG": "en_US.UTF-8"])).environment
        #expect(english["LANG"] == "en_US.UTF-8")
    }

    @Test func optionSwitches() throws {
        let options = LaunchOptions(disableAgentView: false, forceClassicRenderer: true, disableNonessentialTraffic: true)
        let env = try LaunchPlanner.plan(F.request(.continueLast, options: options)).environment
        #expect(env["CLAUDE_CODE_DISABLE_AGENT_VIEW"] == nil)
        #expect(env["CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN"] == "1")
        #expect(env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1")
    }

    @Test func optionsFromSettings() {
        var s = AppSettings()
        #expect(LaunchOptions(settings: s) == LaunchOptions())
        s.disableAgentViewInEmbedded = false
        s.forceClassicRenderer = true
        s.disableNonessentialTraffic = true
        s.extraEnv = ["A": "1"]
        #expect(LaunchOptions(settings: s) == LaunchOptions(disableAgentView: false, forceClassicRenderer: true,
                                                            disableNonessentialTraffic: true, extraEnv: ["A": "1"]))
    }

    @Test func extraEnvCannotHijackRouting() throws {
        let extra = [
            HookWire.envAgentID: "someone-else", HookWire.envToken: "stolen", HookWire.envSocket: "/tmp/evil.sock",
            HookWire.envDebug: "1", "ANTHROPIC_LOG": "debug", "TERM": "xterm", "BAD=KEY": "x", "": "y", "NUL": "a\0b",
        ]
        let r = F.request(.continueLast, options: LaunchOptions(extraEnv: extra))
        let plan = try LaunchPlanner.plan(r)
        #expect(plan.environment[HookWire.envAgentID] == r.agent.id.description)
        #expect(plan.environment[HookWire.envToken] == F.token)
        #expect(plan.environment[HookWire.envSocket] == F.socketPath)
        #expect(plan.environment[HookWire.envDebug] == "1")
        #expect(plan.environment["ANTHROPIC_LOG"] == "debug")
        #expect(plan.environment["TERM"] == "xterm")
        #expect(plan.environment["BAD=KEY"] == nil)
        #expect(plan.environment[""] == nil)
        #expect(plan.environment["NUL"] == nil)
    }

    @Test func environmentArrayIsSortedAndComplete() throws {
        let plan = try LaunchPlanner.plan(F.request(.continueLast))
        #expect(plan.environmentArray == plan.environmentArray.sorted())
        #expect(plan.environmentArray.count == plan.environment.count)
        #expect(plan.environmentArray.contains("PATH=" + F.path))
    }

    @Test func planIsDeterministic() throws {
        let r = F.request(.new(initialPrompt: "Écris les tests"), newSessionID: F.sessionUUID,
                          options: LaunchOptions(extraEnv: ["B": "2", "A": "1"]))
        let first = try LaunchPlanner.plan(r)
        for _ in 0..<5 { #expect(try LaunchPlanner.plan(r) == first) }
    }

    // MARK: - Copy the command

    @Test func displayCommandNeverContainsTheToken() throws {
        let r = F.request(.new(initialPrompt: "Corrige l'erreur"), newSessionID: F.sessionUUID,
                          options: LaunchOptions(forceClassicRenderer: true, extraEnv: [HookWire.envDebug: "1"]))
        let command = LaunchPlanner.displayCommand(try LaunchPlanner.plan(r))
        #expect(!command.contains(F.token))
        #expect(!command.contains("PIXEL_"))
        #expect(command.hasPrefix("cd '/Users/seraphin/Projets/pixel demo' && "))
        #expect(command.contains("CLAUDE_CODE_DISABLE_AGENT_VIEW=1 CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 /Users/seraphin/.local/bin/claude"))
        #expect(command.contains("--settings '\(F.settingsPath)'"))
        #expect(command.hasSuffix(" 'Corrige l'\\''erreur'"))
        #expect(!command.contains("PATH="))
    }

    @Test func displayCommandUsesEnvForUnusualNames() throws {
        let r = F.request(.continueLast, options: LaunchOptions(disableAgentView: false, extraEnv: ["MY-VAR": "a b"]))
        let command = LaunchPlanner.displayCommand(try LaunchPlanner.plan(r))
        #expect(command.contains("&& env 'MY-VAR=a b' /Users/seraphin/.local/bin/claude"))
    }

    @Test func displayCommandMasksSecretValues() throws {
        let extra = ["ANTHROPIC_API_KEY": "sk-ant-api03-secret", "GITHUB_TOKEN": "ghp_secret",
                     "AWS_SECRET_ACCESS_KEY": "aws-secret", "DB_PASSWORD": "hunter2",
                     "DATABASE_URL": "postgres://app:hunter3@db.local:5432/app", "DOCS_URL": "https://example.com/a@b",
                     "EDITOR": "vim"]
        let r = F.request(.continueLast, options: LaunchOptions(disableAgentView: false, extraEnv: extra))
        let plan = try LaunchPlanner.plan(r)
        // The session itself still gets the real values.
        #expect(plan.environment["GITHUB_TOKEN"] == "ghp_secret")
        let command = LaunchPlanner.displayCommand(plan)
        for secret in ["sk-ant-api03-secret", "ghp_secret", "aws-secret", "hunter2", "hunter3"] {
            #expect(!command.contains(secret))
        }
        #expect(command.contains("ANTHROPIC_API_KEY='<masqué>' "))
        #expect(command.contains("DATABASE_URL='<masqué>' "))
        #expect(command.contains("DOCS_URL=https://example.com/a@b "))
        #expect(command.contains("EDITOR=vim "))
    }

    @Test func secretNames() {
        #expect(LaunchPlanner.isSecret(name: "OPENAI_API_KEY", value: "x"))
        #expect(LaunchPlanner.isSecret(name: "npm_config_authToken", value: "x"))
        #expect(LaunchPlanner.isSecret(name: "SSH_PRIVATE_KEY_PATH", value: "/k"))
        #expect(LaunchPlanner.isSecret(name: "REDIS", value: "redis://:motdepasse@localhost:6379"))
        #expect(!LaunchPlanner.isSecret(name: "REDIS", value: "redis://localhost:6379"))
        #expect(!LaunchPlanner.isSecret(name: "MAIL", value: "moi@example.com"))
        #expect(!LaunchPlanner.isSecret(name: "CLAUDE_CODE_DISABLE_AGENT_VIEW", value: "1"))
    }

    @Test func displayCommandMasksALeakedToken() {
        let plan = LaunchPlan(executable: "/bin/claude", args: ["--name", "x" + F.token], environment: [HookWire.envToken: F.token],
                              cwd: "/tmp")
        #expect(!LaunchPlanner.displayCommand(plan).contains(F.token))
    }

    // MARK: - Session name

    @Test func sessionNameSlug() {
        func name(_ project: String, _ agent: String) -> String {
            let p = F.project(name: project)
            return LaunchPlanner.sessionName(project: p, agent: F.agent(p, name: agent))
        }
        #expect(name("API", "Nova") == "api-nova")
        #expect(name("Pixel Open Space", "Zéphyr") == "pixel-open-space-zephyr")
        #expect(name("  Cœur & Âme!! ", "Écume") == "coeur-ame-ecume")
        #expect(name("日本", "…") == "projet-agent")
        let long = name(String(repeating: "très long nom de projet ", count: 5), "Frimousse")
        #expect(long.count <= 40)
        #expect(long.hasSuffix("-frimousse"))
        #expect(!long.contains("--"))
        #expect(long.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        #expect(name("API", String(repeating: "x", count: 60)).count <= 40)
    }
}
