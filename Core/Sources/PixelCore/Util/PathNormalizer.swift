import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One spelling per folder, so that a project added twice (typed path, dropped folder, symlink) is recognised,
/// and so that paths compare equal to the `cwd` Claude Code reports in its hooks.
public enum PathNormalizer {
    /// `~` expanded, made absolute against `currentDirectory`, standardized (`.`, `..`, `//`), symlinks resolved
    /// on the longest existing prefix (the rest is kept as written), no trailing slash except for "/".
    /// Reads the file system (symlinks); `standardize` is the pure part.
    public static func normalize(_ path: String, home: String, currentDirectory: String = "/") -> String {
        var expanded = expandTilde(path.trimmingCharacters(in: .newlines), home: home)
        if !expanded.hasPrefix("/") {
            expanded = standardize(currentDirectory) + "/" + expanded
        }
        return resolvingSymlinks(standardize(expanded))
    }

    /// "~" → `home`, "~/x" → `home`/x. "~user" is left alone.
    public static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst() }
        return path
    }

    /// Lexical clean-up of an absolute path: collapses duplicate slashes, removes "." and resolves ".."
    /// (never above "/"), strips the trailing slash. Relative paths stay relative. No file system access.
    public static func standardize(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else if !absolute {
                    components.append(component)
                }
            default:
                components.append(component)
            }
        }
        let joined = components.joined(separator: "/")
        if absolute { return "/" + joined }
        return joined.isEmpty ? "." : joined
    }

    /// `realpath(3)` on the longest existing prefix of a standardized absolute path.
    static func resolvingSymlinks(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var existing = path
        var missing: [String] = []
        while true {
            if let real = realPath(existing) {
                let resolved = missing.isEmpty ? real : (real == "/" ? "" : real) + "/" + missing.reversed().joined(separator: "/")
                return standardize(resolved)
            }
            guard existing != "/", let slash = existing.lastIndex(of: "/") else { return path }
            missing.append(String(existing[existing.index(after: slash)...]))
            existing = slash == existing.startIndex ? "/" : String(existing[..<slash])
        }
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
