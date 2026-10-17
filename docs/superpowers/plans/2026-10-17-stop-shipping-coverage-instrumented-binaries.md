# Plan: Stop shipping coverage-instrumented binaries

Breaks down `docs/superpowers/specs/2026-10-17-stop-shipping-coverage-instrumented-binaries.md`.

**Date:** 2026-10-17
**Base:** 2f0c60e (Remove unused import from BundledResourcesTests; document early exit investigation, #273)

The spec's Decisions table (D1-D10) is the source of truth. This plan orders the work and says how
each piece is verified. D3 is confirmed by the operator: `ci.sh` and `ci.yml` switch to
`-scheme Clearway`, and no `ClearwayTests` scheme is defined.

## Architecture decisions carried from the spec

- D1: `project.yml` top-level `settings:` gains `configs: Release: ENABLE_CODE_COVERAGE: NO`. Debug
  keeps the Xcode default. Every target inherits it.
- D2: a top-level `schemes:` key defines exactly two schemes. `Clearway`: build `Clearway: all`;
  test `config: Debug`, `gatherCoverageData: false`, `targets: [ClearwayTests]`. `ClearwayCLI`:
  build `ClearwayCLI: all`, no test action.
- D3: `scripts/ci.sh` (both `xcodebuild` lines) and the `Test` step of `.github/workflows/ci.yml`
  use `-scheme Clearway` instead of `-scheme ClearwayTests`. No third scheme.
- D4: no `-enableCodeCoverage YES` anywhere. Nothing reads coverage.
- D5: one function, `clearway_require_uninstrumented <app path>`, in `scripts/release/common.sh`.
  It checks `<app>/Contents/MacOS/Clearway` and `<app>/Contents/MacOS/cway`, and returns non-zero
  with an error naming the binary when the file is missing, when `otool -l` exits non-zero, or when
  the `otool -l` output contains `__llvm_prf`.
- D6: called in `scripts/release/build.sh` right after the `APP_PATH` existence check, before
  `xattr` and the zip; and in `scripts/install.sh` right after its `APP_PATH` check, before the
  `rm -rf "$INSTALL_PATH"`. `install.sh` sources `scripts/release/common.sh` to get it.
- D7: the guard checks `__llvm_prf` sections only, not `__llvm_profile_*` symbols.
- D8: if the Debug `Clearway` binary built from the new scheme has no `__llvm_prf`, remove the
  docs that say a Debug launch leaves `default.profraw` (`CLAUDE.md:25-26`, the last sentence of
  `CLAUDE.md:176-177`, the comment at `scripts/release/common.sh:63`). `clearway_require_clean_tree`
  keeps `--untracked-files=no`. If the Debug binary is still instrumented, leave those docs alone
  and record why in the build log.
- D9: `default.profraw` is not added to `.gitignore`.
- D10: the `xcodegen generate` output is committed: `Clearway.xcodeproj/project.pbxproj` and the
  new `Clearway.xcodeproj/xcshareddata/xcschemes/Clearway.xcscheme` and `ClearwayCLI.xcscheme`.

## Implementation notes

- D5 under `set -o pipefail`: do not write `otool -l "$bin" | grep -q __llvm_prf`. Besides the
  missing-file case the spec names, `grep -q` exits on the first match, `otool` can then die of
  SIGPIPE, and the pipeline reports failure for an instrumented binary, so the guard would pass it.
  Capture the output first (`out=$(otool -l "$bin")` with an explicit failure branch), then test
  the captured text.
- `common.sh` is sourced by scripts running `set -euo pipefail`. Follow its existing style: print
  `Error: ...` to stderr and `return 1`, as `clearway_require_clean_tree` does.
- `install.sh` keeps its own `PRODUCT_NAME`, `SCRIPT_DIR` and `PROJECT_DIR` lines only if they are
  still needed after sourcing `common.sh`, which already sets `PRODUCT_NAME="Clearway"`,
  `PROJECT_DIR` and `cd`s to the repo root. Drop what becomes redundant.
- Run every probe in the scratchpad, never in the repo.

## Dependency graph

```
T1 (project.yml, schemes, ci.sh)
 ├── T2 (guard + callers, Release proof)   needs T1's uninstrumented Release build to pass
 └── T3 (ci.yml, Debug docs)               needs T1's Debug result for D8; edits common.sh after T2
         ▲
         └── T2 (sequential: both touch scripts/release/common.sh)
```

Order: T1, then T2, then T3.

### T1: Turn coverage off for Release and commit explicit schemes

**Files:** `project.yml`, `Clearway.xcodeproj/project.pbxproj` (regenerated),
`Clearway.xcodeproj/xcshareddata/xcschemes/Clearway.xcscheme` (new, generated),
`Clearway.xcodeproj/xcshareddata/xcschemes/ClearwayCLI.xcscheme` (new, generated), `scripts/ci.sh`.

**What it does:** adds D1's `settings.configs.Release.ENABLE_CODE_COVERAGE: NO` and D2's
`schemes:` block to `project.yml`, runs `xcodegen generate`, and changes both `-scheme ClearwayTests`
in `scripts/ci.sh` to `-scheme Clearway` (D3). The `ci.sh` change has to land here: once
`schemes:` exists, the `ClearwayTests` scheme is gone and `ci.sh` would fail.

**Acceptance criteria:**
- `xcodebuild -project Clearway.xcodeproj -scheme Clearway -configuration Release -showBuildSettings`
  reports `ENABLE_CODE_COVERAGE = NO` and no `CLANG_COVERAGE_MAPPING = YES`; the same holds for
  `-scheme ClearwayCLI`. `xcodebuild -list` shows schemes `Clearway` and `ClearwayCLI` only.
- `Clearway.xcscheme` has no `codeCoverageEnabled = "YES"`, and its test action lists only
  `ClearwayTests`.
- Running `xcodegen generate` a second time leaves `git status --porcelain` unchanged.
- `./scripts/ci.sh` exits 0.
- D8 input recorded in the build log: `otool -l <Debug BUILT_PRODUCTS_DIR>/Clearway.app/Contents/MacOS/Clearway | grep -c __llvm_prf`
  after the `ci.sh` run (resolve `BUILT_PRODUCTS_DIR` with
  `xcodebuild -project Clearway.xcodeproj -scheme Clearway -configuration Debug -showBuildSettings`).

**Verification:** the commands above, with output and exit status in the build log. `./scripts/ci.sh`
is the regression check and runs after the last edit.

### T2: Guard shipped binaries against profiling instrumentation

**Files:** `scripts/release/common.sh`, `scripts/release/build.sh`, `scripts/install.sh`.

**What it does:** adds `clearway_require_uninstrumented` (D5, and the pipefail note above) and calls
it at the two D6 sites. `install.sh` sources `scripts/release/common.sh`.

**Acceptance criteria:**
- Negative proof, done **before** `install.sh` replaces `/Applications/Clearway.app`: copy the
  installed 2.1.2 app to the scratchpad (`ditto /Applications/Clearway.app <scratchpad>/old/Clearway.app`),
  source `scripts/release/common.sh` in a `bash -euo pipefail` subshell, and run
  `clearway_require_uninstrumented <scratchpad>/old/Clearway.app`. It exits non-zero and the error
  names the instrumented binary. If the installed app is not instrumented (check with
  `otool -l ... | grep -c __llvm_prf` first), record that in the build log and build an
  instrumented sample in the scratchpad instead: a one-file `tool` built with
  `ENABLE_CODE_COVERAGE=YES CLANG_COVERAGE_MAPPING=YES` (spec probe P1), placed as
  `Contents/MacOS/Clearway` and `Contents/MacOS/cway` of a fake `.app` directory.
- Missing-binary proof: a scratchpad copy of the new Release app with `Contents/MacOS/cway` deleted
  makes the function exit non-zero with an error naming `cway`.
- `./scripts/install.sh` exits 0, which means the guard passed on the new Release build.
  Then `otool -l /Applications/Clearway.app/Contents/MacOS/Clearway | grep -c __llvm_prf` and the
  same for `.../cway` both print `0`.
- In a new scratchpad directory: `git init -q && /Applications/Clearway.app/Contents/MacOS/cway task list; ls -a`
  shows no `default.profraw`.
- `bash -n` passes on all three scripts. In `install.sh` the call comes before `rm -rf "$INSTALL_PATH"`;
  in `release/build.sh` it comes before `xattr -cr`. `release/build.sh` itself is not run here: it
  requires a clean tree and does a full clean build, and `install.sh` exercises the same function on
  the same Release build.
- `./scripts/ci.sh` exits 0.

**Verification:** the commands above, with output and exit status in the build log. `install.sh`
needs the Developer ID signing identity on this machine; if it is missing, the task is blocked, not
done.

### T3: Keep CI in step and drop the stale profraw docs

**Files:** `.github/workflows/ci.yml`, `CLAUDE.md`, `scripts/release/common.sh`.

**What it does:** changes the `Test` step of `ci.yml` to `-scheme Clearway` (D3). Then applies D8
using T1's recorded Debug result: if the Debug `Clearway` binary had 0 `__llvm_prf`, delete the
paragraph at `CLAUDE.md:25-26`, the sentence "Expect the un-gitignored `default.profraw` noted above
after any Debug launch." at `CLAUDE.md:176-177`, and the comment at `scripts/release/common.sh:63`.
If it was non-zero, change only `ci.yml` and record why in the build log.

**Acceptance criteria:**
- `git grep -n ClearwayTests -- .github scripts` finds no `-scheme ClearwayTests`.
- `ci.yml`'s `Test` step and `scripts/ci.sh` pass the same `-scheme`.
- With D8 confirmed: `git grep -n profraw -- ':!docs/superpowers'` finds nothing, and
  `clearway_require_clean_tree` still uses `--untracked-files=no`.
- `./scripts/ci.sh` exits 0.

**Verification:** the greps above and `./scripts/ci.sh`, run after the last edit, with exit status in
the build log. `ci.yml` is otherwise exercised only by GitHub on the PR.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| The `Clearway` scheme's test action does not build or launch `ClearwayTests` the way the hidden scheme did. | `ci.sh` fails in T1. | T1 runs `ci.sh` before anything else builds on it. |
| `install.sh` overwrites the only instrumented sample before the negative proof. | T2 loses its negative case. | T2 copies the installed app to the scratchpad first. |
| `otool | grep -q` SIGPIPE makes the guard pass an instrumented binary. | A bad release ships. | Implementation note above; T2's negative proof catches it. |

## Build log

### T1: Turn coverage off for Release and commit explicit schemes

| File | State |
| --- | --- |
| `project.yml` | Top-level `settings.configs.Release.ENABLE_CODE_COVERAGE: NO` (D1); top-level `schemes:` with `Clearway` (build `Clearway: all`, test `config: Debug`, `gatherCoverageData: false`, `targets: [ClearwayTests]`) and `ClearwayCLI` (build `ClearwayCLI: all`) (D2) |
| `Clearway.xcodeproj/project.pbxproj` | Regenerated; the one change is `ENABLE_CODE_COVERAGE = NO;` in the project-level Release configuration |
| `Clearway.xcodeproj/xcshareddata/xcschemes/Clearway.xcscheme` | New, generated |
| `Clearway.xcodeproj/xcshareddata/xcschemes/ClearwayCLI.xcscheme` | New, generated |
| `scripts/ci.sh` | Both `xcodebuild` lines use `-scheme Clearway` (D3) |

Evidence:

- Before the change, `-showBuildSettings -configuration Release`: `Clearway` reported
  `CLANG_COVERAGE_MAPPING = YES`, `ENABLE_CODE_COVERAGE = YES`; `ClearwayCLI` reported
  `ENABLE_CODE_COVERAGE = YES`.
- After: `Clearway` Release reports `ENABLE_CODE_COVERAGE = NO` and no `CLANG_COVERAGE_MAPPING`;
  `ClearwayCLI` Release reports `ENABLE_CODE_COVERAGE = NO` and no `CLANG_COVERAGE_MAPPING`.
- `xcodebuild -list` schemes: `Clearway`, `ClearwayCLI`.
- `grep -c codeCoverageEnabled Clearway.xcscheme` prints `0`; the `TestAction` has one
  `TestableReference`, `ClearwayTests.xctest`.
- Idempotence: `git status --porcelain` plus md5 of `project.yml`, `project.pbxproj` and both
  schemes taken before and after a second `xcodegen generate --quiet` are identical.
- D8 input, after the `ci.sh` run: `BUILT_PRODUCTS_DIR` (Debug, `-scheme Clearway`) is
  `~/Library/Developer/Xcode/DerivedData/Clearway-dllfcreuqswboqczqtxfntilfdbb/Build/Products/Debug`.
  `otool -l .../Clearway.app/Contents/MacOS/Clearway | grep -c __llvm_prf` prints `0`, and the same
  for `.../cway` prints `0`. Debug still resolves `ENABLE_CODE_COVERAGE = YES` with no
  `CLANG_COVERAGE_MAPPING`, as D1 intends. No `default.profraw` appeared in the repo root after the
  test run. D8 is confirmed for T3.

Deviations: none. No regression test applies; the change is build configuration, verified by the
settings and `otool` checks above.

Gate: `./scripts/ci.sh` after the last edit to code or config, exit 0 (956 tests, 0 failures).

### T2: Guard shipped binaries against profiling instrumentation

| File | State |
| --- | --- |
| `scripts/release/common.sh` | New `clearway_require_uninstrumented <app>` (D5): for `Contents/MacOS/$PRODUCT_NAME` and `Contents/MacOS/cway`, fails naming the binary when it is missing, when `otool -l` fails, or when the captured output contains `__llvm_prf`. Output is captured before matching, per the pipefail note |
| `scripts/release/build.sh` | Calls the guard after the `APP_PATH` check, before `xattr -cr` (D6) |
| `scripts/install.sh` | Sources `release/common.sh` in place of its own `SCRIPT_DIR`/`PROJECT_DIR`/`cd`/`PRODUCT_NAME` lines; calls the guard after the `APP_PATH` check, before `rm -rf "$INSTALL_PATH"` (D6) |

Evidence (all probes in the scratchpad):

- The installed 2.1.2 app, copied with `ditto` before `install.sh` ran: `otool -l ... | grep -c __llvm_prf`
  prints `7` for `Clearway` and `7` for `cway`, so no synthetic sample was needed.
- RED, before the function existed: `bash -euo pipefail -c "source scripts/release/common.sh; clearway_require_uninstrumented <scratchpad>/old/Clearway.app"`
  printed `clearway_require_uninstrumented: command not found`, exit 127.
- Negative proof, same command after the change: exit 1,
  `Error: <scratchpad>/old/Clearway.app/Contents/MacOS/Clearway is built with profiling instrumentation (__llvm_prf sections).`
- The `cway` branch on its own: a copy of the new app with the 2.1.2 `cway` swapped in exits 1,
  `Error: <scratchpad>/oldcway/Clearway.app/Contents/MacOS/cway is built with profiling instrumentation (__llvm_prf sections).`
- Missing-binary proof: a copy of the new app with `Contents/MacOS/cway` deleted exits 1,
  `Error: <scratchpad>/nocway/Clearway.app/Contents/MacOS/cway not found.`
- `./scripts/install.sh` exit 0, so the guard passed on the new Release build. Afterwards
  `otool -l /Applications/Clearway.app/Contents/MacOS/Clearway | grep -c __llvm_prf` prints `0`, and `0`
  for `.../cway`. The guard run directly on `/Applications/Clearway.app` exits 0.
- In a fresh scratchpad directory, `git init -q && /Applications/Clearway.app/Contents/MacOS/cway task list`
  printed `[]` (exit 0) and `ls -a` shows only `.`, `..`, `.git`: no `default.profraw`.
- `bash -n` passes on all three scripts.

Deviations: none. `release/build.sh` was not run, as the plan says.

Gate: `./scripts/ci.sh` after the last script edit, exit 0 (956 tests, 0 failures).
