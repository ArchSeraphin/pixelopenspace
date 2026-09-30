# PixelCore — contract and working rules

Design reference: `docs/PROPOSITION.md` (French). Section numbers below refer to it.

## Layout

| Path | Content | Owner (step 2a work package) |
|---|---|---|
| `Package.swift` | Manifest | lead (frozen) |
| `Sources/PixelCore/Model/` | IDs, `Project`, `Agent`, `SessionRef`, `Workspace`, `AppSettings` | lead (frozen) |
| `Sources/PixelCore/Hooks/HookEvent.swift` | `HookEventName`, `HookEvent`, `HookPayload`, `HookEnvelope` | lead (frozen) |
| `Sources/PixelCore/Hooks/HookDecoder.swift` | `HookDecoder` public signatures (bodies owned by **hooks**) | hooks |
| `Sources/PixelCore/Hooks/*` (other files) | settings builder, router, deduplicator, JSON helpers | hooks |
| `Sources/PixelCore/State/AgentRuntime.swift`, `AgentInputEffect.swift` | runtime state, inputs, effects, `ReducerConfig` | lead (frozen) |
| `Sources/PixelCore/State/*` (other files) | `AgentStateMachine`, `AgentPresenter`, `StatusSummary` | state |
| `Sources/PixelCore/Launch/`, `Persistence/`, `Util/` (except `ShellQuote.swift`) | launch planning, environment, workspace operations, codecs, screen patterns | launch |
| `Sources/PixelIPC/` (except `HookWire.swift`, frozen) | Unix socket server/client, process ancestry | ipc |
| `Sources/pixel-hook/`, `Sources/fake-claude/` | executables | ipc |
| `Tests/PixelCoreTests/<Area>Tests.swift`, `Tests/PixelCoreTests/Fixtures/<area>/` | tests per package | each package its own files |
| `Tests/PixelIPCTests/` | IPC + end-to-end tests | ipc |

"Frozen" files are the shared contract. Do not edit them. If you need more, add an `extension` in a file you own.
If a contract change is truly unavoidable, do the minimum and list it under `CONTRACT CHANGE` in your final report.

## Rules

- Swift 6 language mode, strict concurrency. Every public type is `Sendable`.
- `PixelCore` and `PixelIPC` must build and test on **Linux and macOS**: Foundation only, no third-party dependencies,
  OS-specific code behind `#if canImport(Darwin)` / `#elseif canImport(Glibc)`. No CoreGraphics, AppKit, Combine, OSLog.
- Pure logic stays pure: no clocks (`Date()` only passed in), no I/O in reducers, planners and parsers.
- Tests use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`). Name test files `<Area>Tests.swift`.
- Build and test with the Docker toolchain wrapper, using **your own build name**:
  `cd /home/user/pixelopenspace/Core && /tmp/claude-0/-home-user-pixelopenspace/d699a716-61e5-5f8a-bbc6-95fba8f57f9c/scratchpad/bin/sw <your-package-name> swift test`
  (add `--filter <SuiteName>` to run yours only; first build takes ~1 min).
- Other packages edit other files of the same targets at the same time. If the build breaks in a file you do not own,
  wait 60–90 s and retry (up to 10 times). Never "fix" someone else's file. Keep your own files compiling at all times
  (write compilable skeletons first, then fill them in).
- Comments: short, explain the why. Doc comments on public API. Code and identifiers in English; user-facing strings
  in French (they will move to the app's String Catalog).
