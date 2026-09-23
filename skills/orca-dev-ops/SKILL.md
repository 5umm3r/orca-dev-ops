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
| Choose model and effort | user | One AskUserQuestion after plan approval; the only pre-implementation question |
| Implement and test | child worktree | Agent started with `orca worktree create` + `orca terminal create`, changes left uncommitted |
| Control the child | master only | `orca terminal wait/read/send`, `orca orchestration check/reply`; never hand approval or follow-ups to the user |
| Final review | master | `git -C <worktree> status/diff` against scope and spec |
| Commit, rebase, merge, push | master | `git -C <worktree> commit`, rebase onto `origin/master`, `git merge --ff-only`, `git push origin master` |
| Clean up | master | `orca worktree rm` |

The `orca-dev-ops` plugin ships these hooks and they enforce this for Claude sessions:
- `orca-role-context.sh` (SessionStart) tells each session whether it is master or child.
- `orca-role-guard.sh` (PreToolUse) blocks, in the master checkout, Write/Edit outside documentation (`*.md`, `docs/`, `references/`, `.claude/`, any size) unless the change is Edit/MultiEdit to at most 2 files and 20 changed lines total; edits to child worktrees; raw `git worktree add/remove`. In child sessions it blocks `git commit/push/merge/rebase/cherry-pick/am/revert`, `orca worktree create/rm`, and edits outside the own worktree; and, from Bash, `rm -r`/`-f` on absolute, `~`, `$HOME`, or `..` targets outside the own worktree, `git reset --hard`, `git clean -f`, `git branch -d/-D`, `git stash drop/clear`, `git update-ref`, `git -C <path outside the own worktree>` with any subcommand other than `status/diff/log/show/rev-parse/ls-files/blame/grep`, and external mutations (`npm/pnpm/yarn publish`, `gh pr merge`, `gh repo delete`, `gh release create/delete/upload/edit`, `supabase db reset/push`, `wrangler deploy/delete`, `firebase deploy`). The matching is best effort, not a sandbox.
- `orca-child-control.sh` (PostToolUse) injects the control procedure after every `orca worktree create`.
Codex children are not covered by Claude hooks; the Codex sandbox (`-s workspace-write`, step 3) limits their writes to the worktree, and the repository's AGENTS.md rules and the task prompt must state the same limits.

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

1. Plan. Agree the spec with the user (use AskUserQuestion when the user asks for hearing). Decide the files the task may edit, acceptance tests, and verification commands. Run `orca worktree ps`; if an active task declares an overlapping file, or the repository's no-parallel-edit list is involved on both sides, do not start. The plan also recommends an agent+model and an effort grade - max (最高) / high (高) / normal (普通) / low (低) - each with a one-line reason. Check current models first with `claude --help` (aliases such as `opus` / `sonnet`) and `codex debug models`; do not rely on a remembered list.
2. Choose model and effort. After the user explicitly approves the plan, call AskUserQuestion exactly once with two questions: (a) agent+model, e.g. "Claude Opus", "Claude Sonnet", "Codex <model>"; (b) effort grade. Put the recommended option first with a label ending in "(Recommended)"; the user may answer with Other. Never skip this question and never start the child before the answer. This is the one explicit exception to "never hand approval or follow-ups to the user".
3. Start the child with the full plan, the chosen model, and the effort mapped below. Name `cc-<topic>` for Claude and `cx-<topic>` for Codex. `--agent` cannot pass CLI flags, so create the worktree and the agent terminal, wait until the agent is ready, then send the prompt:
   ```sh
   orca worktree create --name cc-<topic> --base-branch origin/master \
     --comment "agent:claude model:<model> effort:<grade> scope:<files>" --json
   orca terminal create --worktree name:cc-<topic> --title agent \
     --command "claude --dangerously-skip-permissions --model <model> --effort <level>" --json
   orca terminal wait --terminal <handle> --for tui-idle --timeout-ms 120000
   orca terminal send --terminal <handle> --text "Read <absolute prompt-file path> and execute it." --enter --wait-submit 20
   ```
   Send only this single-line instruction; multi-line `--text` may submit early.
   **Required for every Claude Code child launch or restart:** explicitly pass `--dangerously-skip-permissions` (YOLO mode: bypass permission checks). Do not rely on the parent session's permissions or local config defaults, and do not use bare `--agent claude` for this workflow because it cannot pass this required flag. Preserve the chosen model and effort, and keep the Orca worktree rules and hooks in effect. With permission prompts off, the PreToolUse guard (`orca-role-guard.sh`) is what blocks destructive commands in Claude children.
   For Codex use `--command "codex -a never -s workspace-write --add-dir <worktree git dir> -c sandbox_workspace_write.network_access=true -m <model> -c model_reasoning_effort=<level>"`, where `<worktree git dir>` is the output of `git -C <worktree> rev-parse --absolute-git-dir` (the per-worktree `.git/worktrees/<name>`, not the common `.git`).
   **Required for every Codex child launch or restart:** explicitly pass `-a never` (no approval prompts) and `-s workspace-write` (writes limited to the worktree), plus `--add-dir <worktree git dir>` and `-c sandbox_workspace_write.network_access=true` so git and package installs keep working. Never use `--dangerously-bypass-approvals-and-sandbox`. Do not rely on the parent session's permissions or local config defaults, and do not use bare `--agent codex` for this workflow because it cannot pass these required flags. Preserve the chosen model and effort, and continue to enforce the Orca worktree rules through the task prompt.
   Write the prompt file to the scratchpad: "<approved plan>. Allowed files: <files>. Acceptance: <tests>. Verification: <commands>. Follow the Orca worktree rules: implement now, leave changes uncommitted. When a step does not need the master's input, keep going; stop and ask through `orca orchestration ask` only when you cannot continue without the master, or before anything destructive (deleting files outside this worktree, `git reset --hard`/`git clean -fd`, large dependency changes, database or external-service operations). For multi-step tasks, keep a checklist in `TASKS.md` at the worktree root (add `TASKS.md` to `.git/info/exclude` first), ticking items as done. Report in five lines: result / changed files / verification (commands run + last lines of output) / blocked on master / found." Use `--setup skip` on `orca worktree create` for documentation-only tasks that need no `node_modules`.

   Effort mapping (the only part to update when the CLIs change):

   | Grade | Claude `--effort` (low, medium, high, xhigh, max) | Codex `model_reasoning_effort` (low, medium, high, xhigh, max, ultra; model-dependent) |
   |---|---|---|
   | max (最高) | `max` | `max`; `xhigh` when the model lacks `max` (e.g. gpt-5.5) |
   | high (高) | `high` | `high` |
   | normal (普通) | `medium` | `medium` |
   | low (低) | `low` | `low` |
4. Control. Find the terminal with `orca terminal list --worktree name:<name>`, run `orca terminal wait --terminal <handle> --for tui-idle` in the background, and read with `orca terminal read --terminal <handle> --screen | tail`. Answer questions and send follow-ups with `orca terminal send --terminal <handle> --text "..." --enter --wait-submit 20`. Send spec additions mid-run the same way instead of restarting the child. Ask the user only about decisions outside the approved plan. Never open a second agent session in the same task.
5. Final review. On the five-line report (result / changed files / verification: commands run + last lines of output / blocked on master / found), check the verification line first; if it has no evidence, send it back. Then check `git -C <worktree> status --short` and `git -C <worktree> diff` against the declared scope and spec. List only problems that would block the merge, each with file:line, why it is wrong, and how to show it fails. For large diffs, delegate the diff read to a reviewer subagent to save master context. Send required fixes back to the child and repeat. After a rebase that moved the base, have the child rerun verification.
6. Commit and ship from the master session.
   ```sh
   git -C <worktree> add -A && git -C <worktree> commit -m "<conventional message>"
   git fetch origin && git -C <worktree> rebase origin/master   # if the base moved, have the child rerun verification
   git merge --ff-only <task-branch>                           # in the master checkout
   git push origin master
   ```
7. Clean up: `orca orchestration worker-release --dispatch <id>` when the child was started as a supervised worker, then `orca worktree rm --worktree name:<name>`.

## Small changes

Direct edits in the master checkout are allowed within these limits (the PreToolUse guard enforces them):

- Documentation (`*.md` at any depth, `docs/`, `references/`, `.claude/`): any tool, any size.
- Other files: Edit or MultiEdit only (no Write), at most 2 files and 20 changed lines of uncommitted non-documentation change in total, counting existing uncommitted and untracked files.

Conditions: the change does not overlap an active child's declared scope, and the master runs the repository's required verification before committing. Commit on a task branch (`git switch -c <topic>`, commit, `git switch master`, `git merge --ff-only <topic>`, push, delete the branch), never directly on master. Anything beyond the limits goes through a child worktree.

Every direct edit spends master context. When a change grows past the limits, stop and hand the rest to a child worktree instead of working around the guard.

## Exceptions

- Mac mini unreachable: on the MacBook, clone temporarily, `git fetch`, branch from `origin/master`, push the branch, delete the local branch. Merge later from the master session as usual.
- Dev server for a task: run it inside that task worktree on a distinct port; the master checkout's server only reflects `master`.

## Token discipline

- Keep master conversations short: plan, start, control, review, ship, clean up.
- Task prompts carry the full plan, target files, acceptance, and verification commands so the child does not explore or re-plan.
- Verification follows the repository's verification ladder; the full suite only where the repository requires it or before merge when requested.
- Once a question is answered, treat the answer as settled; do not revisit it.
