import Foundation

extension HookWire {
    /// Longest default socket path used as is (proposal 3.2); a little under `maxSocketPathBytes` for safety.
    public static let preferredSocketPathBytes = 100

    /// File next to the socket holding the token, for sessions started outside the app (proposal 5.5):
    /// `pixel-hook` reads it when `PIXEL_HOOK_TOKEN` is not set. The app writes it with mode 0600.
    public static let tokenFileName = "token"

    /// `tokenFileName` in the socket's directory.
    public static func tokenPath(socketPath: String) -> String {
        guard let slash = socketPath.lastIndex(of: "/") else { return tokenFileName }
        return (slash == socketPath.startIndex ? "" : String(socketPath[..<slash])) + "/" + tokenFileName
    }

    /// The socket the app listens on, and where `pixel-hook` sends when `PIXEL_HOOK_SOCKET` is not set:
    /// `defaultSocketPath(home:)`, or `<temporaryDirectory>/pos-<uid>/hook.sock` when that path is longer than
    /// `preferredSocketPathBytes` (a very long home directory). `temporaryDirectory` is `$TMPDIR`; `/tmp` if empty.
    public static func socketPath(home: String, temporaryDirectory: String?, uid: UInt32) -> String {
        let preferred = defaultSocketPath(home: home)
        guard preferred.utf8.count > preferredSocketPathBytes else { return preferred }
        var base = temporaryDirectory ?? ""
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        if base.isEmpty || base == "/" { base = "/tmp" }
        return base + "/pos-\(uid)/hook.sock"
    }
}
