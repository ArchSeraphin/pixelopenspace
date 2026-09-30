import AppKit

/// Application delegate, installed by the SwiftUI `App` with `@NSApplicationDelegateAdaptor(AppDelegate.self)`.
///
/// - Closing the last window does not quit: sessions keep running, the Dock and the menu bar stay (proposal 2.5).
/// - ⌘Q with busy agents shows the quit sheet (`AppModel.quitRequest`) instead of quitting; see `AppModel+Quit`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment { AppEnvironment.shared }

    func applicationWillFinishLaunching(_ notification: Notification) {
        environment.prepareForLaunch()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        environment.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        environment.model.handleTerminationRequest()
    }
}
