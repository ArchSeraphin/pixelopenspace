import PixelCore

/// French explanations of Claude Code's permission modes (https://code.claude.com/docs/en/permissions.md).
enum PermissionModeInfo {
    static func summary(_ mode: PermissionMode) -> String {
        switch mode {
        case .default: return "demande avant les actions sensibles"
        case .acceptEdits: return "accepte seul les modifications de fichiers du dossier"
        case .plan: return "explore et propose, sans modifier les fichiers"
        case .auto: return "accepte seul, avec des vérifications de sécurité"
        case .dontAsk: return "refuse ce qui demanderait une autorisation"
        case .bypassPermissions: return "aucune demande d'autorisation"
        }
    }

    /// Modes that let Claude act without asking: shown with a warning.
    static func isRisky(_ mode: PermissionMode) -> Bool {
        mode == .bypassPermissions
    }

    static let bypassWarning = "AUCUN GARDE-FOU : Claude exécute tout sans demander. À réserver à un environnement isolé."
}
