# Sources/Ghostty

- `Ghostty.SurfaceView.swift` — `NSView` hosting a `ghostty_surface_t` (input, rendering).
  Nothing on it is reachable from XCTest: an instance is needed to call anything, and the
  initializer needs a real `ghostty_app_t`. So any decision rule here is lifted out into a pure
  helper that gets tested instead — the same split `TerminalManager.firstTabSource` makes
  for a worktree's first tab.
  A focused surface swallows **every** Cmd/Ctrl combo, encoding it for the shell, unless the app
  claims it via `SurfaceView.claimsShortcut` — one **static** provider wired in `ClearwayApp.init`
  to `AppKeyboardShortcuts.claims`. Process-scoped, not per-window: the value must stay
  window-independent, so wire it there rather than beside the per-window seams in
  `ContentView.onAppear`. A SwiftUI `.keyboardShortcut` declared without a matching entry is
  unreachable whenever a terminal has focus, which is why the table and the declarations live in
  the same layer.
  `SurfaceView.agentEnvironment` is the second such provider, wired beside it in `ClearwayApp.init`
  to a closure that decodes the owner tag and hands it to `AgentHookIdentity.environment` — the one
  place the opaque string becomes a typed owner, so an undecodable one is reported there rather than
  dropped. It returns the env vars to stamp on a surface's child process from its `surfaceId` and
  `activityOwner`, and it exists so this layer never learns the names: `Sources/Ghostty` wraps
  libghostty and must not import the hook feature, and a provider makes the names testable without
  a `ghostty_app_t`. Its default is `{ _, _ in [] }`, so
  a missing wiring line compiles, launches and silently ships a dead feature —
  `AgentHookIdentityTests.testTheSurfaceProviderIsWiredAtLaunch` is the pin, and it works because
  the unit-test bundle is hosted by the app, so `ClearwayApp.init` has already run.
  The pairs are `strdup`ed into a `[ghostty_env_var_s]` and freed in a `defer` after
  `ghostty_surface_new`: `Surface.init` `dupeZ`s both key and value into the surface config's arena
  synchronously (`ghostty/src/apprt/embedded.zig`), so the Swift copies need to outlive that one
  call and nothing more.
