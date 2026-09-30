import PixelCore
import SwiftUI

/// Symbol and tint of each agent state. A state is always shown with its symbol AND its text, never by color
/// alone (proposal 7.9); the tint only reinforces it.
enum StateStyle {
    /// Symbol of a status-bar counter (the cards use `AgentStatusDisplay.symbolName`, which also depends on the
    /// tool or the wait).
    static func symbolName(for kind: AgentStateKind) -> String {
        switch kind {
        case .waitingInput: return "exclamationmark.bubble.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .done: return "checkmark.circle.fill"
        case .waitingBackground: return "hourglass"
        case .quotaPaused: return "clock"
        case .working: return "hammer.fill"
        case .thinking: return "ellipsis.bubble"
        case .launching: return "arrow.up.circle"
        case .idle: return "zzz"
        case .offline: return "power"
        }
    }

    /// Palette 7.1: alert orange (the yellow of the scene is unreadable as text on a light background), error red,
    /// OK green, screen glow, thinking lilac.
    static func tint(for kind: AgentStateKind) -> Color {
        switch kind {
        case .waitingInput: return Color(red: 0.89, green: 0.52, blue: 0.11)
        case .error: return Color(red: 0.84, green: 0.27, blue: 0.24)
        case .done: return Color(red: 0.30, green: 0.73, blue: 0.39)
        case .waitingBackground: return Color(red: 0.37, green: 0.38, blue: 0.81)
        case .quotaPaused: return Color(red: 0.95, green: 0.62, blue: 0.30)
        case .working: return Color(red: 0.23, green: 0.53, blue: 0.78)
        case .thinking: return Color(red: 0.65, green: 0.55, blue: 0.90)
        case .launching: return Color(red: 0.16, green: 0.62, blue: 0.56)
        case .idle: return Color.secondary
        case .offline: return Color.gray
        }
    }

    /// Short state name for the filter chip ("Filtre : en attente").
    static func filterName(for kind: AgentStateKind) -> String {
        switch kind {
        case .waitingInput: return "en attente"
        case .error: return "en erreur"
        case .done: return "tour terminé"
        case .waitingBackground: return "tâche de fond"
        case .quotaPaused: return "limite d'usage"
        case .working: return "au travail"
        case .thinking: return "réfléchit"
        case .launching: return "démarre"
        case .idle: return "au repos"
        case .offline: return "hors ligne"
        }
    }
}
