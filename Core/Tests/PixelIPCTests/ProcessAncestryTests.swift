import Foundation
import Testing
@testable import PixelIPC
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite struct ProcessAncestryTests {
    @Test func describesTheCurrentProcess() throws {
        #expect(ProcessAncestry.parentPID(of: getpid()) == getppid())
        let name = try #require(ProcessAncestry.name(of: getpid()))
        #expect(!name.isEmpty)
        #expect(!ProcessAncestry.isShell(name))
        let start = try #require(ProcessAncestry.startTime(of: getpid()))
        #expect(start <= Date(timeIntervalSinceNow: 2))
        #expect(start > Date(timeIntervalSinceNow: -86_400))
    }

    @Test func unknownProcessesHaveNoInformation() {
        for pid: Int32 in [0, -1, Int32.max] {
            #expect(ProcessAncestry.parentPID(of: pid) == nil)
            #expect(ProcessAncestry.name(of: pid) == nil)
            #expect(ProcessAncestry.startTime(of: pid) == nil)
        }
        #expect(ProcessAncestry.claudePID(startingAt: 1) == nil)
        #expect(ProcessAncestry.claudePID(startingAt: 0) == nil)
        #expect(ProcessAncestry.claudePID(startingAt: Int32.max) == nil)
    }

    @Test func claudePIDSkipsAShellUpToItsParent() throws {
        // A shell blocked on its own stdin: it stays a shell (no exec) until the pipe closes.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "read line; exit 0"]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
        let shell = process.processIdentifier
        let deadline = Date(timeIntervalSinceNow: 5)
        while !(ProcessAncestry.name(of: shell).map(ProcessAncestry.isShell) ?? false), Date() < deadline {
            usleep(5_000)
        }

        let name = try #require(ProcessAncestry.name(of: shell))
        #expect(ProcessAncestry.isShell(name))
        #expect(ProcessAncestry.parentPID(of: shell) == getpid())
        #expect(ProcessAncestry.claudePID(startingAt: shell) == getpid())
        #expect(ProcessAncestry.claudePID(startingAt: shell, maxDepth: 1) == nil)
        #expect(ProcessAncestry.claudePID(startingAt: getpid()) == getpid())

        let parentStart = try #require(ProcessAncestry.startTime(of: getpid()))
        let childStart = try #require(ProcessAncestry.startTime(of: shell))
        // Linux start times are only as precise as the boot time (1 s).
        #expect(childStart >= parentStart.addingTimeInterval(-1))
        #expect(childStart <= Date(timeIntervalSinceNow: 2))
    }

    @Test func shellNamesAreRecognised() {
        for name in ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "-zsh", "-bash", "/bin/zsh", "/usr/local/bin/fish"] {
            #expect(ProcessAncestry.isShell(name), "\(name)")
        }
        for name in ["claude", "node", "2.1.201", "zshrc", "", "-", "pixel-hook", "fake-claude", "shell"] {
            #expect(!ProcessAncestry.isShell(name), "\(name)")
        }
    }

    @Test func parsesProcStatWithAwkwardCommandNames() {
        let stat = "1234 (we(ird) na me)) S 99 1234 1234 0 -1 4194560 100 0 0 0 1 2 0 0 20 0 1 0 987654 "
            + "12345678 300 18446744073709551615 1 1 0 0 0 0 0 0 0 0 0 0 17 3 0 0 0 0 0\n"
        #expect(ProcessAncestry.parseStat(stat) == .init(name: "we(ird) na me)", parentPID: 99, startTicks: 987_654))
        #expect(ProcessAncestry.parseStat("1 (sh) S 0 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 5")
            == .init(name: "sh", parentPID: 0, startTicks: 5))
        #expect(ProcessAncestry.parseStat("1234 no parentheses S 1") == nil)
        #expect(ProcessAncestry.parseStat("1234 (short) S 1 2 3") == nil)
        #expect(ProcessAncestry.parseStat("") == nil)
    }

    @Test func parsesTheBootTime() {
        #expect(ProcessAncestry.bootTime(fromProcStat: "cpu  1 2 3\nintr 0\nbtime 1727690000\nprocesses 5\n") == 1_727_690_000)
        #expect(ProcessAncestry.bootTime(fromProcStat: "cpu  1 2 3\n") == nil)
    }
}
