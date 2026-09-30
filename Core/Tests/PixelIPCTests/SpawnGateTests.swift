import Foundation
import PixelIPC
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite struct SpawnGateTests {
    @Test func sweepMarksOpenDescriptorsCloseOnExec() throws {
        let pipe = Pipe()
        let fds = [pipe.fileHandleForReading.fileDescriptor, pipe.fileHandleForWriting.fileDescriptor]
        SpawnGate.markAllCloseOnExec()
        for fd in fds {
            #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
        }
    }

    /// The macOS failure this prevents: a child keeping an unrelated pipe open (so its reader never sees EOF).
    @Test func childStartedThroughTheGateInheritsOnlyItsStdio() throws {
        let unrelated = Pipe()
        let unrelatedFDs: Set<Int32> = [unrelated.fileHandleForReading.fileDescriptor,
                                        unrelated.fileHandleForWriting.fileDescriptor]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Prints which of these descriptors are open in the child, by duplicating each one. Listing /dev/fd would
        // not do: `ls` (or a glob) opens the directory itself, on the lowest free descriptor, often 3 or 4. The
        // probe is an external command: for a builtin, bash first saves stdout on descriptor 10 or above, so
        // `: >&10` succeeds even when 10 was never inherited.
        let candidates = unrelatedFDs.sorted().map(String.init).joined(separator: " ")
        process.arguments = ["-c", "for fd in \(candidates); do /usr/bin/true 2>/dev/null >&$fd && echo $fd; done; exit 0"]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try SpawnGate.run { try process.run() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let listed = Set(String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) })
        #expect(listed.isDisjoint(with: unrelatedFDs), "child inherited \(listed.intersection(unrelatedFDs))")
        withExtendedLifetime(unrelated) {}
    }
}
