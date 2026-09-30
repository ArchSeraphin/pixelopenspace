import Foundation
import PixelCore
import PixelIPC

/// State of the hook server, for the hooks banner.
enum HookServerState: Equatable, Sendable {
    case stopped
    case running
    /// Listening, but `Contents/Helpers/pixel-hook` is missing from the bundle: every session will be degraded.
    case helperMissing(path: String)
    /// Another Pixel Open Space answers on the socket (proposal 3.2).
    case anotherInstance
    case failed(String)

    var isListening: Bool {
        switch self {
        case .running, .helperMissing: return true
        case .stopped, .anotherInstance, .failed: return false
        }
    }
}

/// Receives the hook events of the embedded sessions (proposal 2.3, 3.2).
///
/// Each launch draws a fresh random token (32 bytes, hex). `start()` listens on the Unix socket
/// (`PixelIPC.UnixSocketServer`: peer uid checked, one message per connection), then, once the socket is ours, writes
/// the token to `run/token` (0600, for sessions started outside the app) and `run/hooks-settings.json` (0600, passed
/// to `claude --settings`, pointing at the bundled `pixel-hook`). Another running copy keeps both files untouched.
/// Lines are decoded on the server's thread, counted per agent (`arrivals`, guard G2 of a delivery), rate-limited per
/// agent (200 per second) and delivered in arrival order through `envelopes`. Token checks and routing happen on the
/// main actor (`HookRouter`).
@MainActor
final class HookServer {
    nonisolated static let maxEventsPerSecondPerAgent = 200

    let socketPath: String
    let settingsPath: String
    let tokenPath: String
    let helperPath: String
    /// Per-launch token: events from a previous run of the app (orphan processes) are rejected.
    let token: String
    /// Decoded envelopes, in arrival order. One consumer (`AppModel`).
    let envelopes: AsyncStream<HookEnvelope>

    private(set) var state: HookServerState = .stopped
    private let continuation: AsyncStream<HookEnvelope>.Continuation
    private let server: UnixSocketServer
    private let limiter = HookRateLimiter(limit: HookServer.maxEventsPerSecondPerAgent)
    /// Messages received for each agent, counted on the socket's thread before anything else (proposal 5.6, G2).
    nonisolated let arrivals = HookArrivalCounter()

    init(directories: AppDirectories, helperPath: String = HookServer.bundledHelperPath) {
        socketPath = directories.socketPath
        settingsPath = directories.hookSettingsFile.path
        tokenPath = directories.tokenPath
        self.helperPath = helperPath
        token = Self.makeToken()
        let (stream, continuation) = AsyncStream.makeStream(of: HookEnvelope.self,
                                                             bufferingPolicy: .bufferingNewest(4096))
        envelopes = stream
        self.continuation = continuation
        server = UnixSocketServer(path: socketPath, mode: 0o600)
    }

    /// `PixelOpenSpace.app/Contents/Helpers/pixel-hook`.
    nonisolated static var bundledHelperPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("pixel-hook", isDirectory: false)
            .path
    }

    /// Listens, then writes the token and the hooks settings. Idempotent while running.
    @discardableResult
    func start() -> HookServerState {
        guard !state.isListening else { return state }
        // The socket's folder (run/, or $TMPDIR/pos-<uid>/) holds the token too: create it first.
        let socketDirectory = (socketPath as NSString).deletingLastPathComponent
        if let problem = AppDirectories.makePrivateDirectory(socketDirectory) {
            state = .failed(problem)
            return state
        }

        let continuation = self.continuation
        let limiter = self.limiter
        let arrivals = self.arrivals
        do {
            try server.start { data, _ in
                guard let envelope = try? HookDecoder.decodeEnvelope(data) else {
                    AppLog.hooks.debug("undecodable hook message (\(data.count) bytes)")
                    return
                }
                // Before the rate limit, the token check and the main actor: a delivery's guard G2 must see an event
                // the reducer has not handled yet (a PreToolUse or PermissionRequest reaches us before the dialog
                // is drawn). Messages of a nested `claude` or with a wrong token count too: the safe side.
                if let agentID = envelope.agentID { arrivals.record(agentID) }
                guard limiter.admit(envelope.agentID?.description ?? "") else { return }
                continuation.yield(envelope)
            }
        } catch UnixSocketError.addressInUse {
            state = .anotherInstance
            return state
        } catch UnixSocketError.pathTooLong(let bytes) {
            state = .failed("Chemin du socket trop long (\(bytes) octets) : \(socketPath)")
            return state
        } catch UnixSocketError.system(let call, let code) {
            state = .failed("Socket des hooks indisponible (\(call) : \(String(cString: strerror(code))))")
            return state
        } catch {
            state = .failed("Socket des hooks indisponible : \(error.localizedDescription)")
            return state
        }

        // Only now: when another copy owns the socket (`.anotherInstance` above), its token and settings stay.
        do {
            try AppDirectories.writePrivateFile(Data(token.utf8), to: URL(fileURLWithPath: tokenPath))
            let command = HookSettingsBuilder.hookCommand(helperPath: helperPath, managed: false)
            try AppDirectories.writePrivateFile(HookSettingsBuilder.settingsJSON(hookCommand: command),
                                                to: URL(fileURLWithPath: settingsPath))
        } catch {
            server.stop()
            state = .failed("Impossible d'écrire la configuration des hooks : \(error.localizedDescription)")
            AppLog.hooks.error("hook setup files: \(error.localizedDescription, privacy: .public)")
            return state
        }

        let helper = helperPath
        if FileManager.default.isExecutableFile(atPath: helper) {
            state = .running
        } else {
            state = .helperMissing(path: helper)
            AppLog.hooks.error("pixel-hook missing at \(helper, privacy: .public)")
        }
        let socket = socketPath
        AppLog.hooks.info("listening on \(socket, privacy: .public)")
        return state
    }

    /// Stops listening and removes the socket. The stream stays open (a later `start()` feeds it again).
    func stop() {
        server.stop()
        state = .stopped
    }

    /// 32 random bytes (the system generator is cryptographically secure on Apple platforms), in hex.
    static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        var text = ""
        for _ in 0..<32 {
            let byte = UInt8.random(in: 0...255, using: &generator)
            text += String(byte, radix: 16).leftPadded(to: 2)
        }
        return text
    }
}

/// Per-agent count of the hook messages received on the socket (guard G2 of a delivery, proposal 5.6): written on
/// the socket server's thread as soon as a message is decoded, read on the main actor just before each check of a
/// delivery. Only compared for equality with an earlier reading: it never decreases.
final class HookArrivalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [AgentID: UInt64] = [:]

    func record(_ agentID: AgentID) {
        lock.lock()
        counts[agentID, default: 0] &+= 1
        lock.unlock()
    }

    func count(for agentID: AgentID) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return counts[agentID] ?? 0
    }
}

/// At most `limit` events per second for each agent (proposal 3.2); extra events are dropped. Called from the
/// socket server's thread.
final class HookRateLimiter: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var windows: [String: (start: UInt64, count: Int)] = [:]

    init(limit: Int) {
        self.limit = limit
    }

    func admit(_ key: String) -> Bool {
        let now = HookWire.monotonicNanos()
        lock.lock()
        defer { lock.unlock() }
        if windows.count > 1_000 {
            windows = windows.filter { now &- $0.value.start < 1_000_000_000 }
        }
        var window = windows[key] ?? (start: now, count: 0)
        if now &- window.start >= 1_000_000_000 {
            window = (start: now, count: 0)
        }
        window.count += 1
        windows[key] = window
        if window.count == limit + 1 {
            AppLog.hooks.error("hook rate limit reached, dropping events")
        }
        return window.count <= limit
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
