@preconcurrency import AppKit
import PixelCore

/// Observes key presses aimed at an agent's terminal and reports their class (proposal 4.3, T23): a keystroke tones a
/// wait down and triggers a new screen reading. SwiftTerm's `keyDown` is not overridable, so this is a local event
/// monitor placed ahead of the view (the approach SwiftTerm documents for hosts); it never consumes the event.
@MainActor
final class KeystrokeMonitor {
    private var token: Any?

    func install() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags.rawValue
            MainActor.assumeIsolated {
                KeystrokeMonitor.route(keyCode: keyCode, modifierFlags: flags)
            }
            return event
        }
    }

    func uninstall() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    /// Reports the key to the terminal that has keyboard focus, if any.
    static func route(keyCode: UInt16, modifierFlags: UInt) {
        guard let keyClass = classify(keyCode: keyCode, modifierFlags: NSEvent.ModifierFlags(rawValue: modifierFlags)),
              let terminal = focusedTerminal() else { return }
        terminal.onKeystroke?(keyClass)
    }

    /// `nil` for Command shortcuts: they go to the menus, not to the program.
    static func classify(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> KeyClass? {
        if modifierFlags.contains(.command) { return nil }
        switch keyCode {
        case 36, 76: // Return, keypad Enter
            return .enter
        case 53: // Escape
            return .escape
        case 115, 116, 119, 121, 123, 124, 125, 126: // Home, Page Up, End, Page Down, arrows
            return .navigation
        case 48: // Tab
            return .control
        default:
            return modifierFlags.contains(.control) ? .control : .printable
        }
    }

    private static func focusedTerminal() -> AgentTerminalView? {
        var view = NSApplication.shared.keyWindow?.firstResponder as? NSView
        while let current = view {
            if let terminal = current as? AgentTerminalView { return terminal }
            view = current.superview
        }
        return nil
    }
}
