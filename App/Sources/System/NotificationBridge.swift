import AppKit
import PixelCore
@preconcurrency import UserNotifications

/// Who a notification is about.
struct NotificationSubject: Sendable, Equatable {
    var agentID: AgentID
    var agentName: String
    var projectID: ProjectID
    var projectName: String
}

/// macOS notifications (proposal 3.12).
///
/// - One notification per agent: `agent-<id>-waiting`, `-done` and `-error` replace each other, so an agent never
///   has more than its latest state in Notification Center. `threadIdentifier` = project, `userInfo["agentID"]`.
/// - Posts are debounced by 1 s per agent: a wait lifted (or superseded) within that second posts nothing, nor while
///   the permission is being asked.
/// - Waiting: always posted, even with the app in front (decision 18, `NotificationPrefs.waitingAlways`).
///   Turn done: only when the app is in the background or the agent is out of sight (`isAgentVisible`).
///   Errors: only when the app is in the background.
/// - Global issues (usage limit, signed out): one notification for all agents.
/// - Authorization is requested lazily, the first time something is posted. Refused: the Dock badge remains.
/// - Clicking a notification activates the app and calls `onOpenAgent`.
@MainActor
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let agentKey = "agentID"
    static let debounce: Duration = .seconds(1)

    enum Kind: String, CaseIterable, Sendable {
        case waiting, done, error
    }

    var prefs: NotificationPrefs
    /// Whether the user can see the agent now (its card or its terminal on screen); `nil` counts as visible.
    var isAgentVisible: (@MainActor (AgentID) -> Bool)?
    /// Notification clicked: bring this agent into view.
    var onOpenAgent: (@MainActor (AgentID) -> Void)?
    /// Called just before macOS asks for the permission, so the app can say why (in context).
    var onWillRequestAuthorization: (@MainActor () -> Void)?
    /// Called when the permission is known to be refused or granted.
    var onAuthorizationChange: (@MainActor (_ denied: Bool) -> Void)?

    /// A debounced post, from `post` until it is delivered, cancelled or superseded.
    private struct PendingPost {
        let id: UUID
        let kind: Kind
        let task: Task<Void, Never>
    }

    private(set) var authorizationDenied = false
    private var authorizationTask: Task<Bool, Never>?
    private var pending: [AgentID: PendingPost] = [:]
    /// Global posts waiting for the permission; `withdrawGlobal` cancels them.
    private var pendingGlobal: [GlobalIssueKind: Task<Void, Never>] = [:]

    init(prefs: NotificationPrefs) {
        self.prefs = prefs
        super.init()
    }

    /// Must run in `applicationWillFinishLaunching`, so that a click that launched the app is delivered.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Agents

    func post(_ notification: AgentNotification, subject: NotificationSubject) {
        let kind: Kind
        switch notification {
        case .waiting: kind = .waiting
        case .turnDone: kind = .done
        case .error: kind = .error
        }
        pending[subject.agentID]?.task.cancel()
        let id = UUID()
        let task = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard let self, !Task.isCancelled else { return }
            // Still pending while `deliver` waits for the permission: `withdraw` can cancel it until the post.
            await self.deliver(notification, kind: kind, subject: subject)
            if self.pending[subject.agentID]?.id == id {
                self.pending[subject.agentID] = nil
            }
        }
        pending[subject.agentID] = PendingPost(id: id, kind: kind, task: task)
    }

    /// Cancels a pending post and removes the delivered notifications of these kinds (the wait was answered…).
    func withdraw(agentID: AgentID, kinds: [Kind] = Kind.allCases) {
        if let post = pending[agentID], kinds.contains(post.kind) {
            post.task.cancel()
            pending[agentID] = nil
        }
        let identifiers = kinds.map { Self.identifier(agentID, $0) }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Runs in the pending post's task: a cancellation while the permission is asked drops the post.
    private func deliver(_ notification: AgentNotification, kind: Kind, subject: NotificationSubject) async {
        let appActive = NSApplication.shared.isActive
        switch kind {
        case .waiting:
            guard prefs.waitingAlways || !appActive else { return }
        case .done:
            let visible = isAgentVisible?(subject.agentID) ?? true
            guard prefs.turnDoneWhenInBackground, !appActive || !visible else { return }
        case .error:
            guard !appActive else { return }
        }
        guard await ensureAuthorized(), !Task.isCancelled else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(subject.agentName) · \(subject.projectName)"
        content.body = body(for: notification)
        content.sound = .default
        content.threadIdentifier = subject.projectID.description
        content.userInfo = [Self.agentKey: subject.agentID.description]
        content.interruptionLevel = .active

        let others = Kind.allCases.filter { $0 != kind }.map { Self.identifier(subject.agentID, $0) }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: others)
        center.removeDeliveredNotifications(withIdentifiers: others)
        Self.add(UNNotificationRequest(identifier: Self.identifier(subject.agentID, kind), content: content, trigger: nil))
    }

    private func body(for notification: AgentNotification) -> String {
        let hide = prefs.hideDetails
        switch notification {
        case .waiting(let reason):
            let headline: String
            if case .question = reason {
                headline = "Te pose une question"
            } else {
                headline = "Attend ta réponse"
            }
            return hide ? headline : headline + "\n" + AgentPresenter.describe(reason)
        case .turnDone:
            return "Tour terminé"
        case .error(let error):
            return hide ? "Erreur" : "Erreur : " + AgentPresenter.describe(error)
        }
    }

    // MARK: - Global issues

    /// One notification for the whole account (usage limit, signed out), whatever the number of agents.
    func postGlobal(_ issue: GlobalIssue) {
        let kind = issue.kind
        pendingGlobal[kind]?.cancel()
        pendingGlobal[kind] = Task { [weak self] in
            guard let self else { return }
            let authorized = await self.ensureAuthorized()
            guard !Task.isCancelled else { return }
            self.pendingGlobal[kind] = nil
            guard authorized else { return }
            let content = UNMutableNotificationContent()
            switch issue {
            case .quota:
                content.title = "Limite d'usage atteinte"
                content.body = "Les agents en pause reprendront quand la limite sera levée."
            case .account(let type):
                content.title = "Problème de compte Claude Code"
                content.body = AgentPresenter.describe(AgentError.account(type))
            }
            content.sound = .default
            content.interruptionLevel = .active
            Self.add(UNNotificationRequest(identifier: Self.globalIdentifier(issue.kind), content: content, trigger: nil))
        }
    }

    func withdrawGlobal(_ kind: GlobalIssueKind) {
        pendingGlobal.removeValue(forKey: kind)?.cancel()
        let identifiers = [Self.globalIdentifier(kind)]
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    // MARK: - Plumbing

    /// Nonisolated so that the completion handler is not bound to the main actor (it runs on a framework queue).
    private nonisolated static func add(_ request: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AppLog.notifications.error("post failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func identifier(_ agentID: AgentID, _ kind: Kind) -> String {
        "agent-\(agentID.description)-\(kind.rawValue)"
    }

    static func globalIdentifier(_ kind: GlobalIssueKind) -> String {
        switch kind {
        case .quota: return "global-quota"
        case .account: return "global-account"
        }
    }

    /// Asks for the permission the first time; concurrent callers share the same request.
    private func ensureAuthorized() async -> Bool {
        if let task = authorizationTask { return await task.value }
        let task = Task { [weak self] () -> Bool in
            let status = await Self.authorizationStatus()
            switch status {
            case .denied:
                return false
            case .notDetermined:
                self?.onWillRequestAuthorization?()
                return await Self.requestAuthorization()
            default:
                return true
            }
        }
        authorizationTask = task
        let granted = await task.value
        // Asked again next time: the user may change it in System Settings meanwhile.
        authorizationTask = nil
        if authorizationDenied == granted {
            authorizationDenied = !granted
            onAuthorizationChange?(!granted)
        }
        return granted
    }

    private nonisolated static func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    private nonisolated static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func open(agent raw: String?) {
        NSApplication.shared.activate()
        guard let raw, let agentID = AgentID(string: raw) else { return }
        onOpenAgent?(agentID)
    }

    // MARK: - UNUserNotificationCenterDelegate

    // Explicit selectors: the framework finds these by selector, whatever the SDK's Sendable annotations.
    @objc(userNotificationCenter:willPresentNotification:withCompletionHandler:)
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    @objc(userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:)
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let raw = response.notification.request.content.userInfo[Self.agentKey] as? String
            Task { @MainActor in
                self.open(agent: raw)
            }
        }
        completionHandler()
    }
}

extension GlobalIssue {
    var kind: GlobalIssueKind {
        switch self {
        case .quota: return .quota
        case .account: return .account
        }
    }
}
