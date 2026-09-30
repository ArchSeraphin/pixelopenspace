import Foundation
import PixelIPC

/// Paths of the app's files (proposal 4.5):
/// `~/Library/Application Support/PixelOpenSpace/{state,run,logs,backups}`. Every directory is private (0700):
/// `run/` holds the hook socket and token, `state/` the workspace and the board, `logs/` the optional hook log.
struct AppDirectories: Sendable {
    let home: String
    let support: URL
    /// The hook socket (`HookWire.socketPath`): `run/hook.sock`, or `$TMPDIR/pos-<uid>/hook.sock` when the default
    /// path would be too long for `sun_path`.
    let socketPath: String

    var state: URL { support.appendingPathComponent("state", isDirectory: true) }
    var run: URL { support.appendingPathComponent("run", isDirectory: true) }
    var logs: URL { support.appendingPathComponent("logs", isDirectory: true) }
    var backups: URL { support.appendingPathComponent("backups", isDirectory: true) }
    var stateBackups: URL { backups.appendingPathComponent("state", isDirectory: true) }

    var workspaceFile: URL { state.appendingPathComponent("workspace.json", isDirectory: false) }
    var settingsFile: URL { state.appendingPathComponent("settings.json", isDirectory: false) }
    /// The cork board: post-its, queued instructions, prompt templates.
    var tasksFile: URL { state.appendingPathComponent("tasks.json", isDirectory: false) }
    /// Passed to `claude --settings`; regenerated at every app launch.
    var hookSettingsFile: URL { run.appendingPathComponent("hooks-settings.json", isDirectory: false) }
    /// Token for sessions started outside the app, next to the socket (`HookWire.tokenPath`).
    var tokenPath: String { HookWire.tokenPath(socketPath: socketPath) }

    init(home: String, temporaryDirectory: String?, uid: UInt32) {
        var home = home
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        self.home = home
        support = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("PixelOpenSpace", isDirectory: true)
        socketPath = HookWire.socketPath(home: home, temporaryDirectory: temporaryDirectory, uid: uid)
    }

    /// The current user's directories.
    static func standard() -> AppDirectories {
        AppDirectories(home: NSHomeDirectory(),
                       temporaryDirectory: ProcessInfo.processInfo.environment["TMPDIR"],
                       uid: getuid())
    }

    /// Creates the directories with mode 0700 (existing ones are tightened to 0700). Returns a French message for
    /// each directory that could not be prepared; the app keeps running and reports it.
    func prepare() -> [String] {
        var problems: [String] = []
        for directory in [support, state, run, logs, backups, stateBackups] {
            if let problem = Self.makePrivateDirectory(directory.path) { problems.append(problem) }
        }
        // The socket's own directory when it falls back to $TMPDIR (UnixSocketServer creates it 0700 if missing).
        let socketDirectory = (socketPath as NSString).deletingLastPathComponent
        if socketDirectory != run.path, FileManager.default.fileExists(atPath: socketDirectory) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: socketDirectory)
        }
        return problems
    }

    /// `mkdir -p` then `chmod 0700`. `nil` on success.
    static func makePrivateDirectory(_ path: String) -> String? {
        let manager = FileManager.default
        do {
            try manager.createDirectory(atPath: path, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            return nil
        } catch {
            return "Impossible de préparer le dossier \(path) : \(error.localizedDescription)"
        }
    }

    /// Writes `data` atomically with mode 0600 (tokens, settings, state files).
    static func writePrivateFile(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
