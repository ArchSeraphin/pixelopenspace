import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Unix stream socket server for the `pixel-hook` wire (`HookWire`): one message per connection,
/// terminated by "\n" or by the end of the connection.
///
/// Connections are accepted and read on a dedicated thread, one at a time, each within a 1 s budget.
/// Peers running as another user, messages over `HookWire.maxMessageBytes` and incomplete messages are
/// dropped without calling back. `onMessage` runs on that thread: callers hop to their own isolation.
public final class UnixSocketServer: @unchecked Sendable {
    public let path: String
    /// Permissions of the socket file.
    public let mode: UInt16

    /// Time a peer has to send its whole message, from `accept`.
    static let receiveTimeoutMilliseconds = 1000
    static let backlog: Int32 = 64

    private struct Running {
        /// Our end of the wake-up socket pair: closing it stops the accept thread.
        let wakeFD: Int32
        let thread: Thread
        let finished: DispatchSemaphore
        /// The socket file we bound, so `stop()` never unlinks another server's socket.
        let identity: FileIdentity?
    }

    struct FileIdentity: Equatable {
        var device: UInt64
        var inode: UInt64
    }

    private let lock = NSLock()
    /// Guarded by `lock`.
    private var running: Running?

    public init(path: String, mode: UInt16 = 0o600) {
        self.path = path
        self.mode = mode
    }

    deinit {
        stop()
    }

    /// Binds and starts accepting.
    ///
    /// Creates missing parent directories with mode 0700 (existing ones are left as they are). A socket file
    /// left by a dead server is removed; if a server answers on `path`, throws `.addressInUse`.
    public func start(onMessage: @escaping @Sendable (Data, PeerCredentials) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard running == nil else { throw UnixSocketError.system("already started", EALREADY) }

        let byteCount = path.utf8.count
        guard byteCount <= HookWire.maxSocketPathBytes else { throw UnixSocketError.pathTooLong(byteCount) }
        guard byteCount > 0, !path.utf8.contains(0) else { throw UnixSocketError.system("invalid path", EINVAL) }
        try Self.createDirectories(Posix.parentDirectory(of: path))
        try Self.removeStaleSocket(at: path)

        guard let listenFD = Posix.makeUnixSocket() else { throw UnixSocketError.system("socket", errno) }
        let bound = Posix.withUnixAddress(path) { bind(listenFD, $0, $1) } ?? -1
        guard bound == 0 else {
            let code = errno
            Posix.closeDescriptor(listenFD)
            throw code == EADDRINUSE ? UnixSocketError.addressInUse : UnixSocketError.system("bind", code)
        }
        let identity = Self.identity(of: path)
        func abandon(_ call: String, _ code: Int32) -> UnixSocketError {
            Posix.closeDescriptor(listenFD)
            if let identity, Self.identity(of: path) == identity { unlink(path) }
            return .system(call, code)
        }
        guard chmod(path, mode_t(mode)) == 0 else { throw abandon("chmod", errno) }
        guard listen(listenFD, Self.backlog) == 0 else { throw abandon("listen", errno) }
        guard Posix.setNonBlocking(listenFD) else { throw abandon("fcntl", errno) }
        guard let pair = Posix.makeSocketPair() else { throw abandon("socketpair", errno) }
        let (wakeFD, loopWakeFD) = pair

        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            Self.acceptLoop(listenFD: listenFD, wakeFD: loopWakeFD, onMessage: onMessage)
            finished.signal()
        }
        thread.name = "PixelIPC.UnixSocketServer"
        running = Running(wakeFD: wakeFD, thread: thread, finished: finished, identity: identity)
        thread.start()
    }

    /// Stops accepting, waits for the accept thread to finish (unless called from `onMessage`), and removes
    /// the socket file. Idempotent; `start` may be called again afterwards.
    public func stop() {
        lock.lock()
        let state = running
        running = nil
        lock.unlock()
        guard let state else { return }

        // New clients now fail with ENOENT instead of waiting in the backlog.
        if let identity = state.identity, Self.identity(of: path) == identity {
            unlink(path)
        }
        // The loop's end of the pair becomes readable (EOF): the thread returns and closes its descriptors.
        Posix.closeDescriptor(state.wakeFD)
        if Thread.current !== state.thread {
            state.finished.wait()
        }
    }

    // MARK: - Accept thread

    private enum Received {
        case message(Data)
        case dropped
        case stopping
    }

    private static func acceptLoop(listenFD: Int32, wakeFD: Int32,
                                   onMessage: @Sendable (Data, PeerCredentials) -> Void) {
        defer {
            Posix.closeDescriptor(listenFD)
            Posix.closeDescriptor(wakeFD)
        }
        let ownUID = getuid()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            switch Posix.wait([listenFD, wakeFD], for: Int16(POLLIN), until: nil) {
            case .ready(0): break
            case .failed(let code) where code == ENOMEM || code == EAGAIN:
                Posix.sleep(milliseconds: 50)
                continue
            case .ready, .failed: return
            case .timedOut: continue
            }
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else {
                switch errno {
                case EINTR, EAGAIN, ECONNABORTED, EPROTO:
                    continue
                case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                    // Out of descriptors or memory: back off instead of spinning.
                    Posix.sleep(milliseconds: 50)
                    continue
                default:
                    return
                }
            }
            Posix.setCloseOnExec(client)
            Posix.disableSigPipe(client)
            let outcome: Received
            if let peer = peerCredentials(client), peer.uid == ownUID, Posix.setNonBlocking(client) {
                outcome = receive(client, wakeFD: wakeFD, buffer: &buffer)
                if case .message(let data) = outcome, !data.isEmpty {
                    Posix.closeDescriptor(client)
                    onMessage(data, peer)
                    continue
                }
            } else {
                outcome = .dropped
            }
            Posix.closeDescriptor(client)
            if case .stopping = outcome { return }
        }
    }

    /// Reads one message: bytes up to the first "\n" (excluded), or up to the end of the connection.
    private static func receive(_ fd: Int32, wakeFD: Int32, buffer: inout [UInt8]) -> Received {
        let deadline = Posix.deadline(afterMilliseconds: receiveTimeoutMilliseconds)
        var message = Data()
        while true {
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count > 0 {
                let chunk = buffer[0..<count]
                if let newline = chunk.firstIndex(of: 0x0A) {
                    guard message.count + newline <= HookWire.maxMessageBytes else { return .dropped }
                    message.append(contentsOf: chunk[..<newline])
                    return .message(message)
                }
                guard message.count + count <= HookWire.maxMessageBytes else { return .dropped }
                message.append(contentsOf: chunk)
            } else if count == 0 {
                return .message(message)
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                switch Posix.wait([fd, wakeFD], for: Int16(POLLIN), until: deadline) {
                case .ready(0): continue
                case .ready: return .stopping
                case .timedOut, .failed: return .dropped
                }
            } else {
                return .dropped
            }
        }
    }

    // MARK: - Peer credentials

    static func peerCredentials(_ fd: Int32) -> PeerCredentials? {
        #if canImport(Darwin)
        var uid = uid_t(0)
        var gid = gid_t(0)
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        // SOL_LOCAL (0) / LOCAL_PEERPID (0x002), from <sys/un.h>.
        var pid: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let hasPID = getsockopt(fd, 0, 0x002, &pid, &length) == 0 && pid > 0
        return PeerCredentials(uid: UInt32(uid), pid: hasPID ? pid : nil)
        #else
        // `struct ucred { pid_t pid; uid_t uid; gid_t gid; }`, hidden behind _GNU_SOURCE in Swift's Glibc.
        var credentials = [UInt32](repeating: 0, count: 3)
        var length = socklen_t(MemoryLayout<UInt32>.size * 3)
        let rc = credentials.withUnsafeMutableBytes { getsockopt(fd, SOL_SOCKET, SO_PEERCRED, $0.baseAddress, &length) }
        guard rc == 0 else { return nil }
        let pid = Int32(bitPattern: credentials[0])
        return PeerCredentials(uid: credentials[1], pid: pid > 0 ? pid : nil)
        #endif
    }

    // MARK: - Socket file

    static func identity(of path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(truncatingIfNeeded: info.st_ino))
    }

    /// `mkdir -p` with mode 0700 for the directories it creates; never changes existing ones.
    static func createDirectories(_ directory: String) throws {
        guard !directory.isEmpty else { return }
        var info = stat()
        if stat(directory, &info) == 0 {
            guard Posix.isDirectory(info.st_mode) else { throw UnixSocketError.system("not a directory: \(directory)", ENOTDIR) }
            return
        }
        guard errno == ENOENT else { throw UnixSocketError.system("stat \(directory)", errno) }
        try createDirectories(Posix.parentDirectory(of: directory))
        if mkdir(directory, 0o700) != 0, errno != EEXIST {
            throw UnixSocketError.system("mkdir \(directory)", errno)
        }
    }

    /// Removes a socket file nobody listens on; throws `.addressInUse` if a server answers.
    static func removeStaleSocket(at path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return }
            throw UnixSocketError.system("lstat", errno)
        }
        guard Posix.isSocket(info.st_mode) else { throw UnixSocketError.system("not a socket: \(path)", EEXIST) }
        switch Posix.connectUnix(path, deadline: Posix.deadline(afterMilliseconds: 250)) {
        case .connected(let fd):
            Posix.closeDescriptor(fd)
            throw UnixSocketError.addressInUse
        case .failed(let code) where code == ECONNREFUSED || code == ENOENT:
            if unlink(path) != 0, errno != ENOENT { throw UnixSocketError.system("unlink", errno) }
        case .failed(let code) where code == ETIMEDOUT:
            // A listener exists but its backlog stays full: it is alive.
            throw UnixSocketError.addressInUse
        case .failed(let code):
            throw UnixSocketError.system("connect", code)
        }
    }
}
