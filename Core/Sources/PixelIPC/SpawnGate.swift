import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Keeps child processes from inheriting descriptors they were not given.
///
/// On macOS a child starts with every descriptor of the parent that is not close-on-exec: `Pipe()` ends, and the
/// pty master (and its `dup`) that SwiftTerm's `forkpty` creates, are not. Two children started close together
/// can then each hold the other's stdin open, so neither ever reads end-of-file (a `claude` would also keep the
/// other agents' terminals alive). Every child is started inside `SpawnGate.run`, which marks all open descriptors
/// close-on-exec before the start (the child only gets what the spawner maps to 0, 1, 2, so create its pipes
/// before calling `run`) and after it (descriptors the start itself created, such as the pty master).
public enum SpawnGate {
    private static let lock = NSLock()

    /// Runs `body` (which starts one child) with no other gated spawn in between, sweeping descriptors
    /// close-on-exec before and after.
    public static func run<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer {
            markAllCloseOnExec()
            lock.unlock()
        }
        markAllCloseOnExec()
        return try body()
    }

    /// Sets FD_CLOEXEC on every open descriptor above stderr.
    public static func markAllCloseOnExec() {
        var limit = rlimit()
        let upper: Int32
        #if canImport(Darwin)
        let resource = RLIMIT_NOFILE
        #else
        let resource = __rlimit_resource_t(RLIMIT_NOFILE.rawValue)
        #endif
        if getrlimit(resource, &limit) == 0 {  // RLIM_INFINITY is a huge value: capped below
            upper = Int32(min(UInt64(limit.rlim_cur), 65_536))
        } else {
            upper = 65_536
        }
        guard upper > 3 else { return }
        for fd in 3..<upper {
            let flags = fcntl(fd, F_GETFD)
            if flags >= 0, flags & FD_CLOEXEC == 0 {
                _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
            }
        }
    }
}
