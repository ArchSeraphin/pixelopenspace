import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Thin POSIX helpers shared by the socket server, the client and `ProcessAncestry` (Darwin + Glibc).
enum Posix {
    #if canImport(Darwin)
    static let streamType = SOCK_STREAM
    /// Darwin has no `MSG_NOSIGNAL`: sockets get `SO_NOSIGPIPE` instead (see `makeUnixSocket`).
    static let sendFlags: Int32 = 0
    #else
    static let streamType = Int32(SOCK_STREAM.rawValue)
    static let sendFlags = Int32(MSG_NOSIGNAL)
    #endif

    // MARK: - Descriptors

    static func closeDescriptor(_ fd: Int32) {
        _ = close(fd)
    }

    static func setCloseOnExec(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    static func setNonBlocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    /// Never raises `SIGPIPE` on Darwin; Linux passes `MSG_NOSIGNAL` on every send instead.
    static func disableSigPipe(_ fd: Int32) {
        #if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// A close-on-exec `AF_UNIX` stream socket, so it never leaks into the `claude` processes the app spawns.
    static func makeUnixSocket() -> Int32? {
        #if canImport(Darwin)
        let fd = socket(AF_UNIX, streamType, 0)
        #else
        let fd = socket(AF_UNIX, streamType | Int32(SOCK_CLOEXEC.rawValue), 0)
        #endif
        guard fd >= 0 else { return nil }
        setCloseOnExec(fd)
        disableSigPipe(fd)
        return fd
    }

    /// A connected pair of close-on-exec, no-SIGPIPE stream sockets.
    static func makeSocketPair() -> (Int32, Int32)? {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, streamType, 0, &fds) == 0 else { return nil }
        for fd in fds {
            setCloseOnExec(fd)
            disableSigPipe(fd)
        }
        return (fds[0], fds[1])
    }

    // MARK: - Addresses

    /// Calls `body` with a `sockaddr_un` for `path`; `nil` when the path is empty, contains NUL or does not fit.
    static func withUnixAddress<R>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R? {
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity, !bytes.contains(0) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }

    // MARK: - Time and polling

    /// Monotonic deadline `milliseconds` from now.
    static func deadline(afterMilliseconds milliseconds: Int) -> UInt64 {
        HookWire.monotonicNanos() + UInt64(max(0, milliseconds)) * 1_000_000
    }

    /// Milliseconds left before `deadline`, rounded up; 0 once it has passed.
    static func remainingMilliseconds(until deadline: UInt64) -> Int32 {
        let now = HookWire.monotonicNanos()
        guard deadline > now else { return 0 }
        return Int32(clamping: (deadline - now + 999_999) / 1_000_000)
    }

    enum PollOutcome: Equatable {
        /// The index of the first descriptor with any event (including error or hang-up).
        case ready(Int)
        case timedOut
        case failed(Int32)
    }

    /// Waits until one of `fds` has `events` (or an error), or until `deadline` (`nil`: no deadline). EINTR-safe.
    static func wait(_ fds: [Int32], for events: Int16, until deadline: UInt64?) -> PollOutcome {
        var entries = fds.map { pollfd(fd: $0, events: events, revents: 0) }
        while true {
            let timeout: Int32 = deadline.map(remainingMilliseconds(until:)) ?? -1
            let rc = poll(&entries, nfds_t(entries.count), timeout)
            if rc > 0, let index = entries.firstIndex(where: { $0.revents != 0 }) {
                return .ready(index)
            }
            if rc == 0 {
                if let deadline, HookWire.monotonicNanos() < deadline { continue }
                return .timedOut
            }
            if rc < 0, errno != EINTR { return .failed(errno) }
        }
    }

    static func sleep(milliseconds: Int32) {
        _ = poll(nil, 0, milliseconds)
    }

    // MARK: - Connect and send

    enum ConnectOutcome {
        case connected(Int32)
        case failed(Int32)
    }

    /// Non-blocking connect to the Unix socket at `path`, retried until `deadline`. The returned descriptor
    /// is non-blocking; the caller closes it.
    static func connectUnix(_ path: String, deadline: UInt64) -> ConnectOutcome {
        guard let fd = makeUnixSocket() else { return .failed(errno) }
        guard setNonBlocking(fd) else {
            let code = errno
            close(fd)
            return .failed(code)
        }
        while true {
            guard let rc = withUnixAddress(path, { connect(fd, $0, $1) }) else {
                close(fd)
                return .failed(ENAMETOOLONG)
            }
            if rc == 0 { return .connected(fd) }
            let code = errno
            switch code {
            case EISCONN:
                return .connected(fd)
            case EINPROGRESS, EINTR, EALREADY:
                // The connection completes asynchronously: wait for writability, then read its status.
                switch wait([fd], for: Int16(POLLOUT), until: deadline) {
                case .ready:
                    var status: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    if getsockopt(fd, SOL_SOCKET, SO_ERROR, &status, &length) == 0, status == 0 {
                        return .connected(fd)
                    }
                    close(fd)
                    return .failed(status != 0 ? status : errno)
                case .timedOut:
                    close(fd)
                    return .failed(ETIMEDOUT)
                case .failed(let error):
                    close(fd)
                    return .failed(error)
                }
            case EAGAIN:
                // Linux: the listener's backlog is full. Retry shortly, within the deadline.
                guard remainingMilliseconds(until: deadline) > 0 else {
                    close(fd)
                    return .failed(ETIMEDOUT)
                }
                sleep(milliseconds: 1)
            default:
                close(fd)
                return .failed(code)
            }
        }
    }

    /// Writes all of `data` to the non-blocking `fd` before `deadline`. Never raises `SIGPIPE`.
    static func sendAll(_ fd: Int32, _ data: Data, deadline: UInt64) -> Bool {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = send(fd, base + offset, buffer.count - offset, sendFlags)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                guard written < 0, errno == EAGAIN else { return false }
                guard case .ready = wait([fd], for: Int16(POLLOUT), until: deadline) else { return false }
            }
            return true
        }
    }

    // MARK: - Files

    /// Reads a small file (such as `/proc/<pid>/stat`, whose reported size is 0) with plain `read(2)`.
    static func readSmallFile(_ path: String, limit: Int = 1 << 16) -> Data? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while data.count < limit {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: chunk[0..<min(count, limit - data.count)])
            } else if count == 0 {
                break
            } else if errno != EINTR {
                return nil
            }
        }
        return data
    }

    /// The directory part of `path` (`""` when there is none), ignoring trailing slashes.
    static func parentDirectory(of path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return "" }
        if slash == trimmed.startIndex { return "/" }
        return String(trimmed[..<slash])
    }

    static func isSocket(_ mode: mode_t) -> Bool {
        // S_IFMT / S_IFSOCK: same values on Darwin and Linux.
        (UInt32(mode) & 0o170000) == 0o140000
    }

    static func isDirectory(_ mode: mode_t) -> Bool {
        (UInt32(mode) & 0o170000) == 0o040000
    }
}
