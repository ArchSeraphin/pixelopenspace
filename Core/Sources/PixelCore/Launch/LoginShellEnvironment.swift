import Foundation

/// Reads the environment of the user's login shell, the way VS Code does (proposal 3.1, `ClaudeLocator` step 3).
///
/// An app started from the Dock gets launchd's minimal environment, without the `PATH` set in `~/.zprofile` or
/// `~/.zshrc` (Homebrew, nvm, Herd…). The app runs `command(shell:marker:)` with stdin on `/dev/null`, a deadline,
/// and `resolvingFlag=1` in its environment (so rc files can skip heavy work), then `parse(_:marker:)` on stdout.
public enum LoginShellEnvironment {
    /// Set to `1` while the shell runs; stripped again by `EnvSanitizer` (it starts with `PIXEL_`).
    public static let resolvingFlag = "PIXEL_RESOLVING_ENVIRONMENT"

    /// Shell used when the account's shell is unknown: the macOS default.
    public static let fallbackShell = "/bin/zsh"

    /// Interactive login shell printing `marker`, the NUL-separated environment, then `marker` again.
    ///
    /// The marker is printed in two halves, so it never appears whole in the command text: a shell tracing its
    /// commands (`set -x` in an rc file) cannot fake it. sh, bash, zsh and fish accept `-i -l -c`;
    /// csh and tcsh accept `-l` only alone, but read their rc files for every shell, so they get `-c` alone.
    /// `marker` should be random letters and digits.
    public static func command(shell: String, marker: String) -> (executable: String, arguments: [String]) {
        let trimmed = shell.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = trimmed.hasPrefix("/") ? trimmed : fallbackShell
        let half = marker.index(marker.startIndex, offsetBy: marker.count / 2)
        let printMarker = "printf '%s%s' " + ShellQuote.quote(String(marker[..<half])) + " "
            + ShellQuote.quote(String(marker[half...]))
        let script = printMarker + "; /usr/bin/env -0; " + printMarker
        let name = executable.split(separator: "/").last.map(String.init) ?? ""
        if name == "csh" || name == "tcsh" {
            return (executable, ["-c", script])
        }
        return (executable, ["-i", "-l", "-c", script])
    }

    /// The variables printed between the first two occurrences of `marker` (rc files may print noise before
    /// and after). Entries are split on NUL, then at the first `=`; malformed or non-UTF-8 entries are skipped.
    /// `nil` when the markers are missing or nothing could be read.
    public static func parse(_ output: Data, marker: String) -> [String: String]? {
        let bytes = [UInt8](output)
        let needle = [UInt8](marker.utf8)
        guard !needle.isEmpty,
              let first = firstIndex(of: needle, in: bytes, from: 0),
              let second = firstIndex(of: needle, in: bytes, from: first + needle.count)
        else { return nil }

        var environment: [String: String] = [:]
        for entry in bytes[(first + needle.count)..<second].split(separator: 0, omittingEmptySubsequences: true) {
            guard let equals = entry.firstIndex(of: UInt8(ascii: "=")), equals > entry.startIndex,
                  let name = String(bytes: entry[entry.startIndex..<equals], encoding: .utf8),
                  let value = String(bytes: entry[(equals + 1)...], encoding: .utf8)
            else { continue }
            environment[name] = value
        }
        return environment.isEmpty ? nil : environment
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard needle.count <= haystack.count, start <= haystack.count - needle.count else { return nil }
        var i = start
        while i <= haystack.count - needle.count {
            if haystack[i] == needle[0], haystack[i..<(i + needle.count)].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }
}
