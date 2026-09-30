import Foundation
import PixelIPC
import Testing
@testable import PixelIPC
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Short scratch paths: `sun_path` holds about 104 bytes, so sockets live in `/tmp/pos-<6 chars>/`.
enum TestPaths {
    /// A fresh path under /tmp; the directory is not created.
    static func makeTemporaryDirectory() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        while true {
            let suffix = String((0..<6).map { _ in alphabet.randomElement() ?? "x" })
            let path = "/tmp/pos-" + suffix
            if !FileManager.default.fileExists(atPath: path) { return path }
        }
    }

    static func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Permission bits of `path` (following symlinks), `nil` if it does not exist.
    static func permissions(_ path: String) -> UInt32? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return UInt32(info.st_mode) & 0o777
    }

    static func isSocket(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && Posix.isSocket(info.st_mode)
    }
}

/// Collects what a `UnixSocketServer` delivers, from its accept thread.
final class Inbox: @unchecked Sendable {
    struct Message {
        var data: Data
        var peer: PeerCredentials
        /// `HookWire.monotonicNanos()` at delivery.
        var receivedNs: UInt64

        var text: String { String(decoding: data, as: UTF8.self) }

        func json() throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    private let condition = NSCondition()
    private var messages: [Message] = []

    func append(_ data: Data, _ peer: PeerCredentials) {
        let received = HookWire.monotonicNanos()
        condition.lock()
        messages.append(Message(data: data, peer: peer, receivedNs: received))
        condition.broadcast()
        condition.unlock()
    }

    /// Waits until at least `count` messages arrived or `timeout` elapsed; returns all messages so far.
    func wait(for count: Int, timeout: TimeInterval) -> [Message] {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while messages.count < count, condition.wait(until: deadline) {}
        return messages
    }
}

/// A server on a fresh short path, delivering into an `Inbox`.
final class TestServer {
    let directory: String
    let path: String
    let inbox = Inbox()
    let server: UnixSocketServer

    init(socketName: String = "h.sock") throws {
        directory = TestPaths.makeTemporaryDirectory()
        path = directory + "/run/" + socketName
        server = UnixSocketServer(path: path)
        let inbox = inbox
        try server.start { data, peer in inbox.append(data, peer) }
    }

    func tearDown() {
        server.stop()
        TestPaths.remove(directory)
    }
}

/// Finds the executables built with the tests (`pixel-hook`, `fake-claude`).
/// Override with `PIXEL_PRODUCTS_DIR`.
enum Products {
    static let directory: URL? = locate()

    static func executable(_ name: String) throws -> URL {
        let directory = try #require(directory, "built products not found: set PIXEL_PRODUCTS_DIR")
        let url = directory.appendingPathComponent(name)
        try #require(FileManager.default.isExecutableFile(atPath: url.path), "\(name) not found in \(directory.path)")
        return url
    }

    private static func locate() -> URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["PIXEL_PRODUCTS_DIR"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        #if canImport(Darwin)
        // The image holding this code: …/PixelCorePackageTests.xctest/Contents/MacOS/PixelCorePackageTests.
        var info = Dl_info()
        if dladdr(#dsohandle, &info) != 0, let file = info.dli_fname {
            candidates.append(URL(fileURLWithPath: String(cString: file)).deletingLastPathComponent())
        }
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            candidates.append(bundle.bundleURL.deletingLastPathComponent())
        }
        #else
        if let executable = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") {
            candidates.append(URL(fileURLWithPath: executable).deletingLastPathComponent())
        }
        #endif
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent())
        }
        candidates.append(Bundle.main.bundleURL)
        if let first = CommandLine.arguments.first {
            candidates.append(URL(fileURLWithPath: first).deletingLastPathComponent())
        }
        for candidate in candidates {
            var directory = candidate.standardizedFileURL
            // Up to …/debug from an .xctest bundle's Contents/MacOS.
            for _ in 0..<4 {
                if FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("pixel-hook").path) {
                    return directory
                }
                directory = directory.deletingLastPathComponent()
            }
        }
        return nil
    }
}

/// Runs a child process with piped stdin, stdout and stderr.
enum ChildProcess {
    struct Result {
        var status: Int32
        var exitedNormally: Bool
        var stdout: Data
        var stderr: Data
        var pid: Int32
        var seconds: TimeInterval
        /// Whether all of stdin was written (the child read it to the end, or at least did not close it early).
        var stdinWritten: Bool
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]
        private var written = false
        private var hasExited = false

        func set(_ key: String, _ data: Data) {
            lock.lock()
            values[key] = data
            lock.unlock()
        }

        func setWritten(_ value: Bool) {
            lock.lock()
            written = value
            lock.unlock()
        }

        func get(_ key: String) -> Data {
            lock.lock()
            defer { lock.unlock() }
            return values[key] ?? Data()
        }

        func markExited() {
            lock.lock()
            hasExited = true
            lock.unlock()
        }

        var exited: Bool {
            lock.lock()
            defer { lock.unlock() }
            return hasExited
        }

        var stdinWritten: Bool {
            lock.lock()
            defer { lock.unlock() }
            return written
        }
    }

    /// The current environment without any `PIXEL_*` variable (tests may run inside an app-launched agent),
    /// plus `overrides`.
    static func environment(_ overrides: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("PIXEL_") }
        for (key, value) in overrides { environment[key] = value }
        return environment
    }

    static func run(_ executable: URL, arguments: [String] = [], environment: [String: String],
                    stdin: Data = Data(), timeout: TimeInterval = 30) throws -> Result {
        // A child that exits early must not kill the test runner through SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // Through the gate: children started by concurrent tests must not inherit (and keep open) this child's
        // stdin, which would hang both on macOS.
        try SpawnGate.run { try process.run() }

        let box = Box()
        let group = DispatchGroup()
        let started = Date()
        let pid = process.processIdentifier

        let writer = input.fileHandleForWriting
        DispatchQueue.global().async(group: group) {
            let written = (try? writer.write(contentsOf: stdin)) != nil
            try? writer.close()
            box.setWritten(written)
        }
        let stdoutReader = output.fileHandleForReading
        DispatchQueue.global().async(group: group) {
            box.set("out", (try? stdoutReader.readToEnd()) ?? Data())
        }
        let stderrReader = errors.fileHandleForReading
        DispatchQueue.global().async(group: group) {
            box.set("err", (try? stderrReader.readToEnd()) ?? Data())
        }
        // Watchdog: never let a hung child hang the test run.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if !box.exited { kill(pid, SIGKILL) }
        }
        process.waitUntilExit()
        box.markExited()
        let seconds = Date().timeIntervalSince(started)
        _ = group.wait(timeout: .now() + 10)
        return Result(
            status: process.terminationStatus,
            exitedNormally: process.terminationReason == .exit,
            stdout: box.get("out"),
            stderr: box.get("err"),
            pid: pid,
            seconds: seconds,
            stdinWritten: box.stdinWritten
        )
    }
}

/// Percentile of `values` (nearest rank), for latency reports.
func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
    return sorted[min(max(rank - 1, 0), sorted.count - 1)]
}
