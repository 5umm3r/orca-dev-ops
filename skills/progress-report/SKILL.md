---
name: progress-report
description: Report the progress of every running Orca child task as a percentage, one row per task, in the coordinator (master) session. Use when the user says "進捗報告", "進捗は？", "進み具合", "どこまで進んだ", "progress report", or asks for each task's progress in %. Not for child worktree agents.
---

# Progress report (Orca child tasks)

The coordinator reports where each child task stands without reading full
agent logs and without disturbing the children: no `orca terminal send`, no
`status` request, no consuming `check`. Children send no routine `status`
(see the orca-dev-ops skill), so the screen and the worktree are the sources.

## 1. Collect

Resolve the plugin root as the orca-dev-ops skill does for
`orca-base-ref.sh` (in Claude, `${CLAUDE_PLUGIN_ROOT}`; in other agents,
`../..` from the directory containing this loaded `SKILL.md`), then run, in
the coordinator's own Orca terminal from the main checkout:

```sh
sh "<plugin root>/scripts/orca-progress.sh"
```

Add `--run <run_id>` when the session already uses a Run that is not bound to
this terminal. The script is read-only: it never creates a Run. It prints one
JSON object:

- `tasks[]`: every task not `completed`, with `title`, `status`, `agent`,
  `worktree`, `branch`, `diff` (`files`, `insertions`, `deletions` against
  `HEAD`, `untracked` besides `TASKS.md`), `checklist` (`done`/`total` of the
  `TASKS.md` checkboxes, or null), `screen` (the last 40 non-blank rendered
  screen lines, or null when the read failed), `unread` (unread messages for the
  task: `type`, `subject`).
- `completed[]`: finished tasks of the Run. `idleWorktrees[]`: linked
  worktrees with no unfinished task (done but not yet integrated or removed).
- `unreadOther[]`: unread messages of no unfinished task (`taskId`, `title`,
  `type`, `subject`). An unread `worker_done` here is a task Orca already
  marks completed: report it at 95, review pending.
- `peekFailed`: the mailbox could not be read; `terminalsTruncated`: the
  terminal list was cut short, so some `worktree` fields may be null. Say so
  in the report.

Exit 3: not inside an Orca terminal and no `--run`; 1: `run-current` or
`task-list` failed (receipt on stderr). `run` null means no Run is bound:
there is no child task.

Workflow mode `direct` (session-start context or `scripts/orca-config.sh
show`): there are no child worktrees; say in one line that no child task runs
and stop.

## 2. Estimate the percentage

An estimate, not a measurement; say so once. Read the stage from `screen`
(current action, spinner line with elapsed time, background agents such as a
test-runner), `diff`, and `unread`, and place it in this scale:

| Stage | % |
|---|---|
| Dispatched; reading the prompt and the code, planning | 5-15 |
| Writing the failing test or the first edits | 15-30 |
| Implementing (diff growing, no suite runs yet) | 30-55 |
| Running related tests and fixing failures | 55-75 |
| Related tests pass; docs, cleanup, measurements | 75-85 |
| The repository's full verification running | 85-92 |
| Verification passed; writing `worker_done` | 92-95 |
| Unread `worker_done`; coordinator review pending | 95 |
| Coordinator: review fixes, commit, verification on the base ref | 96-99 |
| Integrated (and published when the workflow publishes) | 100 |

With a `checklist` of at least 3 items, also place the task within its band
by `done / total` (for example 3 of 6 inside 30-55 gives about 42), and show
the count. A task `ready` without an assignee has not started: 0.

Do not raise the number for these; name them instead:

- an unread `question` or an open `ask` on screen: waits on the coordinator;
- an unread `escalation`, an error or blocked screen, or the same test failing
  run after run: blocked;
- `screen` null: the terminal could not be read.

## 3. Report (in the user's language)

- One table, one row per task: task (title and worktree name), %, what it is
  doing now (one line in plain words, no log dump), diff size
  (`+insertions/-deletions`, files).
- Then one or two lines: what comes next (review, integration, which task
  finishes first) and anything needing the user's decision. List
  `idleWorktrees` as done but not integrated.
- Report only what is on screen or in the snapshot. Never claim a test passed
  unless its output was on screen, and do not report partial results that are
  not in the child's report yet.
- After the report, handle any unread message per the orca-dev-ops skill.
