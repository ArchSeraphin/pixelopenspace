import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// `fake-claude`: stands in for the `claude` CLI in tests and demos.
//
//   fake-claude replay --hook <path> --fixture <file.jsonl> [--delay-ms N] [--session <id>]
//       Runs the hook command once per non-empty fixture line, with the line on stdin, through `/bin/sh -c`
//       like Claude Code's shell-form hooks, so `pixel-hook` has to skip a shell to find this process.
//       A line {"_sleep_ms": N} pauses instead. `--session` overrides every event's `session_id`.
//   fake-claude sleep <seconds>
//       Stays alive, to emulate a running session.
//
// Prints nothing on success. Exit codes: 1 bad usage or unreadable fixture, 2 a hook failed.

enum FakeClaude {
    static let usage = """
        usage: fake-claude replay --hook <path> --fixture <file.jsonl> [--delay-ms N] [--session <id>]
               fake-claude sleep <seconds>

        """

    struct ReplayOptions {
        var hook: String
        var fixture: String
        var delayMilliseconds = 0
        var session: String?
    }

    static func main(_ arguments: [String]) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        guard let command = arguments.first else { return fail(usage) }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "replay":
            guard let options = parseReplay(rest) else { return fail(usage) }
            return replay(options)
        case "sleep":
            guard rest.count == 1, let seconds = TimeInterval(rest[0]), seconds >= 0, seconds.isFinite else {
                return fail(usage)
            }
            Thread.sleep(forTimeInterval: seconds)
            return 0
        default:
            return fail(usage)
        }
    }

    static func parseReplay(_ arguments: [String]) -> ReplayOptions? {
        var hook: String?
        var fixture: String?
        var delay = 0
        var session: String?
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else { return nil }
            let value = arguments[index + 1]
            switch arguments[index] {
            case "--hook": hook = value
            case "--fixture": fixture = value
            case "--delay-ms":
                guard let milliseconds = Int(value), milliseconds >= 0 else { return nil }
                delay = milliseconds
            case "--session":
                guard !value.isEmpty else { return nil }
                session = value
            default:
                return nil
            }
            index += 2
        }
        guard let hook, !hook.isEmpty, let fixture, !fixture.isEmpty else { return nil }
        return ReplayOptions(hook: hook, fixture: fixture, delayMilliseconds: delay, session: session)
    }

    static func replay(_ options: ReplayOptions) -> Int32 {
        guard let contents = try? Data(contentsOf: URL(fileURLWithPath: options.fixture)) else {
            return fail("fake-claude: cannot read fixture \(options.fixture)\n")
        }
        var status: Int32 = 0
        for rawLine in String(decoding: contents, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            if let object, let pause = milliseconds(object["_sleep_ms"]) {
                sleep(milliseconds: pause)
                continue
            }
            var input = Data(line.utf8)
            if var object, let session = options.session {
                object["session_id"] = session
                if let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) {
                    input = data
                }
            }
            if let failure = runHook(options.hook, input: input) {
                _ = fail("fake-claude: \(failure)\n")
                status = 2
            }
            sleep(milliseconds: options.delayMilliseconds)
        }
        return status
    }

    /// Runs `/bin/sh -c <quoted hook>` with `input` on stdin and waits. Returns a failure description, if any.
    /// `posix_spawn` + `waitpid` rather than `Process`, whose wait polls on Linux and would skew timings.
    static func runHook(_ hook: String, input: Data) -> String? {
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else { return "pipe: \(describe(errno))" }
        let (readEnd, writeEnd) = (pipeFDs[0], pipeFDs[1])
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t? = nil
        #else
        var actions = posix_spawn_file_actions_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, readEnd, STDIN_FILENO)

        let words: [String] = ["/bin/sh", "-c", shellQuote(hook)]
        let variables: [String] = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let arguments: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        let environment: [UnsafeMutablePointer<CChar>?] = variables.map { strdup($0) } + [nil]
        defer { (arguments + environment).forEach { free($0) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/bin/sh", &actions, nil, arguments, environment)
        close(readEnd)
        guard spawned == 0 else {
            close(writeEnd)
            return "cannot run the hook: \(describe(spawned))"
        }
        // A hook that exits without reading its input only costs an EPIPE here (SIGPIPE is ignored).
        input.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(writeEnd, base + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
        close(writeEnd)

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            guard errno == EINTR else { return "waitpid: \(describe(errno))" }
        }
        // <sys/wait.h> encoding, the same on Darwin and Linux: low 7 bits = signal, next byte = exit code.
        let signal = status & 0x7F
        guard signal == 0 else { return "the hook was killed by signal \(signal)" }
        let code = (status >> 8) & 0xFF
        return code == 0 ? nil : "the hook ended with status \(code)"
    }

    static func describe(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    static func milliseconds(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return max(0, number.intValue) }
        if let text = value as? String { return Int(text).map { max(0, $0) } }
        return nil
    }

    static func sleep(milliseconds: Int) {
        guard milliseconds > 0 else { return }
        Thread.sleep(forTimeInterval: TimeInterval(milliseconds) / 1_000)
    }

    /// POSIX shell quoting (same rules as PixelCore's `ShellQuote`, which this executable does not link).
    static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/-_.,:=@%+".contains($0)) }) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Writes `message` to stderr and returns the usage exit code.
    static func fail(_ message: String) -> Int32 {
        _ = message.utf8CString.withUnsafeBufferPointer { write(STDERR_FILENO, $0.baseAddress, $0.count - 1) }
        return 1
    }
}

exit(FakeClaude.main(Array(CommandLine.arguments.dropFirst())))
