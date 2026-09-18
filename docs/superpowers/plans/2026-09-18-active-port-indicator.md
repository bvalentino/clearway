# Plan: Active Port Indicator

**Date:** 2026-09-18
**Base:** 7ae81c1fca4c52beaf290a2035746c975ff95c69
**PR:** #224

Breaks down `docs/superpowers/specs/2026-09-18-active-port-indicator.md`.

## Architecture decisions carried from the spec

1. A listening socket belongs to the worktree whose path contains the owning process's cwd;
   among nested matches the longest path wins (spec 1, 10).
2. Enumeration is `libproc` in-process — `proc_listpids`, `proc_pidinfo(PROC_PIDLISTFDS)`,
   `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`, `proc_pidinfo(PROC_PIDVNODEPATHINFO)`. No subprocess,
   no `lsof`, no PATH resolution (spec 5). The app is unsandboxed, so same-user pids answer and
   root-owned ones return 0 and are skipped (spec 6).
3. Only TCP sockets in `LISTEN`, on any local interface, rendered as the bare port number.
   No UDP, no HTTP probing (spec 4).
4. Poll every 2 s, unconditionally, from a `Task` loop with `Task.sleep(for: .seconds(2))`
   driving a `Task.detached(priority: .utility)` scan. **No `@convention(block)` or
   `@convention(c)` literal is written anywhere in this change** — no `DispatchSource`, no
   `DispatchWorkItem`, no `Process.terminationHandler` (spec 7, 8).
5. One app-wide monitor: `@StateObject` on `ClearwayApp` beside `savedCommandManager`, injected
   with `.environmentObject`. It publishes raw `(cwd, port)` records; mapping them onto a
   project's worktrees is a pure function each window calls (spec 9).
6. Ports are deduplicated per worktree and sorted ascending — an IPv4 and an IPv6 bind of one
   server count as one port (spec 11).
7. Ports attributed to no worktree are discarded (spec 12).
8. Attribution runs over the full tracked list, `worktreeManager.worktrees`, so a listener inside
   a hidden nested worktree belongs to that hidden worktree and is simply not rendered. The status
   bar is the only renderer, and it shows only the selected worktree. `Worktree.visible` is
   untouched (spec 13).
9. The second surface is the detail pane's `WorktreeStatusBar`: the selected worktree's port
   numbers on the right, immediately before the PR info, and nothing at all when it has none
   (spec 14, 16). There is no toolbar button; do not reinstate one.
10. There is no popover anywhere in the feature (spec 15).
11. The sidebar renders no ports at all. `WorktreeRow` takes no `ports` parameter and holds no
    `PortBadge`; `SidebarView` never reaches the monitor (spec 17, 18). Do not reinstate a badge.
12. Each status-bar port carries a `.help()` tooltip naming the URL its click opens (spec 19).
13. Clicking opens `http://localhost:<port>` with `NSWorkspace.shared.open`, guarded rather than
    force-unwrapped (spec 20). Every string a port appears in — the label, the tooltip and the URL
    — is built by `PortLink` with `String(port)`, never interpolated into a string literal, because
    a literal binds `Text`'s and `.help`'s `LocalizedStringKey` overload, which locale-formats the
    integer and rendered `http://localhost:3,000` (spec 25).
14. No keyboard shortcut, so `AppKeyboardShortcuts` gains nothing (spec 21).
15. `PortScanner` is untested; `PortAttribution` is pure and takes the whole suite in
    `Tests/PortAttributionTests.swift`, and `PortLink` is pinned by `Tests/PortLinkTests.swift`
    (spec 22, 25).
16. `ContentView.swift` is **not** split. It only loses the retired `ToolbarItem` and its
    `ToolbarGroupBreak`; the ports render in `ContentViewHelpers.swift` (spec 23).
17. No Settings toggle for the feature or its cadence (spec 24).

**Two mechanical choices this plan fixes.**

The spec writes the scan's output as `[(cwd: String, port: UInt16)]`. This plan names it a
`struct PortScanner.Listener: Equatable, Hashable, Sendable { let cwd: String; let port: UInt16 }`
for two reasons, neither of which reopens a spec decision:

- An array of tuples is not `Equatable`, so `PortMonitor` could not compare a fresh scan against
  the published one and would republish every 2 s, invalidating the sidebar 30 times a minute for
  no change. With `Equatable` the assignment is skipped when nothing moved.
- `Tests/PortAttributionTests.swift` builds the input by hand; a named type reads better there.

Second: `PortMonitor.pollTask` is a plain `private var pollTask: Task<Void, Never>?` cancelled
from a nonisolated `deinit`, with no RAII holder. `Task` is `Sendable`, so a nonisolated `deinit`
of a `@MainActor` class may read it — verified by compiling the exact shape with
`swiftc -swift-version 6 -target arm64-apple-macos13.0`, exit 0, zero warnings (probe in the
planning session's scratchpad, nothing written into the repo). `ScheduledWork` exists for
`DispatchWorkItem`, which is not `Sendable`; it is not needed here.

## Dependency graph

```
T1 (PortAttribution + tests)  ─┐
                               ├─→ T4 (sidebar badge)
T2 (PortScanner) ─→ T3 (PortMonitor + app wiring) ─┤
                               └─→ T5 (second surface; see T5's note)
```

T1 and T2 are independent and can run in either order. T3 needs T2's type. T4 and T5 are
independent of each other and both need T1 and T3.

## Task list

### T1: Pure port-to-worktree attribution, with its test suite

**Files touched**

- `Sources/App/PortAttribution.swift` (new)
- `Tests/PortAttributionTests.swift` (new)

**What it does**

Adds the whole of the change's decision logic as one pure function, plus the record type the
scanner will fill in T2. Nothing in this task reads the kernel or renders anything.

```swift
enum PortScanner {
    struct Listener: Equatable, Hashable, Sendable {
        let cwd: String
        let port: UInt16
    }
}
```

Declare `PortScanner` and its nested `Listener` **in `PortAttribution.swift`** if T2 has not
landed yet, or add `Listener` to T2's `PortScanner.swift` if it has; either way exactly one
declaration exists when both tasks are done, and the build agent for whichever lands second
removes the duplicate rather than renaming anything.

```swift
enum PortAttribution {
    static func attribute(
        _ listeners: [PortScanner.Listener],
        to worktrees: [Worktree]
    ) -> [String: [UInt16]]
}
```

The rule, in order:

1. Drop worktrees whose `path` is `nil`.
2. A worktree matches a listener when `listener.cwd == path || listener.cwd.hasPrefix(path + "/")`.
   The `+ "/"` is load-bearing: it stops `/a/clearway-old` matching the worktree `/a/clearway`.
3. Among matches, the one with the longest `path` wins. A listener matching nothing is discarded.
4. Ports accumulate per worktree id into a `Set<UInt16>`, so an IPv4 and an IPv6 bind of one port
   collapse. The returned arrays are `.sorted()`, ascending.
5. A worktree with no ports has no key in the result.

`Worktree.id` is `path ?? branch ?? ""` (`Worktree.swift:19`), so the key is the worktree's path
for every worktree that has one.

Write no comment inside the function body; the rule is short enough to read. A doc comment on
`attribute` naming the longest-match rule is worth keeping, since that rule is the one a future
reader would otherwise "simplify" into a bare `hasPrefix`.

**Acceptance criteria**

1. Nested worktrees: a listener whose cwd is `/r/.worktrees/a` with `/r` and `/r/.worktrees/a`
   both in the list is attributed to `/r/.worktrees/a` only.
2. A listener whose cwd is exactly a worktree path is attributed to it.
3. A listener whose cwd is `/r/clearway-old` is **not** attributed to the worktree `/r/clearway`.
4. A listener whose cwd is outside every worktree (e.g. `/opt/homebrew/var/db/redis`) produces no
   key at all.
5. Two listeners with the same cwd and the same port (the IPv4 + IPv6 case) produce one port.
6. Several ports under one worktree come back ascending regardless of input order.
7. Empty listeners, or empty worktrees, return `[:]`.
8. A worktree with `path == nil` is skipped and does not crash.
9. A listener inside a hidden nested worktree (bare-detached, not open) passed in the same list as
   its visible parent is attributed to the hidden child, and the parent gets no key.

**How the criteria are verified**

`Tests/PortAttributionTests.swift`, one `XCTestCase` with one test per criterion above, built
with `makeWorktree(branch:path:isMain:headStatus:)` from `Tests/TestHelpers.swift`. No
`ghostty_app_t`, no file system, no async. Run through `./scripts/ci.sh` — the new test file is
invisible to the build until `xcodegen generate` runs, which only `ci.sh` does. Criterion 9 of the
spec (SwiftLint clean) applies: `Tests` is linted.

### T2: `libproc` scan of listening TCP sockets and their owners' cwds

**Files touched**

- `Sources/App/PortScanner.swift` (new)

**What it does**

Adds `enum PortScanner` with one entry point:

```swift
import Darwin

enum PortScanner {
    nonisolated static func scan() -> [Listener]
}
```

and three private `static` helpers. The shape below was compiled and run in the planning
session's scratchpad with `swiftc -swift-version 6 -target arm64-apple-macos13.0` — exit 0, zero
warnings — and returned 16 listeners in 5.02 ms on this machine, with 5432 (postgres) and 6379
(redis) resolving to their real cwds. Build it this way; the byte-order and buffer-sizing details
are where this file goes wrong.

1. `allPids()` — `proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)` returns a byte count; divide by
   `MemoryLayout<pid_t>.size`, allocate, call again with the buffer and its **byte** size, then
   `prefix(written / MemoryLayout<pid_t>.size)` and drop non-positive pids. `proc_listpids` returns
   bytes written, not a count.
2. `listeningPorts(pid:)` — the same two-call sizing with `proc_pidinfo(pid, PROC_PIDLISTFDS, …)`
   over `proc_fdinfo`. For each entry where `proc_fdtype == UInt32(PROX_FDTYPE_SOCKET)`, call
   `proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size)` into a `socket_fdinfo` and
   require the return to equal `MemoryLayout<socket_fdinfo>.size`. Keep it when
   `info.psi.soi_kind == SOCKINFO_TCP && info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN`.
   The port is `UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))`
   — `insi_lport` is an `Int32` in network byte order. Collect into a `Set<UInt16>`, which already
   collapses one server's IPv4 and IPv6 sockets.
3. `currentDirectory(pid:)` — `proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)` into a
   `proc_vnodepathinfo`, require the return to equal the struct size, then read
   `info.pvi_cdir.vip_path` (a C char tuple) through
   `withUnsafeBytes { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }`.
   Return `nil` for an empty path. Call this **only** for pids that produced at least one
   listening port — it is the expensive half and the spec measured it at 0.19 ms that way.
4. `scan()` returns one `Listener` per (cwd, port). Every failed syscall is skipped silently: a
   root-owned daemon returning 0 is the normal case, not an error, so log nothing.

No `os.Logger`, no throwing, no `@MainActor`, no subprocess. `import Darwin` reaches every
constant used; no bridging-header entry is needed.

If `Listener` already exists from T1, do not redeclare it — move it here and delete it there, so
one declaration remains.

**Acceptance criteria**

1. `PortScanner.scan()` is `nonisolated static` and returns `[PortScanner.Listener]`.
2. The file declares no `@convention(c)` or `@convention(block)` closure, no `DispatchSource`, no
   `DispatchQueue`, and spawns no `Process`.
3. Ports are converted from network byte order, so a server on 8123 reports 8123, not 44063.
4. A pid whose `proc_pidinfo` returns 0 or a short read is skipped without logging or crashing.
5. `proc_pidinfo(PROC_PIDVNODEPATHINFO)` is called only for pids that matched a listening socket.
6. The file compiles under `SWIFT_VERSION: "6.0"` with zero warnings and passes
   `swiftlint lint --quiet` with zero errors.

**How the criteria are verified**

- Criteria 1, 2, 5: read the diff. Criterion 2 is a grep of the new file for `convention`,
  `DispatchSource`, `DispatchQueue` and `Process` — all must be absent.
- Criteria 3 and 4 are the reason the shape above is prescribed rather than described; the build
  agent reproduces it. XCTest cannot assert them — the function reads live kernel state and the
  spec (decision 22) rules out building an injectable seam for it. They are confirmed end to end
  by the operator's hands-on check, which is exactly criteria 1–5 of the spec's success criteria.
- Criterion 6: `./scripts/ci.sh`.

### T3: The polling monitor, wired app-wide

**Files touched**

- `Sources/App/PortMonitor.swift` (new)
- `Sources/App/ClearwayApp.swift`

**What it does**

Adds the poller and injects it.

```swift
@MainActor
final class PortMonitor: ObservableObject {
    @Published private(set) var listeners: [PortScanner.Listener] = []

    private var pollTask: Task<Void, Never>?

    init() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let scanned = await Task.detached(priority: .utility) { PortScanner.scan() }.value
                guard let self else { return }
                if scanned != self.listeners { self.listeners = scanned }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    deinit {
        pollTask?.cancel()
    }
}
```

Points that are not negotiable, each one a rule from CLAUDE.md's Concurrency section:

- The `deinit` is **not** `isolated deinit`. Leave it unannotated; a `@MainActor` class's `deinit`
  is nonisolated by default, and `isolated deinit` links a Swift 6.2 runtime symbol that fails at
  launch on a macOS 13 target.
- `[weak self]` goes on the **outer** `Task` closure and nowhere else. Do not add an inner one.
- The scan runs inside `Task.detached`, off the main actor. Do not call `PortScanner.scan()`
  directly from the main-actor loop body.
- The first scan happens before the first sleep, so ports appear at launch rather than 2 s later.
- The `scanned != self.listeners` guard is what keeps SwiftUI from re-rendering every 2 s.

In `ClearwayApp`: `@StateObject private var portMonitor = PortMonitor()` beside
`savedCommandManager` (`ClearwayApp.swift:130`), and `.environmentObject(portMonitor)` in the
`WindowGroup` beside the other four (`ClearwayApp.swift:160-163`). Nothing goes in `init()`.

**Acceptance criteria**

1. `PortMonitor` is `@MainActor final class … ObservableObject` with one `@Published
   private(set) var listeners`.
2. The poll loop cancels on `deinit` and the `deinit` is nonisolated (unannotated).
3. No `DispatchSource`, `DispatchWorkItem`, `ScheduledWork`, `Timer` or `@convention` literal
   appears in the file.
4. Every window in the process shares one monitor — the `@StateObject` is on `ClearwayApp`, not on
   `ProjectContentView`.
5. Reassigning `listeners` is skipped when the scan is unchanged.
6. `./scripts/ci.sh` is green.

**How the criteria are verified**

- Criteria 1–5: read the diff, and grep the new file for `DispatchSource`, `DispatchWorkItem`,
  `ScheduledWork`, `Timer`, `convention` and `isolated deinit` — all absent. Criterion 4 is
  checked by confirming the `@StateObject` line is in `ClearwayApp.swift` and that
  `ProjectWindow.swift` is untouched.
- Criterion 6: `./scripts/ci.sh`. There is no unit test here; a 2-second poll over live kernel
  state has nothing XCTest can assert without inventing a seam the spec rejected. The behaviour is
  covered by the operator's hands-on check (spec success criteria 1 and 2: a server appears within
  5 s and disappears within 5 s).

### T4: Port badges on the sidebar rows

**Superseded.** This task shipped a per-port capsule on each sidebar row, then a single `globe`
button after the first hands-on change. The operator retired the sidebar surface entirely during a
later hands-on check: `WorktreeRow` and `SidebarView` are back to their content at base, and the
detail status bar is the only rendering. See the Changelog entries of 2026-09-18 and the build log
below. Do not reinstate a sidebar badge. The original task follows unedited.

**Files touched**

- `Sources/App/WorktreeRow.swift`
- `Sources/App/SidebarView.swift`

**What it does**

`WorktreeRow` gains `var ports: [UInt16] = []`, defaulted so the one call site is the only change
needed. In `body`'s outer `HStack`, immediately after the `if worktree.isMain { PrimaryBadge() }
else if let status { StatusBadge(...) }` block and before the `Spacer()`
(`WorktreeRow.swift:31-36`):

```swift
if !ports.isEmpty {
    PortBadge(ports: ports)
}
```

`PortBadge` is a new `private struct` in the same file, beside `PrimaryBadge` and `StatusBadge`. It
draws one `globe` for the whole worktree and uses no `rowBadge(_:)` capsule:

```swift
private struct PortBadge: View {
    let ports: [UInt16]

    var body: some View {
        Button {
            guard let port = ports.min(), let url = URL(string: "http://localhost:\(port)") else { return }
            NSWorkspace.shared.open(url)
        } label: {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(ports.sorted().map { "localhost:\($0)" }.joined(separator: ", "))
    }
}
```

`import SwiftUI` re-exports AppKit on macOS, so `NSWorkspace` needs no extra import — the same as
`ContentViewHelpers.swift`. The `guard let url` form replaces a force unwrap, per spec decision 20.

In `SidebarView`: add `@EnvironmentObject private var portMonitor: PortMonitor` to the existing
block (`SidebarView.swift:13-19`), and a computed property

```swift
private var portsByWorktree: [String: [UInt16]] {
    PortAttribution.attribute(portMonitor.listeners, to: worktreeManager.worktrees)
}
```

`worktreeManager.worktrees` is the full tracked list, not `sortedWorktrees` — a port inside a
hidden nested worktree must attribute to that hidden worktree and go unrendered, never to its
visible parent (spec 13). Rendering is unaffected: `worktreeRowView` (`SidebarView.swift:483-511`)
still runs over `sortedWorktrees` and passes `ports: portsByWorktree[wt.id] ?? []` to
`WorktreeRow`, so a hidden worktree's ports reach no row.

**Acceptance criteria**

1. A worktree with one or more live ports renders exactly one globe, after the primary/status badge
   and before the working/notification dot.
2. A worktree with no live ports renders no globe and no extra spacing.
3. Clicking the globe opens `http://localhost:<lowest live port>` in the default browser.
4. Clicking the globe does **not** change the sidebar selection, and the row still drags.
5. Hovering the globe shows `localhost:8123`, or `localhost:8123, localhost:8124` with two servers
   live in that worktree.
6. At a narrow sidebar width the row name truncates and the globe stays whole.
7. `WorktreeRow` keeps exactly one construction site and the new parameter is defaulted.
8. `./scripts/ci.sh` is green and `swiftlint lint --quiet` reports zero errors.

**How the criteria are verified**

- Criteria 1–6 are user-visible and XCTest cannot reach them; CLAUDE.md's pipeline memory is
  explicit that build agents do not launch the app. They go to the operator's hands-on check with
  `python3 -m http.server 8123` and `8124` running in two worktrees. Criterion 4 is the one the
  spec (decision 18) singles out as the risk: if the plain `Button` swallows the row's click or
  drag, the fallback is `.onTapGesture` plus `.contentShape(Rectangle())` on the badge, the shape
  `prStatusView` already uses (`ContentViewHelpers.swift:123-126`). Report which one shipped.
- Criterion 7: read the diff — `SidebarView.worktreeRowView` is the only caller
  (`SidebarView.swift:483`).
- Criterion 8: `./scripts/ci.sh`. `WorktreeRow.swift` is 111 lines and `SidebarView.swift` is 653;
  both stay under the 700-line warning after roughly 25 added lines.

### T5: The selected worktree's ports in the detail status bar

**Superseded.** This task shipped as a `network` toolbar button whose `.popover` listed every live
port grouped by worktree, in a new `Sources/App/LivePortsMenu.swift`. The operator retired that
surface during the hands-on check: the second surface is now the detail pane's status bar, and
`LivePortsMenu.swift` is deleted. See the Changelog entry of 2026-09-18 and the build log below.
Do not reinstate the toolbar item.

**Files touched**

- `Sources/App/ContentViewHelpers.swift`
- `Sources/App/ContentView.swift`

**What it does**

`WorktreeStatusBar` gains `@EnvironmentObject private var portMonitor: PortMonitor` beside the
`worktreeManager` it already holds, a private `livePorts` computed property, and a `livePortsView`
rendered after the `Spacer()` and before the PR info:

```swift
private var livePorts: [UInt16] {
    guard let worktree else { return [] }
    return PortAttribution.attribute(portMonitor.listeners, to: worktreeManager.worktrees)[worktree.id] ?? []
}
```

Attributing against `worktreeManager.worktrees`, the full tracked list, while rendering only the
selected worktree is spec decision 13: a hidden child's ports stay on the hidden child and never
climb to its visible parent.

`livePortsView` is an `HStack(spacing: 8)` over `livePorts` — already ascending and deduped by
`PortAttribution` — each port a `Text(String(port))` in the bar's `.system(size: 11, design:
.monospaced)` `.secondary` style with `.contentShape(Rectangle())`, `pointerCursorOnHover()`, an
`.onTapGesture` opening `http://localhost:<port>` through the guarded `NSWorkspace.shared.open`
form, and `.help("http://localhost:\(port)")`. An empty `livePorts` renders an empty `HStack`,
which is zero-width, so the bar reads exactly as it did before this change. The bar's outer
`HStack` goes from `spacing: 0` to `spacing: 12` to separate the ports from the PR info; the
`Spacer()` absorbs it, so nothing else moves.

In `ContentView.detailView.toolbar`, the `ToolbarItem` holding `LivePortsMenu` and the
`ToolbarGroupBreak()` after it are deleted, and `Sources/App/LivePortsMenu.swift` with them.
`./scripts/ci.sh` must run so `xcodegen generate` drops the file from the project.

**Acceptance criteria**

1. With the selected worktree's server up, its port number appears on the right of the status bar,
   immediately before the PR info.
2. Two servers in that worktree show both numbers, ascending; an IPv4+IPv6 pair on one port shows
   one number.
3. Clicking a number opens `http://localhost:<port>` in the default browser.
4. Hovering a number shows `http://localhost:<port>`.
5. With no live ports in the selected worktree, nothing renders between the path and the PR info.
6. There is no Live Ports toolbar button, and `Sources/App/LivePortsMenu.swift` does not exist.
7. `./scripts/ci.sh` is green and `swiftlint lint --quiet` reports zero errors.

**How the criteria are verified**

- Criteria 1–5 are pixels and browser launching, which XCTest cannot reach; they go to the
  operator's hands-on check with `python3 -m http.server` in the selected worktree and then with
  none running. The attribution behind them is `PortAttribution.attribute`, already pinned by
  `Tests/PortAttributionTests.swift`.
- Criterion 6: `grep -rn "LivePortsMenu" Sources/ Tests/` returns nothing.
- Criterion 7: `./scripts/ci.sh`.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| A plain `Button` inside the selectable `List` row steals the row's selection or drag | Medium — it is the only unverifiable-from-tests behaviour in the change | Spec decision 18 names the fallback: `.onTapGesture` + `.contentShape(Rectangle())`, the shape `prStatusView` uses. T4's hands-on check decides, and the build agent reports which shipped. |
| `PortScanner` is wrong in a way nothing catches until the operator looks | Medium | T2 prescribes the exact call sequence, buffer sizing and byte-order conversion from a probe that compiled clean and returned correct ports on this machine. Criterion 3 (byte order) is the failure mode that would otherwise look like plausible garbage. |
| `@Published` fires every 2 s and re-renders the sidebar continuously | Low | `Listener` is `Equatable` and T3 skips the assignment when the scan is unchanged. |
| A machine with hundreds of processes makes the scan slower than measured | Low | Measured at 5.02 ms on this machine at planning time, against a 2 s period. The scan runs on `Task.detached(priority: .utility)`, so it never blocks the main actor whatever it costs. |

## Out of scope

Everything the spec's "Out of scope" section lists: controlling a server, copying a URL, choosing
a browser, any Settings toggle, UDP, remote hosts, naming the process behind a port, HTTP probing,
ports outside the open project's worktrees, changing `Worktree.visible`, splitting
`ContentView.swift`, and the `WorktreeGroupStore.openFileWatcher` fd leak.

## Changelog

- **2026-09-18, during T1 — attribution runs over all tracked worktrees.** Operator decision taken
  after the plan was written. Attribution's input is `worktreeManager.worktrees`, the full tracked
  list, not the visible one: a listener inside a hidden nested worktree attributes to that hidden
  worktree and is simply not rendered, never to its visible parent. Spec decision 13 was amended to
  match and now reads "Operator" as its source. In this plan it changed architecture decision 8,
  T4's `portsByWorktree` (from `sortedWorktrees` to `worktreeManager.worktrees`, and the paragraph
  that described the old consequence), T5's `LivePortsMenu` signature (a second
  `trackedWorktrees` parameter, attributed against, while `worktrees` stays the rendered order),
  and T1's acceptance criteria (a ninth, pinning the hidden-child case). T3 is unaffected.
- **2026-09-18, after T5 — the sidebar row shows one globe, not a badge per port.** Operator
  decision taken during the hands-on check of the five committed tasks. `WorktreeRow` draws a
  single SF Symbol `globe` when the worktree has at least one live port and nothing when it has
  none; the port numbers move into the globe's tooltip (`localhost:8123`, or
  `localhost:8123, localhost:8124` for several, ascending), and clicking it opens the lowest live
  port. The toolbar popover is unchanged and stays the place to pick among several ports. Spec
  decisions 2, 4, 11, 17, 18, 19 and 20, its opening paragraph, success criteria 1 and 5–7 and its
  files table were amended to match, and decision 17's source is now "Operator". In this plan it
  changed architecture decisions 6 and 11–13 and T4's implementation sketch and acceptance
  criteria 1–6. T1, T2, T3 and T5 are unaffected.
- **2026-09-18, after T5 — the second surface is the detail status bar, not a toolbar popover.**
  Operator decision taken during the hands-on check. `WorktreeStatusBar` now lists the selected
  worktree's live ports on its right, immediately before the PR info: bare ascending numbers, each
  clickable to open `http://localhost:<port>` in the default browser and tooltipped with that URL,
  and nothing at all when the worktree has no ports. The Live Ports toolbar item is removed from
  `ContentView` and `Sources/App/LivePortsMenu.swift` is deleted; the sidebar globe is unchanged.
  Spec decisions 2, 4, 11, 13–17, 20 and 23, its opening paragraph, assumptions 6, 7 and 9,
  success criteria 1 and 5–7 and its files table were amended to match, and decisions 14–16 now
  read "Operator". In this plan it changed architecture decisions 9, 10, 13 and 16, the dependency
  graph, the whole of T5 (superseded in place, with the new surface's sketch and criteria) and the
  popover risk row, which is dropped. T1–T4 are unaffected.

- **2026-09-18, after T5 — the status-bar tooltip's port lost its grouping separator.** Operator
  bug report from the hands-on check: the tooltip read `http://localhost:3,000`. `.help` and `Text`
  take a `LocalizedStringKey`, so a `UInt16` interpolated into the string *literal*
  `"http://localhost:\(port)"` is formatted for the locale. The fix is one pure helper,
  `Sources/App/PortLink.swift` — `label(_:)`, `urlString(_:)`, `url(_:)`, each built with
  `String(port)` and passed to the view as a `String` expression, which binds the verbatim
  overloads. `Tests/PortLinkTests.swift` pins the text for port 3000 and for the range's bounds.
  Spec decisions 19 and 20 were rewritten and a new decision 25 added; success criteria 6 and 8
  were amended. In this plan it changed architecture decisions 13 and 15 and added this entry and
  its build-log section. No other surface was affected: the audit found the defect only in that one
  `.help`, since the label was already `String(port)` and the `URL(string:)` call already took a
  plain-`String` interpolation.
- **2026-09-18, after T5 — the sidebar globe is removed; the status bar is the only rendering.**
  Operator decision from the same hands-on check. `WorktreeRow` loses its `PortBadge`, its
  `ports: [UInt16]` parameter and nothing else; `SidebarView` loses `@EnvironmentObject portMonitor`,
  `portsByWorktree` and the row's `ports:` argument. Both files are back to their content at base.
  `PortAttribution`, `PortScanner`, `PortMonitor` and `ClearwayApp`'s wiring are untouched — the
  status bar still uses all four. Spec decisions 2, 4, 11, 13, 17–20, the opening paragraph,
  assumption 5, success criteria 1, 2 and 5–8 and the files table were amended to match, and
  decisions 17–20 now read "Operator". In this plan it changed architecture decisions 8 and 11–13
  and superseded T4 in place. T1, T2, T3 and T5 are unaffected.
- **2026-09-18, after the simplify pass — three review findings applied in one commit.** (F1) The
  status bar's outer `HStack` had gone `spacing: 0` → `12` while `livePortsView` stayed a plain
  computed property, so a portless worktree rendered a zero-width subview that still drew 12 pt on
  each side and cost the middle-truncated path about five characters against base `7ae81c1`. The
  stack is back to `spacing: 0` and `livePortsView` is `@ViewBuilder` again — the `@ViewBuilder` the
  simplify pass removed — wrapping its `HStack` in `if !ports.isEmpty` and carrying the gap before
  the PR info as its own `.padding(.trailing, 12)`. A portless worktree is therefore byte-identical
  to base in layout terms. (F2) `PortScanner.scan()` now returns its array sorted by `(cwd, port)`;
  `proc_listpids` orders by pid, so `PortMonitor`'s `scanned != listeners` check republished
  whenever an unattributed listener anywhere on the machine started or ended. Spec decision 9 holds
  — the records stay raw and attribution stays out of the monitor. (F3) The doc comment on
  `livePorts` restated `PortAttribution.attribute`'s and is gone. No spec decision changed.

## Build log

### T1: Pure port-to-worktree attribution, with its test suite

| File | State |
| --- | --- |
| `Sources/App/PortAttribution.swift` | New. `enum PortScanner` with the nested `Listener` record (moves to T2's file when it lands), and `PortAttribution.attribute` — the longest-match rule, deduped into a `Set<UInt16>`, returned ascending. |
| `Tests/PortAttributionTests.swift` | New. Ten tests, one per acceptance criterion plus the two empty-input cases. |
| `docs/superpowers/specs/2026-09-18-active-port-indicator.md` | Decision 13 amended (see Changelog). Committed here for the first time. |
| `docs/superpowers/plans/2026-09-18-active-port-indicator.md` | Architecture decision 8, T1 criterion 9, T4 and T5 amended; this Changelog and Build log added. Committed here for the first time. |

**Evidence.** The suite was first run against a deliberately naive `attribute` — a bare
`hasPrefix` sweep with no longest-match, no `+ "/"` boundary and no sort — and `./scripts/ci.sh`
reported four failures, one per load-bearing rule:

```
Test Suite 'PortAttributionTests' started at 2026-09-18 17:07:40.734.
    ✖ testHiddenNestedWorktreeKeepsItsOwnPortsRatherThanItsParent, XCTAssertNil failed: "[8123]"
    ✖ testNestedWorktreesAttributeToTheLongestMatch, XCTAssertEqual failed: ("["/r/.worktrees/a": [8123], "/r": [8123]]") is not equal to ("["/r/.worktrees/a": [8123]]")
    ✖ testPortsUnderOneWorktreeComeBackAscending, XCTAssertEqual failed: ("["/r": [9000, 3000, 8080]]") is not equal to ("["/r": [3000, 8080, 9000]]")
    ✖ testSiblingSharingAPathPrefixIsNotMatched, XCTAssertEqual failed: ("["/r/clearway": [8080]]") is not equal to ("[:]")
Executed 10 tests, with 4 failures (0 unexpected) in 0.100 (0.102) seconds
Executed 467 tests, with 4 failures (0 unexpected) in 59.865 (60.058) seconds
```

The naive version was then replaced with the rule the plan prescribes and the four went green.

**Deviations from the plan.** One, and it is the operator decision recorded in the Changelog:
attribution takes the full tracked worktree list rather than the visible one, and the suite gained
a test pinning the hidden-child case. The function's signature is unchanged — it already took
`[Worktree]` — so only its doc comment and its callers in T4/T5 carry the difference.

**Gate.** `./scripts/ci.sh` — `Executed 467 tests, with 0 failures (0 unexpected) in 61.901
seconds`, `==> CI passed.`, exit 0. `swiftlint lint --quiet` runs inside it and reported nothing.

### T2: `libproc` scan of listening TCP sockets and their owners' cwds

| File | State |
| --- | --- |
| `Sources/App/PortScanner.swift` | New. `enum PortScanner` with the `Listener` record moved here from T1's file, `nonisolated static func scan()`, and the three private helpers: `allPids`, `listeningPorts(pid:)`, `currentDirectory(pid:)`. Exactly the call sequence, two-call buffer sizing and `UInt16(bigEndian:)` conversion the plan prescribes. |
| `Sources/App/PortAttribution.swift` | The temporary `enum PortScanner { struct Listener … }` stub T1 carried is deleted; one declaration of `Listener` now exists, in `PortScanner.swift`. |

**Evidence.** `PortScanner` has no automated test (spec decision 22), so the scan was verified
against a server started for the purpose. `python3 -m http.server 8123` was run in
`<scratchpad>/serverdir`, and the scanner — the repository file itself, compiled with
`swiftc -swift-version 6 -target arm64-apple-macos13.0` (exit 0, zero warnings) against a
throwaway `main.swift` in the scratchpad, nothing written into the repo — printed:

```
scan: 17 listeners in 3.60 ms
  5432  /opt/homebrew/var/postgresql@18
  6379  /opt/homebrew/var/db/redis
  8123  /private/tmp/claude-501/.../scratchpad/serverdir
```

8123 with the server's own working directory is criteria 3 and the cwd lookup together: the port
reads as 8123, not the byte-swapped 44063, and 5432/6379 likewise land on their real decimal ports
and their daemons' cwds. `pkill`ing the server and re-running printed no 8123 line (`grep -c 8123`
→ 0), so a socket that goes away leaves the scan. The 17 listeners include pids whose
`PROC_PIDVNODEPATHINFO` answered `/` and root-owned ones that answered nothing at all; neither
logged nor crashed, which is criterion 4.

Criteria 1, 2 and 5 are read off the file: `scan()` is `nonisolated static` returning
`[Listener]`; `grep -nE "convention|DispatchSource|DispatchQueue|Process|Logger|@MainActor"
Sources/App/PortScanner.swift` returns nothing; and `currentDirectory(pid:)` is called inside the
`flatMap` only after `guard !ports.isEmpty`.

**Deviations from the plan.** None.

**Gate.** `./scripts/ci.sh` — `Executed 467 tests, with 0 failures (0 unexpected) in 60.160`,
`==> CI passed.`, exit 0. SwiftLint runs inside it and reported nothing for the new file.

One intermediate run of the gate failed on `ShellPathResolverTests`:

```
✖ testTheResolvedValueIsTheSanitizedOne, XCTAssertEqual failed: ("degraded("/usr/bin:/bin")") is not equal to ("full("/usr/bin:/bin")")
```

It is a pre-existing flake under machine load, not this change: the test spawns a real shell with
a 0.5 s timeout (`ShellPathResolverTests.swift:11`), and when the `-ilc` attempt misses that
deadline the `-lc` fallback returns the same path classified `.degraded`
(`ShellPathResolver.swift:57`). Nothing in T2 runs a `Process` or touches PATH. The run before it
and the run after it were both green.

### T3: The polling monitor, wired app-wide

| File | State |
| --- | --- |
| `Sources/App/PortMonitor.swift` | New. `@MainActor final class PortMonitor: ObservableObject` with `@Published private(set) var listeners: [PortScanner.Listener]`, a `private var pollTask: Task<Void, Never>?` started in `init`, and an unannotated `deinit` that cancels it. Exactly the shape the plan prescribes. |
| `Sources/App/ClearwayApp.swift` | `@StateObject private var portMonitor = PortMonitor()` beside `savedCommandManager`, and `.environmentObject(portMonitor)` on the project `WindowGroup` beside the other four. Two lines; `init()` untouched. |

**Evidence.** There is no unit test here — the plan (T3, "How the criteria are verified") rules one
out, so there is no watched failure to quote. Criteria 1–5 are read off the diff:

- 1: the declaration is `@MainActor final class PortMonitor: ObservableObject` with the single
  `@Published private(set) var listeners`.
- 2: `deinit { pollTask?.cancel() }`, unannotated — not `isolated deinit`, so no
  `_swift_task_deinitOnExecutor` reference on a macOS 13 target.
- 3: `grep -nE "DispatchSource|DispatchWorkItem|ScheduledWork|Timer|convention|isolated deinit"
  Sources/App/PortMonitor.swift` returns nothing (exit 1). The file forms no `@convention(block)`
  or `@convention(c)` literal at all, so the trap that cost v1.9.3 a crash cannot apply.
- 4: the `@StateObject` is on `ClearwayApp`; `git status --porcelain` shows `ProjectWindow.swift`
  untouched, so one monitor serves every window.
- 5: the loop assigns only under `if scanned != listeners`, so an unchanged scan publishes nothing
  and SwiftUI is not invalidated every 2 s.

`[weak self]` is on the outer `Task` closure and nowhere else; the scan runs inside
`Task.detached(priority: .utility)` rather than on the main actor; and the first scan precedes the
first `Task.sleep`, so ports are present at launch rather than 2 s later.

**Deviations from the plan.** One, cosmetic: the plan's snippet writes `self.listeners` inside the
`guard let self else` body. The explicit `self.` is unnecessary after the unwrap and the code reads
`if scanned != listeners { listeners = scanned }`. `import Foundation` is enough for
`ObservableObject` and `@Published` here, as in `ClaudeActivityMonitor.swift:1`.

**Gate.** `./scripts/ci.sh` — `Executed 467 tests, with 0 failures (0 unexpected) in 59.587
seconds`, final line `==> CI passed.` (reachable only on success under the script's `set -euo
pipefail`), exit 0. SwiftLint runs inside it and reported nothing.

The run before it failed two `ShellPathResolverTests` cases —
`testTheResolvedValueIsTheSanitizedOne` and `testExtraLinesAroundThePathDoNotBreakResolution`,
both `degraded(…)` where `full(…)` was expected. This is the pre-existing 0.5 s fake-shell timeout
flake already recorded under T2, now seen on a second case of the same class. Both were run three
times in isolation immediately afterwards and passed 3/3 (`Executed 2 tests, with 0 failures` each
time), and the next full gate was green. Nothing in T3 spawns a `Process` or touches PATH; the
2 s poll costs ~3 ms of a utility-priority thread.

### T4: Port badges on the sidebar rows

**What landed.**

| File | State |
| --- | --- |
| `Sources/App/WorktreeRow.swift` | Gains `var ports: [UInt16] = []`, a `ForEach(ports, id: \.self)` of `PortBadge` between the primary/status badge and the `Spacer()`, and a new `private struct PortBadge` beside `PrimaryBadge`/`StatusBadge` reusing `rowBadge(.quaternary)`. 130 lines. |
| `Sources/App/SidebarView.swift` | `@EnvironmentObject private var portMonitor: PortMonitor`, a `portsByWorktree` computed property, and `ports: portsByWorktree[wt.id] ?? []` on the single `WorktreeRow(...)` construction. 660 lines. |

**Evidence.** No test was written and none was watched fail. T4 adds no decision rule: the whole of
the attribution logic is `PortAttribution.attribute`, already pinned by `Tests/PortAttributionTests.swift`
under T1, and what T4 adds on top is a SwiftUI view parameter and one call into that function.
Criteria 1–6 are pixels, click routing, drag routing and tooltips, which XCTest cannot reach — the
plan routes them to the operator's hands-on check, and CLAUDE.md's pipeline memory forbids a build
agent launching the app. Criterion 7 is read off the diff: `SidebarView.worktreeRowView` is still
the only `WorktreeRow(` construction site in `Sources/` (`grep -rn "WorktreeRow(" Sources/`), and
the new parameter is defaulted.

The plain `Button` shipped, not the `.onTapGesture` + `.contentShape(Rectangle())` fallback that
spec decision 18 holds in reserve. Whether it steals the row's selection or drag is exactly what
the operator's check decides; if it does, the fallback is a one-view change confined to `PortBadge`.

`portsByWorktree` is a computed property, per the plan, so the attribution runs once per rendered
row rather than once per sidebar body. At the sizes involved — a handful of worktrees against the
listeners on one machine — that is a few hundred string comparisons per render, and hoisting it
would mean threading a dictionary through three `worktreeRowView` call sites in different branches
of the list.

**Deviations from the plan.** None.

**Gate.** `./scripts/ci.sh` — `Executed 467 tests, with 0 failures (0 unexpected) in 57.478
seconds`, final line `==> CI passed.`, which the script's `set -euo pipefail` only reaches on
success. `swiftlint lint --quiet` afterwards printed nothing: zero errors, zero warnings.
`git status --porcelain` showed only the two modified sources — no `default.profraw`, since the app
was never launched.

### T5: The toolbar button and its live-ports popover

**What landed.**

| File | State |
| --- | --- |
| `Sources/App/LivePortsMenu.swift` | New, 57 lines. The `network` button with `.help("Live ports")`, `.disabled(groups.isEmpty)`, and a `.popover(isPresented:arrowEdge: .bottom)` whose `VStack` renders one `.caption`/`.secondary` worktree header per group with its ports below as `.link` buttons. `groups` attributes `portMonitor.listeners` against `trackedWorktrees` and walks `worktrees` to keep sidebar order, dropping those with no ports. |
| `Sources/App/ContentView.swift` | Four lines: a `ToolbarItem(placement: .primaryAction)` holding `LivePortsMenu(worktrees: sortedWorktrees, trackedWorktrees: worktreeManager.worktrees)` and a `ToolbarGroupBreak()`, between the `OpenInMenu` block and the archive item. 1032 lines. |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated by `xcodegen` for the new source file, as in T1–T3. |

**Evidence.** No test was written and none was watched fail. T5 adds no decision rule: the
attribution is `PortAttribution.attribute`, already pinned by `Tests/PortAttributionTests.swift`
under T1, and what T5 adds on top is one `compactMap` preserving the caller's order plus a SwiftUI
view. Criteria 1–6 are pixels, popover presentation and browser launching, which XCTest cannot
reach — the plan routes them to the operator's hands-on check, and CLAUDE.md's pipeline memory
forbids a build agent launching the app.

Criterion 6 is read off the file: the button's only action is `isPresented = true` and it is
`.disabled(groups.isEmpty)`, so no path opens the popover with nothing in it. Criterion 7 is read
off the diff: `git diff --stat Sources/App/ContentView.swift` reports `4 ++++`, against a budget of
eight, and the added lines contain no logic — `sortedWorktrees` and `worktreeManager.worktrees`
both already existed for the sidebar.

**Deviations from the plan.** Two, both cosmetic.

- The plan says "pick the number by eye and leave it as the only magic number in the file". The
  `minWidth` is a named `private let popoverMinWidth: Double = 160` at file scope, matching
  `ContentView.swift:5-11`'s form for the same kind of constant, rather than an inline literal.
- Each port is a `Button(String(port))` with `.buttonStyle(.link)` and `.monospacedDigit()`. The
  plan named neither style; `.link` is what makes a row read as openable inside a popover, where
  the default bordered button would render as a stack of full-width controls.

**Gate.** `./scripts/ci.sh` — `Executed 467 tests, with 0 failures (0 unexpected) in 60.136
seconds`, `Test Succeeded`, final line `==> CI passed.`, which the script's `set -euo pipefail`
only reaches on success. `swiftlint lint --quiet` run afterwards printed nothing and exited 0.
`git status --porcelain` showed only `Clearway.xcodeproj/project.pbxproj`, `Sources/App/ContentView.swift`
and the untracked `Sources/App/LivePortsMenu.swift` — no `default.profraw`, since the app was never
launched.

### Hands-on change: one globe per row in place of the per-port badges

**What landed.**

| File | State |
| --- | --- |
| `Sources/App/WorktreeRow.swift` | `PortBadge` now takes `ports: [UInt16]` and draws one `Image(systemName: "globe")` in `.secondary` instead of a capsule per port; its `.help` is the ports as `localhost:<port>`, ascending, comma-separated; its action opens `ports.min()`. The row renders it under `if !ports.isEmpty`. 127 lines. |
| `docs/superpowers/specs/2026-09-18-active-port-indicator.md` | Decisions 2, 4, 11, 17, 18, 19, 20, the opening paragraph, success criteria 1 and 5–7 and the files table amended; decision 17 now reads "Operator". |
| `docs/superpowers/plans/2026-09-18-active-port-indicator.md` | Architecture decisions 6 and 11–13, T4's sketch and acceptance criteria 1–6, this Changelog entry and this section. |

Untouched: `SidebarView` (it still passes `portsByWorktree[wt.id] ?? []`, unchanged),
`PortAttribution`, `PortScanner`, `PortMonitor`, `LivePortsMenu`, `ContentView`, and
`Clearway.xcodeproj/project.pbxproj` — no file was added or removed.

**Evidence.** No test was written and none was watched fail. The change is display-only: it removes
no decision rule and adds none that XCTest can reach. The ports reaching the row are still
`PortAttribution.attribute`'s output, deduped and ascending, pinned by
`Tests/PortAttributionTests.swift` under T1; what is new is which glyph the row draws, the tooltip
string and `ports.min()`, all inside a SwiftUI `View` with no seam short of launching the app. T4's
criteria 1–6 were already routed to the operator's hands-on check for that reason, and CLAUDE.md's
pipeline memory forbids a build agent launching the app.

**Deviations from the operator's request.** None. `ports.min()` rather than `ports.first` for the
click, and `ports.sorted()` in the tooltip, restate the ascending contract locally rather than
lean on `PortAttribution` sorting its output — one line each, and they make "lowest" readable at
the call site.

**Gate.** `./scripts/ci.sh` — `Executed 467 tests, with 0 failures (0 unexpected) in 57.241
seconds`, `Test Succeeded`, final line `==> CI passed.`, which the script's `set -euo pipefail`
only reaches on success. The run before it failed one test,
`ShellPathResolverTests/testAHealthyShellGivesFullFromOneInteractiveAttempt` —
`XCTAssertEqual failed: ("degraded("/opt/homebrew/bin:/usr/bin:/bin")") is not equal to
("full("/opt/homebrew/bin:/usr/bin:/bin")")` — the known pre-existing 0.5 s fake-shell timing
flake, unrelated to this change and green on the rerun. `swiftlint lint --quiet` printed nothing
and exited 0. `git status --porcelain` showed only the three modified files below — no
`default.profraw`, since the app was never launched.

### Hands-on change: the live ports move from the toolbar popover to the detail status bar

**What landed.**

| File | State |
| --- | --- |
| `Sources/App/ContentViewHelpers.swift` | `WorktreeStatusBar` gains `@EnvironmentObject private var portMonitor`, a private `livePorts` attributing `portMonitor.listeners` against `worktreeManager.worktrees` and keying out the selected worktree, and a `livePortsView` of clickable, `.help`-tooltipped monospaced port numbers rendered after the `Spacer()` and before the PR info. The outer `HStack` goes from `spacing: 0` to `spacing: 12`. 215 lines. |
| `Sources/App/ContentView.swift` | The `ToolbarItem` holding `LivePortsMenu` and the `ToolbarGroupBreak()` after it are deleted — four lines. 1028 lines, back to its pre-T5 length. |
| `Sources/App/LivePortsMenu.swift` | Deleted. |
| `Clearway.xcodeproj/project.pbxproj` | `xcodegen generate`, run by `./scripts/ci.sh`, dropped the deleted file's two entries. |
| `docs/superpowers/specs/2026-09-18-active-port-indicator.md` | Decisions 2, 4, 11, 13–17, 20 and 23, the opening paragraph, assumptions 6, 7 and 9, success criteria 1 and 5–7 and the files table amended; decisions 14–16 now read "Operator". |
| `docs/superpowers/plans/2026-09-18-active-port-indicator.md` | Architecture decisions 9, 10, 13 and 16, the dependency graph, T5 superseded in place, the popover risk row dropped, this Changelog entry and this section. |

Untouched: `PortAttribution`, `PortScanner`, `PortMonitor`, `ClearwayApp`, `WorktreeRow` and
`SidebarView` — the sidebar globe is unchanged, as the operator asked.

**Evidence.** No test was written and none was watched fail. The change is display-only: it moves
one surface and removes another, and adds no decision rule XCTest can reach. The ports reaching the
status bar are `PortAttribution.attribute`'s output, deduped and ascending, already pinned by
`Tests/PortAttributionTests.swift` under T1; what is new is where they render and which tap target
opens them, all inside a SwiftUI `View` with no seam short of launching the app, which CLAUDE.md's
pipeline memory forbids a build agent. T5's superseding criteria 1–5 are routed to the operator's
hands-on check for that reason; criterion 6 is mechanical — `grep -rn "LivePortsMenu" Sources/
Tests/` returns nothing.

**Deviations from the operator's request.** None. Two mechanical choices the request left open:
the ports render in an `HStack` that is simply empty when there are none, rather than behind an
`if`, so `livePorts` is computed once per body rather than twice; and the outer `HStack`'s spacing
carries the separation from the PR info rather than a conditional `.padding(.trailing,)`, since
the `Spacer()` absorbs it and nothing else moves.

**Gate.** `./scripts/ci.sh` — `Executed 467 tests, with 0 failures (0 unexpected) in 58.835
seconds`, `Test Succeeded`, final line `==> CI passed.`. The run before it failed two tests in
`ShellPathResolverTests` (`testATrailingPathShapedLineIsNotMistakenForThePath`,
`testExtraLinesAroundThePathDoNotBreakResolution`) with
`XCTAssertEqual failed: ("degraded("/opt/homebrew/bin:/usr/bin:/bin")") is not equal to
("full("/opt/homebrew/bin:/usr/bin:/bin")")` — the known pre-existing 0.5 s fake-shell timing
flake, unrelated to this change and green on the rerun. `swiftlint lint --quiet` printed nothing
and exited 0. `git status --porcelain` showed only the six files above — no `default.profraw`,
since the app was never launched.

### Hands-on change: the tooltip's port loses its grouping separator

**What landed.**

| File | State |
| --- | --- |
| `Sources/App/PortLink.swift` | New, 22 lines. `enum PortLink` with `label(_:)` = `String(port)`, `urlString(_:)` = `"http://localhost:" + String(port)` and `url(_:)` = `URL(string: urlString(port))`. Its doc comment records why: a port interpolated into a string *literal* binds `Text`'s and `.help`'s `LocalizedStringKey` overload, which locale-formats the integer. |
| `Sources/App/ContentViewHelpers.swift` | `livePortsView` now reads `Text(PortLink.label(port))`, `if let url = PortLink.url(port)` and `.help(PortLink.urlString(port))`. Each takes a `String` expression, which binds the verbatim overloads. 215 lines. |
| `Tests/PortLinkTests.swift` | New, 24 lines. Pins the URL string, the label and `url(_:)?.absoluteString` for port 3000, plus 1, 8080 and 65535. |
| `Clearway.xcodeproj/project.pbxproj` | `xcodegen generate`, run by `./scripts/ci.sh`, added the two new files. |

**The audit.** `grep -rn "localhost" Sources/ Tests/` found four sites before the change: two in
`ContentViewHelpers.swift` and two in `WorktreeRow.swift`'s `PortBadge`, which the next section
deletes outright. Of the four, exactly one was defective — `.help("http://localhost:\(port)")`.
The status-bar label was already `Text(String(port))` and the `URL(string:)` call already took a
plain-`String` interpolation, both of which are verbatim; `PortBadge`'s `.help` took a `String`
expression built by `map`/`joined`, which binds `help<S: StringProtocol>`. After the change no port
is interpolated into a string literal anywhere in `Sources/`.

**Evidence.** `Tests/PortLinkTests.swift` was watched fail against the defect. With `urlString`
temporarily returning `String(localized: "http://localhost:\(port)")` — the same
`LocalizationValue` interpolation `LocalizedStringKey` uses — `xcodebuild … test
-only-testing:ClearwayTests/PortLinkTests` reported `Executed 4 tests, with 4 failures`:

```
Tests/PortLinkTests.swift:8: error: -[ClearwayTests.PortLinkTests testTheURLStringCarriesNoGroupingSeparator] : XCTAssertEqual failed: ("http://localhost:3,000") is not equal to ("http://localhost:3000")
Tests/PortLinkTests.swift:21: error: -[ClearwayTests.PortLinkTests testEveryPortBoundRoundTrips] : XCTAssertEqual failed: ("http://localhost:8,080") is not equal to ("http://localhost:8080")
Tests/PortLinkTests.swift:16: error: -[ClearwayTests.PortLinkTests testTheURLParsesToTheSameText] : XCTAssertEqual failed: ("nil") is not equal to ("Optional("http://localhost:3000")")
```

The third line is worth keeping: a comma makes the string unparseable as a `URL`, so the same
defect on the click path would have opened nothing at all. It was not on the click path — that call
site interpolated into a plain `String` — but it is now one `PortLink.url` call away from any
future one. The fix restored, all four pass.

**Deviations from the operator's request.** None. The operator asked for the URL string to be built
with `String(port)` and lifted into a testable helper; `label(_:)` was lifted with it so the
status-bar number and its tooltip cannot drift apart, and so the pin covers both strings the
operator named.

**Gate.** `./scripts/ci.sh` — `Executed 471 tests, with 0 failures (0 unexpected) in 58.760
seconds`, `Test Succeeded`, final line `==> CI passed.`, which the script's `set -euo pipefail`
only reaches on success. One run, no flake; the known `ShellPathResolverTests` 0.5 s fake-shell
timing flake did not trip. `swiftlint lint --quiet` printed nothing and exited 0. This gate covers
this section and the next — the two changes were built and committed together.

### Hands-on change: the sidebar globe is removed

**What landed.**

| File | State |
| --- | --- |
| `Sources/App/WorktreeRow.swift` | `PortBadge`, the `ports: [UInt16]` parameter and the `if !ports.isEmpty` branch deleted. 111 lines — `git diff 7ae81c1 -- Sources/App/WorktreeRow.swift` is empty, so the file is byte-identical to base. |
| `Sources/App/SidebarView.swift` | `@EnvironmentObject private var portMonitor`, `portsByWorktree` and its doc comment, and the row's `ports:` argument deleted. 653 lines, likewise byte-identical to base. |
| `docs/superpowers/specs/2026-09-18-active-port-indicator.md` | Decisions 2, 4, 11, 13, 17–20 rewritten and 25 added; the opening paragraph, assumption 5, success criteria 1, 2 and 5–8 and the files table amended; decisions 17–20 now read "Operator". |
| `docs/superpowers/plans/2026-09-18-active-port-indicator.md` | Architecture decisions 8 and 11–13 and 15, T4 superseded in place, two Changelog entries and these two sections. |

Untouched: `PortAttribution`, `PortScanner`, `PortMonitor` and `ClearwayApp`'s `@StateObject` /
`.environmentObject` wiring — the status bar is still their one consumer, and `PortMonitor` is
still injected app-wide. `Tests/PortAttributionTests.swift` is unchanged and still passes: the
attribution rules it pins are what feeds the status bar.

**Evidence.** No test was written and none was watched fail. The change only deletes a rendering;
it removes no decision rule and adds none XCTest can reach. The proof that nothing else depended on
it is mechanical: `grep -rn "PortBadge\|portsByWorktree" Sources/ Tests/` returns nothing, and both
touched files diff clean against base `7ae81c1`.

**Deviations from the operator's request.** None.

**Gate.** As above — one `./scripts/ci.sh` run covering both sections, 471 tests, 0 failures,
`==> CI passed.`, `swiftlint lint --quiet` silent and exit 0. `git status --porcelain` before the
commit showed `Clearway.xcodeproj/project.pbxproj`, `Sources/App/ContentViewHelpers.swift`,
`Sources/App/SidebarView.swift`, `Sources/App/WorktreeRow.swift`, the two documents, and the
untracked `Sources/App/PortLink.swift` and `Tests/PortLinkTests.swift` — no `default.profraw`,
since the app was never launched.

### Simplify pass

Four cleanup reviews over `7ae81c1..HEAD`. The removals themselves were clean — `PortBadge`,
`portsByWorktree` and `LivePortsMenu` have no surviving references — so only shape was left over:
`PortScanner.Listener` dropped its unused `Hashable`, `PortMonitor.deinit` became `nonisolated`
to match the other monitors, `WorktreeStatusBar.livePortsView` lost an `@ViewBuilder` it did not
need, and `PortAttribution` now builds each worktree's `path + "/"` once instead of once per
listener. The spec's files table had `PortScanner` returning a tuple rather than `Listener`.

Deliberately not changed: `PortLink` and its three helpers (a recorded operator decision),
`attribute(_:to:)`'s dictionary return, and `PortMonitor`'s free-running 2 s poll — the last two
are follow-ups, not simplifications.

### Review findings F1–F3

**What landed.**

| File | State |
| --- | --- |
| `Sources/App/ContentViewHelpers.swift` | `WorktreeStatusBar`'s outer `HStack` back to `spacing: 0`; `livePortsView` is `@ViewBuilder`, binds `livePorts` once, renders its `HStack(spacing: 8)` only under `if !ports.isEmpty` and owns the 12 pt gap before the PR info as `.padding(.trailing, 12)`; the doc comment on `livePorts` deleted. |
| `Sources/App/PortScanner.swift` | `scan()` ends in `.sorted { ($0.cwd, $0.port) < ($1.cwd, $1.port) }`, with the reason as its doc comment. The per-pid `ports.sorted()` is now redundant and became `ports.map`. |
| `Tests/PortScannerTests.swift` | New, one test: `scan()` equals its own `(cwd, port)` sort. Reads the live machine, so it is vacuous with fewer than two listeners — stated in the test. |
| `docs/superpowers/plans/2026-09-18-active-port-indicator.md` | This Changelog entry and this section. |

**Evidence.** `testTheScanIsOrderedByDirectoryThenPort` was watched fail against the unfixed
`scan()` — the test file present, the `.sorted` line absent — in a full `./scripts/ci.sh` run:

```
Test Suite 'PortScannerTests' started at 2026-09-18 18:48:54.655.
    ✖ testTheScanIsOrderedByDirectoryThenPort, XCTAssertEqual failed:
      ("[… Listener(cwd: "/", port: 44438), Listener(cwd: "/", port: 50043),
         Listener(cwd: "/", port: 7768), … Listener(cwd: "/opt/homebrew/var/db/redis", port: 6379),
         Listener(cwd: "/opt/homebrew/var/postgresql@18", port: 5432),
         Listener(cwd: "/", port: 7000), Listener(cwd: "/", port: 5000), …]")
      is not equal to
      ("[Listener(cwd: "/", port: 5000), Listener(cwd: "/", port: 6768), … ]")
Executed 472 tests, with 1 failure (0 unexpected) in 57.326 seconds
```

16 live listeners, in pid order, with three unattributed directories (`/`, a Stream Deck plugin,
redis, postgres) interleaved — exactly the churn F2 describes: any of those starting or ending
permutes the array and republishes `PortMonitor.listeners` for nothing.

F1 and F3 carry no test. F1 is layout — nothing on `WorktreeStatusBar` is reachable from XCTest
and the decision rule it encodes (`livePorts.isEmpty`) is already pinned by
`PortAttributionTests`' two empty-input cases. F3 deletes a comment.

**Deviations.** One, inside F2: `ports.sorted()` per pid was dropped because the array-wide sort
subsumes it. Dead work, not a behaviour change — the final order is identical either way.

**Gate.** `./scripts/ci.sh` after the last edit: `xcodegen generate`, `swiftlint lint --quiet`
silent, 472 tests, 0 failures, `==> CI passed.`, exit 0. `git status --porcelain` before the commit
listed only `Clearway.xcodeproj/project.pbxproj`, `Sources/App/ContentViewHelpers.swift`,
`Sources/App/PortScanner.swift`, this plan and the untracked `Tests/PortScannerTests.swift` — no
`default.profraw`, since the app was never launched.
