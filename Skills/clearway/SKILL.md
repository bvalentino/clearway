---
name: clearway
description: Create, list and show Clearway tasks through the Clearway CLI. Use only when the user asks to create, list or show Clearway tasks.
---

# Clearway tasks

Clearway keeps a project's tasks as files. Manage them only through the Clearway CLI at
`~/.clearway/cway`. Always run that path, never a bare `cway`.

Run it from inside the project: the main checkout or any of its worktrees. The CLI picks the
project from the working directory.

If `~/.clearway/cway` does not exist, stop and ask the user to click Install in Clearway's
Settings.

## Create a task

```bash
~/.clearway/cway task create --title "Fix the login redirect"
```

For a multi-line body, pass `--body -` and the body on stdin through a heredoc:

```bash
~/.clearway/cway task create --title "Fix the login redirect" --body - <<'EOF'
The redirect drops the query string.

Steps to reproduce: ...
EOF
```

A short body can also go inline: `--body "One line of detail."`.

When filing several follow-ups, run one `task create` per task.

Prints `{"id": "...", "path": "..."}`.

## List and show tasks

```bash
~/.clearway/cway task list
~/.clearway/cway task show <id>
```

`task list` prints a JSON array of tasks with `id`, `title`, `location` (`backlog` or `worktree`),
`worktree` and `path`. `task show` prints one task in the same shape plus its `body`. Take the id
from `task list` or `task create`.

## Exit codes and errors

- `0`: success. Output is JSON on stdout.
- `2`: usage error (wrong command, flag, or argument).
- `1`: runtime failure (not in a git repository, unknown id, file not writable).

The error message is on stderr. Report it to the user.

A line starting `cway: warning:` on stderr from `task list` or `task show` means a task file was
skipped because it could not be read or parsed. The command still succeeded, but tell the user
which file was skipped and why.

## Rules

- Never create a task the user did not ask for.
- Never generate a task id (UUID) or write task frontmatter yourself.
- Never read or write files under `.clearway/` directly; go through `~/.clearway/cway`.
