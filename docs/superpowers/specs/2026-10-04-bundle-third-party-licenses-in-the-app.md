# Bundle THIRD-PARTY-LICENSES in the app

**Date:** 2026-10-04
**Base:** be4a80f (Bundle clearway skill and add skill installer to Settings, #268)

`THIRD-PARTY-LICENSES` at the repo root has never been copied into `Clearway.app`. `project.yml`
lists it under the `Clearway` target's `resources:` key, which xcodegen does not read, so the
generated project has no reference to the file. This change adds the file to the target as a
`sources` entry with `buildPhase: resources`, so it lands at `Contents/Resources/THIRD-PARTY-LICENSES`
in every configuration, deletes the dead `resources:` key, and adds a unit test that fails when
the built app no longer carries the file. It also fixes the known gaps in the file's content: today
it holds only Git's notice, so this change adds the licence notices of Ghostty, cmark-gfm and
Sparkle, and corrects the stated location of the bundled git binary from `Resources/git` to
`Resources/git-dist/git`.

After this change the file is still **not a complete licence audit**. libghostty statically links
third-party code whose notices are not in it, and no other dependency beyond the four named here
has been checked. That audit is a separate follow-up (see Out of scope).

## Decisions

| # | Question | Decision | Why |
| --- | --- | --- | --- |
| D1 | Is the file really missing from a release build? | Yes. Confirmed three ways, recorded under "Confirmation" below. | Brief: "Not yet confirmed against a release build; do that first." |
| D2 | How is the file added to the target? | One entry under the `Clearway` target's `sources:`: `- path: THIRD-PARTY-LICENSES` with `buildPhase: resources`. No `type:` key. | Brief, Pointers: "A single file may only need a `sources` entry with `buildPhase: resources`." Scratchpad probe (xcodegen 2.45.3) confirmed it: the generated project gets a `THIRD-PARTY-LICENSES in Resources` build file in the Resources build phase, and both a Debug and a Release build of the probe app hold `Contents/Resources/THIRD-PARTY-LICENSES`. `type: folder` is for directories (as `Skills` uses, `project.yml:32-34`) and is not needed for one file. |
| D3 | What happens to the `resources:` key? | The whole key (`project.yml:35-39`) is deleted, including its `Resources` entry. | Brief, acceptance. xcodegen ignores the key, so neither entry has ever had an effect: `Clearway.xcodeproj/project.pbxproj` has no reference to `THIRD-PARTY-LICENSES` or to a `Resources` folder, and its Resources build phase holds only `Assets.xcassets` and `Skills` (`project.pbxproj:802-811`). The only content under `Resources/` besides `.gitkeep` is the gitignored `git-dist`, which the "Sign and verify bundled git runtime" post-build script copies itself (`project.yml:164-177`), so dropping the `Resources` entry changes nothing. |
| D4 | What check fails when the file stops being bundled? | A unit test in a new `Tests/BundledResourcesTests.swift`: `Bundle.main.url(forResource: "THIRD-PARTY-LICENSES", withExtension: nil)` is non-nil, and the file it points to reads as a UTF-8 string. The content assertion is D13. | The test host is the built `Clearway.app` (`Bundle.main` is the app, as `TaskCommandTests.swift:88,106` already rely on), and `./scripts/ci.sh` and `.github/workflows/ci.yml` both run the suite, so the check runs on every PR. A Release-only post-build guard would duplicate it: the Copy Bundle Resources phase is not configuration-specific (probe: same output in Debug and Release), so a Debug test covers the Release build. A new file rather than a case in `TaskCommandTests`, which is about the `cway` CLI. |
| D5 | Does the test compare the bundled bytes with the repo copy? | No. Presence plus the D13 name check only. | Comparing needs the repo path through `#filePath` traversal, which no test here does. Xcode's copy phase copies the file as is, so a mismatch is not a failure mode this task has to catch. |
| D6 | Does the project CLAUDE.md change? | Yes, one sentence. The `Skills/` bullet (`CLAUDE.md:117`) ends with "the target-level `resources:` key is ignored by xcodegen". It gains that `THIRD-PARTY-LICENSES` is added the same way, as a `sources` entry with `buildPhase: resources`, and that the target has no `resources:` key for this reason. | Keeps the rule next to the one other bundled resource that already documents it, so nobody re-adds a `resources:` key. |
| D7 | Does this task fix the contents of `THIRD-PARTY-LICENSES`? | **Operator answer: "Bundle + fix known gaps".** Yes, for the known gaps only: add the Ghostty, cmark-gfm and Sparkle notices, and correct the git binary's stated location. A full audit of libghostty's statically linked dependencies, and of any dependency beyond these, stays out of scope as a follow-up. | Operator decision, answering the question the first spec pass raised. The file today has one section, Git (GPL v2, 14 lines). Bundling it as is would ship a notice file that omits the three dependencies the brief itself names. |
| D8 | Which Ghostty text? | `ghostty/LICENSE` verbatim: MIT, `Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors`. | The submodule is pinned at `c2e9de2` (`git ls-tree HEAD ghostty`). The worktree's `ghostty/LICENSE` is byte-identical to `git show c2e9de2:LICENSE` in the main checkout's initialised submodule (checked with `diff`). GhosttyKit is built from this tree, and the app also ships Ghostty's `Resources/ghostty` and `Resources/terminfo`. |
| D9 | Which parts of cmark-gfm's `COPYING` apply? | Four of its seven sections: the main BSD-2-Clause notice (`Copyright (c) 2014, John MacFarlane`), and the MIT notices for houdini (`Copyright (C) 2012 Vicent Martí`), buffer/chunk (`(C) 2012 Github, Inc.`) and utf8 (`(C) 2009 Public Software Group e. V., Berlin, Germany.`). Leave out the normalize.py (Karl Dubost), CommonMark spec (CC-BY-SA 4.0) and test-software sections. | The pinned package (`brokenhandsio/cmark-gfm` 2.1.0, revision `e97450a`, `Package.resolved`) has one target, `cmark`, built from `Sources/cmark`. That directory contains `houdini.h`, `houdini_href_e.c`, `houdini_html_e.c`, `houdini_html_u.c`, `buffer.c`, `buffer.h`, `chunk.h`, `utf8.c`, `utf8.h`, so those three notices cover compiled code. The checkout has no `normalize.py`, no `spec.txt` and no `test/`: none of that code is in the package, so it is not in the binary. Copying those sections would state licences for code Clearway does not ship. |
| D10 | Which parts of Sparkle's `LICENSE` apply? | The whole file, verbatim: the main MIT notice (seven copyright lines, Andy Matuschak through Big Nerd Ranch) and every section under "EXTERNAL LICENSES" (bsdiff/bspatch, sais-lite, ed25519, SUSignatureVerifier.m). | Sparkle comes in as a prebuilt `binaryTarget` (`Package.swift:20-24` at revision `066e75a`, version 2.9.1), so which sources went into it cannot be read off a source list. `strings` on the shipped 2.0.1 `Sparkle.framework` finds ed25519 symbols in all binaries and the `BSDIFF40` delta marker in `Autoupdate`, so at least two external components ship. The framework carries no licence file of its own (`find -iname '*licen*'` is empty), so this file is the only place the notices reach the user. Trimming risks dropping a notice that applies; an extra one costs nothing. |
| D11 | What does the corrected git line say? | `The bundled git binary (Resources/git-dist/git) and its helpers (Resources/git-dist/git-core/) are built from unmodified source using scripts/bundle-git.sh.` The rest of the Git section is unchanged. | Verified: `/Applications/Clearway.app/Contents/Resources/git-dist/` holds `git` and `git-core`; `scripts/bundle-git.sh:3-7` names `Resources/git-dist/git` and `Resources/git-dist/git-core/` as the outputs; the post-build phase copies to `Resources/git-dist` (`project.yml:168`). The helpers are git binaries too, so the notice names them. |
| D12 | How is the file laid out? | Keep the existing preamble and the Git section in place; append one section each for Ghostty, cmark-gfm and Sparkle, in that order, using the existing banner (80 `=` characters, the name, 80 `=` characters). Each section: a `Source code:` line with the upstream URL, a blank line, then the licence text copied verbatim. The file itself does not carry an "incomplete" disclaimer. Operator confirmed this on 2026-10-04. | Smallest diff that keeps one consistent format. A disclaimer in a shipped notice file says nothing to the user that they can act on; the incompleteness is tracked in this spec and the follow-up. |
| D13 | Does the test assert content? | Yes: the bundled file has each of `Git`, `Ghostty`, `cmark-gfm` and `Sparkle` as a whole line (the banner name line from D12), checked per name. No licence-text matching. | A presence-only test passes if a later edit truncates the file back to one section, which is the exact gap this task closes. A plain substring check would be hollow for `Git`, which also matches "Github, Inc." in the cmark-gfm text; matching whole lines avoids that. Four checks cost nothing and fail with a useful name. Matching licence text would break on any upstream wording change and duplicates what review already checks. |
| D14 | Where does the build agent get the texts? | Copy them from the files, never retype: `ghostty/LICENSE`; cmark-gfm `COPYING` and Sparkle `LICENSE` from `~/Library/Developer/Xcode/DerivedData/Clearway-*/SourcePackages/checkouts/{cmark-gfm,Sparkle}` after checking with `git -C <checkout> rev-parse HEAD` that the revision is `e97450a77a40f12b4f88f95891621c3b5d8669de` / `066e75a8b3e99962685d6a90cdd5293ebffd9261`. If no checkout at those revisions exists, run `./scripts/ci.sh` once (it resolves packages) or fetch `https://raw.githubusercontent.com/brokenhandsio/cmark-gfm/e97450a77a40f12b4f88f95891621c3b5d8669de/COPYING` and `https://raw.githubusercontent.com/sparkle-project/Sparkle/066e75a8b3e99962685d6a90cdd5293ebffd9261/LICENSE`. | The revisions are the ones in the tracked `Package.resolved`. This session found checkouts at both revisions in several DerivedData folders (e.g. `Clearway-aezxkneuiqqzxufyrfaljpspmgux`). Retyping licence text invites silent errors. |

## Confirmation (D1)

All probes ran in the session scratchpad, never in the repo.

1. **Shipped Release build.** `/Applications/Clearway.app` is version 2.0.1, signed
   `Developer ID Application: Bruno Valentino (76AEQBHY3K)`, timestamp 2026-09-25, and
   `spctl -a -vv` reports `source=Notarized Developer ID`. Its `Contents/Resources` holds
   `AppIcon.icns`, `Assets.car`, `ghostty`, `git-dist`, `terminfo`. No `THIRD-PARTY-LICENSES`.
2. **Generated project.** `grep THIRD Clearway.xcodeproj/project.pbxproj` at `be4a80f` finds
   nothing. Its Resources build phase lists `Assets.xcassets` and `Skills` only. Since every
   configuration builds from this one project, no configuration copies the file.
3. **Local Debug builds.** Three `Clearway.app` bundles in DerivedData, one including the new
   `Skills` folder, have no `THIRD-PARTY-LICENSES` in `Contents/Resources`.
4. **The fix works (xcodegen 2.45.3).** A minimal app in the scratchpad with
   `- path: THIRD-PARTY-LICENSES` / `buildPhase: resources` under `sources:`, and a second file
   listed under a target-level `resources:` key: built in Debug and Release, both apps had
   `Contents/Resources/THIRD-PARTY-LICENSES` and neither had the file from `resources:`.

A full Release build of Clearway itself was not run for the confirmation: its pre-build phase
rebuilds git from source and its post-build phases sign with the Developer ID identity. The
shipped, notarized 2.0.1 bundle is the stronger evidence for "a release build". The build stage
verifies acceptance criterion 1 through the probe result plus the test (D4); the operator can check
a real Release bundle with `./scripts/release.sh` at release time.

## Assumptions

Checked against the tree at `be4a80f`.

- `THIRD-PARTY-LICENSES` exists at the repo root and is tracked (`git log` shows it added in
  a08b405, #132). It has no file extension, which the probe showed xcodegen and Xcode handle.
- The `Clearway` target's `sources:` already mixes compiled sources and a resource entry
  (`project.yml:25-34`), so the new entry follows an existing shape.
- `Bundle.main` in the test host is the built `Clearway.app`: `ClearwayTests` depends on the
  `Clearway` target (`project.yml:358-359`) and existing tests read bundle paths from it
  (`TaskCommandTests.swift:88`, `:106`; `GitResolverTests.swift:31`).
- `ci.sh` regenerates the project before building (`scripts/ci.sh`, `xcodegen generate --quiet`), so
  the new `sources` entry and the new test file are picked up without a manual step.
- `Clearway.xcodeproj/project.pbxproj` is tracked (`git ls-files`), so the regenerated pbxproj is
  part of the diff, as `scripts/release.sh` already expects for project changes.
- No script, workflow or doc other than `project.yml` refers to `THIRD-PARTY-LICENSES` (grep over
  `scripts`, `.github`, `RELEASING.md`, `README.md`, `Sources`).
- The stale path is `THIRD-PARTY-LICENSES:12`, `The bundled git binary (Resources/git) is built from
  unmodified source using`. It is the only line in the file that names a location.
- The package pins are tracked: `Clearway.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
  pins cmark-gfm 2.1.0 at `e97450a` and Sparkle 2.9.1 at `066e75a`. `project.yml:14-19` declares
  cmark-gfm `exactVersion: 2.1.0` and Sparkle `from: 2.6.0`, so Sparkle can move on a future
  re-resolve; the notice is correct for the pinned revision only.
- The cmark-gfm package compiles only `Sources/cmark` (its `Package.swift` declares one target,
  `cmark`, with no path override), checked in the DerivedData checkout at `e97450a`.
- Sparkle's SPM product is a prebuilt XCFramework (`binaryTarget`, `Package.swift:20-24` at `066e75a`).
- The Ghostty and Sparkle probes (`diff` of `LICENSE`, `strings` and `find` on the shipped
  framework) ran against files outside the repo; nothing was written into the worktree.

## Objective and success criteria

Every build of `Clearway.app` carries `Contents/Resources/THIRD-PARTY-LICENSES`, the file holds the
notices of Git, Ghostty, cmark-gfm and Sparkle with the git binary's real location, and the test
suite fails if the file stops being bundled or loses one of those sections. The file is still not a
complete audit of everything the app links or ships.

- [ ] `project.yml`'s `Clearway` target has `- path: THIRD-PARTY-LICENSES` with
      `buildPhase: resources` under `sources:`, and no `resources:` key.
- [ ] The regenerated `Clearway.xcodeproj/project.pbxproj` has a `THIRD-PARTY-LICENSES in Resources`
      entry in the `Clearway` target's Resources build phase.
- [ ] `THIRD-PARTY-LICENSES` lines 12-15 read per D11, wrapped at 80 columns as the plan shows
      (`Resources/git-dist/git` and `Resources/git-dist/git-core/`); no `Resources/git)` remains.
- [ ] `THIRD-PARTY-LICENSES` gains a Ghostty, a cmark-gfm and a Sparkle section after Git, in the
      D12 format, with `Source code:` URLs `https://github.com/ghostty-org/ghostty`,
      `https://github.com/brokenhandsio/cmark-gfm` and `https://github.com/sparkle-project/Sparkle`.
- [ ] Ghostty section: `ghostty/LICENSE` verbatim (D8). Sparkle section: Sparkle `LICENSE` at
      `066e75a` verbatim, external licences included (D10). cmark-gfm section: the four D9 sections of
      `COPYING` at `e97450a`, verbatim, in their original order, with the original `-----` separators
      between them (upstream wording kept as is, including its "utf8.c and utf8.c" typo).
- [ ] Texts copied from the files named in D14, not retyped.
- [ ] `Tests/BundledResourcesTests.swift` asserts the bundled file exists and has `Git`,
      `Ghostty`, `cmark-gfm` and `Sparkle` each as a whole line (D13). Before the `project.yml` change it fails; after, it
      passes. The build log records both runs.
- [ ] `CLAUDE.md` `Skills/` bullet updated per D6.
- [ ] `./scripts/ci.sh` exits 0 after the last edit.

## Commands

From the project's `## Pipeline` section:

| Step | Command |
| --- | --- |
| Every build task (regression check) | `./scripts/ci.sh` |
| Sign-off (full gate) | `./scripts/ci.sh` |

Before sign-off: `git status --porcelain`, and report untracked or ignored files
(`default.profraw` is expected after any Debug launch).

## Files touched

- `project.yml`: add the `sources` entry, delete the `resources:` key.
- `Clearway.xcodeproj/project.pbxproj`: regenerated by `xcodegen generate`.
- `THIRD-PARTY-LICENSES`: fix the git location line, append three sections.
- `Tests/BundledResourcesTests.swift`: new, one test.
- `CLAUDE.md`: one sentence in the `Skills/` bullet.

## Out of scope

- A full licence audit (D7), recorded as a follow-up. This task does not make the file complete.
  Not covered: the third-party code libghostty statically links (its Zig package dependencies) and
  the third-party content in Ghostty's shipped `Resources/ghostty` and `Resources/terminfo`; any
  dependency beyond Git, Ghostty, cmark-gfm and Sparkle; re-checking Sparkle's notice when its
  `from: 2.6.0` requirement resolves to a new version.
- Showing the licences in the app's UI (an About or Acknowledgements panel).
- Any change to the git-dist, Ghostty-resource or Sparkle build scripts.
