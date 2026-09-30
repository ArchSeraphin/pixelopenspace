import Foundation
import PixelIPC
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// `pixel-hook`: the command hook Claude Code runs for each subscribed event (proposal 3.2, 5.4).
// Reads the hook JSON on stdin, wraps it (`HookWire`) and sends one line to the app's Unix socket.
// Whatever happens (app closed, no socket, invalid JSON): exit code 0, nothing on stdout or stderr,
// so Claude Code never shows a hook error and never waits long.

enum PixelHook {
    static func run() {
        let startedNs = HookWire.monotonicNanos()
        signal(SIGPIPE, SIG_IGN)
        silenceStandardOutputs()

        let agent = environment(HookWire.envAgentID)
        // Global install (step 5): sessions launched by the app already report through `--settings`.
        if agent != nil, CommandLine.arguments.dropFirst().contains(HookWire.managedMarker) {
            _ = drainStandardInput(keeping: 0)
            return
        }

        let input = drainStandardInput(keeping: HookWire.maxStdinBytes)
        guard let socketPath = socketPath() else { return }
        let line = HookWireEncoder.envelope(
            stdin: input.data,
            stdinLength: input.length,
            agent: agent,
            token: environment(HookWire.envToken) ?? tokenFile(besides: socketPath),
            claudePID: ProcessAncestry.claudePID(),
            timestampNs: startedNs
        )
        let sent = UnixSocketClient.sendOnce(line, to: socketPath, deadlineMilliseconds: HookWire.sendDeadlineMilliseconds)

        if environment(HookWire.envDebug) == "1" {
            let micros = (HookWire.monotonicNanos() - startedNs) / 1_000
            appendDebugLog(socketPath: socketPath, event: eventName(input.data), sent: sent, micros: micros)
        }
    }

    /// Non-empty environment variable.
    static func environment(_ name: String) -> String? {
        guard let value = getenv(name) else { return nil }
        let text = String(cString: value)
        return text.isEmpty ? nil : text
    }

    /// Points stdout and stderr at /dev/null: nothing (not even a runtime warning) may reach Claude Code,
    /// which would parse stdout as a hook decision.
    static func silenceStandardOutputs() {
        let null = open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard null >= 0 else { return }
        _ = dup2(null, STDOUT_FILENO)
        _ = dup2(null, STDERR_FILENO)
        if null > STDERR_FILENO { close(null) }
    }

    /// Reads stdin to EOF, keeping the first `limit` bytes. Never stops early: closing the pipe while Claude
    /// Code is still writing would hand it an EPIPE.
    static func drainStandardInput(keeping limit: Int) -> (data: Data, length: Int) {
        var kept = Data()
        var length = 0
        let chunkSize = 64 * 1024
        let chunk = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { chunk.deallocate() }
        while true {
            let count = read(STDIN_FILENO, chunk, chunkSize)
            if count > 0 {
                length += count
                let room = limit - kept.count
                if room > 0 {
                    kept.append(chunk.assumingMemoryBound(to: UInt8.self), count: min(room, count))
                }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                // Non-blocking stdin inherited from the parent: wait for data or EOF.
                var entry = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                _ = poll(&entry, 1, 1_000)
            } else {
                break
            }
        }
        return (kept, length)
    }

    /// `$PIXEL_HOOK_SOCKET`, else the app's default path (`HookWire.socketPath`).
    static func socketPath() -> String? {
        if let path = environment(HookWire.envSocket) { return path }
        guard let home = environment("HOME") ?? accountHome() else { return nil }
        return HookWire.socketPath(home: home, temporaryDirectory: environment("TMPDIR"), uid: getuid())
    }

    static func accountHome() -> String? {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
        let home = String(cString: directory)
        return home.isEmpty ? nil : home
    }

    /// `run/token` next to the socket: the token of sessions launched outside the app (proposal 5.5).
    static func tokenFile(besides socketPath: String) -> String? {
        guard socketPath.contains("/") else { return nil }
        let fd = open(HookWire.tokenPath(socketPath: socketPath), O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: 256)
        let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count > 0 else { return nil }
        let token = String(decoding: bytes[0..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { return nil }
        return token
    }

    static func directory(of path: String) -> String? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    // MARK: - Debug log (PIXEL_HOOK_DEBUG=1)

    /// Largest debug log kept; beyond it the file starts over.
    static let maxDebugLogBytes = 8 << 20

    static func eventName(_ input: Data) -> String {
        guard let name = HookWireEncoder.eventName(stdin: input) else { return "_unparsed" }
        let printable = name.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        return String(String.UnicodeScalarView(printable.prefix(64)))
    }

    /// Appends one line to `<run>/../logs/pixel-hook.log`. Errors are ignored.
    static func appendDebugLog(socketPath: String, event: String, sent: Bool, micros: UInt64) {
        guard let runDirectory = directory(of: socketPath), let base = directory(of: runDirectory) else { return }
        let logs = (base == "/" ? "" : base) + "/logs"
        _ = mkdir(logs, 0o700)
        let fd = open(logs + "/pixel-hook.log", O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        if fstat(fd, &info) == 0, Int(info.st_size) > maxDebugLogBytes {
            _ = ftruncate(fd, 0)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let text = "\(formatter.string(from: Date())) \(event) sent=\(sent ? 1 : 0) \(micros)us pid=\(getpid())\n"
        _ = text.utf8CString.withUnsafeBufferPointer { buffer in
            write(fd, buffer.baseAddress, buffer.count - 1)
        }
    }
}

PixelHook.run()
exit(0)
