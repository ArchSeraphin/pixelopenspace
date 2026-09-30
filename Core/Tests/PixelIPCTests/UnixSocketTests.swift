import Foundation
import Testing
@testable import PixelIPC
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite struct UnixSocketTests {
    private func send(_ text: String, to path: String, deadline: Int = 2_000) -> Bool {
        UnixSocketClient.sendOnce(Data(text.utf8), to: path, deadlineMilliseconds: deadline)
    }

    @Test func roundTripDeliversOneMessagePerConnection() throws {
        let server = try TestServer()
        defer { server.tearDown() }

        #expect(send("hello\n", to: server.path))
        #expect(send("no newline", to: server.path))
        #expect(send("first\nsecond\n", to: server.path))
        let messages = server.inbox.wait(for: 3, timeout: 5)
        #expect(messages.map(\.text) == ["hello", "no newline", "first"])
        for message in messages {
            #expect(message.peer.uid == getuid())
            #expect(message.peer.pid == getpid())
        }
    }

    @Test func emptyConnectionDeliversNothing() throws {
        let server = try TestServer()
        defer { server.tearDown() }

        #expect(UnixSocketClient.sendOnce(Data(), to: server.path, deadlineMilliseconds: 1_000))
        #expect(send("\n", to: server.path))
        #expect(send("after", to: server.path))
        #expect(server.inbox.wait(for: 1, timeout: 5).map(\.text) == ["after"])
        #expect(server.inbox.wait(for: 2, timeout: 0.3).count == 1)
    }

    @Test func createsPrivateDirectoriesAndSocketFile() throws {
        let directory = TestPaths.makeTemporaryDirectory()
        defer { TestPaths.remove(directory) }
        let path = directory + "/a/b/h.sock"
        let server = UnixSocketServer(path: path)
        try server.start { _, _ in }
        defer { server.stop() }

        #expect(TestPaths.permissions(directory) == 0o700)
        #expect(TestPaths.permissions(directory + "/a") == 0o700)
        #expect(TestPaths.permissions(directory + "/a/b") == 0o700)
        #expect(TestPaths.isSocket(path))
        #expect(TestPaths.permissions(path) == 0o600)
    }

    @Test func leavesAnExistingDirectoryAsItIs() throws {
        let directory = TestPaths.makeTemporaryDirectory()
        defer { TestPaths.remove(directory) }
        #expect(mkdir(directory, 0o755) == 0)
        #expect(chmod(directory, 0o755) == 0)
        let server = UnixSocketServer(path: directory + "/h.sock", mode: 0o660)
        try server.start { _, _ in }
        defer { server.stop() }

        #expect(TestPaths.permissions(directory) == 0o755)
        #expect(TestPaths.permissions(directory + "/h.sock") == 0o660)
    }

    @Test func oversizeMessageIsDroppedAndTheServerKeepsServing() throws {
        let server = try TestServer()
        defer { server.tearDown() }

        var oversize = Data(repeating: UInt8(ascii: "x"), count: HookWire.maxMessageBytes + 1)
        oversize.append(0x0A)
        // The server hangs up mid-message: the client may see EPIPE, never SIGPIPE.
        _ = UnixSocketClient.sendOnce(oversize, to: server.path, deadlineMilliseconds: 5_000)

        var atLimit = Data(repeating: UInt8(ascii: "y"), count: HookWire.maxMessageBytes)
        atLimit.append(0x0A)
        #expect(UnixSocketClient.sendOnce(atLimit, to: server.path, deadlineMilliseconds: 5_000))
        #expect(send("after", to: server.path))

        let messages = server.inbox.wait(for: 2, timeout: 10)
        try #require(messages.count == 2)
        #expect(messages[0].data.count == HookWire.maxMessageBytes)
        #expect(messages[0].data.allSatisfy { $0 == UInt8(ascii: "y") })
        #expect(messages[1].text == "after")
        #expect(server.inbox.wait(for: 3, timeout: 0.3).count == 2)
    }

    @Test func staleSocketFileIsReplaced() throws {
        let directory = TestPaths.makeTemporaryDirectory()
        defer { TestPaths.remove(directory) }
        #expect(mkdir(directory, 0o700) == 0)
        let path = directory + "/h.sock"
        // A server that died without unlinking: bound, never listening, closed.
        let fd = try #require(Posix.makeUnixSocket())
        #expect(Posix.withUnixAddress(path, { bind(fd, $0, $1) }) == 0)
        close(fd)
        #expect(TestPaths.isSocket(path))

        let inbox = Inbox()
        let server = UnixSocketServer(path: path)
        try server.start { inbox.append($0, $1) }
        defer { server.stop() }
        #expect(send("fresh", to: path))
        #expect(inbox.wait(for: 1, timeout: 5).map(\.text) == ["fresh"])
    }

    @Test func secondServerOnALivePathThrowsAddressInUse() throws {
        let first = try TestServer()
        defer { first.tearDown() }

        let second = UnixSocketServer(path: first.path)
        #expect(throws: UnixSocketError.addressInUse) {
            try second.start { _, _ in }
        }
        second.stop()
        // The first server's socket file survived the attempt.
        #expect(send("still here", to: first.path))
        #expect(first.inbox.wait(for: 1, timeout: 5).map(\.text) == ["still here"])
    }

    @Test func pathLengthIsBounded() throws {
        let tooLong = "/tmp/" + String(repeating: "a", count: 120) + "/h.sock"
        #expect(throws: UnixSocketError.pathTooLong(tooLong.utf8.count)) {
            try UnixSocketServer(path: tooLong).start { _, _ in }
        }
        #expect(!send("x", to: tooLong, deadline: 100))

        // Exactly `maxSocketPathBytes` fits on both platforms.
        let directory = TestPaths.makeTemporaryDirectory()
        defer { TestPaths.remove(directory) }
        let name = String(repeating: "s", count: HookWire.maxSocketPathBytes - directory.utf8.count - 1)
        let path = directory + "/" + name
        #expect(path.utf8.count == HookWire.maxSocketPathBytes)
        let inbox = Inbox()
        let server = UnixSocketServer(path: path)
        try server.start { inbox.append($0, $1) }
        defer { server.stop() }
        #expect(send("longest", to: path))
        #expect(inbox.wait(for: 1, timeout: 5).map(\.text) == ["longest"])
    }

    @Test func regularFileAtThePathIsNeverRemoved() throws {
        let directory = TestPaths.makeTemporaryDirectory()
        defer { TestPaths.remove(directory) }
        #expect(mkdir(directory, 0o700) == 0)
        let path = directory + "/h.sock"
        #expect(FileManager.default.createFile(atPath: path, contents: Data("keep".utf8)))

        #expect(throws: UnixSocketError.system("not a socket: \(path)", EEXIST)) {
            try UnixSocketServer(path: path).start { _, _ in }
        }
        #expect(FileManager.default.contents(atPath: path) == Data("keep".utf8))
    }

    @Test func stopRemovesTheSocketAndStartWorksAgain() throws {
        let server = try TestServer()
        defer { server.tearDown() }

        #expect(throws: UnixSocketError.system("already started", EALREADY)) {
            try server.server.start { _, _ in }
        }
        server.server.stop()
        #expect(!TestPaths.isSocket(server.path))
        let started = Date()
        #expect(!send("nobody", to: server.path))
        #expect(Date().timeIntervalSince(started) < 1)
        server.server.stop()

        let inbox = server.inbox
        try server.server.start { inbox.append($0, $1) }
        #expect(send("again", to: server.path))
        #expect(inbox.wait(for: 1, timeout: 5).map(\.text) == ["again"])
    }

    @Test func stopFromTheCallbackDoesNotDeadlock() throws {
        let directory = TestPaths.makeTemporaryDirectory()
        defer { TestPaths.remove(directory) }
        let path = directory + "/h.sock"
        let inbox = Inbox()
        let server = UnixSocketServer(path: path)
        try server.start { data, peer in
            inbox.append(data, peer)
            server.stop()
        }
        #expect(send("last", to: path))
        #expect(inbox.wait(for: 1, timeout: 5).map(\.text) == ["last"])
        let deadline = Date(timeIntervalSinceNow: 5)
        while TestPaths.isSocket(path), Date() < deadline { usleep(10_000) }
        #expect(!TestPaths.isSocket(path))
        #expect(!send("late", to: path, deadline: 200))
    }

    @Test func silentPeerOnlyDelaysTheNextOneBriefly() throws {
        let server = try TestServer()
        defer { server.tearDown() }

        guard case .connected(let idle) = Posix.connectUnix(server.path, deadline: Posix.deadline(afterMilliseconds: 1_000)) else {
            Issue.record("could not connect")
            return
        }
        defer { close(idle) }
        let started = Date()
        #expect(send("after idle", to: server.path, deadline: 3_000))
        #expect(server.inbox.wait(for: 1, timeout: 5).map(\.text) == ["after idle"])
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func concurrentClientsAreAllDelivered() throws {
        let server = try TestServer()
        defer { server.tearDown() }

        let path = server.path
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            _ = UnixSocketClient.sendOnce(Data("m\(index)\n".utf8), to: path, deadlineMilliseconds: 5_000)
        }
        let messages = server.inbox.wait(for: 40, timeout: 10)
        #expect(Set(messages.map(\.text)) == Set((0..<40).map { "m\($0)" }))
    }

    /// Needs root to run a client as another user (Linux CI container); the check itself is platform code.
    @Test(.enabled(if: getuid() == 0 && FileManager.default.isExecutableFile(atPath: "/usr/bin/setpriv")))
    func peerRunningAsAnotherUserIsIgnored() throws {
        let directory = TestPaths.makeTemporaryDirectory()
        defer { TestPaths.remove(directory) }
        // World-accessible on purpose, so only the uid check stands in the way.
        #expect(mkdir(directory, 0o755) == 0)
        #expect(chmod(directory, 0o755) == 0)
        let hook = directory + "/pixel-hook"
        try FileManager.default.copyItem(atPath: try Products.executable("pixel-hook").path, toPath: hook)
        #expect(chmod(hook, 0o755) == 0)
        let path = directory + "/h.sock"
        let inbox = Inbox()
        let server = UnixSocketServer(path: path, mode: 0o777)
        try server.start { inbox.append($0, $1) }
        defer { server.stop() }

        let input = Data(#"{"session_id":"s","hook_event_name":"Stop"}"#.utf8)
        let environment = ChildProcess.environment([HookWire.envSocket: path, "HOME": directory])
        let stranger = try ChildProcess.run(URL(fileURLWithPath: "/usr/bin/setpriv"),
                                            arguments: ["--reuid=65534", "--regid=65534", "--clear-groups", hook],
                                            environment: environment, stdin: input)
        #expect(stranger.status == 0)
        #expect(inbox.wait(for: 1, timeout: 0.5).isEmpty)

        _ = try ChildProcess.run(URL(fileURLWithPath: hook), environment: environment, stdin: input)
        let messages = inbox.wait(for: 1, timeout: 5)
        #expect(messages.count == 1)
        #expect(messages.first?.peer.uid == getuid())
    }

    @Test func sendingToAMissingSocketFailsFast() {
        // Well under the deadline, with room for a loaded machine.
        let started = Date()
        #expect(!send("x", to: TestPaths.makeTemporaryDirectory() + "/none.sock", deadline: 5_000))
        #expect(Date().timeIntervalSince(started) < 2)
    }
}
