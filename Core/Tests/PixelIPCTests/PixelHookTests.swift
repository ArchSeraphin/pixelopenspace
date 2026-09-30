import Foundation
import Testing
import PixelCore
import PixelIPC
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Runs the built `pixel-hook` executable, as Claude Code would.
@Suite struct PixelHookTests {
    private static let sessionID = "3f6c2a9e-8d41-4b7a-9c55-1e2f7a8b9c0d"

    private func hookJSON(_ extra: [String: Any] = [:]) throws -> Data {
        var hook: [String: Any] = [
            "session_id": Self.sessionID,
            "hook_event_name": "Stop",
            "cwd": "/Users/seraphin/Projets/pixel demo",
            "stop_hook_active": false,
        ]
        hook.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: hook)
    }

    private func runHook(stdin: Data, socket: String?, home: String, arguments: [String] = [],
                         extra: [String: String] = [:]) throws -> ChildProcess.Result {
        var overrides = ["HOME": home]
        if let socket { overrides[HookWire.envSocket] = socket }
        overrides.merge(extra) { _, new in new }
        let result = try ChildProcess.run(try Products.executable("pixel-hook"), arguments: arguments,
                                          environment: ChildProcess.environment(overrides), stdin: stdin)
        #expect(result.exitedNormally)
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
        #expect(result.stdinWritten)
        return result
    }

    @Test func withoutAServerItExitsAtOnceAndSilently() throws {
        let home = TestPaths.makeTemporaryDirectory()
        defer { TestPaths.remove(home) }
        // Neither the explicit socket nor the default one under HOME exists.
        let explicit = try runHook(stdin: try hookJSON(), socket: home + "/run/none.sock", home: home)
        let byDefault = try runHook(stdin: try hookJSON(), socket: nil, home: home)
        // Generous bounds: the first exec of a fresh binary can be slow on a loaded machine.
        #expect(explicit.seconds < 3)
        #expect(byDefault.seconds < 3)
        #expect(!FileManager.default.fileExists(atPath: home))
    }

    @Test func withoutAnExplicitSocketItUsesTheAppDefault() throws {
        let temporary = TestPaths.makeTemporaryDirectory()
        defer { TestPaths.remove(temporary) }
        // A home too long for the Application Support path: the default moves to $TMPDIR/pos-<uid>/.
        let home = temporary + "/" + String(repeating: "h", count: 60)
        let inbox = Inbox()
        let server = UnixSocketServer(path: "\(temporary)/pos-\(getuid())/hook.sock")
        try server.start { inbox.append($0, $1) }
        defer { server.stop() }

        _ = try runHook(stdin: try hookJSON(), socket: nil, home: home, extra: ["TMPDIR": temporary + "/"])
        #expect(inbox.wait(for: 1, timeout: 5).count == 1)
    }

    @Test func forwardsTheHookWithEnvironmentAndParent() throws {
        let server = try TestServer()
        defer { server.tearDown() }
        let agent = UUID().uuidString
        let result = try runHook(stdin: try hookJSON(), socket: server.path, home: server.directory,
                                 extra: [HookWire.envAgentID: agent, HookWire.envToken: "jeton-secret"])

        let message = try #require(server.inbox.wait(for: 1, timeout: 5).first)
        let root = try message.json()
        #expect(root[HookWire.keyVersion] as? Int == HookWire.version)
        #expect(root[HookWire.keyAgent] as? String == agent)
        #expect(root[HookWire.keyToken] as? String == "jeton-secret")
        // Started directly by this test process, which is not a shell.
        #expect(root[HookWire.keyClaudePID] as? Int == Int(getpid()))
        let timestamp = try #require((root[HookWire.keyTimestamp] as? NSNumber)?.uint64Value)
        #expect(timestamp > 0 && timestamp <= message.receivedNs)
        let hook = try #require(root[HookWire.keyHook] as? [String: Any])
        #expect(hook["session_id"] as? String == Self.sessionID)
        #expect(hook["hook_event_name"] as? String == "Stop")
        #expect(message.peer.pid == result.pid)
        #expect(message.peer.uid == getuid())
    }

    @Test func emptyVariablesAreLeftOut() throws {
        let server = try TestServer()
        defer { server.tearDown() }
        _ = try runHook(stdin: try hookJSON(), socket: server.path, home: server.directory,
                        extra: [HookWire.envAgentID: "", HookWire.envToken: ""])
        let root = try #require(server.inbox.wait(for: 1, timeout: 5).first).json()
        #expect(root[HookWire.keyAgent] == nil)
        #expect(root[HookWire.keyToken] == nil)
    }

    @Test func tokenFileBesidesTheSocketIsTheFallback() throws {
        let server = try TestServer()
        defer { server.tearDown() }
        let tokenPath = HookWire.tokenPath(socketPath: server.path)
        #expect(tokenPath == server.directory + "/run/token")
        #expect(FileManager.default.createFile(atPath: tokenPath, contents: Data("jeton-du-fichier\n".utf8)))

        _ = try runHook(stdin: try hookJSON(), socket: server.path, home: server.directory)
        _ = try runHook(stdin: try hookJSON(), socket: server.path, home: server.directory,
                        extra: [HookWire.envToken: "jeton-env"])
        let messages = server.inbox.wait(for: 2, timeout: 5)
        try #require(messages.count == 2)
        #expect(try messages[0].json()[HookWire.keyToken] as? String == "jeton-du-fichier")
        #expect(try messages[1].json()[HookWire.keyToken] as? String == "jeton-env")
    }

    @Test func invalidJSONIsForwardedAsUnparsed() throws {
        let server = try TestServer()
        defer { server.tearDown() }
        let input = Data("{ pas du json".utf8)
        _ = try runHook(stdin: input, socket: server.path, home: server.directory)

        let root = try #require(server.inbox.wait(for: 1, timeout: 5).first).json()
        let hook = try #require(root[HookWire.keyHook] as? [String: Any])
        #expect(hook["_unparsed"] as? Bool == true)
        #expect(hook["len"] as? Int == input.count)
    }

    /// A lone surrogate escape (a string Claude Code cut inside an emoji) used to turn the event into `_unparsed`.
    @Test func loneSurrogateKeepsTheEventReadable() throws {
        let server = try TestServer()
        defer { server.tearDown() }
        let input = Data((#"{"session_id":"\#(Self.sessionID)","hook_event_name":"PostToolUse","tool_name":"Bash","#
            + #""tool_use_id":"toolu_1","tool_response":{"stdout":"ok \ud83d... done"}}"#).utf8)
        _ = try runHook(stdin: input, socket: server.path, home: server.directory,
                        extra: [HookWire.envDebug: "1"])

        let message = try #require(server.inbox.wait(for: 1, timeout: 5).first)
        let event = try HookDecoder.decodeEnvelope(message.data).event
        #expect(event.sessionID == Self.sessionID)
        #expect(event.payload == .postToolUse(tool: "Bash", toolUseID: "toolu_1", failed: false))
        let log = try #require(FileManager.default.contents(atPath: server.directory + "/logs/pixel-hook.log"))
        #expect(String(decoding: log, as: UTF8.self).contains(" PostToolUse sent=1 "))
    }

    @Test func fiveMegabytesOfInputAreDrainedAndTruncated() throws {
        let server = try TestServer()
        defer { server.tearDown() }
        // About 3.2 MB of JSON, padded with spaces to 5 MB: the kept 4 MB still hold the whole object.
        var input = try hookJSON([
            "hook_event_name": "UserPromptSubmit",
            "prompt": String(repeating: "à", count: 600_000),
            "last_assistant_message": String(repeating: "m", count: 1_000_000),
            "tool_response": ["stdout": String(repeating: "o", count: 1_000_000)],
        ])
        let total = 5 * 1024 * 1024
        input.append(Data(repeating: UInt8(ascii: " "), count: total - input.count))
        _ = try runHook(stdin: input, socket: server.path, home: server.directory)

        let message = try #require(server.inbox.wait(for: 1, timeout: 5).first)
        #expect(message.data.count < 64 * 1024)
        let root = try message.json()
        #expect(root[HookWire.keyPromptLength] as? Int == 600_000)
        #expect(Set(root[HookWire.keyTruncated] as? [String] ?? []) == ["prompt", "last_assistant_message", "tool_response"])
        let hook = try #require(root[HookWire.keyHook] as? [String: Any])
        #expect((hook["prompt"] as? String)?.utf8.count == HookWire.truncateFieldBytes)
        #expect(hook["session_id"] as? String == Self.sessionID)
    }

    @Test func inputBeyondTheCapIsDrainedAndReportedUnparsed() throws {
        let server = try TestServer()
        defer { server.tearDown() }
        let input = Data(repeating: UInt8(ascii: "x"), count: 5 * 1024 * 1024)
        _ = try runHook(stdin: input, socket: server.path, home: server.directory)

        let root = try #require(server.inbox.wait(for: 1, timeout: 5).first).json()
        let hook = try #require(root[HookWire.keyHook] as? [String: Any])
        #expect(hook["_unparsed"] as? Bool == true)
        #expect(hook["len"] as? Int == input.count)
    }

    @Test func managedInstallStaysQuietForAppSessions() throws {
        let server = try TestServer()
        defer { server.tearDown() }
        // Larger than a pipe buffer: the write only completes if pixel-hook drains stdin.
        let input = try hookJSON(["last_assistant_message": String(repeating: "z", count: 300_000)])
        _ = try runHook(stdin: input, socket: server.path, home: server.directory,
                        arguments: [HookWire.managedMarker], extra: [HookWire.envAgentID: UUID().uuidString])
        #expect(server.inbox.wait(for: 1, timeout: 0.5).isEmpty)

        // Without PIXEL_AGENT_ID (a session started outside the app), the managed hook reports.
        _ = try runHook(stdin: input, socket: server.path, home: server.directory, arguments: [HookWire.managedMarker])
        #expect(server.inbox.wait(for: 1, timeout: 5).count == 1)
    }

    @Test func claudePIDSkipsTheShellsInBetween() throws {
        let server = try TestServer()
        defer { server.tearDown() }
        let hookPath = try Products.executable("pixel-hook").path
        // Two shells between this process and pixel-hook; "; exit 0" keeps the outer one from exec'ing.
        let command = "/bin/sh -c " + quote(quote(hookPath)) + "; exit 0"
        let result = try ChildProcess.run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command],
            environment: ChildProcess.environment([HookWire.envSocket: server.path, "HOME": server.directory]),
            stdin: try hookJSON()
        )
        #expect(result.status == 0)
        let root = try #require(server.inbox.wait(for: 1, timeout: 5).first).json()
        #expect(root[HookWire.keyClaudePID] as? Int == Int(getpid()))
    }

    @Test func debugLogGoesNextToTheRunDirectory() throws {
        let server = try TestServer()
        defer { server.tearDown() }
        _ = try runHook(stdin: try hookJSON(), socket: server.path, home: server.directory,
                        extra: [HookWire.envDebug: "1"])
        #expect(server.inbox.wait(for: 1, timeout: 5).count == 1)

        let log = try #require(FileManager.default.contents(atPath: server.directory + "/logs/pixel-hook.log"))
        let text = String(decoding: log, as: UTF8.self)
        #expect(text.contains(" Stop sent=1 "))
        #expect(text.hasSuffix("\n"))
        #expect(TestPaths.permissions(server.directory + "/logs/pixel-hook.log") == 0o600)
    }

    private func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
