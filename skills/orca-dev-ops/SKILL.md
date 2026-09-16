---
name: orca-dev-ops
description: Master-session procedure for multi-device development through Orca (Mac mini hub, MacBook and Orca mobile as clients, Claude and Codex task worktrees). Use when acting as the master/coordinator session - planning a task with the user, choosing claude or codex, starting a task worktree, controlling the child, final review, committing, merging into master, pushing, or cleaning up worktrees. Not for child worktree agents; they follow the repository's "Orca worktree rules" in CLAUDE.md/AGENTS.md.
---

# Orca dev ops (master session)

Full rationale: `references/orca-operations-plan.md`. Read it only when a rule below is unclear.

## Mandatory division of work

| Step | Who | How |
|---|---|---|
| Plan with the user | master | Hearing, spec, file scope, acceptance tests |
| Implement and test | child worktree | Agent started by `orca worktree create`, changes left uncommitted |
| Control the child | master only | `orca terminal wait/read/send`, `orca orchestration check/reply`; never hand approval or follow-ups to the user |
| Final review | master | `git -C <worktree> status/diff` against scope and spec |
| Commit, rebase, merge, push | master | `git -C <worktree> commit`, rebase onto `origin/master`, `git merge --ff-only`, `git push origin master` |
| Clean up | master | `orca worktree rm` |

The `orca-dev-ops` plugin ships these hooks and they enforce this for Claude sessions:
- `orca-role-context.sh` (SessionStart) tells each session whether it is master or child.
- `orca-role-guard.sh` (PreToolUse) blocks, in the master checkout, Write/Edit outside `.claude/`, `references/`, or Edit changes of at most 5 lines; edits to child worktrees; raw `git worktree add/remove`. In child sessions it blocks `git commit/push/merge/rebase/cherry-pick/am/revert`, `orca worktree create/rm`, and edits outside the own worktree.
- `orca-child-control.sh` (PostToolUse) injects the control procedure after every `orca worktree create`.
Codex children are not covered by Claude hooks; the repository's AGENTS.md rules and the task prompt must state the same limits.

## Repository setup

A repository joins this workflow only once its own "Orca worktree rules" are in
place; the plugin hooks guard Claude sessions, but the child agents still read
those rules, and Codex children have nothing else. Run `/orca-init` in the
repository to install the generic block into `.claude/CLAUDE.md` (and link
`AGENTS.md` to it). The command is idempotent: it replaces the marked block on
later plugin upgrades and leaves everything outside the markers untouched.
Repository-specific rules - the no-parallel-edit file list and the verification
commands - go outside the markers by hand.

## Invariants

- The Mac mini is the only place that holds checkouts, worktrees, agents, and dev servers. MacBook and phone only connect to it.
- `origin/master` is the source of truth. Never commit on the `master` branch; a local pre-commit / pre-merge-commit hook enforces this. `master` only advances by fast-forward.
- The only permanent worktree is `master`. Never create device-named worktrees (`macbook`, `device-a`). `sandbox` is allowed but is reset to `origin/master` before each use and never merged.
- One task = one worktree = one branch, created from `origin/master`, always through the orca CLI.
- The master session does not implement or read full agent logs.

## Limits

- At most 3 task worktrees at once. Do not start another while at the limit.
- Remove a worktree immediately after merge or abandonment.

## Task lifecycle

1. Plan. Agree the spec with the user (use AskUserQuestion when the user asks for hearing). Decide the agent (`claude` or `codex`), the files the task may edit, acceptance tests, and verification commands. Run `orca worktree ps`; if an active task declares an overlapping file, or the repository's no-parallel-edit list is involved on both sides, do not start.
2. Start the child with the full plan. Name `cc-<topic>` for Claude and `cx-<topic>` for Codex.
   ```sh
   orca worktree create --name cc-<topic> --base-branch origin/master --agent claude \
     --comment "agent:claude scope:<files>" \
     --prompt "<approved plan>. Allowed files: <files>. Acceptance: <tests>. Verification: <commands>. Follow the Orca worktree rules: implement now, leave changes uncommitted, report in four lines."
   ```
   Write long prompts to the scratchpad and pass `--prompt "$(cat <file>)"`. Use `--setup skip` for documentation-only tasks that need no `node_modules`.
3. Control. Find the terminal with `orca terminal list --worktree name:<name>`, run `orca terminal wait --terminal <handle> --for tui-idle` in the background, and read with `orca terminal read --terminal <handle> --screen | tail`. Answer questions and send follow-ups with `orca terminal send --terminal <handle> --text "..." --enter --wait-submit 20`. Ask the user only about decisions outside the approved plan. Never open a second agent session in the same task.
4. Final review. On the four-line report (result / changed files / test results / open issues), check `git -C <worktree> status --short` and `git -C <worktree> diff` against the declared scope and spec. Send required fixes back to the child and repeat.
5. Commit and ship from the master session.
   ```sh
   git -C <worktree> add -A && git -C <worktree> commit -m "<conventional message>"
   git fetch origin && git -C <worktree> rebase origin/master   # if the base moved, have the child rerun the required tests
   git merge --ff-only <task-branch>                           # in the master checkout
   git push origin master
   ```
6. Clean up: `orca orchestration worker-release --dispatch <id>` when the child was started as a supervised worker, then `orca worktree rm --worktree name:<name>`.

## Small changes

Direct edits in the master checkout are allowed only under `.claude/`, `references/`, or as Edit changes of at most 5 lines, and only when no active task overlaps. Commit them on a task branch (`git switch -c <topic>`, commit, `git switch master`, `git merge --ff-only <topic>`, push, delete the branch). Everything else goes through a child worktree.

## Exceptions

- Mac mini unreachable: on the MacBook, clone temporarily, `git fetch`, branch from `origin/master`, push the branch, delete the local branch. Merge later from the master session as usual.
- Dev server for a task: run it inside that task worktree on a distinct port; the master checkout's server only reflects `master`.

## Token discipline

- Keep master conversations short: plan, start, control, review, ship, clean up.
- Task prompts carry the full plan, target files, acceptance, and verification commands so the child does not explore or re-plan.
- Verification follows the repository's verification ladder; the full suite only where the repository requires it or before merge when requested.
