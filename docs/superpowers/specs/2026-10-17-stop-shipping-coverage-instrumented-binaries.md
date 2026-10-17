# Stop shipping coverage-instrumented binaries

**Date:** 2026-10-17
**Base:** 2f0c60e (Remove unused import from BundledResourcesTests; document early exit investigation, #273)

Release builds of `Clearway.app` and the embedded `cway` are compiled with LLVM profiling
instrumentation, so every `cway` run writes a `default.profraw` into the user's current directory
and the app binary is about 3.6 MB larger than it should be. The cause is the scheme Xcode
autocreates for the `Clearway` target: it turns on `CLANG_COVERAGE_MAPPING` for every action and
configuration, and Xcode 27.1 defaults `ENABLE_CODE_COVERAGE` to YES, so the Swift compiler gets
`-profile-coverage-mapping -profile-generate`. This change turns code coverage off for every
Release build in `project.yml`, commits explicit schemes so the autocreated ones no longer decide
build flags, and adds a check to `scripts/release/build.sh` and `scripts/install.sh` that fails
when either shipped binary carries a `__llvm_prf` section.

## Decisions

| # | Question | Decision | Why |
| --- | --- | --- | --- |
| D1 | Where does Release turn coverage off? | Top-level `settings:` of `project.yml` gains `configs: Release: ENABLE_CODE_COVERAGE: NO`. Debug keeps the Xcode default (YES). | Brief, Change 1. Every target inherits project-level settings, so this holds for `Clearway`, `ClearwayCLI` and `ClearwayTests` whatever scheme builds them. Xcode's `Swift.xcspec` makes the compile flags conditional on it (A3). Probe P2 shows the project-level setting takes effect while the scheme still sets `CLANG_COVERAGE_MAPPING = YES`. Debug keeps YES so a developer can still opt in with `-enableCodeCoverage YES`. |
| D2 | Which schemes does `project.yml` define? | Two, under a top-level `schemes:` key. `Clearway`: build `Clearway: all`; test `config: Debug`, `targets: [ClearwayTests]`, `gatherCoverageData: false`. `ClearwayCLI`: build `ClearwayCLI: all`, no test action. | Brief, Change 2. xcodegen writes them to `Clearway.xcodeproj/xcshareddata/xcschemes/`, so they are committed and the autocreated defaults stop applying. `gatherCoverageData` defaults to false in xcodegen (A6), but it is written out because it is the setting this change depends on. |
| D3 | The explicit schemes remove the hidden `ClearwayTests` scheme that `ci.sh` and CI test with. What replaces it? | `scripts/ci.sh` (lines 19 and 22) and the `Test` step of `.github/workflows/ci.yml` (line 106) change `-scheme ClearwayTests` to `-scheme Clearway`. No third scheme. | Probe P3: once `schemes:` is defined, `xcodebuild -scheme AppTests` fails with "does not contain a scheme named". The brief did not foresee this. The `Clearway` scheme's test action from D2 runs exactly the `ClearwayTests` bundle, so a separate `ClearwayTests` scheme would be a second definition of the same test run. `ci.sh` and `ci.yml` must stay in step (CLAUDE.md, "Verifying a change"), so both change together. |
| D4 | Does the test run need coverage, via `-enableCodeCoverage YES` in `ci.sh`? | No. `ci.sh` and `ci.yml` stay without it. | Brief, Change 2: enable it only "if it needs coverage". Nothing reads coverage: no script, workflow step or doc mentions coverage or `.profdata` (`grep -rni coverage scripts .github` finds nothing). |
| D5 | Where does the guard live? | One function in `scripts/release/common.sh`, `clearway_require_uninstrumented <app path>`. It checks `<app>/Contents/MacOS/Clearway` and `<app>/Contents/MacOS/cway`. For each it fails with an error naming the binary when the file is missing, or when `otool -l` exits non-zero or prints no `LC_SEGMENT_64` load command (it exits 0 on a file that is not Mach-O, an empty one included), or when its output contains `__llvm_prf`. | Brief, Change 3: "One shared function in the release helpers." Under `set -o pipefail`, a bare `otool -l "$bin" \| grep -q __llvm_prf` passes when the file is missing: `otool` fails, `grep` matches nothing, and the `if` is false. So the existence and `otool` checks must be explicit. The executable name is `Clearway` because both callers pass `APP_PRODUCT_NAME="$PRODUCT_NAME"` with `PRODUCT_NAME="Clearway"` (`install.sh:10,14`, `common.sh:9`, `release/build.sh:18`). |
| D6 | Where is it called? | `scripts/release/build.sh`: right after the `APP_PATH` existence check (line 32), before `xattr` and the zip. `scripts/install.sh`: right after its `APP_PATH` check (line 26), before anything under `/Applications` is removed. `install.sh` sources `scripts/release/common.sh` to get it. | A bad build must stop before it is zipped or installed. In `install.sh` it has to run before `rm -rf "$INSTALL_PATH"` (line 32), or a failed guard would leave the user with no app at all. Sourcing `common.sh` is harmless here: it only `cd`s to the repo root (as `install.sh:8` already does) and sets `PRODUCT_NAME="Clearway"` (same value as `install.sh:10`), `RELEASE_DIR` and functions. |
| D7 | Does the guard also check for linked profile runtime symbols (`__llvm_profile_*`)? | No. `__llvm_prf` sections only, as the brief says. | Probe P1: with `ENABLE_CODE_COVERAGE=NO` and `CLANG_COVERAGE_MAPPING=YES`, neither the compile nor the link step gets `-profile-generate`, and the binary has 0 `__llvm_prf` sections, 0 `__llvm_profile` symbols, and writes no `default.profraw`. With both YES it has 7 sections, 68 symbols, and writes the file. The two signals move together, so one check is enough. |
| D8 | What happens to Debug builds and the docs that describe them? | The explicit `Clearway` scheme turns off `CLANG_COVERAGE_MAPPING` for Debug too (probe P3), so `build.sh`/`run.sh` Debug builds should stop writing `default.profraw`. The build stage confirms this on the real project (`otool -l` on the Debug `Clearway` binary shows no `__llvm_prf`). If confirmed, remove the claims that a Debug launch leaves `default.profraw`: `CLAUDE.md:25-26` (the paragraph), the last sentence of `CLAUDE.md:176-177`, and the comment at `scripts/release/common.sh:63`. `clearway_require_clean_tree` keeps `--untracked-files=no`. If the Debug binary is still instrumented, leave the docs as they are and record why in the build log. | "Leave Debug alone" in the brief is about not setting `ENABLE_CODE_COVERAGE: NO` for Debug (D1), and D1 honours that. Losing Debug instrumentation follows from Change 2 and does not break anything (D4). Docs that describe a file that no longer appears would be wrong. Ignoring untracked files in the release tree check is still correct on its own terms, so only its stated reason goes. |
| D9 | Is `default.profraw` added to `.gitignore`? | No. | The fix removes the cause. A gitignore entry would also hide the file if instrumentation ever came back, and the guard exists to catch exactly that. |
| D10 | Is the pbxproj regenerated and committed? | Yes. Commit the `xcodegen generate` output: `Clearway.xcodeproj/project.pbxproj` and the two new files under `Clearway.xcodeproj/xcshareddata/xcschemes/`. | `install.sh` and `release/build.sh` do not run xcodegen, so they build whatever project is committed. `project.pbxproj` is tracked today (`git ls-files Clearway.xcodeproj`). `.gitignore` excludes only `xcuserdata/`, so `xcshareddata/xcschemes` can be committed. |

## Assumptions (verified)

- A1. `project.yml` has no scheme definitions and no coverage settings. Top-level `settings:` is
  `base:` only (`project.yml:8-11`). No target has a `scheme:` key, there is no `schemes:` key,
  and nothing sets `ENABLE_CODE_COVERAGE` or `CLANG_COVERAGE_MAPPING` (`grep -n -i coverage project.yml` is empty).
  No scheme files are tracked (`git ls-files Clearway.xcodeproj` lists only `project.pbxproj`,
  `contents.xcworkspacedata` and `Package.resolved`).
- A2. Current resolved settings on this machine (`xcodebuild -showBuildSettings`, Xcode 27.1 build 27A9275):
  `-scheme Clearway`, Debug and Release: `CLANG_COVERAGE_MAPPING = YES`, `ENABLE_CODE_COVERAGE = YES`.
  `-scheme ClearwayCLI`, Debug and Release: `ENABLE_CODE_COVERAGE = YES`, no `CLANG_COVERAGE_MAPPING`.
  `xcodebuild -list` shows schemes `Clearway` and `ClearwayCLI` only, and `ClearwayTests` still
  resolves as a hidden autocreated scheme (`ci.sh:19,22` and `ci.yml:106` use it today).
- A3. Xcode's build specs gate the flags on `ENABLE_CODE_COVERAGE`.
  `SwiftBuild.framework/.../CoreBuildSystem.xcspec:3624-3629`: `ENABLE_CODE_COVERAGE`,
  `DefaultValue = YES`, "This is only used when the build has code coverage enabled, which is
  typically done via the Xcode scheme or test plan settings." `Swift.xcspec:1161-1171`:
  `CLANG_COVERAGE_MAPPING` with `Condition = "$(ENABLE_CODE_COVERAGE)"` and
  `YES = ("-profile-coverage-mapping", "-profile-generate")`. The linker-side
  `CLANG_COVERAGE_MAPPING_LINKER_ARGS` (`Swift.xcspec:1175-1191`) has no such condition, so probe
  P1 was needed to show that the link step drops `-profile-generate` too.
- A4. `cway` ends up in the app at `Contents/MacOS/cway`: the `ClearwayCLI` dependency is embedded with
  `copy: destination: executables` (`project.yml:306-310`) and its `PRODUCT_NAME` is `cway` (`project.yml:324`).
- A5. Both release paths build `-scheme Clearway -configuration Release` (`install.sh:13-19`,
  `release/build.sh:17-25`). `release.sh:45-48` runs `xcodegen generate` and commits only
  `project.yml` and `project.pbxproj`. After this change the scheme files are already committed and do
  not change on a version bump, so that `git add` list still covers what a release changes.
- A6. xcodegen 2.45.3 (installed; `xcodegen --version`). Its ProjectSpec at tag 2.45.3, fetched
  2026-10-17 from `https://raw.githubusercontent.com/yonaskolb/XcodeGen/2.45.3/Docs/ProjectSpec.md`:
  `gatherCoverageData`: "a boolean that indicates if this scheme should gather coverage data. This
  defaults to false." Build targets: "A map of target names to build and which build types they
  should be enabled for" (example `MyTarget: all`). Test `targets`: "a list of targets to test."
  Action `config`: without one, "`debug` for run, test, and analyze, and `release` for profile and archive."
- A7. `ci.yml` runs `xcodegen generate` before building (`ci.yml:78`), so CI uses the schemes from
  `project.yml` and needs no other change than D3.

### Probes (all in the scratchpad, none in the repo)

- P1, a one-file `tool` target: Release built with `ENABLE_CODE_COVERAGE=YES CLANG_COVERAGE_MAPPING=YES`
  gets `-profile-coverage-mapping -profile-generate`, has 7 `__llvm_prf` load-command lines and 68
  `llvm_profile` symbols, and writes `default.profraw` into the cwd. With `ENABLE_CODE_COVERAGE=NO
  CLANG_COVERAGE_MAPPING=YES`: no `-profile-generate` anywhere in the build log, 0 sections, 0 symbols,
  no `default.profraw`.
- P2, an app + embedded tool + unit-test bundle like this project's, with no schemes: the autocreated
  `App` scheme reports `CLANG_COVERAGE_MAPPING = YES` in Debug and Release, and the tool's scheme does
  not. This reproduces A2. The brief's throwaway project had no test target, which is why it did not
  reproduce. The test bundle in the app's autocreated scheme is the observed difference; why Xcode then
  sets the flag for every action was not investigated. With
  `settings: configs: Release: ENABLE_CODE_COVERAGE: NO` added, `App` Release reports
  `ENABLE_CODE_COVERAGE = NO` while `CLANG_COVERAGE_MAPPING` stays YES, so the project-level value is
  not overridden.
- P3, the same project with the D2 `schemes:` block: `xcshareddata/xcschemes/App.xcscheme` and
  `CLI.xcscheme` are generated. Neither scheme reports `CLANG_COVERAGE_MAPPING` in Debug or Release,
  and `App.xcscheme` has no `codeCoverageEnabled` attribute. `xcodebuild -scheme AppTests` fails:
  "The project named "P" does not contain a scheme named "AppTests"."

## Objective and success criteria

Nobody who runs the shipped `cway`, or the shipped app, gets a `default.profraw`, and no release can
ship instrumented again without the build failing.

1. A Release build from `-scheme Clearway` gives a `Clearway` and a `cway`, and `otool -l` finds no
   `__llvm_prf` in either.
2. `scripts/install.sh` and `scripts/release/build.sh` call `clearway_require_uninstrumented` on the
   built app before zipping or installing it, and stop with a non-zero exit and an error naming the
   binary if one is instrumented or missing. Build stage proof: run the function on an instrumented app
   (for example the currently installed 2.1.2 `/Applications/Clearway.app`, A2 evidence in the brief),
   and on a path with no `cway`, and see it fail both times. Run it on the new Release build and see it pass.
3. After `scripts/install.sh`, `/Applications/Clearway.app/Contents/MacOS/cway task list` run in a
   scratch git repo exits and leaves no `default.profraw` in that directory.
4. `./scripts/ci.sh` passes with the D3 scheme change, and `ci.yml`'s `Test` step uses the same scheme.
5. `Clearway.xcodeproj/xcshareddata/xcschemes/Clearway.xcscheme` and `ClearwayCLI.xcscheme` are
   committed, and `xcodegen generate` on the committed `project.yml` produces no diff.

## Verification commands

From `CLAUDE.md` `## Pipeline` ("Regression check vs. full gate"):

| Step | Command |
| --- | --- |
| Every `build` task, and `simplify` | `./scripts/ci.sh` |
| `sign-off`, once | `./scripts/ci.sh` |

Task-specific checks (from the brief, Change 4 and Done when):

- `./scripts/install.sh`: the Release build with the guard, then the install. It needs the
  Developer ID signing identity (`README.md:44`) and replaces `/Applications/Clearway.app`, which the
  brief asks for.
- `otool -l /Applications/Clearway.app/Contents/MacOS/Clearway | grep -c __llvm_prf` and the same
  for `.../cway`: both `0`.
- `cd "$(mktemp -d)" && git init -q && /Applications/Clearway.app/Contents/MacOS/cway task list; ls -a`:
  no `default.profraw`. Use a scratchpad directory, not the repo.

Before sign-off, `git status --porcelain` must come back with no untracked files (CLAUDE.md, Merge model).

## Files touched

- `project.yml`: top-level `settings.configs.Release` (D1), top-level `schemes:` (D2).
- `Clearway.xcodeproj/project.pbxproj`, regenerated, and new
  `Clearway.xcodeproj/xcshareddata/xcschemes/Clearway.xcscheme`, `ClearwayCLI.xcscheme` (D10).
- `scripts/release/common.sh`: new `clearway_require_uninstrumented` (D5). Comment at line 63 goes (D8, if confirmed).
- `scripts/release/build.sh`: call after line 32 (D6).
- `scripts/install.sh`: source `release/common.sh`, call after line 26 (D6).
- `scripts/ci.sh`: lines 19 and 22, `-scheme Clearway` (D3).
- `.github/workflows/ci.yml`: line 106, `-scheme Clearway` (D3).
- `CLAUDE.md`: lines 25-26 and 176-177 (D8, if confirmed).

No Swift sources or tests change.

## Out of scope

- Adding `default.profraw` to `.gitignore` (D9).
- Coverage reporting in CI or `ci.sh` (D4).
- Cleaning up `default.profraw` files that 2.1.2 already left in users' repos. The next release's
  notes can mention it, and that belongs to the release, not this change.
- Finding out why Xcode turns on `CLANG_COVERAGE_MAPPING` for an autocreated scheme with a test
  bundle (P2). Once the schemes are committed it no longer affects the build.
- Cutting a release. The fix reaches users with the next `./scripts/release.sh`.
