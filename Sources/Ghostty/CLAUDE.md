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
  `SurfaceView.childEnvironment` is the second such provider, wired beside it in `ClearwayApp.init`
  to a closure that appends `CLIHelperPath.surfaceEnvironment` (the `PATH` below) to what it gets
  from handing the decoded owner tag to `AgentHookIdentity.environment` — the one
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
- `Ghostty.Config.swift` — `Config.loadFromDisk()` is the one loader, for launch and for
  `reloadConfiguration` alike, and it turns off the `shell-integration-features` `path` feature
  after the user's files load. That feature, and `Exec.zig` before it, append the app's
  `Contents/MacOS` to every shell's `PATH`, where `clearway` resolves to the app executable
  `Clearway` on a case-insensitive volume and launches a second instance. Turning the feature off is
  half of it: the `PATH` the surface environment hands over (`CLIHelperPath.surfaceEnvironment`)
  replaces the value `Exec.zig` built, because libghostty applies `env_vars` after its own append
  (`ghostty/src/termio/Exec.zig`, `env_override`). libghostty accepts config only from files, so the
  override is a temp file passed to `ghostty_config_load_file` and deleted after. Ghostty's parser
  resets every feature a line leaves out to its default, so the line names each feature with the
  user's resolved value read back through `ghostty_config_get`, and `shellIntegrationFeatureNames`
  must match the field order of `ShellIntegrationFeatures` in `ghostty/src/config/Config.zig` —
  `GhosttyConfigTests` fails if a submodule bump reorders it.
