import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Wire format between `pixel-hook` and the app's `HookServer`.
///
/// One Unix-socket connection per hook event, carrying one line of JSON terminated by "\n":
/// ```json
/// {"v":1,"agent":"<PIXEL_AGENT_ID or absent>","token":"<PIXEL_HOOK_TOKEN or absent>",
///  "claude_pid":1234,"ts_ns":123456789,"prompt_len":42,"truncated":["prompt"],"hook":{ …Claude Code hook JSON… }}
/// ```
/// `hook` is the JSON Claude Code wrote on the hook's stdin, with the large fields in `truncatedFields`
/// cut to `truncateFieldBytes` (UTF-8 safe). If stdin was not valid JSON, `hook` is `{"_unparsed":true,"len":n}`.
public enum HookWire {
    public static let version = 1

    public static let envAgentID = "PIXEL_AGENT_ID"
    public static let envToken = "PIXEL_HOOK_TOKEN"
    public static let envSocket = "PIXEL_HOOK_SOCKET"
    public static let envDebug = "PIXEL_HOOK_DEBUG"

    /// Argument appended to globally installed hook commands (step 5), so they can be found and removed,
    /// and so `pixel-hook` exits at once for sessions launched by the app (which have `PIXEL_AGENT_ID`).
    public static let managedMarker = "--pixel-open-space-managed"

    public static let keyVersion = "v"
    public static let keyAgent = "agent"
    public static let keyToken = "token"
    public static let keyClaudePID = "claude_pid"
    public static let keyTimestamp = "ts_ns"
    public static let keyPromptLength = "prompt_len"
    public static let keyTruncated = "truncated"
    public static let keyHook = "hook"

    /// stdin is always read to EOF (never close it early: Claude would get EPIPE); only this much is kept.
    public static let maxStdinBytes = 4 << 20
    /// The server rejects larger messages.
    public static let maxMessageBytes = 1 << 20
    public static let truncateFieldBytes = 4096
    public static let truncatedFields = ["tool_output", "tool_response", "assistant_message", "last_assistant_message", "prompt"]
    /// Connect + write deadline for `pixel-hook`.
    public static let sendDeadlineMilliseconds = 300

    /// Shells skipped when walking up from `pixel-hook` to find the `claude` process.
    public static let shellNames: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh"]

    /// `~/Library/Application Support/PixelOpenSpace/run/hook.sock` on macOS.
    public static func defaultSocketPath(home: String) -> String {
        home + "/Library/Application Support/PixelOpenSpace/run/hook.sock"
    }

    /// `sun_path` holds 104 bytes on macOS (108 on Linux), terminator included.
    public static let maxSocketPathBytes = 103

    /// Monotonic clock shared by `pixel-hook` and the app (same machine), in nanoseconds.
    public static func monotonicNanos() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    }
}
