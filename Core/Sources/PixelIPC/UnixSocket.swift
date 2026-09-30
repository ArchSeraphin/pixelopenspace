import Foundation

/// Identity of the process at the other end of a Unix socket connection, as reported by the kernel.
public struct PeerCredentials: Sendable, Equatable {
    public var uid: UInt32
    /// `nil` when the platform does not report it. On macOS (LOCAL_PEERPID) that includes a peer that has already
    /// closed its end, which a one-shot `pixel-hook` often has by the time the server accepts.
    public var pid: Int32?

    public init(uid: UInt32, pid: Int32?) {
        self.uid = uid
        self.pid = pid
    }
}

public enum UnixSocketError: Error, Equatable, Sendable {
    /// The path needs this many UTF-8 bytes, more than `HookWire.maxSocketPathBytes`.
    case pathTooLong(Int)
    /// Another server answers on this path.
    case addressInUse
    /// A system call failed: what was attempted, and `errno`.
    case system(String, Int32)
}
