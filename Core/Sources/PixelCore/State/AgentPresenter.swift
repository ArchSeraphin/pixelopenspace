import Foundation

/// What the list view, the waiting tray and tooltips show for one agent. Text in French.
public struct AgentStatusDisplay: Equatable, Sendable {
    public var kind: AgentStateKind
    /// "Attend ta réponse", "Travaille", "Endormi"…
    public var title: String
    /// "Bash : rm -rf dist", the question asked, the error…
    public var detail: String?
    /// SF Symbols name.
    public var symbolName: String
    /// 0…3 (proposal 4.3): waiting 3, error 2, done/background/quota 1.
    public var urgency: Int
    /// Start of the oldest open wait, otherwise of the phase.
    public var since: Date
    /// "+1 attente", "2 sous-agents", "sans nouvelles", "mode dégradé".
    public var badges: [String]

    public init(kind: AgentStateKind, title: String, detail: String?, symbolName: String, urgency: Int, since: Date,
                badges: [String]) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.symbolName = symbolName
        self.urgency = urgency
        self.since = since
        self.badges = badges
    }
}

/// Pure projection of an agent's runtime state to text and icons (proposal 3.7, derived states of 4.3).
public enum AgentPresenter {
    /// Idle for longer than this: shown asleep (never confused with offline).
    public static let asleepAfter: TimeInterval = 600

    public static func present(_ r: AgentRuntime, now: Date) -> AgentStatusDisplay {
        var display: AgentStatusDisplay
        if let oldest = r.oldestWait {
            let reason = oldest.reason
            display = AgentStatusDisplay(kind: .waitingInput, title: waitingTitle(reason), detail: describe(reason),
                                         symbolName: symbolName(for: reason), urgency: AgentStateKind.waitingInput.urgency,
                                         since: oldest.since, badges: [])
            let others = r.pendingWaits.count - 1
            if others > 0 { display.badges.append("+\(plural(others, "attente", "attentes"))") }
        } else {
            display = present(r.phase, since: r.phaseSince, now: now)
        }
        // Liveness badges only make sense while a process runs.
        if r.pid != nil {
            if r.activeSubagents > 0 { display.badges.append(plural(r.activeSubagents, "sous-agent", "sous-agents")) }
            if r.stale { display.badges.append("sans nouvelles") }
            if r.hookHealth == .degraded { display.badges.append("mode dégradé") }
        }
        return display
    }

    /// "Nova, projet API, attend ta réponse : Bash : rm -rf dist, depuis 42 secondes, +1 attente" (VoiceOver).
    public static func accessibilityLabel(_ d: AgentStatusDisplay, agentName: String, projectName: String,
                                          now: Date) -> String {
        var state = lowercasingFirst(d.title)
        if let detail = d.detail, !detail.isEmpty { state += " : \(detail)" }
        var parts = [agentName, "projet \(projectName)", state,
                     "depuis \(DurationText.spoken(now.timeIntervalSince(d.since)))"]
        parts.append(contentsOf: d.badges)
        return parts.joined(separator: ", ")
    }

    // MARK: - Waits

    /// One line for a wait: "Bash : rm -rf dist", the question, the MCP message…
    public static func describe(_ reason: WaitReason) -> String {
        switch reason {
        case .permission(let tool, let summary):
            return summary.isEmpty ? tool : "\(tool) : \(summary)"
        case .question(let questions):
            guard let first = questions.first else { return "question" }
            let text = first.question.isEmpty ? first.header : first.question
            let base = text.isEmpty ? "question" : text
            return questions.count > 1 ? "\(base) (+\(questions.count - 1))" : base
        case .elicitation(let server, let message):
            if !message.isEmpty { return message }
            return server.map { "dialogue MCP : \($0)" } ?? "dialogue MCP"
        case .notification(let type):
            switch type {
            case "permission_prompt": return "demande de permission"
            case "agent_needs_input": return "demande une saisie"
            case "elicitation_dialog", "elicitation_url_dialog": return "dialogue MCP"
            case "quota_auto_resume_stale": return "limite réinitialisée : appuie sur Entrée dans le terminal"
            default: return "regarde le terminal"
            }
        case .terminal:
            return "regarde le terminal"
        }
    }

    public static func symbolName(for reason: WaitReason) -> String {
        if case .question = reason { return "questionmark.bubble.fill" }
        return "exclamationmark.bubble.fill"
    }

    static func waitingTitle(_ reason: WaitReason) -> String {
        if case .question = reason { return "Te pose une question" }
        return "Attend ta réponse"
    }

    // MARK: - Tools

    public static func symbolName(for tool: ToolKind) -> String {
        switch tool {
        case .read: return "doc.text"
        case .edit: return "pencil"
        case .bash: return "terminal"
        case .search: return "magnifyingglass"
        case .web: return "globe"
        case .subagent: return "person.2"
        case .question: return "questionmark.bubble"
        case .mcp: return "puzzlepiece"
        case .other: return "hammer"
        }
    }

    /// "lecture", "commande", "MCP : github"…
    public static func label(for tool: ToolKind) -> String {
        switch tool {
        case .read: return "lecture"
        case .edit: return "modification"
        case .bash: return "commande"
        case .search: return "recherche"
        case .web: return "web"
        case .subagent: return "sous-agent"
        case .question: return "question"
        case .mcp(let server): return "MCP : \(server)"
        case .other(let name): return name
        }
    }

    // MARK: - Phases

    static func present(_ phase: AgentPhase, since: Date, now: Date) -> AgentStatusDisplay {
        let title: String
        var detail: String?
        let symbol: String
        switch phase {
        case .offline(let reason):
            title = "Hors ligne"
            detail = describe(reason)
            symbol = "power"
        case .launching:
            title = "Démarre"
            symbol = "arrow.up.circle"
        case .idle:
            let asleep = now.timeIntervalSince(since) > asleepAfter
            title = asleep ? "Endormi" : "Au repos"
            symbol = asleep ? "moon.zzz" : "zzz"
        case .thinking:
            title = "Réfléchit"
            symbol = "ellipsis.bubble"
        case .working(let tool):
            title = "Travaille"
            detail = label(for: tool)
            symbol = symbolName(for: tool)
        case .done:
            title = "Tour terminé"
            symbol = "checkmark.circle.fill"
        case .waitingBackground(let tasks, let crons):
            title = "Attend une tâche de fond"
            var parts: [String] = []
            if tasks > 0 { parts.append(plural(tasks, "tâche de fond", "tâches de fond")) }
            if crons > 0 { parts.append(plural(crons, "tâche planifiée", "tâches planifiées")) }
            detail = parts.isEmpty ? nil : parts.joined(separator: " · ")
            symbol = "hourglass"
        case .quotaPaused(let resetAt, let autoResume):
            title = "En pause : limite d'usage"
            detail = describeQuota(resetAt: resetAt, autoResume: autoResume, now: now)
            symbol = "clock"
        case .error(let error):
            title = "Erreur"
            detail = describe(error)
            symbol = "exclamationmark.triangle.fill"
        }
        let kind = AgentState.phase(phase).kind
        return AgentStatusDisplay(kind: kind, title: title, detail: detail, symbolName: symbol, urgency: kind.urgency,
                                  since: since, badges: [])
    }

    public static func describe(_ reason: OfflineReason) -> String {
        switch reason {
        case .notStarted: return "pas encore lancé"
        case .closedByUser: return "session fermée"
        case .appRelaunched: return "l'app a redémarré"
        case .exited: return "session terminée"
        case .orphanElsewhere: return "tourne encore hors de l'app"
        }
    }

    public static func describe(_ error: AgentError) -> String {
        switch error {
        case .api(let type):
            switch type {
            case "overloaded": return "serveurs surchargés"
            case "server_error": return "erreur du serveur"
            case "invalid_request": return "requête refusée"
            case "model_not_found": return "modèle introuvable"
            case "max_output_tokens": return "réponse trop longue"
            case "cloud_credential_error": return "identifiants cloud invalides"
            case "rate_limit": return "limite d'usage"
            case "unknown": return "erreur API inconnue"
            default: return "erreur API : \(type)"
            }
        case .account(let type):
            switch type {
            case "authentication_failed": return "Claude Code n'est plus connecté : lance /login"
            case "oauth_org_not_allowed": return "organisation non autorisée"
            case "account_on_hold": return "compte suspendu"
            case "billing_error": return "problème de facturation"
            default: return "problème de compte : \(type)"
            }
        case .crashed(let code):
            return code.map { "arrêt inattendu (code \($0))" } ?? "arrêté par un signal"
        case .launchFailed(let message):
            return message.isEmpty ? "lancement impossible" : "lancement impossible : \(message)"
        }
    }

    static func describeQuota(resetAt: Date?, autoResume: Bool, now: Date) -> String {
        guard autoResume else { return "pas de reprise automatique" }
        guard let resetAt else { return "reprise automatique" }
        let remaining = resetAt.timeIntervalSince(now)
        return remaining > 0 ? "reprise automatique dans \(DurationText.short(remaining))" : "reprise imminente"
    }

    // MARK: - Text helpers

    /// French plural: 0 and 1 take the singular.
    static func plural(_ n: Int, _ singular: String, _ pluralForm: String) -> String {
        "\(n) \(abs(n) > 1 ? pluralForm : singular)"
    }

    static func lowercasingFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}

extension AgentRuntime {
    /// The oldest open wait, like `state`, but with a stable choice between waits opened at the same instant
    /// (dictionary order is not), so that the tray and the list do not flip between them. Use it rather than
    /// `state` to pick the wait to show or answer.
    public var oldestWait: PendingWait? {
        pendingWaits.min { lhs, rhs in
            lhs.value.since != rhs.value.since ? lhs.value.since < rhs.value.since
                                               : lhs.key.sortKey < rhs.key.sortKey
        }?.value
    }
}

extension WaitKey {
    var sortKey: String {
        switch self {
        case .tool(let id): return "0" + id
        case .elicitation(let id): return "1" + id
        case .notification(let type): return "2" + type
        case .terminal: return "3"
        }
    }
}

/// Durations for the UI, in French.
public enum DurationText {
    /// "12 s", "3 min", "1 h 05". Negative or non-finite durations read as "0 s".
    public static func short(_ seconds: TimeInterval) -> String {
        let total = wholeSeconds(seconds)
        if total < 60 { return "\(total) s" }
        if total < 3_600 { return "\(total / 60) min" }
        let minutes = (total % 3_600) / 60
        return "\(total / 3_600) h \(minutes < 10 ? "0" : "")\(minutes)"
    }

    /// "42 secondes", "3 minutes", "1 heure 5 minutes": for VoiceOver.
    public static func spoken(_ seconds: TimeInterval) -> String {
        let total = wholeSeconds(seconds)
        if total < 60 { return AgentPresenter.plural(total, "seconde", "secondes") }
        if total < 3_600 { return AgentPresenter.plural(total / 60, "minute", "minutes") }
        let hours = AgentPresenter.plural(total / 3_600, "heure", "heures")
        let minutes = (total % 3_600) / 60
        return minutes == 0 ? hours : "\(hours) \(AgentPresenter.plural(minutes, "minute", "minutes"))"
    }

    private static func wholeSeconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds, TimeInterval(Int.max / 2)).rounded(.down))
    }
}
