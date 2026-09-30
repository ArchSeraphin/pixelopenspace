/// POSIX shell quoting: wraps in single quotes, each `'` becoming `'\''`.
/// Used for hook commands (the app bundle path contains spaces) and "Copy the command".
public enum ShellQuote {
    public static func quote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/-_.,:=@%+".contains($0)) }) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func join(_ args: [String]) -> String {
        args.map(quote).joined(separator: " ")
    }
}
