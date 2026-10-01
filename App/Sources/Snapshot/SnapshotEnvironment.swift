import AppKit
import Foundation
import PixelCore
import SwiftUI

/// The isolated state of the snapshot harness and the demo mode (step 3, task 1): nothing of the user's state is
/// read or written.
///
/// - A folder `$TMPDIR/PixelOpenSpace-snapshot-<pid>-<uuid>` (0700) is the `home` of `AppDirectories`: the
///   support folder, `run/` and the socket path fall inside it. Removed at the end, unless `--keep-state`.
/// - A throwaway preferences domain `fr.vv2.pixelopenspace.snapshot.<pid>`, given to the whole view hierarchy by
///   `.defaultAppStorage(_:)` and prefilled (`welcomeShown`, `boardPanelVisible`, `boardPanelWidth`); erased at the
///   end. The domain is named by its path, `<folder>/Preferences/fr.vv2.pixelopenspace.snapshot.<pid>`: its plist
///   lives in the temporary folder, never in `~/Library/Preferences` (where cfprefsd would write an emptied file
///   after the process has gone).
/// - An `AppEnvironment` in `.isolated` mode: no notification delegate, hook server, session, clock or search for
///   `claude`. The model receives the simulated open space (`commit`, `commitBoard`, `storeRuntime`), `now`, a
///   running hook server and a found `claude`, for display only.
///
/// Audit of what the views could reach (`grep -rn "UserDefaults\|AppStorage\|NSHomeDirectory\|AppEnvironment.shared\|
/// WorkbenchState.shared" App/Sources`): every `@AppStorage` (RootView, BoardPanelView) reads the throwaway domain
/// through `.defaultAppStorage`; `NSHomeDirectory()` is only read to abbreviate or standardize paths (no write);
/// `AppEnvironment.shared` and `WorkbenchState.shared` are only evaluated by `PixelOpenSpaceApp` and `AppDelegate`,
/// never launched here.
@MainActor
final class SnapshotEnvironment {
    static let folderPrefix = "PixelOpenSpace-snapshot-"
    static let defaultsDomainPrefix = "fr.vv2.pixelopenspace.snapshot."

    /// What went wrong while preparing the isolated state (French).
    struct SetupError: Error, CustomStringConvertible {
        var description: String
    }

    let root: URL
    /// "fr.vv2.pixelopenspace.snapshot.<pid>".
    let defaultsDomain: String
    /// The path that names the domain for `UserDefaults(suiteName:)`: `<root>/Preferences/<defaultsDomain>`.
    let defaultsPath: String
    let defaults: UserDefaults
    let keepState: Bool
    let environment: AppEnvironment
    let workbench: WorkbenchState
    /// What the model shows now (the empty workspace during the `empty` scenario).
    private(set) var showcase: ShowcaseWorkspace
    private var cleanedUp = false

    var model: AppModel { environment.model }

    init(keepState: Bool) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let manager = FileManager.default
        root = manager.temporaryDirectory
            .appendingPathComponent("\(Self.folderPrefix)\(pid)-\(UUID().uuidString)", isDirectory: true)
        if let problem = AppDirectories.makePrivateDirectory(root.path) {
            throw SetupError(description: problem)
        }
        self.keepState = keepState
        defaultsDomain = "\(Self.defaultsDomainPrefix)\(pid)"
        let preferences = root.appendingPathComponent("Preferences", isDirectory: true)
        defaultsPath = preferences.appendingPathComponent(defaultsDomain, isDirectory: false).path
        guard AppDirectories.makePrivateDirectory(preferences.path) == nil,
              let defaults = UserDefaults(suiteName: defaultsPath) else {
            try? manager.removeItem(at: root)
            throw SetupError(description: "Impossible d'ouvrir le domaine de préférences \(defaultsDomain).")
        }
        defaults.set(true, forKey: "welcomeShown")
        defaults.set(true, forKey: "boardPanelVisible")
        defaults.set(340.0, forKey: "boardPanelWidth")
        self.defaults = defaults

        // The socket path falls back to `<root>/tmp` when the default one is too long for `sun_path`, never to the
        // user's `$TMPDIR/pos-<uid>`. Nothing listens on it anyway.
        let directories = AppDirectories(home: root.path, temporaryDirectory: root.appendingPathComponent("tmp").path,
                                         uid: getuid())
        environment = AppEnvironment(directories: directories, mode: .isolated)
        workbench = WorkbenchState(model: environment.model, commands: environment.commands,
                                   presenter: environment.presenter)
        showcase = Showcase.appWorkspace()

        let model = environment.model
        model.hookServerState = .running
        model.environmentSource = .loginShell("/bin/zsh")
        // A path that exists nowhere: a launch attempt can never start a real `claude`.
        model.claude = ClaudeStatus(phase: .found, path: root.appendingPathComponent("bin/claude").path,
                                    version: ClaudeStatus.minimumVersion, error: nil, searched: [])
        load(showcase)
        // The fresh temporary files load without a warning; nothing to report about them.
        model.dismissLoadWarnings()
    }

    /// Puts a simulated open space in the model: workspace, board, every agent's runtime, `now`. The selection is
    /// cleared.
    func load(_ showcase: ShowcaseWorkspace) {
        self.showcase = showcase
        let model = self.model
        model.select(agent: nil)
        model.select(project: nil)
        model.commit(showcase.workspace)
        model.commitBoard(showcase.board)
        for id in model.runtimes.keys where showcase.runtimes[id] == nil {
            model.forgetRuntime(id)
        }
        applyRuntimes(showcase.runtimes)
        model.now = showcase.now
    }

    /// Replaces the runtimes of the agents given (demo trials and animation); an agent without one shows offline.
    func applyRuntimes(_ runtimes: [AgentID: AgentRuntime]) {
        let model = self.model
        for agent in model.workspace.agents {
            let runtime = runtimes[agent.id] ?? AgentRuntime(phase: .offline(.notStarted), phaseSince: showcase.now)
            model.storeRuntime(runtime, for: agent.id)
        }
    }

    /// The main window's root view, with its environments and the throwaway preferences.
    func rootView() -> some View {
        RootView()
            .environment(model)
            .environment(workbench)
            .defaultAppStorage(defaults)
    }

    /// Writes what the model still holds (inside the temporary folder), then erases the preferences domain and
    /// removes the folder (unless `--keep-state`). Idempotent.
    func cleanUp() async {
        guard !cleanedUp else { return }
        await model.flushPersistence()
        removeEverything()
    }

    /// The synchronous part of `cleanUp()`, for an interruption.
    func removeEverything() {
        guard !cleanedUp else { return }
        cleanedUp = true
        Self.erase(defaultsPath: defaultsPath, root: keepState ? nil : root)
    }

    /// Erases the preferences domain named by `defaultsPath`, then removes `root` if given (the domain's file with
    /// it). Callable from any thread (the watchdog).
    nonisolated static func erase(defaultsPath: String, root: URL?) {
        UserDefaults(suiteName: defaultsPath)?.removePersistentDomain(forName: defaultsPath)
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// The application of the isolated modes. In the snapshot harness, nothing may take the focus: activating the app
/// is refused (`WorkbenchState.bringMainWindowForward()` asks for it when a sheet opens).
final class IsolatedApplication: NSApplication {
    /// Set by the snapshot harness before the first window.
    nonisolated(unsafe) static var refusesActivation = false

    override func activate() {
        guard !Self.refusesActivation else { return }
        super.activate()
    }

    override func activate(ignoringOtherApps flag: Bool) {
        guard !Self.refusesActivation else { return }
        super.activate(ignoringOtherApps: flag)
    }
}

/// The main window of the isolated modes: an `NSWindow` (not restorable) whose view hosts `RootView`. Hidden in the
/// snapshot harness: never key nor main, transparent, click-through, kept at the size asked even when the screen is
/// smaller.
final class IsolatedWindow: NSWindow {
    var isHiddenForSnapshot = false

    override var canBecomeKey: Bool { isHiddenForSnapshot ? false : super.canBecomeKey }
    override var canBecomeMain: Bool { isHiddenForSnapshot ? false : super.canBecomeMain }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        isHiddenForSnapshot ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    /// A titled window of `contentSize` points at the top of `screen`, showing `content`. SwiftUI toolbars and titles
    /// are not bridged to the window: the harness's windows have no toolbar (décision 12).
    static func make<Content: View>(title: String, contentSize: CGSize, hidden: Bool, screen: NSScreen?,
                                    content: Content) -> IsolatedWindow {
        let window = IsolatedWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                    backing: .buffered, defer: false, screen: screen)
        window.isHiddenForSnapshot = hidden
        window.title = title
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = [.minSize]
        hosting.sceneBridgingOptions = []
        window.contentView = hosting
        window.setContentSize(contentSize)
        if hidden {
            hideForSnapshot(window)
        }
        if let screen {
            let visible = screen.visibleFrame
            let frame = window.frame
            window.setFrameOrigin(NSPoint(x: visible.minX + max(0, (visible.width - frame.width) / 2),
                                          y: visible.maxY - frame.height))
        }
        return window
    }

    /// Any window of the app in the snapshot harness: transparent and click-through, so that nothing shows and
    /// nothing takes a click. Its drawing still renders at the screen's scale.
    static func hideForSnapshot(_ window: NSWindow) {
        if window.alphaValue != 0 { window.alphaValue = 0 }
        if !window.ignoresMouseEvents { window.ignoresMouseEvents = true }
        window.isRestorable = false
    }

    /// The screen the snapshot harness draws on: the finest one (highest backing scale), the main screen among
    /// equals. With an external 1x monitor as the main screen, the built-in Retina display: the captures then have
    /// the scale of a Retina Mac, where the overview zoom is at rest (7.3).
    static func captureScreen() -> NSScreen? {
        guard var best = NSScreen.main ?? NSScreen.screens.first else { return nil }
        for screen in NSScreen.screens where screen.backingScaleFactor > best.backingScaleFactor {
            best = screen
        }
        return best
    }

    /// Moves a top-level window that lies on another screen (or none) to the top left of `screen`, so that it
    /// draws at that screen's scale. Sheets and child windows follow their parent.
    static func keep(_ window: NSWindow, on screen: NSScreen) {
        guard window.sheetParent == nil, window.parent == nil,
              window.screen.flatMap({ number(of: $0) }) != number(of: screen) else { return }
        let visible = screen.visibleFrame
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 24, y: visible.maxY - 24))
    }

    private static func number(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
