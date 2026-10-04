# Plan: Bundle THIRD-PARTY-LICENSES in the app

Breaks down `docs/superpowers/specs/2026-10-04-bundle-third-party-licenses-in-the-app.md`.

**Date:** 2026-10-04
**Base:** be4a80f (Bundle clearway skill and add skill installer to Settings, #268)

The spec's Decisions table (D1-D14) is the source of truth. This plan orders the work and says how
each piece is verified. Where it fixes a detail the spec leaves open, it says so.

## Architecture decisions carried from the spec

- D2: `THIRD-PARTY-LICENSES` joins the `Clearway` target as a `sources:` entry,
  `- path: THIRD-PARTY-LICENSES` with `buildPhase: resources` and no `type:` key. It lands at
  `Contents/Resources/THIRD-PARTY-LICENSES` in every configuration.
- D3: the target-level `resources:` key (`project.yml:35-39`, both entries) is deleted. xcodegen
  ignores it, so it has never had an effect.
- D4: a new `Tests/BundledResourcesTests.swift` asserts that
  `Bundle.main.url(forResource: "THIRD-PARTY-LICENSES", withExtension: nil)` is non-nil and the file
  reads as UTF-8. `Bundle.main` in the test host is the built `Clearway.app`. No Release-only guard.
- D5: the test does not compare the bundled bytes with the repo copy.
- D6: the `Skills/` bullet in the project `CLAUDE.md` (line 117) gains one sentence: `THIRD-PARTY-LICENSES`
  is added the same way, as a `sources` entry with `buildPhase: resources`, and the target has no
  `resources:` key for this reason.
- D7 (operator answer "Bundle + fix known gaps"): add the Ghostty, cmark-gfm and Sparkle notices and
  correct the git location. No wider licence audit.
- D8: Ghostty section = `ghostty/LICENSE` verbatim.
- D9: cmark-gfm section = the first four sections of `COPYING` at `e97450a` (main BSD-2-Clause,
  houdini, buffer/chunk, utf8) verbatim with their `-----` separators. That is exactly `COPYING`
  lines 1-102. Omit normalize.py, the CommonMark spec and test-software sections.
- D10: Sparkle section = Sparkle `LICENSE` at `066e75a` verbatim, external licences included.
- D11: the git sentence becomes `The bundled git binary (Resources/git-dist/git) and its helpers
  (Resources/git-dist/git-core/) are built from unmodified source using scripts/bundle-git.sh.` The
  rest of the Git section is unchanged.
- D12: keep the preamble and Git section; append Ghostty, cmark-gfm, Sparkle in that order. Each
  section: blank line, 80 `=`, the name, 80 `=`, blank line, `Source code: <URL>`, blank line,
  licence text. No "incomplete" disclaimer in the file.
- D13: the test checks that `Git`, `Ghostty`, `cmark-gfm` and `Sparkle` each appear as a whole line,
  one assertion per name. No licence-text matching.
- D14: copy licence texts from files, never retype them (sources and revisions in T1).

**Detail this plan fixes.** The spec does not say how the D11 sentence wraps. This plan wraps it at
80 columns to match the rest of the file, so it spans lines 12-15 instead of the old 12-14:

```
The bundled git binary (Resources/git-dist/git) and its helpers
(Resources/git-dist/git-core/) are built from unmodified source using
scripts/bundle-git.sh. Per GPL v2 Section 3, the complete corresponding source
code is available at the URL above.
```

**Why the content work is its own task.** One point is still open with the operator: whether the
shipped file should say it is not a complete audit. The spec says no (D12) and this plan follows
D12. If that answer changes, only T1 changes. T2's test checks the four name lines only, so a
disclaimer would not affect it.

## Dependency graph

```
T1 (file content) ──► T2 (bundle + test + CLAUDE.md)
```

T2 depends on T1 because the D13 assertions need the Ghostty, cmark-gfm and Sparkle name lines that
T1 adds. Run T1 first, then T2.

## Tasks

### T1: Fix the content of THIRD-PARTY-LICENSES

**Files:** `THIRD-PARTY-LICENSES` only.

**What it does.** Rewrites the git location sentence (D11, wrapped as shown above) and appends the
Ghostty, cmark-gfm and Sparkle sections (D8-D10, D12). Licence texts are copied from files by
command, never typed by hand.

Sources (D14):

- Ghostty: `ghostty/LICENSE` in this worktree.
- cmark-gfm and Sparkle: a DerivedData checkout directory
  `~/Library/Developer/Xcode/DerivedData/Clearway-*/SourcePackages/checkouts` whose `cmark-gfm` is at
  `e97450a77a40f12b4f88f95891621c3b5d8669de` and whose `Sparkle` is at
  `066e75a8b3e99962685d6a90cdd5293ebffd9261` (check with `git -C <dir> rev-parse HEAD`). During
  planning, `Clearway-aezxkneuiqqzxufyrfaljpspmgux` held both. If none does, fetch
  `https://raw.githubusercontent.com/brokenhandsio/cmark-gfm/e97450a77a40f12b4f88f95891621c3b5d8669de/COPYING`
  and `https://raw.githubusercontent.com/sparkle-project/Sparkle/066e75a8b3e99962685d6a90cdd5293ebffd9261/LICENSE`
  into the scratchpad and use those.

Build the expected file in the scratchpad with this recipe (it was run during planning and
produces 293 lines with the four names on lines 4, 18, 46 and 155), then copy it over the repo file:

```bash
CO=<checkouts dir found above>
BAN=$(printf '=%.0s' $(seq 80))
section() { printf '\n%s\n%s\n%s\n\nSource code: %s\n\n' "$BAN" "$1" "$BAN" "$2"; }
{ sed -n 1,11p THIRD-PARTY-LICENSES
  printf '%s\n' \
    'The bundled git binary (Resources/git-dist/git) and its helpers' \
    '(Resources/git-dist/git-core/) are built from unmodified source using' \
    'scripts/bundle-git.sh. Per GPL v2 Section 3, the complete corresponding source' \
    'code is available at the URL above.'
  section Ghostty https://github.com/ghostty-org/ghostty;        cat ghostty/LICENSE
  section cmark-gfm https://github.com/brokenhandsio/cmark-gfm;  sed -n 1,102p "$CO/cmark-gfm/COPYING"
  section Sparkle https://github.com/sparkle-project/Sparkle;    cat "$CO/Sparkle/LICENSE"
} > "$SCRATCH/expected-THIRD-PARTY-LICENSES"
```

Before copying, confirm `sed -n 102p "$CO/cmark-gfm/COPYING"` prints `DEALINGS IN THE SOFTWARE.` and
`sed -n 104p` prints `-----` (the separator before the omitted normalize.py section). If not, the
upstream file differs from the pinned revision; stop and report.

**Acceptance criteria:**

- Lines 1-11 are unchanged from `be4a80f`; lines 12-15 are the wrapped D11 text; no `Resources/git)`
  remains.
- Ghostty, cmark-gfm and Sparkle sections follow Git, in that order, in the D12 format, with the
  `Source code:` URLs `https://github.com/ghostty-org/ghostty`,
  `https://github.com/brokenhandsio/cmark-gfm`, `https://github.com/sparkle-project/Sparkle`.
- Each licence body is byte-identical to its source (Ghostty whole file, cmark-gfm `COPYING` lines
  1-102, Sparkle whole file), including upstream wording such as "utf8.c and utf8.c".
- No disclaimer or other text beyond D12's format.

**Verification:**

- `diff "$SCRATCH/expected-THIRD-PARTY-LICENSES" THIRD-PARTY-LICENSES` prints nothing.
- `git diff be4a80f -- THIRD-PARTY-LICENSES` shows only lines 12-14 replaced and additions after them.
- `grep -nx 'Git\|Ghostty\|cmark-gfm\|Sparkle' THIRD-PARTY-LICENSES` prints exactly four lines, in
  that order.
- `grep -c 'Resources/git)' THIRD-PARTY-LICENSES` prints `0`.
- `./scripts/ci.sh` exits 0 (regression check; the file is not yet bundled, so nothing else changes).

### T2: Bundle THIRD-PARTY-LICENSES and test that it ships

**Files:** `Tests/BundledResourcesTests.swift` (new), `project.yml`,
`Clearway.xcodeproj/project.pbxproj` (regenerated by `ci.sh`, never hand-edited), `CLAUDE.md`.

**What it does.** Test first, then the fix:

1. Add `Tests/BundledResourcesTests.swift`: `import XCTest`, `@testable import Clearway`,
   `final class BundledResourcesTests: XCTestCase`. One test that gets
   `Bundle.main.url(forResource: "THIRD-PARTY-LICENSES", withExtension: nil)` (fail if nil), reads it
   as a UTF-8 `String`, splits it into lines, and asserts per name that `Git`, `Ghostty`,
   `cmark-gfm` and `Sparkle` are each a whole line, with a failure message naming the missing one
   (D4, D13). A substring check is wrong: `Git` also matches "Github, Inc." in the cmark-gfm text.
2. Run `./scripts/ci.sh` and confirm the new test fails because the URL is nil. Record that failure
   in the build log.
3. In `project.yml`, under the `Clearway` target's `sources:`, after the `Skills` entry, add
   `- path: THIRD-PARTY-LICENSES` with `buildPhase: resources` (no `type:`). Delete the whole
   `resources:` key and both its entries (D2, D3).
4. Run `./scripts/ci.sh` again; it regenerates `project.pbxproj` and the test now passes. Record
   that run in the build log.
5. Append the D6 sentence to the `Skills/` bullet in `CLAUDE.md`, after "the target-level
   `resources:` key is ignored by xcodegen".

**Acceptance criteria:**

- `project.yml`'s `Clearway` target has the `THIRD-PARTY-LICENSES` sources entry with
  `buildPhase: resources` and no `resources:` key.
- `Clearway.xcodeproj/project.pbxproj` has a `THIRD-PARTY-LICENSES in Resources` build file in the
  `Clearway` target's Resources build phase, next to `Assets.xcassets` and `Skills`.
- `BundledResourcesTests` fails before the `project.yml` change and passes after, both runs recorded.
- The `CLAUDE.md` `Skills/` bullet carries the D6 sentence; nothing else in `CLAUDE.md` changes.

**Verification:**

- `grep -n 'THIRD-PARTY-LICENSES in Resources' Clearway.xcodeproj/project.pbxproj` finds the build
  file and its Resources-phase entry.
- `grep -n '^    resources:' project.yml` prints nothing.
- The built app has the file: resolve the bundle as `CLAUDE.md` describes (newest `.app` in
  `BUILT_PRODUCTS_DIR`) and `ls "<app>/Contents/Resources/THIRD-PARTY-LICENSES"`.
- `./scripts/ci.sh` exits 0 after the last edit, with `BundledResourcesTests` in the passing tests.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| No DerivedData checkout at the pinned revisions | T1 cannot copy texts | Fetch the raw URLs in T1 into the scratchpad. |
| Licence text retyped or reflowed | Notice differs from upstream | T1 builds the file by command and verifies with `diff`. |
| Operator reverses D12 (adds a disclaimer) | File content changes | Confined to T1; T2's test checks name lines only. |
| `ci.sh` launches the Debug app and leaves `default.profraw` | Dirty tree | Not gitignored; never `git add -A`, stage named files only. |

## Build log

### T1: Fix the content of THIRD-PARTY-LICENSES

| File | State |
| --- | --- |
| `THIRD-PARTY-LICENSES` | 293 lines. Lines 1-11 unchanged from `be4a80f`; lines 12-15 are the wrapped D11 text; Ghostty, cmark-gfm and Sparkle sections appended in D12 format. |
| spec, D12 row | Records the operator's confirmation on 2026-10-04: no "incomplete" disclaimer in the shipped file. |
| spec, acceptance criteria | The git-location criterion now reads "lines 12-15 read per D11, wrapped at 80 columns", matching this plan. |

Sources: checkouts in `Clearway-aezxkneuiqqzxufyrfaljpspmgux/SourcePackages/checkouts`, with cmark-gfm
at `e97450a77a40f12b4f88f95891621c3b5d8669de` and Sparkle at `066e75a8b3e99962685d6a90cdd5293ebffd9261`
(`git rev-parse HEAD`). The file was built with the plan's recipe in the scratchpad and copied over.

Evidence:

- Pre-copy guard: `COPYING` line 102 is `DEALINGS IN THE SOFTWARE.`, line 104 is `-----`.
- `diff expected-THIRD-PARTY-LICENSES THIRD-PARTY-LICENSES`: no output.
- `cmp` of lines 1-11 against `git show be4a80f:THIRD-PARTY-LICENSES`: identical.
- `cmp` of each licence body against its source (Ghostty whole file, cmark-gfm `COPYING` 1-102,
  Sparkle whole file): identical.
- `grep -nx 'Git\|Ghostty\|cmark-gfm\|Sparkle'`: `4:Git`, `18:Ghostty`, `46:cmark-gfm`, `155:Sparkle`.
- `grep -c 'Resources/git)'`: `0`.

Deviations: the plan's verification expects `git diff be4a80f` to show lines 12-14 replaced. Git's
diff shows only line 12 removed and two lines added, because old lines 13-14 survive unchanged as
new lines 14-15. The content is what the plan specifies. Lines over 80 columns appear only inside the
verbatim Sparkle text (lines 218-261), which D10 requires unchanged. No regression test: T1 changes
a text file that is not yet bundled; T2 adds the test.

Gate: `./scripts/ci.sh`. First run exited 65: `WorktreeGroupPersistenceTests.testAHandEditedRegistryDropsBlanksAndRepeats`
failed with "The test runner exited with code 0 before finishing running tests", a test-host exit
unrelated to this change (the file is not in any build phase yet). Rerun after the last edit exited
0, 950 tests, 0 failures.
