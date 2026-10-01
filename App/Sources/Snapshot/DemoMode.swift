import AppKit
import Foundation
import Observation
import PixelCore
import SwiftUI

/// The demo mode (`--demo`, step 3, décision 10), reserved for the user: the "3 s" protocol without `fake-claude`.
/// The same isolated state as the snapshot harness (`SnapshotEnvironment`), with a visible window, a minimal menu
/// bar built from `AppCommand`, and a floating "Démo" panel: "Nouvel essai" puts 2 live agents picked at random in a
/// wait, "Révéler" tells who waits and what (to check the answer said aloud), "Animer" keeps the other agents busy
/// (frame-rate measures). No terminal, no `claude`: the agents are simulated. Quitting (⌘Q, closing the window, or
/// Ctrl-C in the terminal) erases the temporary state.
@MainActor
enum DemoMode {
    /// `NSApplication.delegate` is weak.
    private static var delegate: DemoAppDelegate?

    static func run(_ options: SnapshotOptions) -> Never {
        let app = IsolatedApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = DemoAppDelegate(options: options)
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
        exit(0)
    }
}

/// What the demo panel shows and does. Also built by the snapshot harness (scenario `demo`), without its clock.
@MainActor
@Observable
final class DemoController {
    @ObservationIgnored let environment: SnapshotEnvironment
    private(set) var trials = 0
    var isRevealed = false
    private(set) var isAnimating = false
    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var animation: Timer?

    static let animationInterval: TimeInterval = 4
    /// Live agents that change activity at each animation step.
    static let animatedAgents = 3

    init(environment: SnapshotEnvironment) {
        self.environment = environment
    }

    private var model: AppModel { environment.model }

    /// Who waits now and for what, in sidebar order: "Nova (API) : Bash : rm -rf dist".
    var waitingLines: [String] {
        let model = self.model
        return model.agentsInOrder.compactMap { agent in
            guard let wait = model.runtime(for: agent.id)?.oldestWait else { return nil }
            let project = model.project(agent.projectID)?.name ?? ""
            return "\(agent.name) (\(project)) : \(AgentPresenter.describe(wait.reason))"
        }
    }

    /// 2 distinct live agents at random wait (`ShowcaseWorkspace.runtimes(waiting:)`), the others work as in the
    /// distribution; the clock starts again at `Showcase.now`.
    func newTrial() {
        let showcase = environment.showcase
        var random = SystemRandomNumberGenerator()
        let picks = Array(showcase.liveAgents.shuffled(using: &random).prefix(2))
        guard picks.count == 2 else { return }
        model.now = showcase.now
        environment.applyRuntimes(showcase.runtimes(waiting: picks))
        trials += 1
        isRevealed = false
        model.updateDockBadge()
    }

    func setAnimating(_ on: Bool) {
        isAnimating = on
        animation?.invalidate()
        animation = nil
        guard on else { return }
        animation = Timer.scheduledTimer(withTimeInterval: Self.animationInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.animateStep() }
        }
    }

    /// `animatedAgents` live agents that do not wait take another activity (`Showcase.demoRuntime`).
    func animateStep() {
        var random = SystemRandomNumberGenerator()
        let model = self.model
        let candidates = environment.showcase.liveAgents.filter { model.runtime(for: $0)?.pendingWaits.isEmpty ?? false }
        for id in candidates.shuffled(using: &random).prefix(Self.animatedAgents) {
            model.storeRuntime(Showcase.demoRuntime(Self.randomActivity(&random), now: model.now), for: id)
        }
    }

    static func randomActivity(_ random: inout some RandomNumberGenerator) -> DemoActivity {
        switch Int.random(in: 0..<4, using: &random) {
        case 0:
            let tools: [ToolKind] = [.read, .edit, .bash, .search, .web]
            return .working(tools.randomElement(using: &random) ?? .edit)
        case 1: return .thinking
        case 2: return .idle(minutes: Int.random(in: 0...14, using: &random))
        default: return .done
        }
    }

    /// The model's clock advances every second from `Showcase.now` (only `model.now`, never a tick).
    func startClock() {
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let model = self?.environment.model else { return }
                model.now = model.now.addingTimeInterval(1)
            }
        }
    }

    func stop() {
        clock?.invalidate()
        clock = nil
        setAnimating(false)
    }

    /// The floating "Démo" panel, at the top right of `screen`. It follows its content: "Révéler" makes it taller.
    func makePanel(screen: NSScreen?) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 260),
                            styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Démo"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isRestorable = false
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: DemoPanelView(controller: self).defaultAppStorage(environment.defaults))
        hosting.sizingOptions = .standardBounds
        panel.contentView = hosting
        // The fitting size is only known once SwiftUI has laid the panel out.
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        if fitting.width >= 1, fitting.height >= 1 {
            panel.setContentSize(fitting)
        }
        if let screen {
            let visible = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - panel.frame.width - 24, y: visible.maxY - 24))
        }
        return panel
    }
}

/// The content of the "Démo" panel.
struct DemoPanelView: View {
    let controller: DemoController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Protocole « 3 s »")
                .font(.headline)
            Text("« Nouvel essai » met 2 agents au hasard en attente. Dis à voix haute qui attend et quoi, "
                 + "puis vérifie avec « Révéler ».")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Nouvel essai") { controller.newTrial() }
                Button(controller.isRevealed ? "Cacher" : "Révéler") { controller.isRevealed.toggle() }
                Spacer()
                Text("Essais : \(controller.trials)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if controller.isRevealed {
                VStack(alignment: .leading, spacing: 4) {
                    let lines = controller.waitingLines
                    if lines.isEmpty {
                        Text("Personne n'attend.")
                    } else {
                        ForEach(lines, id: \.self) { line in
                            Text(line)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.callout)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            Toggle("Animer (3 agents changent d'activité toutes les 4 s)", isOn: Binding(
                get: { controller.isAnimating },
                set: { controller.setAnimating($0) }
            ))
            Divider()
            Label("Agents simulés : aucun terminal, aucun claude", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// The demo's application delegate: isolated state, menu bar, window, panel, clock; cleanup on quit.
@MainActor
final class DemoAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let options: SnapshotOptions
    private var environment: SnapshotEnvironment?
    private var controller: DemoController?
    private var window: NSWindow?
    private var panel: NSPanel?
    private var signalSources: [DispatchSourceSignal] = []
    private var isQuitting = false

    init(options: SnapshotOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        let environment: SnapshotEnvironment
        do {
            environment = try SnapshotEnvironment(keepState: options.keepState)
        } catch {
            FileHandle.standardError.write(Data("PixelOpenSpace --demo : \(error)\n".utf8))
            exit(2)
        }
        self.environment = environment
        installSignalHandlers()
        let controller = DemoController(environment: environment)
        self.controller = controller
        NSApplication.shared.mainMenu = makeMainMenu()

        let window = IsolatedWindow.make(title: "Pixel Open Space · démo", contentSize: options.windowSize, hidden: false,
                                         screen: NSScreen.main, content: environment.rootView())
        window.delegate = self
        self.window = window
        window.makeKeyAndOrderFront(nil)
        let panel = controller.makePanel(screen: NSScreen.main)
        self.panel = panel
        panel.orderFront(nil)
        controller.startClock()
        NSApplication.shared.activate()

        let kept = options.keepState ? " (conservé à la sortie)" : ""
        print("Mode démo : état temporaire \(environment.root.path)\(kept), préférences \(environment.defaultsDomain). "
              + "Quitte avec ⌘Q pour tout effacer.")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let environment else { return .terminateNow }
        controller?.stop()
        Task { @MainActor in
            await environment.cleanUp()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func windowWillClose(_ notification: Notification) {
        guard !isQuitting else { return }
        isQuitting = true
        NSApplication.shared.terminate(nil)
    }

    /// Ctrl-C or a kill in the terminal that launched the demo: the temporary state is erased all the same.
    private func installSignalHandlers() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.environment?.removeEverything()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Menus

    /// "Rechercher Claude Code" would run `claude --version`, and "Réglages…" has no window here: both are left out.
    private static let excludedCommands: Set<AppCommand> = [.redetectClaude, .showSettings]

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu(title: "Pixel Open Space")
        for command in AppCommand.commands(in: .app) where !Self.excludedCommands.contains(command) {
            appMenu.addItem(item(for: command))
        }
        if !appMenu.items.isEmpty { appMenu.addItem(.separator()) }
        appMenu.addItem(NSMenuItem(title: "Masquer Pixel Open Space", action: #selector(NSApplication.hide(_:)),
                                   keyEquivalent: "h"))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quitter la démo", action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        add(appMenu, to: main)

        add(commandMenu(.file), to: main)

        let edit = NSMenu(title: "Édition")
        edit.addItem(NSMenuItem(title: "Annuler", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Rétablir", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        add(edit, to: main)

        for menu in [AppMenu.view, .agent, .go] {
            add(commandMenu(menu), to: main)
        }
        return main
    }

    private func commandMenu(_ menu: AppMenu) -> NSMenu {
        let result = NSMenu(title: menu.title)
        for command in AppCommand.commands(in: menu) where !Self.excludedCommands.contains(command) {
            result.addItem(item(for: command))
        }
        return result
    }

    private func add(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }

    private func item(for command: AppCommand) -> NSMenuItem {
        let item = NSMenuItem(title: command.title, action: #selector(performCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = command.rawValue
        if let shortcut = command.shortcut {
            switch shortcut.key {
            case .character(let character): item.keyEquivalent = String(character).lowercased()
            case .leftArrow: item.keyEquivalent = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
            case .rightArrow: item.keyEquivalent = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
            }
            var modifiers: NSEvent.ModifierFlags = []
            if shortcut.command { modifiers.insert(.command) }
            if shortcut.shift { modifiers.insert(.shift) }
            if shortcut.option { modifiers.insert(.option) }
            if shortcut.control { modifiers.insert(.control) }
            item.keyEquivalentModifierMask = modifiers
        }
        return item
    }

    private func command(of item: NSMenuItem) -> AppCommand? {
        (item.representedObject as? String).flatMap(AppCommand.init(rawValue:))
    }

    /// Like the app's menus (`AppMenuCommands`): closing a busy session and removing an agent are confirmed first.
    @objc private func performCommand(_ sender: NSMenuItem) {
        guard let command = command(of: sender), let workbench = environment?.workbench,
              workbench.isAvailable(command) else { return }
        switch command {
        case .closeSession:
            if let agentID = workbench.model.selectedAgentID { workbench.requestCloseSession(agentID) }
        case .removeAgent:
            if let agentID = workbench.model.selectedAgentID { workbench.requestRemove(agentID) }
        default:
            workbench.commands.perform(command)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(performCommand(_:)) else { return true }
        guard let command = command(of: menuItem), let workbench = environment?.workbench else { return false }
        return workbench.isAvailable(command)
    }
}
