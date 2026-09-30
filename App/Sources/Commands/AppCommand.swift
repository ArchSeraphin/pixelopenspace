import SwiftUI

/// Menu a command belongs to (proposal 3.16).
enum AppMenu: String, CaseIterable, Sendable {
    /// Fichier.
    case file
    /// Aller.
    case go
    /// Agent.
    case agent
    /// Présentation.
    case view
    /// Pixel Open Space (application menu).
    case app

    var title: String {
        switch self {
        case .file: return "Fichier"
        case .go: return "Aller"
        case .agent: return "Agent"
        case .view: return "Présentation"
        case .app: return "Pixel Open Space"
        }
    }
}

/// A keyboard shortcut described without SwiftUI (key + modifiers), for menus, the palette and help texts.
struct CommandShortcut: Equatable, Sendable {
    enum Key: Equatable, Sendable {
        case character(Character)
        case leftArrow, rightArrow
    }

    var key: Key
    var command = true
    var shift = false
    var option = false
    var control = false

    /// "⇧⌘N", "⌥⌘→".
    var displayText: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        switch key {
        case .character(let character): text += String(character).uppercased()
        case .leftArrow: text += "←"
        case .rightArrow: text += "→"
        }
        return text
    }
}

/// Every action of the app that menus and the ⌘K palette offer (proposal 3.16). `CommandCenter.perform(_:)` is the
/// only way to run one, so no action exists only in one place. "Aller au projet n" (⌘1…⌘9) is separate:
/// `CommandCenter.selectProject(number:)`.
enum AppCommand: String, CaseIterable, Identifiable, Sendable {
    case newProject
    case newAgent
    case openTerminal
    case interrupt
    case relaunchSession
    case closeSession
    case removeAgent
    case nextWaitingAgent
    case previousWaitingAgent
    case nextAgent
    case previousAgent
    case toggleTerminalPanel
    case redetectClaude
    case showSettings

    var id: String { rawValue }

    /// French menu title.
    var title: String {
        switch self {
        case .newProject: return "Nouveau projet…"
        case .newAgent: return "Nouvel agent…"
        case .openTerminal: return "Ouvrir le terminal"
        case .interrupt: return "Interrompre"
        case .relaunchSession: return "Relancer la session"
        case .closeSession: return "Fermer la session"
        case .removeAgent: return "Retirer l'agent"
        case .nextWaitingAgent: return "Agent en attente suivant"
        case .previousWaitingAgent: return "Agent en attente précédent"
        case .nextAgent: return "Agent suivant"
        case .previousAgent: return "Agent précédent"
        case .toggleTerminalPanel: return "Afficher ou masquer le terminal"
        case .redetectClaude: return "Rechercher Claude Code"
        case .showSettings: return "Réglages…"
        }
    }

    var menu: AppMenu {
        switch self {
        case .newProject, .newAgent: return .file
        case .nextWaitingAgent, .previousWaitingAgent, .nextAgent, .previousAgent: return .go
        case .openTerminal, .interrupt, .relaunchSession, .closeSession, .removeAgent: return .agent
        case .toggleTerminalPanel: return .view
        case .redetectClaude, .showSettings: return .app
        }
    }

    /// SF Symbol for the palette and toolbar buttons.
    var symbolName: String {
        switch self {
        case .newProject: return "folder.badge.plus"
        case .newAgent: return "person.badge.plus"
        case .openTerminal: return "terminal"
        case .interrupt: return "stop.circle"
        case .relaunchSession: return "arrow.clockwise"
        case .closeSession: return "power"
        case .removeAgent: return "person.badge.minus"
        case .nextWaitingAgent: return "exclamationmark.bubble"
        case .previousWaitingAgent: return "exclamationmark.bubble"
        case .nextAgent: return "arrow.right"
        case .previousAgent: return "arrow.left"
        case .toggleTerminalPanel: return "rectangle.bottomthird.inset.filled"
        case .redetectClaude: return "magnifyingglass"
        case .showSettings: return "gearshape"
        }
    }

    /// Table of proposal 3.16. ⌘. is ⇧⌘; on an AZERTY keyboard (checked in step 5). `nil` = menu and palette only.
    var shortcut: CommandShortcut? {
        switch self {
        case .newProject: return CommandShortcut(key: .character("n"), option: true)
        case .newAgent: return CommandShortcut(key: .character("n"), shift: true)
        case .openTerminal: return CommandShortcut(key: .character("t"))
        case .interrupt: return CommandShortcut(key: .character("."))
        case .relaunchSession: return CommandShortcut(key: .character("r"), shift: true)
        case .nextWaitingAgent: return CommandShortcut(key: .character("'"))
        case .previousWaitingAgent: return CommandShortcut(key: .character("'"), shift: true)
        case .nextAgent: return CommandShortcut(key: .rightArrow, option: true)
        case .previousAgent: return CommandShortcut(key: .leftArrow, option: true)
        case .toggleTerminalPanel: return CommandShortcut(key: .character("t"), option: true)
        // ⌘, already belongs to the "Réglages…" item SwiftUI adds for the Settings scene.
        case .showSettings, .closeSession, .removeAgent, .redetectClaude: return nil
        }
    }

    /// The shortcut for SwiftUI's `.keyboardShortcut(_:)`.
    @MainActor
    var keyboardShortcut: KeyboardShortcut? {
        guard let shortcut else { return nil }
        let key: KeyEquivalent
        switch shortcut.key {
        case .character(let character): key = KeyEquivalent(character)
        case .leftArrow: key = .leftArrow
        case .rightArrow: key = .rightArrow
        }
        var modifiers: EventModifiers = []
        if shortcut.command { modifiers.insert(.command) }
        if shortcut.shift { modifiers.insert(.shift) }
        if shortcut.option { modifiers.insert(.option) }
        if shortcut.control { modifiers.insert(.control) }
        return KeyboardShortcut(key, modifiers: modifiers)
    }

    /// Commands of a menu, in declaration order.
    static func commands(in menu: AppMenu) -> [AppCommand] {
        allCases.filter { $0.menu == menu }
    }

    /// "Aller au projet n" (⌘1…⌘9).
    static let projectShortcutNumbers = 1...9

    static func selectProjectTitle(_ number: Int) -> String {
        "Aller au projet \(number)"
    }
}
