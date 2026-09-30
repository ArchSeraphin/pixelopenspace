import AppKit
import Foundation
import PixelCore

/// Creates and wires the app's objects once (proposal 2.1). `AppEnvironment.shared` is reachable from the
/// `AppDelegate` and from the SwiftUI `App`:
/// ```swift
/// @main struct PixelOpenSpaceApp: App {
///     @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
///     private let environment = AppEnvironment.shared
///     var body: some Scene { WindowGroup { RootView(model: environment.model, commands: environment.commands) } }
/// }
/// ```
/// Files are loaded synchronously here (a few kilobytes); the hook server, the clock and the search for `claude`
/// start in `start()`, from `applicationDidFinishLaunching`.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let directories: AppDirectories
    let persistence: PersistenceStore
    let hookServer: HookServer
    let presenter: TerminalPresenter
    let sessions: SessionManager
    let locator: ClaudeLocator
    let notifications: NotificationBridge
    let model: AppModel
    let commands: CommandCenter

    private var started = false

    private init() {
        let directories = AppDirectories.standard()
        let directoryProblems = directories.prepare()
        self.directories = directories

        let persistence = PersistenceStore(directories: directories)
        let settings = persistence.loadSettings()
        let workspace = persistence.loadWorkspace()
        let board = persistence.loadTasks(agents: Set(workspace.value.agents.map(\.id)),
                                          projects: Set(workspace.value.projects.map(\.id)))
        self.persistence = persistence

        let hookServer = HookServer(directories: directories)
        let presenter = TerminalPresenter()
        let sessions = SessionManager(presenter: presenter, terminalPrefs: settings.value.terminal)
        let locator = ClaudeLocator(scratchDirectory: directories.run, home: directories.home)
        let notifications = NotificationBridge(prefs: settings.value.notifications)
        let model = AppModel(workspace: workspace, settings: settings, board: board,
                             extraWarnings: directoryProblems, sessions: sessions, hookServer: hookServer,
                             notifications: notifications, persistence: persistence, locator: locator)
        self.hookServer = hookServer
        self.presenter = presenter
        self.sessions = sessions
        self.locator = locator
        self.notifications = notifications
        self.model = model
        commands = CommandCenter(model: model)

        presenter.onTerminalShown = { [weak model] agentID in
            model?.acknowledge(agentID)
        }
    }

    /// `applicationWillFinishLaunching`: must precede any notification delivery.
    func prepareForLaunch() {
        NSWindow.allowsAutomaticWindowTabbing = false
        notifications.install()
    }

    /// `applicationDidFinishLaunching`: hook server, hook and clock loops, search for `claude`. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        model.start()
    }
}
