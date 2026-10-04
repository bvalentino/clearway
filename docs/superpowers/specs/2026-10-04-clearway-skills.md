# Clearway skills

**Date:** 2026-10-04
**Base:** 206b829 (cway: explicit error messages instead of git's raw output, #267)

`Clearway.app` ships one agent skill, `clearway`, at `Contents/Resources/Skills/clearway/SKILL.md`.
It tells Claude Code and Codex to create, list and show Clearway tasks through the `cway` CLI, and
only when the user asks. A new row in Settings installs it in one click: a symlink
`~/.clearway/cway` to the bundle's `Contents/MacOS/cway`, and a symlink named `clearway` in
`~/.claude/skills` and in `~/.agents/skills`, each pointing at the bundle's skill folder. The same
button uninstalls. Settings judges the state from the links on disk, never from a stored flag, and
nothing is installed at launch. Because every entry is a link into the bundle, an in-place app
update reaches the agents without a reinstall. `cway task list` and `cway task show` also start
warning on stderr when they skip a task file they cannot read or parse, so an agent does not take
an incomplete answer as complete.

## Decisions

| # | Question | Decision | Why |
| --- | --- | --- | --- |
| D1 | What is the CLI called and where is its link? | `cway`, linked at `~/.clearway/cway` (absolute symlink to `<bundle>/Contents/MacOS/cway`). | Brief, "Carried over": the CLI is `cway`, the link must be named `cway`, and a `clearway` link would resolve to or be shadowed by the app executable in an in-app terminal. `~/.clearway` is the directory Clearway already owns (`AgentHookScript.swift:12`). |
| D2 | How does the skill name the binary so it works inside and outside a Clearway terminal? | Always by the fixed path `~/.clearway/cway`, never bare `cway`. | The link exists in both places with no `PATH` dependency (brief: "no shell-profile edit"). The skill and the CLI are then always from the same bundle, because Install links both at once, so the instructions never describe a different CLI version than the one run. Rejected: bare `cway`, which fails outside a Clearway terminal. Rejected: `command -v cway \|\| ~/.clearway/cway`, which inside a Debug build's terminal can pick the installed app's `cway` first (brief, "Debug and installed builds can cross") and pairs a skill from one bundle with a CLI from another, for a fallback that buys nothing once the link exists. If the link is missing, the skill tells the agent to ask the user to run Install in Clearway's Settings. |
| D3 | Where does the skill live in the repo and in the bundle? | Repo `Skills/clearway/SKILL.md`, added to the `Clearway` target as `- path: Skills`, `type: folder`, `buildPhase: resources`. Bundle `Contents/Resources/Skills/clearway/SKILL.md`. | A folder reference keeps the directory structure; the skill folder is what gets linked. It cannot sit under `Sources/`: the target excludes `**/*.md` there (`project.yml:30`). Scratchpad probe (xcodegen 2.45.3): with `type: folder, buildPhase: resources` under `sources:`, the built app held `Contents/Resources/Skills/clearway/SKILL.md`. The same probe showed the target-level `resources:` key the project uses today (`project.yml:32-36`) is ignored by xcodegen and produced nothing, so it is not the route. |
| D4 | Which directory gates each agent? | Claude Code: `~/.claude` must exist as a directory; the link goes in `~/.claude/skills`, created if missing. Codex: `~/.codex` must exist as a directory; the link goes in `~/.agents/skills`, created (with `~/.agents`) if missing. Clearway never creates `~/.claude` or `~/.codex`. Operator-confirmed 2026-10-04: `~/.agents` is a shared cross-tool directory, not an agent's config directory, so creating `~/.agents/skills` does not break the "create no agent's config directory" rule. | Brief, Open risks, second bullet leaves the Codex gate to the engineer within "Clearway creates no agent's config directory". `~/.codex` is Codex's config directory and the gate `AgentHookInstaller` already uses for it (`AgentHookInstaller.swift:12-15`), so one rule decides "Codex is installed here" across both features. `~/.agents/skills` is a skills location, not an agent's config directory. Gating on `~/.agents` would skip a Codex user who has no other skills and install for a machine whose `~/.agents` belongs to some other tool (brief, Out of scope: agents other than Claude Code and Codex). `CLAUDE_CONFIG_DIR` and `CODEX_HOME` are not consulted, as the hook installer does not consult them. |
| D5 | Which entries are Clearway's? | An entry is Clearway's when it is a symbolic link (checked with `lstat` semantics, `FileManager.attributesOfItem`, which does not follow links) whose destination string ends in `.app/Contents/Resources/Skills/clearway` for a skill entry, or `.app/Contents/MacOS/cway` for the CLI entry. Its target need not exist. | This recognises Clearway's link from any bundle path, including a dangling one left by a moved app, so Install can repoint it (brief, Open risks, first bullet) and Uninstall can remove it. A link elsewhere, a real file or a real directory is not Clearway's. |
| D6 | What is the on-disk state of one entry? | One of: `agentAbsent` (gate directory missing; skill entries only), `missing` (nothing at the path), `current` (Clearway's, destination equals this bundle's path), `stale` (Clearway's, another bundle or dangling), `foreign` (anything else at the path). | Brief: "Settings shows whether the install is currently in place, judged from what is on disk." Read fresh each time; nothing is stored. |
| D7 | What does Install do? | For the CLI entry and each skill entry whose gate exists: `missing` → create the link (creating `~/.clearway` with mode `0700`, `~/.claude/skills`, or `~/.agents/skills` as needed); `stale` → remove and recreate it pointing at this bundle; `current` → nothing; `foreign` → left untouched and reported. An entry whose agent is absent is skipped. One entry failing does not stop the others. | Brief, In scope and acceptance: skip an absent agent, never overwrite a foreign entry, Install still succeeds for the other agent. The CLI link is installed even when neither agent directory exists: it is useful from any terminal on its own. |
| D8 | What does Uninstall do? | Removes every entry in state `current` or `stale`. Leaves `missing`, `foreign` and `agentAbsent` entries alone, and removes no directory, including a `skills` directory Install created. | Brief: "Uninstall removes only what Install created and leaves everything else in those directories untouched." Removing a directory Install created would need a stored record of having created it, which D6 rules out, and an empty `skills` directory costs nothing. |
| D9 | When is it "installed"? | Installed when no entry is `missing` or `stale` and at least one entry is `current`. `foreign` and `agentAbsent` entries do not block it. | A foreign entry would otherwise keep the button on Install forever, with Uninstall unreachable while Clearway's own links sit on disk. The foreign entry is shown as a warning instead (D10). A `stale` entry (moved app, or links from another copy such as a Debug build) shows Install, which repoints it. |
| D10 | What does Settings show? | A new section, header "Agents", one row: `LabeledContent("Clearway Skill")` with a button titled "Install" or "Uninstall" per D9. Below it, only when there is something to say, one red line in the style of the hook health line (`SettingsView.swift:36-40`): each foreign entry as "`<~/path>` already exists and was left alone.", or, when both agent gates are absent, "No ~/.claude or ~/.codex directory was found, so the skill was not installed." The state is read on appear and after each action. No helper text. | Brief, Constraints: one self-explanatory label, a line only to prevent error. A foreign entry and a missing agent directory each make the button silently do less than its label says, which is the error the line prevents. Paths are home-relative, built from directory names, as `AgentHookInstaller.swift:44-49` does. |
| D11 | Is anything installed at launch? | No. Install and Uninstall run only from the Settings button. No launch path, `onAppear` or test reaches them with the real home directory. | Brief, acceptance: nothing installed by launching the app, including Debug builds and the `ci.sh` test host. Unlike the hook toggle, which defaults on and installs at launch (`ClearwayApp.swift:200`). |
| D12 | How is the installer structured and tested? | `enum SkillInstaller` in `Sources/App/SkillInstaller.swift`, not actor-isolated, Foundation only. Every function takes `home: String` and `bundlePath: String` as parameters, never reading `NSHomeDirectory()` or `Bundle.main` itself. The Settings view passes `NSHomeDirectory()` and `Bundle.main.bundlePath`. | Same shape as `AgentHookInstaller.install(home:)` (`AgentHookInstaller.swift:17-19`), so tests drive it against a temp root and a fake bundle. |
| D13 | What does the skill say? | Frontmatter `name: clearway` and `description` only. The description says it creates, lists and shows Clearway tasks through the Clearway CLI and is for use only when the user asks for that. The body: run `~/.clearway/cway` from inside the project (any worktree); `task create --title <title>` with `--body -` and a heredoc for a multi-line body; one `create` per task when filing several follow-ups; `task list` and `task show <id>`; output is JSON; exit 2 is a usage error, exit 1 a runtime failure, with the message on stderr; a warning on stderr from `list` or `show` means a task file was skipped and must be reported to the user; never generate a UUID, write frontmatter, or read or write `.clearway/` files directly; never create a task the user did not ask for. | Brief, acceptance criteria 1-5 and "Output contract", "`cway` picks the project from the working directory". Only `name` and `description` because Codex requires both and documents no other key for `SKILL.md`; `allowed-tools` is Claude-only and is left out rather than relying on Codex ignoring it. `disable-model-invocation` stays off: the agent must pick the skill up from "create a Clearway task for X". |
| D14 | Do the stderr warnings for skipped task files ship in this task? | Yes (operator-confirmed 2026-10-04). `TaskFiles.loadPool` also returns the paths it skipped: an existing tasks directory it cannot list, a `<UUID>.md` it cannot read or parse, and an existing worktree `TASK.md` it cannot read, parse, or that has no frontmatter `id`. A missing file or directory is not a skip, and neither is a non-UUID filename in the tasks directory. `cway task list` and `task show` print one `cway: warning: skipped '<path>': <reason>.` line per skip on stderr and keep their stdout and exit code. The app ignores the list. | Brief, "Carried over": "Before the skill ships, these cases should at least warn on stderr." The skill is what turns an agent's trust in `[]` into a wrong answer to the user. Today the loader drops these silently (`TaskFiles.swift:58-78`). |
| D15 | Install from a Debug build | Points the links at that Debug bundle. Settings in the installed app then shows Install (D9, `stale`). | Brief, Constraints, last bullet: the operator's choice. |

## Assumptions

Checked against the tree at `206b829`. Two probes ran in the session scratchpad, never in the
repo: a minimal xcodegen app with a folder-reference resource (D3), and `cway task list` run
through a symlink to the built Debug `cway` from `/tmp` (A5).

| # | Assumption | Evidence |
| --- | --- | --- |
| A1 | Claude Code reads a personal skill from `~/.claude/skills/<name>/SKILL.md`, and that entry may be a symlink. | code.claude.com/docs/en/skills, fetched 2026-10-04: "Personal \| `~/.claude/skills/<skill-name>/SKILL.md`"; "a `<skill-name>` entry in the enterprise, personal, or project location can be a symlink to a directory elsewhere on disk. Claude Code reads `SKILL.md` from the target and loads the skill once even if several locations point at the same target." |
| A2 | Claude Code picks up a new skill without restart, except when `~/.claude/skills` itself is new. | Same page: "When you add, edit, or remove a skill under `~/.claude/skills/` … Claude Code picks up the change within the current session, without a restart." and "If you create a top-level skills directory that didn't exist when the session started, run `/reload-skills`". |
| A3 | Codex reads user skills from `$HOME/.agents/skills`, follows symlinks, and requires `name` and `description`. | developers.openai.com/codex/skills (308 to learn.chatgpt.com/docs/build-skills), fetched 2026-10-04: "User-level (`USER`): `$HOME/.agents/skills`"; "Codex supports symlinked skill folders and follows the symlink target when scanning these locations."; frontmatter must include `name` and `description`; "Codex detects skill changes automatically. If an update doesn't appear, restart Codex." Implicit invocation selects a skill from the prompt by its description. |
| A4 | `~/.codex` is the Codex presence gate already in use, and Clearway never creates an agent's directory. | `AgentHookInstaller.swift:12-15, 92`. |
| A5 | `cway` runs correctly when exec'd through a symlink outside the bundle. | Its only non-system rpath is `@executable_path/../Frameworks` and it links only system libraries (`otool -L`, `otool -l` on the Debug build). Run via a scratchpad symlink from `/tmp`, it printed its own "not inside a git repository" error with exit 1, i.e. it launched. |
| A6 | `~/.clearway` already exists on most machines with mode `0700`, created by the hook installer. | `AgentHookInstaller.swift:62-70`. Install still creates it when absent (D7). |
| A7 | Anything under `Sources/` named `*.md` never reaches the bundle. | `project.yml:26-30`. Hence D3's top-level `Skills/`. |
| A8 | The app executable and the test host are the built `Clearway.app`, so a test can read the bundled skill from `Bundle.main`. | Spec 2026-10-03 A11; `Tests/TaskCommandTests.swift:87` already reads `Contents/MacOS/cway` this way. |
| A9 | `TaskFiles.loadPool` has three callers to update. | `WorkTaskManager.swift:318`, `TaskCommand.swift:166`, `Tests/TaskFilesTests.swift:29,40,56,66`. |
| A10 | Settings is one `Form` with sections; the hook health line is a red `Label` under its toggle. | `SettingsView.swift:7-61`. |
| A11 | An in-place app update keeps the bundle path. | Not verified here against Sparkle's docs; it is the brief's own premise ("after an app update in place"). A path change is the brief's accepted risk, and D5/D9 make it visible and repairable. |

## Objective and success criteria

After one click on Install, an agent in any project creates, lists and shows Clearway tasks
through `~/.clearway/cway` without being told how. Criteria 1-4 come from the brief and are
checked by the operator by hand (build agents do not launch the app or drive agents); the rest are
covered by tests.

1. After Install, "create a Clearway task for X" in Claude Code produces a task through `cway` with
   no further steering, and it appears in the app's Tasks list. (Operator.)
2. The same in Codex. (Operator.)
3. Asking either agent to file several follow-ups produces one task per follow-up. (Operator;
   the skill text states it, D13.)
4. The skill has the agent create a task only when asked, and never generate a UUID, write
   frontmatter, or touch `.clearway/tasks`. (Operator; the skill text states it, D13.)
5. Install creates `~/.clearway/cway`, `~/.claude/skills/clearway` and `~/.agents/skills/clearway`
   as symlinks into this bundle, not copies.
6. With `~/.codex` absent, the Codex link is not made and `~/.agents` is not created; likewise
   `~/.claude` for Claude Code; the other entries still install.
7. A foreign entry at any of the three paths is left byte-for-byte untouched by Install and by
   Uninstall, and is reported.
8. A `stale` link (another or a missing bundle) is repointed by Install and removed by Uninstall.
9. Uninstall removes only Clearway's links; sibling entries in `~/.claude/skills`,
   `~/.agents/skills` and `~/.clearway` remain.
10. The reported state follows D6/D9 from disk alone.
11. Nothing calls Install or Uninstall except the Settings button.
12. The built app contains `Contents/Resources/Skills/clearway/SKILL.md` whose frontmatter has
    `name: clearway` and a non-empty `description`, and `~/.clearway/cway task list` works from a
    terminal outside Clearway. (The bundle half by test; the terminal half by the operator.)
13. `list` and `show` warn on stderr for each skipped file, keep exit 0 and
    valid JSON on stdout, and the app's pool is unchanged.
14. `./scripts/ci.sh` passes.

## Commands

From the project's `## Pipeline` section:

| Step | Command |
| --- | --- |
| Regression check (every build task, simplify) | `./scripts/ci.sh` |
| Full gate (sign-off, once) | `./scripts/ci.sh` |

## Files touched

New:
- `Skills/clearway/SKILL.md` (D13).
- `Sources/App/SkillInstaller.swift` (D5-D9, D12).
- `Sources/App/SkillSettingsSection.swift`: the "Agents" section (D10).
- `Tests/SkillInstallerTests.swift`.

Changed:
- `project.yml`: the `Skills` folder reference on the `Clearway` target (D3).
- `Clearway.xcodeproj/project.pbxproj`: regenerated by `xcodegen generate`.
- `Sources/App/SettingsView.swift`: include the section; adjust the fixed frame height if the
  form no longer fits.
- `Sources/Shared/TaskFiles.swift`, `Sources/Shared/TaskCommand.swift`,
  `Sources/App/WorkTaskManager.swift`: the skipped-file list and its warnings (D14).
- `Tests/TaskFilesTests.swift`, `Tests/TaskCommandTests.swift`: D14 cases; the bundle check of
  criterion 12.
- `CLAUDE.md` (root): an Architecture line for `Skills/`. `Sources/App/CLAUDE.md`: per-file notes
  for the two new files.

## Testing

XCTest through `./scripts/ci.sh`. Installer tests use `TempRootTestCase` as `home` and a fake
bundle directory (`<tmp>/A.app` with `Contents/MacOS/cway` and `Contents/Resources/Skills/clearway/SKILL.md`)
as `bundlePath`.

- T1 Both gates present: Install makes three symlinks with the expected destinations; state is
  installed (crit. 5, 10).
- T2 Only `~/.claude`: Codex skipped, no `~/.agents` created; and the mirror case (crit. 6).
- T3 Neither gate: CLI link made, both skill entries `agentAbsent`, the "no directory" message.
- T4 Foreign real directory, foreign real file, and a symlink to an unrelated path at each entry:
  untouched by Install and Uninstall (contents and link destination compared), reported (crit. 7).
- T5 Stale: a link to `<tmp>/B.app/...` and a dangling link are repointed by Install and removed by
  Uninstall (crit. 8).
- T6 Uninstall leaves sibling entries and the `skills` directories in place (crit. 9).
- T7 State matrix for D9, including installed-with-foreign and stale-blocks-installed (crit. 10).
- T8 Install twice is a no-op the second time.
- T9 `Bundle.main.bundleURL/Contents/Resources/Skills/clearway/SKILL.md` exists, parses as
  frontmatter with `name: clearway` and a non-empty `description` (crit. 12).
- T10 (D14) `TaskFiles.loadPool` reports an unreadable `<UUID>.md` (mode `000`), a `<UUID>.md` with
  no frontmatter, an id-less `TASK.md`, and an unlistable tasks directory; it does not report a
  missing `TASK.md`. `cway task list` and `task show` print the warning lines on stderr, exit 0,
  and stdout still decodes (crit. 13).
- Criterion 11 is a review check: `SkillInstaller.install`/`uninstall` have exactly one call site,
  the Settings button action.

## Boundaries

- Always: run `./scripts/ci.sh` after the last edit; pass `home` and `bundlePath` into every
  installer function; check entries without following links.
- Ask first: adding a package dependency; writing anything into an agent's settings file; any
  install outside the button.
- Never: create `~/.claude` or `~/.codex`; overwrite or remove a non-Clearway entry; touch the real
  home directory from a test; launch the app or take screenshots from a build agent.

## Out of scope

- The CLI's verbs (shipped in #265-#267).
- Starting, planning, editing or deleting tasks from an agent; task status.
- The Linear loop.
- Per-project skills in a repo's `.claude/skills/` or `.agents/skills/`.
- Agents other than Claude Code and Codex, including other readers of `~/.agents/skills`.
- Honouring `CLAUDE_CONFIG_DIR` or `CODEX_HOME`.
- Installing on launch.
- The target-level `resources:` key in `project.yml` being ignored by xcodegen, so
  `THIRD-PARTY-LICENSES` is not bundled today (D3 probe; follow-up).
