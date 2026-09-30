import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Process table lookups used by `pixel-hook` to find the `claude` process that ran it, and by the app to
/// tell a live process from a reused pid (pid + start time).
///
/// Darwin: `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID)`. Linux: `/proc/<pid>/stat`.
public enum ProcessAncestry {
    public static func parentPID(of pid: Int32) -> Int32? {
        #if canImport(Darwin)
        return processInfo(pid).map { $0.kp_eproc.e_ppid }
        #else
        return statFields(pid)?.parentPID
        #endif
    }

    /// Short command name as the kernel records it (at most 16 bytes on Darwin, 15 on Linux).
    public static func name(of pid: Int32) -> String? {
        #if canImport(Darwin)
        guard let info = processInfo(pid) else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return name.isEmpty ? nil : name
        #else
        guard let name = statFields(pid)?.name, !name.isEmpty else { return nil }
        return name
        #endif
    }

    /// When the process started. Linux precision is bounded by the boot time's (1 s).
    public static func startTime(of pid: Int32) -> Date? {
        #if canImport(Darwin)
        guard let info = processInfo(pid) else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
        #else
        guard let ticks = statFields(pid)?.startTicks,
              let procStat = Posix.readSmallFile("/proc/stat"),
              let bootTime = bootTime(fromProcStat: String(decoding: procStat, as: UTF8.self)) else { return nil }
        let ticksPerSecond = sysconf(Int32(_SC_CLK_TCK))
        guard ticksPerSecond > 0 else { return nil }
        return Date(timeIntervalSince1970: bootTime + TimeInterval(ticks) / TimeInterval(ticksPerSecond))
        #endif
    }

    /// The first ancestor, starting at `pid` itself, that is not a shell (`HookWire.shellNames`).
    ///
    /// Claude Code runs a hook command through `sh -c`, which may or may not `exec` it; skipping shells
    /// lands on `claude` either way. `nil` when a lookup fails, `pid <= 1` is reached, or more than
    /// `maxDepth` processes would have to be examined.
    public static func claudePID(startingAt pid: Int32 = getppid(), maxDepth: Int = 8) -> Int32? {
        var current = pid
        var examined = 0
        while examined < maxDepth, current > 1 {
            guard let name = name(of: current) else { return nil }
            if !isShell(name) { return current }
            guard let parent = parentPID(of: current) else { return nil }
            current = parent
            examined += 1
        }
        return nil
    }

    /// `name` is a shell from `HookWire.shellNames`, ignoring any directory and a login shell's leading "-".
    static func isShell(_ name: String) -> Bool {
        var base = Substring(name)
        if let slash = base.lastIndex(of: "/") { base = base[base.index(after: slash)...] }
        if base.hasPrefix("-") { base = base.dropFirst() }
        return HookWire.shellNames.contains(String(base))
    }

    // MARK: - Linux /proc parsing (pure, tested on every platform)

    struct StatFields: Equatable {
        var name: String
        var parentPID: Int32
        /// Field 22: start time in clock ticks after boot.
        var startTicks: UInt64
    }

    /// Parses `/proc/<pid>/stat`. The command name sits in parentheses and may itself contain spaces
    /// and parentheses, so the fields are read after the last ")".
    static func parseStat(_ text: String) -> StatFields? {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else { return nil }
        let name = String(text[text.index(after: open)..<close])
        // Fields 3 (state), 4 (ppid) … 22 (starttime).
        let fields = text[text.index(after: close)...].split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard fields.count > 19, let parentPID = Int32(fields[1]), let startTicks = UInt64(fields[19]) else { return nil }
        return StatFields(name: name, parentPID: parentPID, startTicks: startTicks)
    }

    /// The `btime` line of `/proc/stat`: boot time in seconds since 1970.
    static func bootTime(fromProcStat text: String) -> TimeInterval? {
        for line in text.split(separator: "\n") where line.hasPrefix("btime ") {
            return TimeInterval(line.dropFirst("btime ".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    // MARK: - Platform lookups

    #if canImport(Darwin)
    private static func processInfo(_ pid: Int32) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        // An unknown pid succeeds with a size of 0.
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }
    #else
    private static func statFields(_ pid: Int32) -> StatFields? {
        guard pid > 0, let data = Posix.readSmallFile("/proc/\(pid)/stat") else { return nil }
        return parseStat(String(decoding: data, as: UTF8.self))
    }
    #endif
}
