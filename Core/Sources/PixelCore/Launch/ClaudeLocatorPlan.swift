import Foundation

/// Where to look for the `claude` executable, in order (proposal 3.1, `ClaudeLocator`).
/// Pure: the app checks each candidate (executable file, `--version`) and keeps the first that works.
public enum ClaudeLocatorPlan {
    public static let executableName = "claude"

    /// The path from the settings, each `PATH` entry of the login shell, then the known install locations:
    /// native installer, Homebrew (Apple silicon, Intel), the legacy local install, npm's user prefix.
    /// A leading `~` is expanded; a relative override and relative or empty `PATH` entries are skipped;
    /// duplicates removed (first position kept).
    public static func candidates(override: String?, pathEnv: String?, home: String) -> [String] {
        let home = strippingTrailingSlashes(home)
        var ordered: [String] = []
        var seen: Set<String> = []
        func add(_ path: String) {
            guard path.hasPrefix("/"), seen.insert(path).inserted else { return }
            ordered.append(path)
        }

        if let override {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { add(PathNormalizer.expandTilde(trimmed, home: home)) }
        }
        for entry in (pathEnv ?? "").split(separator: ":", omittingEmptySubsequences: true) {
            let directory = strippingTrailingSlashes(PathNormalizer.expandTilde(String(entry), home: home))
            guard directory.hasPrefix("/") else { continue }
            add(directory == "/" ? "/" + executableName : directory + "/" + executableName)
        }
        add(home + "/.local/bin/claude")
        add("/opt/homebrew/bin/claude")
        add("/usr/local/bin/claude")
        add(home + "/.claude/local/claude")
        add(home + "/.npm-global/bin/claude")
        return ordered
    }

    private static func strippingTrailingSlashes(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
