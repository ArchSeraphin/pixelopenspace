import Foundation
import PixelCore

/// A window-wide banner (mockup 6(o)). Only the most serious one is shown in full; the others are one click away.
struct Banner: Identifiable, Equatable {
    enum Severity: Int, Comparable {
        case error = 0, warning = 1, info = 2

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    let severity: Severity
    let symbol: String
    let title: String
    let message: String?
    let actions: [BannerAction]
}

/// What a banner button does (performed by `BannerStackView`).
enum BannerAction: Hashable {
    case openOtherInstance
    case chooseClaudePath
    case redetectClaude
    case showClaudeSetup
    case openTerminal(AgentID)
    case terminateOrphan(AgentID)
    case cancelQuitWait
    /// "Tout relancer": the sessions checked by default, post-its in progress put back to do.
    case relaunchAll
    /// "Choisir…": the "Relancer les sessions" sheet (mockup 6(p)).
    case chooseRelaunch
    /// "Plus tard": hides the relaunch banner until the next launch.
    case dismissRelaunch
    case dismissLoadWarnings
    case openNotificationSettings
    case hideNotificationWarning

    var title: String {
        switch self {
        case .openOtherInstance: return "Passer à l'autre copie"
        case .chooseClaudePath: return "Indiquer le chemin…"
        case .redetectClaude: return "Réessayer"
        case .showClaudeSetup: return "Détails…"
        case .openTerminal: return "Terminal"
        case .terminateOrphan: return "Terminer ce processus"
        case .cancelQuitWait: return "Ne plus quitter"
        case .relaunchAll: return "Tout relancer"
        case .chooseRelaunch: return "Choisir…"
        case .dismissRelaunch: return "Plus tard"
        case .dismissLoadWarnings: return "OK"
        case .openNotificationSettings: return "Réglages Système…"
        case .hideNotificationWarning: return "Masquer"
        }
    }
}

/// Builds the banners from the model's state, most serious first.
@MainActor
enum BannerCatalog {
    static func banners(model: AppModel, showNotificationWarning: Bool) -> [Banner] {
        var result: [Banner] = []
        if let banner = hookServerBanner(model) { result.append(banner) }
        if let banner = claudeBanner(model) { result.append(banner) }
        if let banner = accountBanner(model) { result.append(banner) }
        if let banner = quotaBanner(model) { result.append(banner) }
        if let banner = degradedBanner(model) { result.append(banner) }
        if let banner = orphanBanner(model) { result.append(banner) }
        if let banner = environmentBanner(model) { result.append(banner) }
        if let banner = relaunchBanner(model) { result.append(banner) }
        if model.isWaitingForTurnsToQuit {
            result.append(Banner(id: "quit-wait", severity: .info, symbol: "hourglass",
                                 title: "Pixel Open Space quittera à la fin des tours en cours",
                                 message: "Rien de nouveau ne sera envoyé aux agents. Une attente reste à traiter par toi.",
                                 actions: [.cancelQuitWait]))
        }
        if !model.loadWarnings.isEmpty {
            result.append(Banner(id: "load", severity: .warning, symbol: "doc.badge.exclamationmark",
                                 title: "Au chargement des fichiers de l'app",
                                 message: model.loadWarnings.joined(separator: "\n"),
                                 actions: [.dismissLoadWarnings]))
        }
        if model.notificationsDenied, showNotificationWarning {
            result.append(Banner(id: "notifications", severity: .info, symbol: "bell.slash",
                                 title: "Notifications refusées",
                                 message: "Seul le badge du Dock compte les agents qui attendent. Autorise les "
                                     + "notifications de Pixel Open Space pour être prévenu en arrière-plan.",
                                 actions: [.openNotificationSettings, .hideNotificationWarning]))
        }
        return result.enumerated()
            .sorted { ($0.element.severity, $0.offset) < ($1.element.severity, $1.offset) }
            .map(\.element)
    }

    private static func hookServerBanner(_ model: AppModel) -> Banner? {
        let problem = model.hookStatus.problem
        switch model.hookServerState {
        case .anotherInstance:
            return Banner(id: "hooks", severity: .error, symbol: "xmark.octagon.fill",
                          title: "UNE AUTRE COPIE DE PIXEL OPEN SPACE EST OUVERTE",
                          message: problem, actions: [.openOtherInstance])
        case .failed:
            return Banner(id: "hooks", severity: .error, symbol: "xmark.octagon.fill",
                          title: "LES HOOKS NE FONCTIONNENT PAS", message: problem, actions: [])
        case .helperMissing:
            return Banner(id: "hooks", severity: .warning, symbol: "exclamationmark.triangle.fill",
                          title: "PIXEL-HOOK EST ABSENT DE L'APP", message: problem, actions: [])
        case .running, .stopped:
            return nil
        }
    }

    private static func claudeBanner(_ model: AppModel) -> Banner? {
        let status = model.claude
        let minimum = ClaudeStatus.minimumVersion.description
        switch status.phase {
        case .detecting:
            return nil
        case .notFound:
            return Banner(id: "claude", severity: .error, symbol: "xmark.octagon.fill",
                          title: "CLAUDE CODE INTROUVABLE",
                          message: status.error ?? "Indique où se trouve l'exécutable claude.",
                          actions: [.chooseClaudePath, .redetectClaude, .showClaudeSetup])
        case .versionUnknown:
            return Banner(id: "claude", severity: .warning, symbol: "questionmark.circle",
                          title: "VERSION DE CLAUDE CODE INCONNUE",
                          message: (status.error ?? "") + " Les agents peuvent être lancés ; version minimale conseillée : \(minimum).",
                          actions: [.redetectClaude, .showClaudeSetup])
        case .found:
            guard !status.meetsMinimum else { return nil }
            let version = status.version?.description ?? "?"
            return Banner(id: "claude", severity: .warning, symbol: "exclamationmark.triangle.fill",
                          title: "CLAUDE CODE \(version) EST TROP ANCIEN",
                          message: "Version minimale : \(minimum). Mets Claude Code à jour (claude update), "
                              + "puis réessaie : certains états pourraient manquer.",
                          actions: [.redetectClaude, .showClaudeSetup])
        }
    }

    private static func accountBanner(_ model: AppModel) -> Banner? {
        guard case .account(let type)? = model.globalIssues[.account] else { return nil }
        let agentID = firstAgent(model) { phase in
            if case .error(.account) = phase { return true }
            return false
        }
        return Banner(id: "account", severity: .error, symbol: "person.crop.circle.badge.xmark",
                      title: "CLAUDE CODE N'EST PLUS CONNECTÉ",
                      message: AgentPresenter.describe(AgentError.account(type)),
                      actions: agentID.map { [.openTerminal($0)] } ?? [])
    }

    private static func quotaBanner(_ model: AppModel) -> Banner? {
        guard case .quota(let resetAt)? = model.globalIssues[.quota] else { return nil }
        let paused = model.liveStatusSummary.count(of: .quotaPaused)
        var title = "LIMITE D'USAGE ATTEINTE"
        if let resetAt { title += " · reprise vers \(clockText(resetAt))" }
        if paused > 0 { title += " · \(paused) en pause" }
        return Banner(id: "quota", severity: .warning, symbol: "clock",
                      title: title, message: "Rien ne sera envoyé aux agents d'ici là.", actions: [])
    }

    private static func degradedBanner(_ model: AppModel) -> Banner? {
        let status = model.hookStatus
        guard status.server.isListening, let first = status.degradedAgents.first else { return nil }
        return Banner(id: "degraded", severity: .warning, symbol: "exclamationmark.triangle.fill",
                      title: "MODE DÉGRADÉ",
                      message: status.problem, actions: [.openTerminal(first)])
    }

    /// An agent's previous `claude` still runs after a crash of the app (proposal 2.5): it cannot be resumed here.
    private static func orphanBanner(_ model: AppModel) -> Banner? {
        let orphans = model.agentsInOrder.filter { model.runtime(for: $0.id)?.phase == .offline(.orphanElsewhere) }
        guard let first = orphans.first else { return nil }
        let names = orphans.map(\.name).joined(separator: ", ")
        return Banner(id: "orphans", severity: .warning, symbol: "exclamationmark.triangle.fill",
                      title: "SESSION ENCORE OUVERTE HORS DE L'APP · \(names)",
                      message: "Après un arrêt brutal de l'app, la session précédente tourne toujours. Elle ne peut "
                          + "pas être reprise ici tant que ce processus vit : termine-le, ou laisse-le finir.",
                      actions: [.terminateOrphan(first.id)])
    }

    /// After a restart or a crash (proposal 2.5): the sessions of the previous run that can be relaunched. Nothing
    /// starts until the user answers; "Tout relancer" only takes the lines checked by default (resume, fork) and
    /// puts their post-its in progress back to do, "Choisir…" opens the sheet for the rest.
    private static func relaunchBanner(_ model: AppModel) -> Banner? {
        guard let offer = model.relaunchOffer else { return nil }
        let count = offer.relaunchable.count
        let title = count == 1 ? "1 session peut être relancée" : "\(count) sessions peuvent être relancées"
        func names(_ lines: [RelaunchCandidate]) -> String {
            lines.map { model.names(of: $0.agentID).agent }.joined(separator: ", ")
        }
        var message = names(offer.relaunchable) + ". Rien ne repart tout seul."
        let byDefault = offer.byDefault
        if byDefault.isEmpty {
            message += " Leur conversation ne peut pas être reprise : « Choisir… » démarre une nouvelle session."
        } else if byDefault.count < count {
            message += " « Tout relancer » reprend \(names(byDefault)) ; les autres se choisissent dans « Choisir… »."
        }
        if byDefault.contains(where: { $0.cardInProgress != nil }) {
            message += " Avec « Tout relancer », les post-its en cours sont remis à faire ; « Choisir… » permet de les "
                + "continuer."
        }
        var actions: [BannerAction] = byDefault.isEmpty ? [] : [.relaunchAll]
        actions += [.chooseRelaunch, .dismissRelaunch]
        return Banner(id: "relaunch", severity: .info, symbol: "arrow.clockwise.circle", title: title,
                      message: message, actions: actions)
    }

    private static func environmentBanner(_ model: AppModel) -> Banner? {
        guard case .appFallback(let shell, let reason) = model.environmentSource else { return nil }
        return Banner(id: "environment", severity: .warning, symbol: "exclamationmark.triangle",
                      title: "ENVIRONNEMENT DU SHELL INDISPONIBLE",
                      message: "Le PATH de ton shell (\(shell)) n'a pas pu être lu : \(reason). Les agents reçoivent "
                          + "l'environnement minimal de l'app ; des outils (node, git…) peuvent manquer.",
                      actions: [.redetectClaude])
    }

    private static func firstAgent(_ model: AppModel, where matches: (AgentPhase) -> Bool) -> AgentID? {
        model.agentsInOrder.first { agent in
            model.runtime(for: agent.id).map { matches($0.phase) } ?? false
        }?.id
    }

    /// "15 h 45".
    static func clockText(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        return "\(hour) h \(minute < 10 ? "0" : "")\(minute)"
    }
}
