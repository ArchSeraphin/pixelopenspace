import AppKit
import Foundation
import PixelCore
import SwiftUI

/// The snapshot harness (`PixelOpenSpace --snapshot <dossier>`, step 3, task 1): launches the app on a temporary,
/// isolated state (`SnapshotEnvironment`), loads the simulated open space (20 agents on 6 projects), runs the
/// scenarios (`SnapshotScenario`), captures the windows and the scene as PNG, compares the scene with the software
/// reference (`SnapshotImages`), writes `report.txt` and `stats.json`, then quits by itself.
///
/// Nothing shows and nothing takes the focus: an accessory app (no Dock icon) that never activates, its windows
/// transparent and click-through on the capture screen (`IsolatedWindow.captureScreen()`: the main screen, or a
/// finer one, so that they draw at a Retina scale when the Mac has one). Exit codes: 0 done (the mismatches are in
/// the report), 1 invalid command line, 2 a file could not be written, 3 watchdog (120 s) or interruption (the
/// report says what is missing).
@MainActor
final class SnapshotRunner: NSObject, NSApplicationDelegate {
    enum ExitCode: Int32 {
        case done = 0, usage = 1, writeFailed = 2, watchdog = 3
    }

    static let watchdogDelay: TimeInterval = 120
    /// The pose after a step that changed something: layout, this delay, then two run-loop turns.
    static let poseDelay: Duration = .milliseconds(300)

    /// `NSApplication.delegate` is weak.
    private static var current: SnapshotRunner?
    /// Where every window of the app is kept (`IsolatedWindow.captureScreen()`), chosen at launch.
    private static var captureScreen: NSScreen?

    static func run(_ options: SnapshotOptions) -> Never {
        guard case .snapshot(let output, let scenarios) = options.mode else { exit(ExitCode.usage.rawValue) }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("PixelOpenSpace --snapshot : impossible de créer \(output.path) : \(error.localizedDescription)\n".utf8))
            exit(ExitCode.writeFailed.rawValue)
        }
        SnapshotHooks.shared.enable()
        IsolatedApplication.refusesActivation = true
        let app = IsolatedApplication.shared
        app.setActivationPolicy(.accessory)
        let runner = SnapshotRunner(options: options, output: output, scenarios: scenarios)
        current = runner
        app.delegate = runner
        app.run()
        exit(ExitCode.done.rawValue)
    }

    private let options: SnapshotOptions
    private let output: URL
    private let scenarios: [SnapshotScenario.ID]
    private let journal: SnapshotJournal
    private let hooks = SnapshotHooks.shared
    private let references = SnapshotReferences()
    private var environment: SnapshotEnvironment!
    private var mainWindow: NSWindow!
    private var stats = SnapshotStats()
    private var writeFailed = false
    private var observers: [NSObjectProtocol] = []
    private var signalSources: [DispatchSourceSignal] = []

    private init(options: SnapshotOptions, output: URL, scenarios: [SnapshotScenario.ID]) {
        self.options = options
        self.output = output
        self.scenarios = scenarios
        journal = SnapshotJournal(output: output)
    }

    // MARK: Application

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        journal.startWatchdog(after: Self.watchdogDelay)
        installSignalHandlers()
        Task { @MainActor in
            await self.runAll()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Every window of the app stays transparent and click-through, whoever opens it.
    private func watchWindows() {
        let names: [Notification.Name] = [NSApplication.didUpdateNotification, NSWindow.didChangeOcclusionStateNotification,
                                          NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Self.hideAllWindows() }
            })
        }
    }

    /// Transparent and click-through; the visible ones (not tooltips nor menus) kept on the capture screen.
    private static func hideAllWindows() {
        for window in NSApplication.shared.windows {
            IsolatedWindow.hideForSnapshot(window)
            if let screen = captureScreen, window.isVisible, isCapturable(window) {
                IsolatedWindow.keep(window, on: screen)
            }
        }
    }

    private func installSignalHandlers() {
        let journal = self.journal
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
            source.setEventHandler {
                journal.abort(reason: "interrompu par le signal \(signalNumber)")
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Run

    private func runAll() async {
        let start = Date()
        journal.append("Banc de captures de Pixel Open Space")
        journal.append("Scénarios : \(scenarios.map(\.rawValue).joined(separator: ", "))")
        journal.append("Fenêtre principale : \(Int(options.windowSize.width)) × \(Int(options.windowSize.height)) pt")
        do {
            environment = try SnapshotEnvironment(keepState: options.keepState)
        } catch {
            journal.append("ÉCHEC : état temporaire impossible à préparer : \(error)")
            finish(code: .writeFailed)
            return
        }
        let environment = self.environment!
        journal.setCleanup(defaultsPath: environment.defaultsPath, root: options.keepState ? nil : environment.root)
        let kept = options.keepState ? "conservé (--keep-state)" : "supprimé à la sortie"
        journal.append("Dossier d'état (temporaire) : \(environment.root.path) (\(kept))")
        journal.append("Domaine de préférences (jetable) : \(environment.defaultsDomain), fichier dans le dossier "
                       + "d'état (\(environment.defaultsPath).plist), effacé à la sortie")
        stats.stateFolder = environment.root.path
        stats.stateFolderKept = options.keepState
        stats.defaultsDomain = environment.defaultsDomain
        stats.defaultsFile = environment.defaultsPath + ".plist"
        stats.windowSize = [Int(options.windowSize.width), Int(options.windowSize.height)]

        let screen = IsolatedWindow.captureScreen()
        Self.captureScreen = screen
        watchWindows()
        let window = IsolatedWindow.make(title: "Pixel Open Space", contentSize: options.windowSize, hidden: true,
                                         screen: screen, content: environment.rootView())
        mainWindow = window
        window.orderFrontRegardless()
        await pose()
        let scale = window.backingScaleFactor
        stats.scale = Double(scale)
        if let screen {
            let main = NSScreen.main
            let isMain = main.map { $0 == screen } ?? true
            let mainScale = main.map { Self.number(Double($0.backingScaleFactor)) } ?? "?"
            stats.screen = screen.localizedName
            journal.append("Écran des captures : \(screen.localizedName)"
                           + (isMain ? " (écran principal)" : " (le plus fin ; l'écran principal est à l'échelle \(mainScale))"))
        }
        journal.append("Échelle d'affichage : \(Self.number(Double(scale)))"
                       + (scale >= 2 ? "" : " (écran sans Retina : la vue d'ensemble n'y est pas au repos)"))
        journal.append("Fournisseur de scène : " + (hooks.sceneProvider == nil
            ? "aucun (tâche 7) : les prises de scène écrivent la référence logicielle seule"
            : "présent"))

        var remaining = scenarios
        for id in scenarios {
            journal.setRemaining(remaining.map(\.rawValue))
            remaining.removeFirst()
            await run(SnapshotScenario.scenario(id))
        }
        journal.setRemaining([])
        journal.setStage("bilan")

        let unsupported = stats.unsupportedByKind
        if !unsupported.isEmpty {
            journal.append("")
            journal.append("Étapes non prises en charge, par crochet :")
            for kind in SnapshotStep.Kind.allCases {
                guard let count = unsupported[kind.rawValue] else { continue }
                journal.append("  \(kind.rawValue) ×\(count) (\(kind.contractOwner))")
            }
        }
        if stats.failedSteps > 0 {
            journal.append("Étapes en échec (crochet ou repli) : \(stats.failedSteps)")
        }
        if writeFailed {
            journal.append("Au moins un fichier n'a pas pu être écrit.")
        }
        journal.append("Durée : \(Self.number((Date().timeIntervalSince(start) * 10).rounded() / 10)) s")
        await environment.cleanUp()
        finish(code: writeFailed ? .writeFailed : .done)
    }

    /// Writes the report and `stats.json`, then exits (unless the watchdog already did).
    private func finish(code: ExitCode) {
        stats.exitCode = Int(code.rawValue)
        stats.mismatches = journal.mismatches
        stats.unsupportedSteps = journal.unsupported
        var finalCode = code
        if let data = try? Self.encoder.encode(stats) {
            if !Self.write(data, to: output.appendingPathComponent("stats.json")) { finalCode = .writeFailed }
        } else {
            finalCode = .writeFailed
        }
        if !journal.finish() { finalCode = .writeFailed }
        environment?.removeEverything()
        exit(finalCode.rawValue)
    }

    private func run(_ scenario: SnapshotScenario) async {
        let id = scenario.id
        journal.setStage("scénario \(id.rawValue)")
        journal.append("")
        journal.append("== \(id.rawValue) ==")
        var record = SnapshotStats.Scenario(id: id.rawValue)
        defer { stats.scenarios.append(record) }

        switch scenario.kind {
        case .selftest:
            record.shots.append(runSelfTest())
            return
        case .demo:
            await resetForScenario(.showcase)
            record.shots.append(await runDemoShot(scenario))
            return
        case .windows:
            break
        }

        await resetForScenario(scenario.distribution)
        var view = SnapshotViewState()
        if !scenario.setup.isEmpty {
            var setup = SnapshotStats.Shot(name: "préparation")
            journal.append("[préparation]")
            for step in scenario.setup {
                await perform(step, view: &view, record: &setup)
            }
            record.shots.append(setup)
        }
        for shot in scenario.shots {
            journal.setStage("scénario \(id.rawValue), prise \(shot.name)")
            journal.append("[\(shot.name)]")
            var shotRecord = SnapshotStats.Shot(name: shot.name)
            for step in shot.steps {
                await perform(step, view: &view, record: &shotRecord)
            }
            await capture(prefix: "\(id.rawValue)-\(shot.name)", view: view, record: &shotRecord)
            record.shots.append(shotRecord)
        }
        if scenario.distribution == .empty {
            environment.load(Showcase.appWorkspace())
        }
    }

    /// Every scenario starts from the same state: the simulated open space (or the empty one), nothing selected, no
    /// sheet, the board beside the scene, no other window than the main one.
    private func resetForScenario(_ distribution: SnapshotScenario.Distribution) async {
        let workbench = environment.workbench
        workbench.activeSheet = nil
        workbench.confirmation = nil
        workbench.pendingTask = nil
        environment.load(distribution == .empty ? Showcase.emptyWorkspace() : Showcase.appWorkspace())
        environment.defaults.set(true, forKey: "boardPanelVisible")
        await pose()
        for window in NSApplication.shared.windows where window !== mainWindow && window.isVisible {
            if let parent = window.sheetParent {
                parent.endSheet(window)
            } else {
                window.close()
            }
        }
        await pose()
    }

    // MARK: Steps

    private func perform(_ step: SnapshotStep, view: inout SnapshotViewState, record: inout SnapshotStats.Shot) async {
        view.apply(step)
        if let handler = hooks.handler(for: step.kind) {
            let owner = hooks.owner(of: step.kind) ?? step.kind.contractOwner
            let done = await handler(step)
            if done {
                note(step, "crochet (\(owner))", outcome: "hook", owner: owner, record: &record)
            } else {
                stats.failedSteps += 1
                note(step, "ÉCHEC du crochet (\(owner))", outcome: "failed", owner: owner, record: &record)
            }
            await pose()
            return
        }
        switch fallback(step) {
        case .done(let what):
            note(step, "repli du banc : \(what)", outcome: "fallback", owner: "banc", record: &record)
            await pose()
        case .failed(let why):
            stats.failedSteps += 1
            note(step, "ÉCHEC du repli du banc : \(why)", outcome: "failed", owner: "banc", record: &record)
        case .none:
            journal.countUnsupported()
            stats.unsupportedByKind[step.kind.rawValue, default: 0] += 1
            note(step, "non prise en charge (\(step.kind.contractOwner))", outcome: "unsupported",
                 owner: step.kind.contractOwner, record: &record)
        }
    }

    private enum Fallback {
        case done(String), failed(String), none
    }

    /// What the harness does itself when no feature registered the step: `select`, and the board beside the scene
    /// or hidden (the `boardPanelVisible` preference of the throwaway domain).
    private func fallback(_ step: SnapshotStep) -> Fallback {
        let model = environment.model
        switch step {
        case .select(let name?):
            guard let id = environment.showcase.agentID(named: name) else { return .failed("agent « \(name) » inconnu") }
            model.select(agent: id)
            return .done("model.select(agent:)")
        case .select(nil):
            model.select(agent: nil)
            return .done("model.select(agent: nil)")
        case .board(.hidden):
            environment.defaults.set(false, forKey: "boardPanelVisible")
            return .done("préférence boardPanelVisible = false")
        case .board(.side):
            environment.defaults.set(true, forKey: "boardPanelVisible")
            return .done("préférence boardPanelVisible = true")
        default:
            return .none
        }
    }

    private func note(_ step: SnapshotStep, _ text: String, outcome: String, owner: String,
                      record: inout SnapshotStats.Shot) {
        journal.append("  \(step) : \(text)")
        record.steps.append(SnapshotStats.Step(step: step.description, kind: step.kind.rawValue, outcome: outcome,
                                               owner: owner))
    }

    /// Layout, `poseDelay`, two run-loop turns: SwiftUI and the scene have drawn the new state.
    private func pose() async {
        layoutWindows()
        try? await Task.sleep(for: Self.poseDelay)
        await runLoopTurn()
        await runLoopTurn()
        layoutWindows()
    }

    private func layoutWindows() {
        Self.hideAllWindows()
        for window in NSApplication.shared.windows where window.isVisible {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func runLoopTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform(inModes: [.common]) { continuation.resume() }
        }
    }

    // MARK: Captures

    private func capture(prefix: String, view: SnapshotViewState, record: inout SnapshotStats.Shot) async {
        let provider = view.showsScene ? hooks.sceneProvider : nil
        var sceneCapture: SceneCapture?
        var undo: (@MainActor () -> Void)?
        if let provider {
            sceneCapture = await provider.captureScene()
            if let sceneCapture {
                undo = provider.showStill(sceneCapture.image)
                layoutWindows()
                await runLoopTurn()
            }
        }
        captureWindows(prefix: prefix, record: &record)
        undo?()

        guard view.showsScene else { return }
        if let sceneCapture {
            compare(sceneCapture, prefix: prefix, record: &record)
        } else {
            if provider != nil {
                record.notes.append("le fournisseur de scène n'a rien rendu")
                journal.append("  scène : le fournisseur n'a rien rendu, référence seule")
            }
            writeReference(prefix: prefix, zoom: view.zoom, record: &record)
        }
    }

    /// The main window first (`window-<prefix>.png`), then the other visible windows (`-2`, `-3`…).
    private func captureWindows(prefix: String, record: inout SnapshotStats.Shot) {
        guard let main = mainWindow else { return }
        let others = NSApplication.shared.windows
            .filter { $0 !== main && $0.isVisible && Self.isCapturable($0) }
            .sorted { $0.windowNumber < $1.windowNumber }
        for (index, window) in ([main] + others).enumerated() {
            let name = index == 0 ? "window-\(prefix).png" : "window-\(prefix)-\(index + 1).png"
            guard let image = SnapshotImages.capture(window) else {
                record.notes.append("\(name) : capture impossible")
                journal.append("  \(name) : capture impossible")
                continue
            }
            write(image, name: name, record: &record)
        }
    }

    /// Not tooltips, menus or tiny helper windows.
    private static func isCapturable(_ window: NSWindow) -> Bool {
        let name = String(describing: type(of: window))
        if name.contains("ToolTip") || name.contains("Menu") { return false }
        return window.frame.width >= 40 && window.frame.height >= 40 && window.contentView != nil
    }

    private func compare(_ capture: SceneCapture, prefix: String, record: inout SnapshotStats.Shot) {
        let canvas = references.canvas(capture.input, overview: capture.overview)
        write(capture.image, name: "scene-\(prefix).png", record: &record)
        guard let comparison = SnapshotImages.compare(capture, canvas: canvas) else {
            record.notes.append("comparaison impossible")
            journal.append("  comparaison impossible (image de scène illisible)")
            return
        }
        write(comparison.reference, name: "reference-\(prefix).png", record: &record)
        write(comparison.diff, name: "diff-\(prefix).png", record: &record)
        journal.addMismatches(comparison.mismatches)
        record.mismatches = comparison.mismatches
        record.compared = comparison.compared
        record.scene = capture.stats
        let rect = capture.visibleCanvasRect
        journal.append("  écarts hors tolérance : \(comparison.mismatches) sur \(comparison.compared) pixels comparés "
                       + "(\(capture.overview ? "vue d'ensemble" : "×1") ; texels \(rect.x), \(rect.y), \(rect.width) × "
                       + "\(rect.height) ; \(capture.pixelsPerTexel) px par texel)")
        if let note = comparison.sizeNote {
            record.notes.append(note)
            journal.append("  \(note)")
        }
        if !capture.stats.isEmpty {
            let text = capture.stats.keys.sorted().map { "\($0) \(capture.stats[$0]!)" }.joined(separator: ", ")
            journal.append("  statistiques de scène : \(text)")
        }
    }

    /// Without a scene provider: the whole world at the shot's zoom, rendered by the core.
    private func writeReference(prefix: String, zoom: SceneZoom, record: inout SnapshotStats.Shot) {
        let name = "reference-\(prefix).png"
        guard let png = references.png(environment.showcase.sceneInput(), zoom: zoom) else {
            writeFailed = true
            record.notes.append("\(name) : rendu impossible")
            journal.append("  \(name) : rendu impossible")
            return
        }
        let label = zoom == .overview ? "vue d'ensemble" : "×\(zoom.rawValue)"
        write(png.data, name: name, width: png.width, height: png.height, detail: "monde entier, \(label)",
              record: &record)
    }

    private func write(_ image: CGImage, name: String, record: inout SnapshotStats.Shot) {
        guard let data = SnapshotImages.pngData(image) else {
            writeFailed = true
            journal.append("  \(name) : encodage PNG impossible")
            return
        }
        write(data, name: name, width: image.width, height: image.height, detail: nil, record: &record)
    }

    private func write(_ data: Data, name: String, width: Int, height: Int, detail: String?,
                       record: inout SnapshotStats.Shot) {
        guard Self.write(data, to: output.appendingPathComponent(name)) else {
            writeFailed = true
            journal.append("  \(name) : écriture impossible")
            return
        }
        record.files.append(SnapshotStats.File(name: name, width: width, height: height))
        journal.append("  écrit \(name) (\(width) × \(height) px\(detail.map { ", \($0)" } ?? ""))")
    }

    private static func write(_ data: Data, to url: URL) -> Bool {
        (try? data.write(to: url, options: .atomic)) != nil
    }

    // MARK: Special scenarios

    /// The demo mode's window and panel, without interaction.
    private func runDemoShot(_ scenario: SnapshotScenario) async -> SnapshotStats.Shot {
        var record = SnapshotStats.Shot(name: "demo")
        journal.append("[demo]")
        let controller = DemoController(environment: environment)
        let panel = controller.makePanel(screen: Self.captureScreen)
        IsolatedWindow.hideForSnapshot(panel)
        panel.orderFrontRegardless()
        await pose()
        captureWindows(prefix: "\(scenario.id.rawValue)-demo", record: &record)
        panel.orderOut(nil)
        panel.close()
        return record
    }

    private func runSelfTest() -> SnapshotStats.Shot {
        var record = SnapshotStats.Shot(name: "selftest")
        let input = Showcase.appWorkspace().sceneInput()
        let result = SnapshotImages.selfTest(canvas: references.canvas(input, overview: false), input: input)
        journal.append("  \(result.text)")
        stats.selftest = result.text
        record.notes.append(result.text)
        if let diff = result.diff {
            write(diff, name: "diff-selftest-decalage.png", record: &record)
        }
        return record
    }

    // MARK: Helpers

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }
}

/// `stats.json`: the same data as the report.
struct SnapshotStats: Codable {
    struct Step: Codable {
        var step: String
        var kind: String
        /// hook, fallback, unsupported, failed.
        var outcome: String
        var owner: String
    }

    struct File: Codable {
        var name: String
        var width: Int
        var height: Int
    }

    struct Shot: Codable {
        var name: String
        var steps: [Step] = []
        var files: [File] = []
        var mismatches: Int?
        var compared: Int?
        /// The scene's statistics (nodes, atlasPages…), with a scene provider.
        var scene: [String: Int]?
        var notes: [String] = []
    }

    struct Scenario: Codable {
        var id: String
        var shots: [Shot] = []
    }

    var scale: Double = 0
    /// The capture screen's name.
    var screen = ""
    var windowSize: [Int] = []
    var stateFolder = ""
    var stateFolderKept = false
    var defaultsDomain = ""
    /// The domain's plist, inside the state folder.
    var defaultsFile = ""
    var scenarios: [Scenario] = []
    var selftest: String?
    var mismatches = 0
    var unsupportedSteps = 0
    var failedSteps = 0
    var unsupportedByKind: [String: Int] = [:]
    var exitCode = 0
}

/// The report as it is written, shared with the watchdog and the signal handlers (other threads): whatever happens,
/// `report.txt` ends with a `BILAN` line and the temporary state is erased.
final class SnapshotJournal: @unchecked Sendable {
    private let lock = NSLock()
    private let output: URL
    private var lines: [String] = []
    private var stage = "démarrage"
    private var remaining: [String] = []
    private var cleanup: (defaultsPath: String, root: URL?)?
    private var exited = false
    private(set) var mismatchCount = 0
    private(set) var unsupportedCount = 0

    init(output: URL) {
        self.output = output
    }

    var mismatches: Int { lock.withLock { mismatchCount } }
    var unsupported: Int { lock.withLock { unsupportedCount } }

    func append(_ line: String) {
        lock.withLock { lines.append(line) }
    }

    func setStage(_ text: String) {
        lock.withLock { stage = text }
    }

    func setRemaining(_ ids: [String]) {
        lock.withLock { remaining = ids }
    }

    func setCleanup(defaultsPath: String, root: URL?) {
        lock.withLock { cleanup = (defaultsPath, root) }
    }

    func addMismatches(_ count: Int) {
        lock.withLock { mismatchCount += count }
    }

    func countUnsupported() {
        lock.withLock { unsupportedCount += 1 }
    }

    /// The normal end: writes `report.txt` with its `BILAN`. False when the file could not be written. Nothing when
    /// the watchdog or a signal already ended the run.
    func finish() -> Bool {
        let text: String? = lock.withLock {
            guard !exited else { return nil }
            exited = true
            return (lines + ["", Self.summary(mismatches: mismatchCount, unsupported: unsupportedCount)])
                .joined(separator: "\n") + "\n"
        }
        guard let text else { return true }
        return (try? Data(text.utf8).write(to: output.appendingPathComponent("report.txt"), options: .atomic)) != nil
    }

    /// The watchdog (or a signal): writes what was done and what is missing, erases the temporary state, exits 3.
    /// Callable from any thread; the main thread may be stuck.
    func abort(reason: String) {
        let state: (text: String, cleanup: (defaultsPath: String, root: URL?)?)? = lock.withLock {
            guard !exited else { return nil }
            exited = true
            var all = lines
            all.append("")
            all.append("ARRÊT : \(reason), pendant « \(stage) ».")
            if !remaining.isEmpty {
                all.append("Scénarios non terminés : \(remaining.joined(separator: ", ")).")
            }
            all.append(Self.summary(mismatches: mismatchCount, unsupported: unsupportedCount) + " · run interrompu")
            return (all.joined(separator: "\n") + "\n", cleanup)
        }
        guard let state else { return }
        try? Data(state.text.utf8).write(to: output.appendingPathComponent("report.txt"), options: .atomic)
        if let cleanup = state.cleanup {
            SnapshotEnvironment.erase(defaultsPath: cleanup.defaultsPath, root: cleanup.root)
        }
        exit(SnapshotRunner.ExitCode.watchdog.rawValue)
    }

    func startWatchdog(after delay: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [self] in
            abort(reason: "chien de garde (\(Int(delay)) s écoulées)")
        }
    }

    static func summary(mismatches: Int, unsupported: Int) -> String {
        "BILAN : écarts hors tolérance \(mismatches) · étapes non prises en charge \(unsupported)"
    }
}
