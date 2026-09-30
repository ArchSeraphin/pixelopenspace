import Foundation

/// Cleans the environment inherited from the login shell before it is given to an embedded `claude`
/// (proposal 3.1, "Environnement").
///
/// Removed: variables that describe another terminal (Claude Code adapts to the terminal it believes it runs in,
/// and `/terminal-setup` would write into that terminal's configuration), variables Claude Code sets for its own
/// child processes (a session launched from one would look nested: excluded from `--resume`, routed as a
/// subprocess), shell bookkeeping, dynamic-linker overrides and the app's own `PIXEL_*` variables.
/// Everything else is kept verbatim, `PATH` entries with spaces included.
public enum EnvSanitizer {
    /// Exact names removed.
    public static let removedNames: Set<String> = [
        // Terminal identity (`TERM_PROGRAM*` is a prefix below). The PTY is neither tmux nor screen.
        "TERM_SESSION_ID", "LC_TERMINAL", "LC_TERMINAL_VERSION", "COLORFGBG", "TMUX", "TMUX_PANE", "STY",
        // Set by Claude Code in the processes it spawns (https://code.claude.com/docs/en/env-vars.md).
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_JOB_DIR", "CLAUDE_PID",
        // macOS launch bookkeeping of the parent app.
        "__CFBundleIdentifier", "XPC_SERVICE_NAME",
        // Shell bookkeeping: meaningless for a process started with its own working directory.
        "PWD", "OLDPWD", "SHLVL", "_",
    ]

    /// Name prefixes removed. `PIXEL_` covers `PIXEL_RESOLVING_ENVIRONMENT` and stale hook variables.
    public static let removedPrefixes: [String] = [
        "TERM_PROGRAM", "ITERM_", "KITTY_", "GHOSTTY_", "WEZTERM_", "ALACRITTY_", "DYLD_", "PIXEL_",
    ]

    public static func shouldRemove(_ name: String) -> Bool {
        removedNames.contains(name) || removedPrefixes.contains { name.hasPrefix($0) }
    }

    /// A pair `execve` can carry: a non-empty name without `=`, no NUL byte anywhere.
    public static func isValidEntry(name: String, value: String) -> Bool {
        !name.isEmpty && !name.contains("=") && !name.contains("\0") && !value.contains("\0")
    }

    public static func sanitize(_ environment: [String: String]) -> [String: String] {
        environment.filter { isValidEntry(name: $0.key, value: $0.value) && !shouldRemove($0.key) }
    }
}
