import Foundation

/// One-shot sender used by `pixel-hook`: connect, write everything, close.
public enum UnixSocketClient {
    /// Sends `data` to the Unix stream socket at `path`. Connecting and writing share one deadline.
    /// Returns `false` on any failure (no server, timeout, path too long); never raises `SIGPIPE`.
    public static func sendOnce(_ data: Data, to path: String, deadlineMilliseconds: Int) -> Bool {
        guard path.utf8.count <= HookWire.maxSocketPathBytes else { return false }
        let deadline = Posix.deadline(afterMilliseconds: deadlineMilliseconds)
        guard case .connected(let fd) = Posix.connectUnix(path, deadline: deadline) else { return false }
        defer { Posix.closeDescriptor(fd) }
        return Posix.sendAll(fd, data, deadline: deadline)
    }
}
