# Clearway

Native macOS terminal app built on libghostty.

## Setup

```bash
./scripts/setup.sh
```

Requires: `zig`, `xcodegen`, `swiftlint`

## Build & Run (Debug)

```bash
./scripts/build.sh   # build only
./scripts/run.sh     # build + launch
```

`build.sh` names the product per worktree (`Clearway (<worktree>).app`) while `ci.sh` builds the
default `Clearway.app` into the same `BUILT_PRODUCTS_DIR`, so the two overwrite each other. Resolve
the bundle the way `run.sh` does — newest `.app` in `BUILT_PRODUCTS_DIR`, executable name from
`CFBundleExecutable` — rather than hardcoding a DerivedData path, or you will run a stale binary.

Running the Debug build drops `default.profraw` in the repo root and it is **not** gitignored, so
`git status` goes dirty after every launch. Never `git add -A` without reading the list.

## Verifying a change

```bash
./scripts/ci.sh
```

Regenerates the Xcode project, lints, builds, and runs the test suite — the same gate `.github/workflows/ci.yml` applies to a PR. Use it instead of a hand-written `xcodebuild` line: new Swift files are invisible to the build until `xcodegen generate` runs, and `build.sh`'s `PRODUCT_NAME` override breaks `TEST_HOST`, so the tests fail to launch.

## Linting

SwiftLint runs as a post-build script phase. To lint manually:

```bash
swiftlint lint --quiet
```

All new code must pass `swiftlint lint` with zero errors before committing. Warnings are acceptable for now but should not be introduced in new code.

## Concurrency

- **Never use `isolated deinit` (SE-0371) while the deployment target is macOS 13.** It typechecks
  and emits object code with no availability diagnostic, but references `_swift_task_deinitOnExecutor`
  — a Swift 6.2 runtime symbol. The SDK's `libswift_Concurrency.tbd` back-deploys to `@rpath` only
  below macOS 12.0, so a 13.0 target links the OS copy and the app fails at launch on older systems.
  The compiler will not warn you. Make the `deinit` genuinely nonisolated instead.
- Prefer an **isolated conformance** (`@MainActor SomeDelegate`) over `@preconcurrency` whenever the
  compiler reports `#ConformanceIsolation`. `@preconcurrency` downgrades the check to a runtime trap;
  an isolated conformance keeps it static. Applies to the unannotated AppKit delegate protocols —
  `NSTextStorageDelegate` is one; `NSTextViewDelegate` is already `NS_SWIFT_UI_ACTOR` and needs neither.
- `DispatchSourceFileSystemObject` is `Sendable`, so a nonisolated `deinit` can cancel one directly.
  `DispatchWorkItem` is not — hold it in a `ScheduledWork` (`Sources/App/ScheduledWork.swift`) whose own
  `deinit` cancels it. `@preconcurrency import Dispatch` also silences the diagnostic, but file-wide;
  the only one left (`FileWatchers.swift:1`) predates the RAII holder.
- `MainActor.assumeIsolated` asserts, it does not dispatch. Use it only where arrival on main is
  already guaranteed — never on a `DispatchSource` callback path. Even where arrival *is* guaranteed
  (a `NotificationCenter` observer registered with `queue: .main`), prefer `Task { @MainActor in }`
  unless the call has to stay synchronous: it keeps the check static instead of runtime.
- A nonisolated `deinit` may not *read* an isolated non-`Sendable` property, but releasing one is not
  reading it. So an RAII holder whose own `deinit` does the cleanup needs no suppression at all —
  `NotificationObservation` deregisters a `NotificationCenter` token, `ScheduledWork` cancels a
  `DispatchWorkItem`, and `Ghostty`'s `AppHandle` / `SurfaceHandle` reach `ghostty_app_free` /
  `ghostty_surface_free`, and `AgentActivityMonitor`'s `HookSocketListener` cancels a
  `DispatchSourceRead` whose cancel handler closes the listening descriptor — so turning the agent
  hooks off is `listener = nil` and no teardown call of its own. Reach for this before a lock.
- **The load-bearing `[weak self]` is the outer one.** On a closure that `NotificationCenter` retains
  — or a `DispatchWorkItem` the object itself owns — the *outer* capture list is what breaks the
  cycle. An inner `Task { @MainActor [weak self] }` nested inside it is redundant: a nested closure
  keeps an outer weak capture weak. Drop the inner one, never the outer. Doing the reverse is exactly
  how `WorkTaskCoordinator` leaked through `.ghosttyChildExited`, and a code review has since
  recommended it a second time, so the shape reads as interchangeable and is not. The exception is an
  outer block that does `guard let self`: there `self` is strong again and the inner `[weak self]`
  earns its place (`TerminalManager`'s `.ghosttyCloseSurface` observer is the one such site).
- `OpaquePointer` and `UnsafeMutableRawPointer` carry an *unavailable* `Sendable` conformance, so no
  wrapper holding a `ghostty_*_t` can be checked-`Sendable`. With the RAII shape above it usually
  does not need to be.
- **Never form a C or block callback inside a `@MainActor` context.** A `@convention(c)` *or*
  `@convention(block)` closure literal written inside a `@MainActor` member is main-actor isolated:
  its prologue calls `swift_task_isCurrentExecutor` and traps when the callback is invoked from any
  other thread. The compiler reports nothing — unlike a plain Swift function-typed parameter, which
  infers the literal `nonisolated` and checks it statically. `Ghostty.App.makeRuntimeConfig` is
  `nonisolated static` for exactly this reason — build the callback table there, never in `init`.
  Marking the callee `static func`s `nonisolated` is also required but is **not** sufficient on its own.
- **`DispatchSource` handlers are that same block trap**, and cost a shipped release (v1.9.3) a
  crash on every worktree switch: `setEventHandler`/`setCancelHandler` take
  `DispatchSourceHandler = @convention(block) () -> Void`, so a literal written in a `@MainActor`
  method traps in `dispatch_assert_queue` the moment libdispatch runs it on the source's queue —
  the cancel handler included, which fires on teardown rather than on any file event. Swift 5.10
  converted these silently; `SWIFT_VERSION: "6.0"` turns them into hard traps. So **every**
  file-system `DispatchSource` goes through `FileWatchers.makeWatcher`, which is `nonisolated static`
  and takes the handler as a plain `() -> Void`. Never call `setEventHandler`/`setCancelHandler` from
  an isolated method. The one source that is not a file watcher — `HookSocketListener`'s read source
  over the hook socket — keeps the rule rather than the door: its whole socket path is a
  `nonisolated static` factory, because an `AF_UNIX` listener shares nothing with `O_EVTONLY` on a
  path but the trap.
- A minimal probe of that shape does not reproduce the trap; it runs the body off-main silently.
  Verify by disassembling the built binary (`lldb -b -o "disassemble -a <addr>"`) and looking for
  `MainActor.shared` / `swift_task_isCurrentExecutor` in the closure's prologue.
- libghostty installs its **own** crash handler, so a crash writes no macOS `.ips`. Reports land in
  `~/.local/state/ghostty/crash/*.ghosttycrash` (a Sentry envelope; the minidump is the
  `event.minidump` attachment, loadable with `lldb --core`). A directly-exec'd crash surfaces as
  exit code 6, not a signal.

## Architecture

- **ghostty/** — upstream ghostty submodule, built into `GhosttyKit.xcframework`
- **Sources/Ghostty/** — first-party Swift wrappers around the libghostty C API. Excluded from SwiftLint (`.swiftlint.yml`), but **not** vendored and not an upstream mirror — only `ghostty/` is a submodule. Held to the same engineering bar as `Sources/App`. Per-file notes: `Sources/Ghostty/CLAUDE.md`.
- **Sources/App/** — SwiftUI app entry point + task/worktree logic. Per-file notes: `Sources/App/CLAUDE.md`.
- **Sources/App/Clearway-Bridging-Header.h** — the only route to cmark-gfm's GFM extension API; the SPM package's umbrella header exposes just `cmark.h`, so `import cmark` cannot see it. Its four prototypes are hand-copied, so the package is pinned with `exactVersion` — a signature change in a later 2.x would not fail the build.
- swift-markdown was evaluated and rejected for the Markdown preview: it is parse-only, ships no HTML renderer, and wraps the same cmark-gfm already vendored.

## Rebuilding GhosttyKit

```bash
cd ghostty && zig build -Demit-xcframework=true -Doptimize=ReleaseFast
```

## Key APIs

Key patterns:
- To run a command in a terminal without a login shell, pass `command:` to `Ghostty.SurfaceView(app, workingDirectory:, command:)`. Do NOT create a bare surface and then `sendCommand()` — that starts a login shell first, making the command visible in the prompt.
- Key input uses `ghostty_input_key_s` with `keycode` (macOS virtual key code), not a key enum

## Pipeline

How the `/work` pipeline runs in this repo. Irrelevant outside it.

### Regression check vs. full gate

One command serves both — `./scripts/ci.sh` is the only runner of the test suite, and it runs
`xcodegen generate`, without which added or deleted Swift files are invisible to the build.

| Step | Command | What it is |
| --- | --- | --- |
| Every `build` task, and `simplify` | `./scripts/ci.sh` | Regression check |
| `sign-off`, once | `./scripts/ci.sh` | Full gate |

The test host launches the app, so on a developer machine **every** `ci.sh` run installs the agent
hook block into the real `~/.claude/settings.json` — the toggle defaults on — and takes the one-time
`settings.json.clearway-backup` beside it. That is the feature, not a test artefact. GitHub's runner
has no `~/.claude`, and the installer's directory gate makes it a no-op there.

### Background load generators

A CPU-load reproduction (`yes > /dev/null &` × N behind an `xcodebuild` loop) must not rely on a
trailing `kill` to clean up: the Bash tool's timeout kills the shell, not its backgrounded children,
and twelve orphaned `yes` processes once ran at 100% CPU each for 22 hours after a
`-run-tests-until-failure` loop outran the 10-minute limit. Bound every generator by its own
lifetime (`timeout 540 yes > /dev/null &`) or `trap 'kill $LOADPIDS' EXIT`, and keep the run
shorter than the tool timeout.

### Merge model

The pipeline never merges; the operator merges by hand once CI is green. Squash and rebase merges
are allowed, merge commits disabled, branch deletion on merge on. Auto-merge is disabled at the repo
level, so there is no command to enable it. The `Main` ruleset blocks only deletion and
non-fast-forward pushes — GitHub requires no status check, so `.github/workflows/ci.yml` (jobs
`SwiftLint`, `Build & Test`) gates by convention, not enforcement.

`ci.sh` does not itself refuse on a dirty tree, so before any CI stamp or sign-off run
`git status --porcelain` and report untracked/ignored files; they block sign-off. Expect the
un-gitignored `default.profraw` noted above after any Debug launch.
