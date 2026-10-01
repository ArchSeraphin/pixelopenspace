# Pixel Open Space: macOS app (`App/`)

The app target of `project.yml` (XcodeGen). It depends on the local `Core` package (`PixelCore`, `PixelIPC`) and on
SwiftTerm (pinned revision), and embeds the `pixel-hook` tool at `PixelOpenSpace.app/Contents/Helpers/pixel-hook`.
Swift 6 language mode, strict concurrency; every UI and model type is `@MainActor`. Design reference:
`docs/PROPOSITION.md` (French); section numbers below refer to it.

```bash
Tools/bootstrap.sh          # or: brew install xcodegen && xcodegen generate
open PixelOpenSpace.xcodeproj   # scheme PixelOpenSpace, ⌘R
```

Generated, never edited by hand: `PixelOpenSpace.xcodeproj` and `App/Info.plist` (from `project.yml › info`).
Signing: `Config/Base.xcconfig` (automatic, hardened runtime, no sandbox) includes the machine-specific, unversioned
`Config/Local.xcconfig` (`DEVELOPMENT_TEAM`, see `Config/Local.xcconfig.example`). The first build asks you to trust
SwiftTerm's build-tool plug-in ("Trust & Enable").

## Data flow

```
claude (PTY) ──hook──► pixel-hook ──Unix socket──► HookServer ──AsyncStream──► AppModel.receive
                                                                    HookDeduplicator → HookRouter → dispatch(.hook)
TerminalHost (SwiftTerm) ── exit, output, keystrokes, bell ───────► AppModel.handleTerminalEvent → dispatch
1 Hz clock ─────────────────────────────────── screen reading + .tick ► dispatch
dispatch = AgentStateMachine.reduce (PixelCore, pure) → runtimes[agent] + effects
effects → Workspace.apply (+ debounced save) · NotificationBridge · global issues · VoiceOver · toasts · screen readings
```

The model is the single source of truth. Views read `AppModel` and call its intents (or `CommandCenter.perform`);
they never touch services directly.

## Files

### `AppMain/`
- `AppEntry.swift`: the only `@main`. Parses the command line (`SnapshotOptions.parse`): `--snapshot` runs the
  snapshot harness, `--demo` the demo mode, anything else the normal app (`PixelOpenSpaceApp.main()`). A command line
  it cannot read: French message and usage on stderr, exit code 1.
- `AppDelegate.swift`: `NSApplicationDelegate` (installed with `@NSApplicationDelegateAdaptor`). Installs the
  notification delegate in `applicationWillFinishLaunching`, starts the environment in `applicationDidFinishLaunching`,
  keeps the app alive when the last window closes, and routes ⌘Q to `AppModel.handleTerminationRequest()`.
- `AppEnvironment.swift`: creates and wires every object once (directories, persistence, hook server, terminal
  presenter, session manager, Claude locator, notifications, `AppModel`, `CommandCenter`). Loads the state files
  synchronously; `start()` starts the rest. `AppEnvironment.shared` is the normal one; `init(directories:mode:)`
  with `.isolated` builds the harness's, for which `prepareForLaunch()` and `start()` do nothing.
- `PixelOpenSpaceApp.swift`: the SwiftUI `App` (written with the UI, `App/Sources/UI/`), launched by `AppEntry`.

### `Snapshot/`
- `SnapshotOptions.swift`: the command line of the harness and of the demo mode.
- `SnapshotEnvironment.swift`: the isolated state (temporary folder, throwaway preferences domain, `.isolated`
  environment filled with `Showcase.appWorkspace()`), `IsolatedApplication` (refuses activation in the harness),
  `IsolatedWindow` (the main window, hidden in the harness) and the choice of the capture screen.
- `SnapshotHooks.swift`: the vocabulary of steps (`SnapshotStep`) and the registry where features plug in their
  hooks (`SnapshotHooks.shared`, `SceneCaptureProviding`).
- `SnapshotScenarios.swift`: the scenarios and their shots.
- `SnapshotRunner.swift`: runs the scenarios, captures, compares, writes `report.txt` and `stats.json`, watchdog.
- `SnapshotImages.swift`: window captures, PNG, the software reference and the comparison (tolerance 1 per channel).
- `DemoMode.swift`: the demo mode: menu bar from `AppCommand`, the "Démo" panel, the clock.

### `Model/`
- `AppModel.swift`: `@MainActor @Observable` state: workspace, settings, `runtimes`, global issues, hook server
  state, Claude Code status, selection, focus and UI requests, toasts, load warnings, quit request, `now` (1 Hz).
  Derived values (`displays`, `statusSummary`, `hookStatus`…) and the store primitives (`commit`, `storeRuntime`…).
- `AppModel+Engine.swift`: `dispatch(_:to:)` and effect execution; hook loop (dedup → route → reduce); terminal
  events; screen sampling (`ScreenPatterns.parse`); the 1 Hz clock and which agents need a tick or a screen reading.
- `AppModel+Intents.swift`: what the UI may ask about projects, agents, selection and navigation, settings and the
  Claude Code search.
- `AppModel+Sessions.swift`: launch / relaunch (resume, or a new session when the conversation is gone) / close /
  interrupt / acknowledge, orphans of a crashed run, "Copier la commande", and the launch plumbing (`LaunchPlanner`
  request, checks, `SessionManager.launch`, `.processStarted` reduced at once).
- `AppModel+Quit.swift`: quit assessment and flow (2.5, mockup 6(p)): sheet, "Attendre la fin des tours",
  "Quitter quand même", closing every session (SIGTERM → SIGKILL), final save. `terminate` is always requested from
  a run-loop timer (`requestTermination()`), never from a main-actor job.
- `ModelTypes.swift`: `Toast`, `FocusRequest`, `UIRequest`, `QuitAssessment`, `QuitRequest`, `QuitChoice`,
  `HookStatus`.

### `Sessions/`
- `SessionManager.swift`: one `TerminalHost` per agent that ran; launch from a `LaunchPlan`, PTY writes, screen
  lines, close (SIGTERM to the process group, SIGKILL after 5 s), close all.
- `TerminalHost.swift`: owns an `AgentTerminalView` created detached (120×36, scrollback, font) before
  `startProcess`; SwiftTerm process delegate (exit, launch failure); throttled output activity; bell relay.
- `AgentTerminalView.swift`: `LocalProcessTerminalView` subclass: reports pastes and bells, reads the live screen
  (also when the user has scrolled back).
- `KeystrokeMonitor.swift`: local key-down monitor that reports the class of keys typed into a terminal (SwiftTerm's
  `keyDown` is not overridable and keystrokes bypass `send(source:data:)`).
- `TerminalPresenter.swift`: grants each terminal view to one container at a time; placeholder and "Afficher ici"
  elsewhere; transfer when the owner goes away.
- `TerminalContainerView.swift`: the `NSView` returned by the UI's `NSViewRepresentable`; ignores layouts smaller
  than 320×160 (no SIGWINCH storms).
- `ClaudeLocator.swift`: login-shell environment (once, 10 s max), candidates from `ClaudeLocatorPlan`,
  `claude --version` (5 s) → `ClaudeStatus` (path, version, minimum met, error).
- `ProcessRunner.swift`: runs a helper command off the main thread with a deadline, stdout through a private temp
  file.

### `Hooks/`
- `HookServer.swift`: the Unix socket (`PixelIPC.UnixSocketServer`), then the per-launch token (`run/token`) and
  `run/hooks-settings.json` pointing at the bundled `pixel-hook`, decoding and per-agent rate limit, `envelopes`
  stream. Another instance on the socket → `.anotherInstance`, and its files are left untouched.

### `System/`
- `AppDirectories.swift`: `~/Library/Application Support/PixelOpenSpace/{state,run,logs,backups}`, all 0700; files
  0600.
- `PersistenceStore.swift`: actor; `state/workspace.json` and `state/settings.json`: synchronous load at launch,
  debounced (500 ms) atomic saves ordered by version, daily backups (5 days), unreadable file set aside
  (`*.corrupt-<date>.json`) with fallback to the last readable backup, newer-format files never overwritten.
- `NotificationBridge.swift`: `UNUserNotificationCenter`: lazy authorization, one notification per agent
  (`agent-<id>-waiting|done|error`), 1 s debounce, waits always posted, turn done in the background or when the
  agent is out of sight, errors in the background only, "hide details", one notification per global issue; a click
  activates the app and focuses the agent.
- `DockBadge.swift`: Dock badge = number of waiting agents.
- `AppLog.swift`: unified logging categories (no hook content is logged).

### `Commands/`
- `AppCommand.swift`: every menu/palette action with its French title, menu, SF Symbol and shortcut (table 3.16).
- `CommandCenter.swift`: `perform(_:)` and `isEnabled(_:)` on the selected agent; ⌘1…⌘9 via
  `selectProject(number:)`.

## For the UI

- Read `AppEnvironment.shared.model` (observable) and call its intents; menus use `AppCommand` +
  `CommandCenter.perform`.
- Observe `model.uiRequest` (sheets, Settings via `openSettings`, terminal panel), then `consumeUIRequest(_:)`;
  observe `model.focusRequest` (reopen a window if none is open), then `consumeFocusRequest()`; show
  `model.quitRequest` as the quit sheet and answer with `respondToQuit(_:)`.
- Terminal: an `NSViewRepresentable` returning `TerminalContainerView(frame: .zero)`, attached with
  `TerminalPresenter.attach(_:to:)` and released with `container.detachFromPresenter()` in `dismantleNSView`
  (see `TerminalPresenter`). The process never depends on a view being shown.
- Do not name UI types `TerminalView` or `Terminal`: those are SwiftTerm types used by `Sessions/`.

## Banc de captures et mode démo

Both run the app on a temporary, isolated state with the simulated open space of `Showcase.appWorkspace()` (6
projects, 20 agents in every state, a board of 19 post-its, fixed clock 2026-10-01 09:00 UTC). No hook server,
session, clock, notification or search for `claude` is started, and nothing of your own state is read or written.

### Snapshot harness

```bash
Tools/snapshot.sh "$TMPDIR/pos-snapshots/tache-7" zooms,fractional   # scenario: all by default
# or directly:
build/DerivedData/Build/Products/Debug/PixelOpenSpace.app/Contents/MacOS/PixelOpenSpace \
    --snapshot <dossier> [--scenario <id,id…>] [--size 1440x900] [--keep-state]
```

The script runs the Debug build of `build/DerivedData` (never `build/Demo`), and fails in French when it is missing.
The app captures, writes into `<dossier>`, then quits by itself. Exit codes: 0 done (mismatches are in the report),
1 invalid command line, 2 a file could not be written, 3 watchdog (120 s) or interruption.

Scenarios (`SnapshotScenarios.swift`): `overview`, `zooms`, `fractional`, `list`, `empty`, `select`, `navigation`,
`agentwindow`, `dragdrop`, `board`, `arrival`, `demo`, `selftest`, and `all` (every one, in that order).

Files:
- `window-<scenario>-<shot>.png`: the main window at the display scale; other visible windows (panels) as `-2`,
  `-3`… The content view is drawn by `cacheDisplay` and laid on the window's background colour.
- With a scene on screen and a scene provider (step 3, task 7): `scene-…png` (the SpriteKit drawing),
  `reference-…png` (`SceneCompositor` on the same input, cropped to the visible texels, scaled to the nearest) and
  `diff-…png` (the reference darkened by half, mismatches in magenta). Without a provider: `reference-…png` only,
  the whole world at the shot's zoom.
- `report.txt` (French): capture screen and display scale, state folder and preferences domain used, one line per
  step (hook and its owner, harness fallback, or "non prise en charge" with the task that will register it), one
  line per file, mismatches per shot, scene statistics; ends with
  `BILAN : écarts hors tolérance N · étapes non prises en charge M`. `stats.json` holds the same data.
- `selftest` checks the comparison tool itself: "outil de comparaison : OK" when a reference matches itself and a
  copy shifted by one texel does not.

A pixel is a mismatch when a channel differs by more than 1 where the reference is opaque. A feature plugs into a
shot by registering its hook in its own files, only when `SnapshotHooks.shared.isEnabled` (contract in
`SnapshotHooks.swift`); the harness files never change for it.

Isolation:
- State folder `$TMPDIR/PixelOpenSpace-snapshot-<pid>-<uuid>` (0700), used as the home of `AppDirectories`: the
  support folder, `run/` and the socket path fall inside it. Removed at the end, unless `--keep-state` (its path is
  in the report).
- Preferences domain `fr.vv2.pixelopenspace.snapshot.<pid>`, given to every view by `.defaultAppStorage(_:)`; its
  plist lives in the state folder, never in `~/Library/Preferences`; erased at the end.
- An accessory app (no Dock icon) that never activates; its windows are transparent, click-through, never key nor
  main. They sit on the capture screen: the main screen, or the finest one (highest backing scale) when the main
  screen is a 1x monitor, so that the captures have a Retina scale whenever the Mac has a Retina display.
- After a run, these print nothing: `ls -d "$TMPDIR"/PixelOpenSpace-snapshot-*`,
  `find ~/Library/Preferences -name 'fr.vv2.pixelopenspace.snapshot*'`, `pgrep -f 'PixelOpenSpace --snapshot'`.

### Demo mode

```bash
build/DerivedData/Build/Products/Debug/PixelOpenSpace.app/Contents/MacOS/PixelOpenSpace --demo [--size 1440x900]
```

For you only (the "3 s" protocol, step 3, décision 10): the same isolated state in a visible window, a minimal menu
bar built from `AppCommand` (without "Rechercher Claude Code" and "Réglages…"), and a floating "Démo" panel:
"Nouvel essai" puts 2 live agents picked at random in a wait (the others work), "Révéler" says who waits and for
what, "Animer" makes 3 agents change activity every 4 s (frame-rate measures). The clock advances every second from
the simulated date. The agents are simulated: no terminal, no `claude`. ⌘Q, closing the window or Ctrl-C erases the
temporary state.
