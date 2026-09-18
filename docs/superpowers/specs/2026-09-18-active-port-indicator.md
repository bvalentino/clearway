# Active Port Indicator

**Date:** 2026-09-18
**Base:** 7ae81c1fca4c52beaf290a2035746c975ff95c69
**PR:** #224

The operator keeps five or so worktrees alive at once and forgets which of them has a dev server
running, and on which port. Nothing in Clearway shows it: a server started in a terminal tab, an
external terminal or an IDE is invisible once the tab scrolls. This change adds a machine-wide
scan of listening TCP sockets, attributes each one to a worktree by the owning process's working
directory, and lists the selected worktree's live ports in the detail pane's status bar. Clicking
a port number opens `http://localhost:<port>` in the default browser.

## Decisions

| # | Question | Decision | Source |
| --- | --- | --- | --- |
| 1 | How is a listening socket attributed to a worktree? | By the owning process's current working directory. A socket belongs to the worktree whose path the cwd is inside, regardless of who started the process — a Clearway tab, an external terminal, an IDE, an agent. | Operator |
| 2 | Where does this surface? | One place: the selected worktree's port numbers on the right of the detail pane's `WorktreeStatusBar`, immediately before the PR info. Amended twice by the operator during the hands-on check. The change first shipped a popover on a detail-toolbar button listing every live port grouped by worktree, then replaced it with the status bar and kept a globe on each sidebar worktree row; the toolbar popover and then the sidebar globe were both removed. The status bar is the only rendering — do not reinstate either. | Operator |
| 3 | What does clicking a port do? | Opens `http://localhost:<port>` in the system default browser. No hover-reveal button, no copy action, no browser picker. | Operator |
| 4 | Which sockets count? | Every TCP socket in `LISTEN` state, on any local interface (`127.0.0.1`, `0.0.0.0`, `::`, `::1`). Rendered as the bare port number in the status bar's entries, the only place a port is shown. No HTTP probing, no UDP. | Operator |
| 5 | What mechanism enumerates listening sockets and process cwds? | The `libproc` C API, in-process: `proc_listpids(PROC_ALL_PIDS)`, then per pid `proc_pidinfo(PROC_PIDLISTFDS)` and `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` for sockets where `soi_kind == SOCKINFO_TCP` and `pri_tcp.tcpsi_state == TSI_S_LISTEN`, then `proc_pidinfo(PROC_PIDVNODEPATHINFO)` for the cwd of the few pids that matched. Measured in the scratchpad against this machine (see Assumptions 1–2): **2.8–4.1 ms** for the full scan, 0.19 ms for the cwd lookups. The alternatives lose on both cost and risk: one `lsof -nP -iTCP -sTCP:LISTEN` is 48–60 ms and still needs a second call for cwds (18 ms), and the single combined `lsof -nP -d cwd -iTCP -sTCP:LISTEN` is 227 ms. More importantly, `libproc` spawns no subprocess, so none of the `Process`/pipe/`DispatchQueue.global` failure modes recorded in CLAUDE.md for `OpenInAppLauncher` can arise, and no PATH resolution is needed. | Spec author |
| 6 | Does the app have the privileges to read other processes' fds and cwd? | Yes. `Clearway.entitlements` declares only `com.apple.security.cs.allow-unsigned-executable-memory` — there is no `com.apple.security.app-sandbox` key, so the app is unsandboxed and `proc_pidinfo` succeeds for every process owned by the same user. Processes owned by another user (root daemons) return `0` from `proc_pidinfo` and are skipped silently; that is correct, since a root daemon's cwd is never inside the user's worktree. | Spec author |
| 7 | Poll cadence? | 2 seconds, fixed. The brief accepts 2–5 s staleness; at ~3 ms per scan a 2 s period costs about 0.15 % of one core, so there is nothing to buy by backing off, and a variable cadence is configuration nobody asked for. The scan runs unconditionally while the app is open — no gating on `NSApplication` activation, which would add state for a saving that does not exist at this cost. | Spec author |
| 8 | What shape is the poller, given CLAUDE.md's block-callback rules? | A `Task` loop: `while !Task.isCancelled { await Task.sleep(for: .seconds(2)); … }`, with the scan itself performed in a `Task.detached(priority: .utility)` over a `nonisolated static` scanner, and the result assigned to an `@Published` property back on the main actor. This forms **no** `@convention(block)` or `@convention(c)` literal at all, so the `DispatchSource` / `DispatchWorkItem` trap that cost v1.9.3 a crash cannot apply. CLAUDE.md already blesses this exact shape — `OpenInAppLauncher`'s watch window is "a `Task.sleep` poll on the cooperative pool" (`OpenInAppLauncher.swift:13,73`). `ClaudeActivityMonitor.pollForParentDirectory` (`ClaudeActivityMonitor.swift:265-287`) is the other precedent and uses `ScheduledWork` + `DispatchQueue.global`; it is not copied here because it builds a `DispatchWorkItem` literal inside a `@MainActor` method, which is the shape CLAUDE.md warns about, and nothing here needs it. | Spec author |
| 9 | Where does the monitor live — app-wide or per project window? | App-wide: a `@StateObject` on `ClearwayApp` (`ClearwayApp.swift:126-130`) injected with `.environmentObject`, beside `savedCommandManager` and `caffeine`. The scan is machine-wide and identical for every window, so a per-window `@StateObject` — the `ClaudeActivityMonitor` shape (`ProjectWindow.swift:80`) — would run N identical scans for N open projects. The monitor publishes raw `(cwd, ports)` records; mapping them onto a project's worktrees is a pure function each window calls. | Spec author |
| 10 | Which worktree wins when one worktree path is inside another? | The longest matching path. Clearway's own layout nests linked worktrees under the primary checkout — `git worktree list --porcelain` on this repo returns `/Users/bvalentino/Developer/bvalentino/clearway` followed by `/Users/bvalentino/Developer/bvalentino/clearway/.worktrees/<name>` — so a naive `hasPrefix` attributes every child's port to the primary as well. Verified empirically: two `python3 -m http.server` processes, one in each, produced cwds that differ only by the suffix (Assumption 3). The match is `cwd == path || cwd.hasPrefix(path + "/")`, and among matches the longest `path` wins. | Spec author |
| 11 | How are duplicate ports handled? | Deduplicated per worktree. A server bound to both IPv4 and IPv6 owns two listening sockets on the same port — the scratchpad scan shows redis on `127.0.0.1:6379` and `[::1]:6379`, and postgres likewise on 5432. The brief's acceptance criterion says a `0.0.0.0` bind must look the same as a `127.0.0.1` bind, so the unit carried through is the port number, sorted ascending, once each. Two servers in one worktree therefore contribute two status-bar entries. | Spec author |
| 12 | Are ports that belong to no worktree shown anywhere? | No. Redis, postgres, AirPlay and every other machine-wide listener is discarded once attribution fails. The feature answers "which worktree has a server up", not "what is listening on this Mac". | Spec author |
| 13 | Do hidden worktrees contribute their ports to a visible parent? | No. Attribution runs over **all** tracked worktrees — `worktreeManager.worktrees`, unfiltered — not over the visible list. A listener inside a hidden nested worktree is therefore attributed to that hidden worktree and is simply not rendered, never to its visible parent: a port shown against a worktree must be a port running in it. Rendering is unchanged — the status bar draws only the selected worktree's ports and the sidebar draws no ports at all, so nothing here touches which worktrees the sidebar shows. `Worktree.visible` itself is untouched. | Operator |
| 14 | What shows when the selected worktree has no live ports? | Nothing — the status bar renders no ports section at all, leaving the bar exactly as it was before this change. There is no empty or disabled placeholder, because the status bar is not a control the user reaches for; it reports. This retires the earlier question of whether a toolbar button was hidden or disabled: **there is no toolbar button.** Amended by the operator during the hands-on check; do not reinstate a Live Ports toolbar item. | Operator |
| 15 | Is there a popover anywhere in this feature? | No. The grouped-by-worktree popover is removed with its toolbar button; the selected worktree is the only one whose ports are listed, so there is nothing to group and nothing to open. `.popover` therefore still appears nowhere in `Sources/`. Amended by the operator during the hands-on check. | Operator |
| 16 | How do the status-bar ports render, and where in the bar? | Bare port numbers, ascending, in the bar's own `.system(size: 11, design: .monospaced)` `.secondary` style, in an `HStack(spacing: 8)` on the right of `WorktreeStatusBar` immediately before the PR info (`ContentViewHelpers.swift`). Each number is a `.contentShape(Rectangle())` + `.onTapGesture` target with `pointerCursorOnHover()` — the pattern `prStatusView` already uses in that bar for a clickable sub-element — and carries `.help("http://localhost:<port>")`, so hovering names the URL the click will open. No icon, no capsule and no label: the bar's existing items are bare text too. | Operator |
| 17 | Does the sidebar row show a port? | No. The sidebar renders nothing for this feature: `WorktreeRow` takes no `ports` parameter, holds no `PortBadge`, and `SidebarView` never reaches the monitor. Amended by the operator during the hands-on check. The row first drew one monospaced-digit capsule per port, then a single `globe` button tooltipped with the ports; both are retired, because the status bar already names the ports of the worktree the user is looking at and the row's job is the worktree, not its servers. Do not reinstate a sidebar badge. | Operator |
| 18 | How is a port click kept clear of the sidebar's selection and drag? | Moot: no port is clickable in the sidebar any more. The status bar sits outside the `List`, so its ports' `.onTapGesture` + `.contentShape(Rectangle())` — the pattern `prStatusView` already uses in that same bar — reaches neither `selection` nor `.draggableIf`. Amended by the operator during the hands-on check, which retired the globe `Button` this decision was about. | Operator |
| 19 | Does a port get a `.help()` tooltip? | Yes, on each status-bar entry, and it names the URL the click opens: `http://localhost:3000`. This is the "prevents error" exemption in CLAUDE.md's no-helper-text rule, not a restatement — a bare number does not say what clicking it does. Its text comes from `PortLink.urlString` (decision 25), never from a string literal. The retired sidebar globe's tooltip, which named the ports instead, is gone with the globe. | Operator |
| 20 | What opens the URL? | `NSWorkspace.shared.open` — the app's existing default-browser call (also `MarkdownPreviewView.swift:45`, `Ghostty.App.swift:229`) — on `PortLink.url(port)`, guarded rather than force-unwrapped. Each status-bar entry opens its own port, and it is the only thing that opens one. | Operator |
| 21 | Does the feature claim a keyboard shortcut? | No, so `AppKeyboardShortcuts` gains no entry and no not-claimed pin. CLAUDE.md: claim exactly what the app handles, and the pins cover keys the app once owned. `OpenInMenu` set the same precedent. | Spec author |
| 22 | What is unit-tested, given a `ghostty_app_t` is unavailable in XCTest? | The scan is split so the decision rules are pure. `PortScanner` (`nonisolated`, `libproc`) is untested — it reads live kernel state and has no injectable seam worth building. `PortAttribution` is a pure function from `[(cwd: String, port: UInt16)]` plus `[Worktree]` to `[worktreeId: [UInt16]]`, and takes the whole test suite: longest-path-wins for nested worktrees, exact-path match, no match, IPv4+IPv6 dedupe, multiple ports sorted ascending, empty input. New file `Tests/PortAttributionTests.swift`. | Spec author |
| 23 | Is `ContentView.swift` split before this change lands in it? | No. CLAUDE.md says "the next addition there needs a split first" about `ContentView.swift` being past SwiftLint's 1000-line `file_length` error (it is 1028 lines, carried by the file-wide `swiftlint:disable file_length` on line 1). That rule is aimed at adding views and logic to the file; after the hands-on check `ContentView.swift` only **loses** four lines here — the retired Live Ports `ToolbarItem` and its `ToolbarGroupBreak` — and the ports render in `ContentViewHelpers.swift`, where `WorktreeStatusBar` already lives. Splitting `ContentView` properly is a refactor of its own with its own risk, and doing it inside this change would bury the feature. Recorded here so the build stage does not re-litigate it; if the operator wants the split, it is a separate task. | Spec author |
| 24 | Is there a Settings toggle for the feature, or for the poll interval? | No. The brief puts both out of scope. | Operator |
| 25 | How is a port turned into text? | Through one pure helper, `PortLink` (`Sources/App/PortLink.swift`): `label(_:)` is `String(port)`, `urlString(_:)` is `"http://localhost:" + String(port)`, and `url(_:)` parses that string. No port is interpolated into a string literal anywhere. A literal handed to `Text` or `.help` binds their `LocalizedStringKey` overload, which formats an integer for the locale — that is what made the status bar's tooltip read `http://localhost:3,000`. Pinned by `Tests/PortLinkTests.swift`. Amended by the operator during the hands-on check, which found the bug. | Operator |

## Assumptions

Each was verified at base `7ae81c1`, by reading the cited file or by running a probe. **The probes
live in the session scratchpad** (`.../scratchpad/probe.swift`, built to `probe` and `probe6`);
nothing was written into the repository.

1. **`libproc` enumerates listening TCP sockets with their ports from Swift, on this deployment
   target, under this language mode.** `probe.swift` compiles clean with
   `swiftc -swift-version 6 -target arm64-apple-macos13.0` — zero warnings, exit 0 — and prints
   21 listening sockets across 11 pids in 2.8–4.1 ms. `insi_lport` is network byte order, so the
   port is `UInt16(bigEndian:)`; the probe returned 6379, 5432 and 8123 correctly, which confirms
   it. The constants used (`PROC_ALL_PIDS`, `PROC_PIDLISTFDS`, `PROX_FDTYPE_SOCKET`,
   `PROC_PIDFDSOCKETINFO`, `SOCKINFO_TCP`, `TSI_S_LISTEN`, `PROC_PIDVNODEPATHINFO`) are all
   reachable from `import Darwin` with no bridging-header entry — unlike cmark-gfm's GFM
   extensions, which needed `Clearway-Bridging-Header.h`.
2. **The cwd of another same-user process is readable.** `proc_pidinfo(PROC_PIDVNODEPATHINFO)`
   returned real paths for every user-owned pid in the probe (`/opt/homebrew/var/db/redis`,
   `~/Library/Application Support/com.elgato.StreamDeck/...`) in 0.19 ms total for 11 pids. The app
   is unsandboxed (decision 6).
3. **Worktree paths nest, and longest-match is therefore required.** `git worktree list
   --porcelain` in this repo returns the primary at
   `/Users/bvalentino/Developer/bvalentino/clearway` and five linked worktrees at
   `.../clearway/.worktrees/<name>`, with no trailing slashes. Starting
   `python3 -m http.server 8123` in the linked worktree and `8124` in the primary produced exactly
   those two cwds in the probe output, so `hasPrefix` alone would attribute 8123 to both.
4. **`Worktree.path` is the string `git worktree list --porcelain` printed, unmodified.**
   `parseWorktreeListOutput` assigns `String(line.dropFirst("worktree ".count))`
   (`Worktree.swift:261`) and `applyHeadResolution` carries it through, so the value compared
   against a process cwd is git's own absolute path. No symlink resolution is applied on either
   side; both are absolute and, on this machine, identical.
5. **`WorktreeRow` has one construction site.** `SidebarView.worktreeRowView`
   (`SidebarView.swift:483-511`) is the only caller; the type lives in
   `Sources/App/WorktreeRow.swift:5`. Adding a parameter touches one call site. Moot after the
   hands-on check retired the sidebar badge: the `ports` parameter added here was removed again and
   `WorktreeRow` is back to its shape at base. Kept because it records why the removal touches one
   call site too.
6. **The detail toolbar is attached to `detailView`, not to the `NavigationSplitView`.**
   `ContentView.swift:193-194`. Moot after the hands-on check removed the feature's toolbar item;
   kept because it records why the removal is a plain four-line deletion with no spacer to rehome.
7. **The full worktree list is available in both surfaces.** `SidebarView` holds
   `@EnvironmentObject worktreeManager` (`SidebarView.swift:16` for `claudeActivityMonitor`, the
   managers alongside) and `WorktreeStatusBar` already holds it too
   (`ContentViewHelpers.swift:85`). No new plumbing is needed to reach the worktrees attribution
   runs over; each surface adds only `@EnvironmentObject portMonitor`.
8. **`Sources/App` is linted.** `.swiftlint.yml` excludes only `Sources/Ghostty` and
   `BuildInfo.generated.swift`, so every new file must pass `swiftlint lint` with zero errors and
   stay under the 700-line `file_length` warning.
9. **`.popover` appears nowhere in `Sources/`.** `grep -rn "\.popover" Sources/` returned nothing
   at base and returns nothing after the hands-on check retired decision 15's popover, so the
   pattern is still unused here.

## Objective

A user running dev servers across several worktrees can see, without leaving Clearway, which
worktree has a server up and on which port, and can open it in one click — including for servers
started outside Clearway and for worktrees whose tabs are not open.

### Success criteria

1. Starting `python3 -m http.server 8123` inside worktree A adds `8123` to the detail status bar
   within 5 seconds with A selected. A's sidebar row is unchanged.
2. Stopping it removes the number within 5 seconds.
3. A server started from an external terminal in worktree A is attributed to A.
4. A server whose cwd is the primary checkout root is attributed to the primary worktree only, and
   a server in `.worktrees/<name>` is attributed to that worktree only.
5. Two servers in one worktree show two numbers in the status bar, ascending; a server bound to
   `0.0.0.0` reads identically to one bound to `127.0.0.1` — one port, not two.
6. Clicking a port number in the status bar opens `http://localhost:<port>` in the default browser.
   Hovering it shows exactly `http://localhost:<port>` — for port 3000, `http://localhost:3000` and
   never `http://localhost:3,000`.
7. With no live ports in the selected worktree, the status bar shows nothing between the path and
   the PR info. No sidebar row carries a port badge of any kind, live ports or not, and there is no
   Live Ports toolbar button.
8. `Tests/PortAttributionTests.swift` covers the attribution and dedupe rules and
   `Tests/PortLinkTests.swift` pins the label and URL text for port 3000; both pass without a
   `ghostty_app_t`.
9. `./scripts/ci.sh` is green and `swiftlint lint --quiet` reports zero errors for the change.

## Verification

```bash
./scripts/ci.sh
```

Regenerates the Xcode project, lints, builds and runs the test suite — the regression check for
every build task and the full gate at sign-off, per CLAUDE.md's `## Pipeline` section. Do not
hand-write an `xcodebuild` line; the new Swift files are invisible to the build until
`xcodegen generate` runs, which only `ci.sh` does.

Criteria 1–7 are user-visible behaviour that XCTest cannot reach, and CLAUDE.md's `## Pipeline`
memory is explicit that build agents do not launch the app. They are confirmed by the operator by
hand in the running app (`./scripts/run.sh`), with `python3 -m http.server` started and stopped in
two worktrees. Criterion 6's "does not change the sidebar selection" half is the one behaviour
decision 18 flags as needing that hands-on check.

Before any CI stamp, run `git status --porcelain`. Expect the un-gitignored `default.profraw` in
the repo root after any Debug launch; report it, and never `git add -A`.

## Files touched

| File | Change |
| --- | --- |
| `Sources/App/PortScanner.swift` | New. `nonisolated enum PortScanner` wrapping `libproc`: returns a `Sendable` `Listener` (cwd plus port) for every same-user process holding a TCP socket in `LISTEN`. No subprocess, no `DispatchSource`. |
| `Sources/App/PortAttribution.swift` | New. Pure mapping from those records plus `[Worktree]` to `[worktreeId: [UInt16]]` — longest-path-wins, deduped, ascending. The whole of the change's decision logic. |
| `Sources/App/PortMonitor.swift` | New. `@MainActor final class PortMonitor: ObservableObject` publishing the latest scan; a `Task` loop with `Task.sleep(for: .seconds(2))` driving `Task.detached` scans, cancelled from a nonisolated `deinit`. |
| `Sources/App/ContentViewHelpers.swift` | `WorktreeStatusBar` gains `@EnvironmentObject portMonitor`, a `livePorts` property attributing against the full tracked list, and a `livePortsView` of clickable, `.help`-tooltipped port numbers on the right, before the PR info. |
| `Sources/App/WorktreeRow.swift` | Untouched by the final shape. A `ports: [UInt16]` parameter and a private `PortBadge` landed under T4 and were removed again during the hands-on check; the file is back to its content at base. |
| `Sources/App/SidebarView.swift` | Untouched by the final shape. `@EnvironmentObject portMonitor`, `portsByWorktree` and the row's `ports:` argument landed under T4 and were removed again during the hands-on check. |
| `Sources/App/PortLink.swift` | New. The one pure helper turning a `UInt16` into the status bar's label, its tooltip text and the URL it opens, all built with `String(port)` rather than interpolation. |
| `Sources/App/ContentView.swift` | Untouched by the final shape. A `ToolbarItem(placement: .primaryAction)` rendering `LivePortsMenu` plus a `ToolbarGroupBreak` landed in `detailView.toolbar` under T5 and were removed again during the hands-on check. |
| `Sources/App/ClearwayApp.swift` | `@StateObject private var portMonitor = PortMonitor()` and `.environmentObject(portMonitor)`. |
| `Tests/PortAttributionTests.swift` | New. The attribution and dedupe rules. |
| `Tests/PortLinkTests.swift` | New. The label and URL text, pinned for port 3000 and for the port range's bounds. |
| `project.yml` | Untouched — `xcodegen` globs `Sources/App`, but `./scripts/ci.sh` must still run for the new files to enter the build. |
| `docs/superpowers/specs/2026-09-18-active-port-indicator.md` | This document. |
| `docs/superpowers/plans/2026-09-18-active-port-indicator.md` | The plan, written by the next stage. |

## Out of scope

- Killing, restarting or otherwise controlling a server from Clearway (brief).
- Copying a port's URL, choosing which browser opens it, or any Settings toggle for the feature or
  its cadence (brief, decision 24).
- UDP sockets, remote hosts, and any URL form other than `http://localhost:<port>` (brief).
- Naming the framework, command or process behind a port (brief). A database, a language server or
  any other non-server listener whose cwd is inside a worktree will show; the brief accepts this.
- HTTP probing to tell a web server from any other listener (brief).
- Ports belonging to no worktree of the open project (decision 12).
- Changing `Worktree.visible` or anything else about which worktrees the sidebar shows
  (decision 13).
- Splitting `ContentView.swift` below SwiftLint's `file_length` error (decision 23).
- The known `WorktreeGroupStore.openFileWatcher` fd leak recorded in CLAUDE.md; unrelated and owed
  its own task.
