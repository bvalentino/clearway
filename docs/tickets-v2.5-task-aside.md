# Tickets v2.5 — Task as Aside Tab + Backlog Flow

## Summary

Reframe the Tasks view as a **backlog** and move active task details into the worktree's aside panel. This follows the natural flow: shape tasks (human judgment) → dispatch to worktree (AI implementation) → review and ship → remove worktree.

## Mental Model

- **Tasks view (dispatch board)** = backlog of tasks that need shaping or haven't been started yet. This is where the human does judgment work — writing descriptions, refining scope, deciding what to dispatch.
- **Worktree (terminal + aside)** = active work. The aside gets a new **Task** tab (alongside Todos and Notes) that shows the task linked to this worktree — its description, status, token usage, error messages, Continue/Restart actions.
- **Remove worktree** = work is shipped. The task can be marked done and the worktree cleaned up.

## What Changes

### Task List Filtering

The dispatch board shows only tasks that need attention:
- `open` tasks — not yet started, may need shaping
- `stopped` tasks — agent failed or stalled, needs human decision

Tasks with status `started` or `done` are **not shown** in the task list — they live in their worktrees. The user sees them by navigating to the worktree in the sidebar.

### New Aside Tab: Task

The aside panel (currently Todos | Notes) gains a **Task** tab:

```swift
private enum SidePanelTab: String, CaseIterable {
    case task = "Task"
    case todos = "Todos"
    case notes = "Notes"
}
```

The Task tab shows (when a worktree has a linked task):
- Task title and status badge
- Task body (the description/plan) — read-only or editable
- Agent metadata: token usage, attempt count, error message
- Action buttons: Continue, Restart, Mark Done
- Last updated timestamp

When the worktree has no linked task, the tab shows an empty state or is hidden.

### Sidebar Task Indicator

Worktrees with a linked task show a subtle indicator in the sidebar:
- Running task: pulsing green dot
- Done task: checkmark
- Stopped task: orange dot

This lets the user see at a glance which worktrees have active/completed agents without opening them.

### Flow

1. **Create task** in the backlog → write title and description
2. **Shape** the task — edit the body, think about scope
3. **Start** the task → creates worktree, launches Claude, task disappears from backlog
4. **Check in** — navigate to worktree, see Task tab in aside for status
5. **Continue** — if agent finished a chunk, click Continue in the Task tab
6. **Ship** — review changes, commit, remove worktree → task is done

### Reopening

If the user closes the worktree (without removing it), the task stays linked. Opening the worktree again shows the Task tab with full context. Starting a new Claude session in the worktree flips the task back to Started (already implemented in v2).

## What's NOT in Scope

- Task editing from the aside (v3 — for now, go back to the backlog to edit)
- Automatic worktree removal on task completion
- Task dependencies or ordering
- Multi-task per worktree

## Key Decisions

- Should `done` tasks appear in the backlog at all? Probably not — they're historical. The worktree (if still around) is the record. Consider a "History" section or filter.
- Should the Task tab auto-select when navigating to a worktree with an active task? Probably yes on first visit, then respect the user's tab choice.
- Should creating a task from a worktree (e.g., "Create Task for this worktree") be supported? Nice to have but not essential.
