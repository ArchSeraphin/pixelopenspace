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
        // Lists the descriptors open in the child: /dev/fd works on macOS and Linux.
        process.arguments = ["-c", "ls /dev/fd"]
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
