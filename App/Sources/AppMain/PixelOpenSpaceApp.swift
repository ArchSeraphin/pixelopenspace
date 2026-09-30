import AppKit
import PixelCore
import SwiftUI

/// Pixel Open Space (step 2a UI): one main window, detached terminal windows (one per agent), Settings, and the
/// menus built from `AppCommand`. Every object is created once by `AppEnvironment` (the delegate starts it).
@main
struct PixelOpenSpaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let environment: AppEnvironment
    /// UI state shared by the windows (one instance for the whole app).
    private let workbench: WorkbenchState

    init() {
        let environment = AppEnvironment.shared
        self.environment = environment
        workbench = WorkbenchState.shared(for: environment)
        // Main window reopened when a notification, a menu or a quit needs it while it is closed.
        workbench.startWatchingRequests()
    }

    var body: some Scene {
        Window("Pixel Open Space", id: WindowID.main) {
            RootView()
                .environment(environment.model)
                .environment(workbench)
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            AppMenuCommands(workbench: workbench)
        }

        WindowGroup("Terminal", id: WindowID.terminal, for: AgentID.self) { $agentID in
            DetachedTerminalWindow(agentID: $agentID)
                .environment(environment.model)
                .environment(workbench)
        }
        .defaultSize(width: 900, height: 560)

        Settings {
            SettingsView()
                .environment(environment.model)
                .environment(workbench)
        }
    }
}
