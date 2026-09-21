# Sources/Ghostty

- `Ghostty.SurfaceView.swift` — `NSView` hosting a `ghostty_surface_t` (input, rendering).
  Nothing on it is reachable from XCTest: an instance is needed to call anything, and the
  initializer needs a real `ghostty_app_t`. So any decision rule here is lifted out into a pure
  helper that gets tested instead — the same split `TerminalManager.revealSecondaryForHook` makes
  for panel visibility.
  A focused surface swallows **every** Cmd/Ctrl combo, encoding it for the shell, unless the app
  claims it via `SurfaceView.claimsShortcut` — one **static** provider wired in `ClearwayApp.init`
  to `AppKeyboardShortcuts.claims`. Process-scoped, not per-window: the value must stay
  window-independent, so wire it there rather than beside the per-window seams in
  `ContentView.onAppear`. A SwiftUI `.keyboardShortcut` declared without a matching entry is
  unreachable whenever a terminal has focus, which is why the table and the declarations live in
  the same layer.
  `SurfaceView.agentEnvironment` is the second such provider, wired in the same two lines of
  `ClearwayApp.init` to `AgentHookIdentity.environment`. It returns the env vars to stamp on a
  surface's child process from its `surfaceId` and `worktreeId`, and it exists so this layer never
  learns the names: `Sources/Ghostty` wraps libghostty and must not import the hook feature, and a
  provider makes the names testable without a `ghostty_app_t`. Its default is `{ _, _ in [] }`, so
  a missing wiring line compiles, launches and silently ships a dead feature —
  `AgentHookIdentityTests.testTheSurfaceProviderIsWiredAtLaunch` is the pin, and it works because
  the unit-test bundle is hosted by the app, so `ClearwayApp.init` has already run.
  The pairs are `strdup`ed into a `[ghostty_env_var_s]` and freed in a `defer` after
  `ghostty_surface_new`: `Surface.init` `dupeZ`s both key and value into the surface config's arena
  synchronously (`ghostty/src/apprt/embedded.zig`), so the Swift copies need to outlive that one
  call and nothing more.
