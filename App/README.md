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
- `AppDelegate.swift`: `NSApplicationDelegate` (installed with `@NSApplicationDelegateAdaptor`). Installs the
  notification delegate in `applicationWillFinishLaunching`, starts the environment in `applicationDidFinishLaunching`,
  keeps the app alive when the last window closes, and routes ⌘Q to `AppModel.handleTerminationRequest()`.
- `AppEnvironment.swift`: `AppEnvironment.shared`: creates and wires every object once (directories, persistence,
  hook server, terminal presenter, session manager, Claude locator, notifications, `AppModel`, `CommandCenter`).
  Loads the state files synchronously; `start()` starts the rest.
- `PixelOpenSpaceApp.swift`: the SwiftUI `@main App` (written with the UI, `App/Sources/UI/`).

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
