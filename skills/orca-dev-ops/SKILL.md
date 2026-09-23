---
name: orca-dev-ops
description: Master-session procedure for multi-device development through Orca (Claude and Codex task worktrees). Use when acting as the master/coordinator session - planning a task with the user, choosing claude or codex, starting a task worktree, controlling the child, final review, committing, merging into the base ref, or cleaning up worktrees. Not for child worktree agents; they follow the repository's "Orca worktree rules" in CLAUDE.md/AGENTS.md.
---

# Orca dev ops (master session)

This skill holds only this plugin's own rules and judgment criteria. For Orca
command syntax, flags, and behavior, read the official guide (below) and
`orca skills get orchestration` / `orca skills get orca-cli`; do not expect
this file to restate them.

Background and historical rollout notes: `references/orca-operations-plan.md`.
Where it conflicts with this file, this file prevails.

## Official guide

Before the first Orca state-changing command in a session, read the relevant
sections of the Orca guide for the running version (`orca --version` or
`$ORCA_APP_VERSION`): `orca skills get orchestration --full` for coordination
flows, `orca skills get orca-cli` for worktree/terminal/repo commands. Read
only the sections the task needs (the full orchestration guide is about
42 KB). Do not re-read the same version's guide again in the same session.

## Division of work

| Step | Who | How |
|---|---|---|
| Plan with the user | master | Hearing, spec, file scope, acceptance tests |
| Choose model and effort | user | Asked once after plan approval, only for values the user did not already specify |
| Implement and test | child worktree | Started per "Starting a child" below, changes left uncommitted |
| Control the child | master only | See "Communication and state"; never hand approval or follow-ups to the user |
| Final review | master | See "Review, integration, cleanup" |
| Commit, rebase, merge, push | master | Against the base ref (see Invariants) |
| Clean up | master | See "Review, integration, cleanup" |

The `orca-dev-ops` plugin ships these hooks and they enforce this for Claude sessions:
- `orca-role-context.sh` (SessionStart) tells each session whether it is master or child.
- `orca-role-guard.sh` (PreToolUse) applies only inside a checkout that opted
  into these rules (the `orca-worktree-rules` marker, see "Repository
  setup"); outside that scope it does nothing. Role comes from `orca worktree
  current --json` with a git fallback; if the checkout is in scope but the
  role can't be determined, it blocks edits and mutating commands rather than
  guessing. In the master checkout it limits direct Write/Edit to the "Small
  changes" limits below and blocks editing child worktrees and raw `git
  worktree add/remove`. In child sessions it blocks commit/push/merge/rebase,
  worktree create/rm/set, `orca terminal` create/close/send/split, most
  `orca orchestration` verbs (only `ask`/`send`/`check`/`reply` and the
  read-only ones are allowed), edits outside the own worktree, and a set of
  destructive/external commands (`git reset --hard`, `rm -r`/`-f` outside the
  worktree, publish/deploy commands, etc.) — see `hooks/orca-role-guard.sh`
  and `hooks/orca-lib.sh` for the exact lists; path handling covers spaces,
  relative paths, `~`, symlinks, and line continuations. Best effort, not a
  sandbox, and Claude sessions only — Codex is limited by its own sandbox
  flags and AGENTS.md, not this hook.
- `orca-child-control.sh` (PostToolUse) injects a short reminder after the commands that start a child (`orca worktree create`, `orca orchestration worker-start`).
Codex children are not covered by Claude hooks; the Codex sandbox (`-s workspace-write`, see "Starting a child") limits their writes to the worktree, and the repository's AGENTS.md rules and the task prompt must state the same limits.

## Repository setup

A repository joins this workflow only once its own "Orca worktree rules" are in
place; the plugin hooks guard Claude sessions, but the child agents still read
those rules, and Codex children have nothing else. Run `/orca-init` in the
repository to install the generic block into `.claude/CLAUDE.md` (and link
`AGENTS.md` to it). The command is idempotent: it replaces the marked block on
later plugin upgrades and leaves everything outside the markers untouched.
Repository-specific rules - the no-parallel-edit file list and the verification
commands - go outside the markers by hand. This installed block is also what
`orca-role-guard.sh` and `orca-role-context.sh` look for (the
`orca-worktree-rules` marker) to decide a checkout is in scope; without it,
the hooks do nothing there.

## Invariants

- The base ref is whatever the plugin's `scripts/orca-base-ref.sh <repo>`
  prints — in Claude, `sh "${CLAUDE_PLUGIN_ROOT}/scripts/orca-base-ref.sh"
  <repo>`; in other agents, `scripts/orca-base-ref.sh` two directories above
  this SKILL.md (it is not on `PATH` and does not work from an arbitrary cwd).
  Never assume a branch name, never guess `master`/`main`. If it fails, stop
  and ask before creating a branch or integrating.
- Only the master session merges into the base ref; a task branch advances it
  only by fast-forward.
- One task = one worktree = one branch, created from the base ref, always
  through the orca CLI.
- The master session does not implement or read full agent logs.

## Limits

- At most 3 task worktrees at once. Do not start another while at the limit.
- Remove a worktree promptly once the removal conditions in "Review,
  integration, cleanup" hold.

## Starting a child

Prefer `orca orchestration worker-start --agent ... --model ... --effort ...`
when it can express the agent, model, effort, base ref, and the required
permission settings below in one call. On Orca 1.4.206 it cannot pass the
Claude `--dangerously-skip-permissions` flag or the Codex `-a never
-s workspace-write --add-dir ... -c sandbox_workspace_write.network_access=true`
flags, so the compatible path — not a deprecated fallback, the supported route
for these agents — is: `orca worktree create` -> `orca terminal create` with
the full agent command -> wait for `tui-idle` -> `orca orchestration
task-create` + `worker-start --terminal <handle> --worktree <sel>`.

```sh
orca worktree create --name cc-<topic> --base-branch <base ref> \
  --comment "agent:claude model:<model> effort:<grade> scope:<files>" --json
orca terminal create --worktree name:cc-<topic> --title agent \
  --command "claude --dangerously-skip-permissions --model <model> --effort <level>" --json
orca terminal wait --terminal <handle> --for tui-idle --timeout-ms 120000
orca orchestration task-create --run <run_id> --task-title "<topic>" \
  --spec "Read <absolute prompt-file path> and execute it." --json
orca orchestration worker-start --run <run_id> --task <task_id> \
  --terminal <handle> --worktree name:cc-<topic> --json
```

For Codex, use `--command "codex -a never -s workspace-write --add-dir
<worktree git dir> -c sandbox_workspace_write.network_access=true -m <model>
-c model_reasoning_effort=<level>"`, where `<worktree git dir>` is
`git -C <worktree> rev-parse --absolute-git-dir` (the per-worktree
`.git/worktrees/<name>`, not the common `.git`).

- Never change approval policy, sandbox, network, extra writable dirs, or hook
  enablement to shorten a launch command; the flags above are required for
  every launch or restart of that agent, not optional defaults.
- Model/effort: check available values (`claude --help`; `codex debug models`
  for slugs and `supported_reasoning_levels`). Never derive a model ID from a
  display name. Check the grade -> effort mapping below against the chosen
  model; if the requested value is invalid for that model, stop and ask —
  never substitute silently.
- If the user already specified agent/model/effort, do not ask again. Ask for
  unspecified items once, after plan approval, with whatever question
  mechanism this session has; put the recommended option first with a label
  ending in "(Recommended)".
- After start, compare requested vs effective settings. With `--terminal`,
  `worker-start` reports `launch.effective` as null, so confirm from the
  child's screen header instead (Claude: the model line; Codex: the status
  line shows model, approval, and sandbox), or report the value as
  unconfirmed if the screen does not show it. Have the child's first `status`
  message confirm it read the repository's Orca worktree rules; for Claude
  children also confirm the guard is active (e.g. the child runs
  `git commit --dry-run -m probe` and reports that the guard denied it).

Effort mapping (the only part to update when the CLIs change):

| Grade | Claude `--effort` (low, medium, high, xhigh, max) | Codex `model_reasoning_effort` (low, medium, high, xhigh, max, ultra; model-dependent) |
|---|---|---|
| max (最高) | `max` | `max`; `xhigh` when the model lacks `max` |
| high (高) | `high` | `high` |
| normal (普通) | `medium` | `medium` |
| low (低) | `low` | `low` |

Write the task prompt to the scratchpad: the approved plan, the allowed
files, done-when conditions (including which verification must pass —
required, never send a prompt without it), verification commands, and the
repository's "Orca worktree rules". Use `--setup skip` on `orca worktree
create` for documentation-only tasks that need no dependency install. Before
the first multi-step task in a repository, add `TASKS.md` to its
`.git/info/exclude` from the master checkout once; it covers every worktree,
and Codex children cannot write the common `.git` from the sandbox.

## Communication and state

- Keep Task, Dispatch, worktree, and terminal IDs separate in the plan/notes.
- Orchestration messages first; `orca terminal read/send` for supplementary
  input and recovery. Sending text to a terminal is not acceptance: confirm by
  the child's screen or its next message.
- `heartbeat` is liveness only (`worker-show` `lastHeartbeatAt`), never
  progress; progress comes in `status` messages.
- A Delivery may hold several messages (e.g. `status` + `worker_done` arrived
  in one batch). Handle every message, then `--ack` that deliveryId. On
  timeout `deliveryId` is null: do not ack a made-up or previous id.
- `worker_done` is accepted once per Dispatch. Review fixes and any follow-up
  work go in a new Task + Dispatch (`task-create` + `worker-start --terminal`
  on the same terminal/worktree when reusable). Never reuse a settled
  dispatch ID. Ignore rejected, late, or duplicate notifications and any
  message whose payload dispatchId is not the active Dispatch; never treat
  one of those as completing new work.
- Monitoring must match what this coordinator session can actually do:
  - Claude Code: a background `check --wait` whose completion re-invokes the
    session; re-arm after every wake-up.
  - An agent without background re-invocation (e.g. Codex): foreground
    `check --wait` with a timeout below its tool-call limit, repeated while
    the turn lasts; when the turn must end, say that supervision pauses and
    how to resume (`orca orchestration check --run <id>` on the next turn).
  - Orca may inject "You have N orchestration message(s)..." into the
    coordinator terminal, which can wake an idle session; treat it as an
    observed, unverified aid, not the primary monitoring mechanism.
  - Do not assume backgrounding a shell command re-invokes any agent.
  - On timeout: check `worker-show` (state, `observation.agentWait`,
    `lastHeartbeatAt`) and the child's screen; `TASKS.md` is a checklist, not
    a liveness or completion signal.

Send spec additions and mid-run corrections with `orca terminal send`; do not
recreate the worktree or restart the agent for a course correction. Ask the
user only about decisions outside the approved plan. Never open a second
agent session in the same task.

## Review, integration, cleanup

- A child's success report is not review, and review is not integration.
- Check: the requested verification output; scope and spec fit;
  `git -C <wt> status --porcelain=v1 --untracked-files=all` (staged, unstaged,
  untracked); no unrelated files. Stage explicit reviewed paths; never a
  blanket `git add -A`. After a rebase that changed the tested content, rerun
  the required verification through a new Dispatch.
- Children keep changes uncommitted; the coordinator commits and integrates.
- `worker-release` and worktree removal are separate steps. Check the
  outcome, terminal ownership, and other live Dispatches in that worktree
  first. Treat `retained`, `release_pending`, `release_unknown` per Orca's
  meaning; never force-close a dispatch because something stayed open.
- Remove a worktree only when: no live worker or writes remain; review,
  verification, and integration are done; no unsaved or unintegrated work
  would be lost; the user did not ask to keep it; the repo/worktree/branch to
  remove is confirmed. On failure, abort, or push failure: keep the work,
  report state and how to resume; discarding needs explicit approval. Never
  use `--force`, `rm -rf`, broad terminal closes, or `orca orchestration
  reset` as routine cleanup.

## Small changes

Direct edits in the master checkout are allowed within these limits (the PreToolUse guard enforces them):

- Documentation (`*.md` at any depth, `docs/`, `references/`, `.claude/`): any tool, any size.
- Other files: Edit or MultiEdit only (no Write), at most 2 files and 20 changed lines of uncommitted non-documentation change in total, counting existing uncommitted and untracked files.

Conditions: the change does not overlap an active child's declared scope, and
the master runs the repository's required verification before committing.
Documentation-only change: commit directly on the base ref and push. Change
with any non-documentation file: task branch (`git switch -c <topic>`,
commit, switch back, `git merge --ff-only <topic>`, push, delete the branch).
Anything beyond the limits goes through a child worktree.

Every direct edit spends master context. When a change grows past the limits, stop and hand the rest to a child worktree instead of working around the guard.

## Token discipline

- Keep master conversations short: plan, start, control, review, ship, clean up.
- Task prompts carry the full plan, target files, done-when conditions, and verification commands so the child does not explore or re-plan.
- Verification follows the repository's verification ladder; the full suite only where the repository requires it or before merge when requested.
- Once a question is answered, treat the answer as settled; do not revisit it.
