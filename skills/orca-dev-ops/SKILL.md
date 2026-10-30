---
name: orca-dev-ops
description: Master-session procedure for multi-device development through Orca (Claude and Codex task worktrees). Use when acting as the master/coordinator session - planning a task with the user, choosing claude or codex, starting a task worktree, controlling the child, final review, committing, merging into the base ref, or cleaning up worktrees. Not for child worktree agents; they follow the repository's "Orca worktree rules" in CLAUDE.md/AGENTS.md.
---

# Orca dev ops (master session)

This skill holds only this plugin's own rules and judgment criteria. For Orca
command syntax, flags, and behavior, read the official guide (below) and
`orca skills get orchestration` / `orca skills get orca-cli`; do not expect
this file to restate them.

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
| Choose agent (claude or codex), model, and effort | user | Launch mode `ask` (default): asked every time after plan approval, one question each with header `Agent`, `Model`, `Effort`; values the user already named, else the settings' `launch` values, are the "(Recommended)" option; the launch gate hook blocks a launch without the answers. Launch mode `semi-auto`: the user chose them once in `.orca-dev-ops.json`; no questions, and the gate allows only those values (see "Repository settings"). With `launch.escalate` set, the user also answers one `Model` question, asked only when the task meets an escalation criterion (see "Model selection guidance"). Launch mode `auto`: the same configured values and no questions at all; with `launch.escalate` set, the coordinator itself picks the default or the escalate tier by the escalation criteria |
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
  changes" limits below, blocks `orca worktree create` at the "Limits"
  worktree count (and when the count cannot be determined), and blocks
  editing child worktrees and raw `git worktree add/remove`. In child
  sessions it blocks editing `.orca-dev-ops.json`, commit/push/merge/rebase,
  worktree create/rm/set, `orca terminal` create/close/send/split, most
  `orca orchestration` verbs (only `ask`/`send`/`check`/`reply` and the
  read-only ones are allowed), acting as another terminal
  (`scripts/orca-mailbox.sh ensure`/`exec`, `orca-wait.sh --terminal`,
  `orca-worker-start.sh --from`, and `orca orchestration` with the Orca
  attestation variables removed or reassigned), edits outside the own worktree, and a set of
  destructive/external commands (`git reset --hard`, `rm -r`/`-f` outside the
  worktree, publish/deploy commands, etc.) — see `hooks/orca-role-guard.sh`
  and `hooks/orca-lib.sh` for the exact lists; path handling covers spaces,
  relative paths, `~`, symlinks, and line continuations. Best effort, not a
  sandbox, and Claude sessions only — Codex is limited by its own sandbox
  flags and AGENTS.md, not this hook.
- `orca-child-control.sh` (PostToolUse) injects a short reminder after the commands that start a child (`orca worktree create`, `orca orchestration worker-start`).
- `orca-launch-gate.sh` (PreToolUse, Bash) gates a child agent launch (`orca terminal create --command` running `claude` or `codex`, or `orca orchestration worker-start --agent` without `--terminal`; `scripts/orca-terminal-create.sh --command` invocations, with the script as any word of the command (run directly, through a shell with options, `.`/`source`, or another wrapper), are gated the same way, and so are `scripts/orca-mailbox.sh exec worker-start --agent` without `--terminal`, launches behind `env -u VAR`/`env VAR=...`, and launches inside `sh -c` strings). In launch mode `ask` (the default) it blocks the launch until this session's transcript holds answered questions with header `Agent`, `Model`, and `Effort` after the last successful launch; a failed launch does not reset that, so its retry needs no new question, and a missing or unrecognized transcript is denied. In launch modes `semi-auto` and `auto` it reads no transcript for the default tier and allows the launch only when its agent, model, and effort equal the configured `launch` values (Claude `--model`/`--effort`; Codex `-m`/`--model` and `-c model_reasoning_effort=`; worker-start `--agent`/`--model`/`--effort`); with `launch.escalate` set, the `launch.agent` with the escalate model and effort is allowed as well: in `auto` without reading the transcript, in `semi-auto` only after an answered `Model` question since the last successful launch. Anything else, including a value the command leaves out, is denied. It covers Codex coordinators too: `orca-init` installs it into the repository's `.codex/hooks.json` (see "Repository setup").
Apart from the launch gate, Codex sessions are not covered by these hooks; the Codex sandbox (`-s workspace-write`, see "Starting a child") limits their writes to the worktree, and the repository's AGENTS.md rules and the task prompt must state the same limits.

## Repository setup

A repository joins this workflow only once its own "Orca worktree rules" are in
place; the plugin hooks guard Claude sessions, but the child agents still read
those rules, and Codex children have nothing else. Use the `orca-init` skill
in the target repository: Claude Code's `/orca-init`, or Codex's `$orca-init`
(also selectable through `/skills`). Read [the shared initialization
procedure](../orca-init/SKILL.md), resolved relative to this file, before
running it. That skill resolves the installed plugin root and passes an
explicit repository path to `scripts/orca-init.sh` to install the generic
block into `.claude/CLAUDE.md` (and link `AGENTS.md` to it).
Initialization is idempotent: it replaces the marked block on
later plugin upgrades and leaves everything outside the markers untouched.
Repository-specific rules - the no-parallel-edit file list and the verification
commands - go outside the markers by hand. This installed block is also what
`orca-role-guard.sh` and `orca-role-context.sh` look for (the
`orca-worktree-rules` marker) to decide a checkout is in scope; without it,
the hooks do nothing there.

The initialization script also installs the launch gate
for Codex coordinators into the repository: copies of `orca-launch-gate.sh`
and `orca-lib.sh` in `.codex/hooks/` (refreshed on every run; do not edit
them) and a `PreToolUse` `Bash` entry in `.codex/hooks.json` that runs the gate
from the checkout's top level. An existing `.codex/hooks.json` without the
entry needs confirmation (`--apply`) and keeps its other hooks. Codex asks the
user once to trust new or changed hooks at its next start; until then the gate
does not run there.

Initialization also creates `.orca-dev-ops.json` in the main checkout when it is
missing, with every key that has a default (see "Repository settings"; no
`--apply` needed, `--no-settings` skips it). An existing file is validated and
its missing keys reported; the user chooses whether to add them
(`--settings=add`) or reset the file to the defaults (`--settings=reset`, with a
`.bak` backup).

## Repository settings

A repository can tune this workflow with an optional `.orca-dev-ops.json` at
its top level (full reference: `docs/config.md` in the plugin): `launch`
(mode `ask`, `semi-auto`, or `auto`, plus `agent`, `model`, `effort`, and in
`semi-auto` or `auto` an optional `escalate` with `model` and `effort`), `limits`
(`maxWorktrees`, `smallChangeFiles`, `smallChangeLines`), and `monitor`
(`wakeOnStatus`, `timeoutMs`). Without the file, the built-in defaults apply,
which are the behavior this skill describes (launch mode `ask`, 3 worktrees,
2 files and 20 lines, 590000 ms); initialization writes exactly these values
when it creates the file, and they stay as written when a later plugin version
changes a default. The hooks and scripts read it from the main
checkout only, never from a child worktree. An invalid file is ignored as a
whole (defaults, launch mode `ask`) with a warning in the session context and
in every deny.

Once per session, before the first launch, run the plugin's
`scripts/orca-config.sh show` (resolved the same way as `orca-base-ref.sh` in
"Invariants") in the repository: it prints the effective settings, and stderr
names the source file and any validation error (exit 3 when invalid). Report
an invalid file to the user. The settings belong to the user: never edit
`.orca-dev-ops.json` to get past a limit or the launch gate, and never add
keys for the invariants below (approval, sandbox, and network flags,
`--dangerously-skip-permissions`, trust prompts, the base ref, fast-forward
integration, `--force`); the loader rejects unknown keys.

## Invariants

- The base ref is whatever the plugin's `scripts/orca-base-ref.sh <repo>`
  prints — in Claude, `sh "${CLAUDE_PLUGIN_ROOT}/scripts/orca-base-ref.sh"
  <repo>`; in other agents, resolve the plugin root as `../..` from the
  directory containing this loaded `SKILL.md`, then use that root's
  `scripts/orca-base-ref.sh` (it is not on `PATH`). Expand catalog root
  aliases before resolving the path; do not guess a cache version.
  Never assume a branch name, never guess `master`/`main`. If it fails, stop
  and ask before creating a branch or integrating.
- Only the master session merges into the base ref; a task branch advances it
  only by fast-forward.
- One task = one worktree = one branch, created from the base ref, always
  through the orca CLI.
- The master session does not implement or read full agent logs.

## Limits

- At most `limits.maxWorktrees` task worktrees at once (default 3). Do not
  start another while at the limit; the guard blocks `orca worktree create`
  at the limit, and also when `orca worktree list` cannot give the count.
- Remove a worktree promptly once the removal conditions in "Review,
  integration, cleanup" hold.

## Starting a child

The coordinator's Run belongs to a mailbox terminal, not to the
coordinator's own agent terminal (see "Communication and state"). Once per
session, before the first child, run the plugin's `scripts/orca-mailbox.sh
ensure` (resolved the same way as `orca-base-ref.sh` in "Invariants"): it
finds the plain shell pane with pane title `orca-mailbox` in the main
checkout or splits one off the coordinator's own pane (`--direction
vertical|horizontal`, default vertical; run it inside the coordinator's Orca
terminal), binds a Run to it when none is bound, and prints
`{"terminal": "<M>", "run": "<run_id>"}`. Exit 4: several `orca-mailbox`
panes, handles on stderr (close all but one, then rerun); 1: another
failure. The pane closes with the coordinator's tab. From then on every coordinator verb acts as M:
`orca-mailbox.sh exec <verb> ...` adds `--from M` (`--terminal M` for
`check`), `orca-worker-start.sh --from M`, and `orca-wait.sh --terminal M`.
`exec` never creates the pane; exit 3 means it is gone, so run `ensure`
again. Do not rely on `run-current` of the coordinator's own terminal.

Prefer `orca orchestration worker-start --agent ... --model ... --effort ...`
(as `orca-mailbox.sh exec worker-start --agent ...`)
when it can express the agent, model, effort, base ref, and the required
permission settings below in one call. On Orca 1.4.206 it cannot pass the
Claude `--dangerously-skip-permissions` flag or the Codex `-a never
-s workspace-write --add-dir ... -c sandbox_workspace_write.network_access=true`
flags, so the compatible path — not a deprecated fallback, the supported route
for these agents — is: `orca worktree create` -> the plugin's
`scripts/orca-terminal-create.sh` with the full agent command (resolved the
same way as `orca-base-ref.sh` in "Invariants") -> wait for `tui-idle` ->
`orca-mailbox.sh exec task-create` + `orca-worker-start.sh --from <M>
--terminal <handle> --worktree <sel>`.

`orca terminal create` into a worktree created moments earlier can fail with
`Timed out waiting for terminal handle after creation` although the agent
starts minutes later. That is not a failure, and never recreate the terminal
by hand: that opens a second agent session in the same task. The script waits
for the terminal (default 180 s), recreates at most once and only when
nothing appeared, and checks for duplicates. Exit 0: one agent terminal, its
handle on stdout (use it for `wait` and `worker-start --terminal`); 3: nothing
appeared after one recreate (stop and report); 4: two or more agent terminals,
all handles on stdout (keep one, close the others that have received no
Dispatch with `orca terminal close --terminal <handle>`, then continue with
the remaining one); 5: a terminal exists but shows no agent header (do not
recreate; stop and report); 1: another failure. The script can run up to
twice `--timeout` plus the create calls (about 6+ minutes by default), longer
than a default tool-call timeout: run it with a tool timeout above that
(Claude Code Bash: `timeout` 600000 ms), or in the background and read its
output when it exits; never start another create while it runs.

`tui-idle` can return before Orca recognizes the agent. Before
`worker-start`, confirm with `orca terminal read --terminal <handle>` that the
agent header (e.g. `Opus 5.5 with high effort`) is on screen. If
`worker-start` still fails with "not a recognized agent", wait a few seconds
and retry once with the same task ID; never re-run `task-create`. If the retry
also fails, stop and report. The plugin's `scripts/orca-worker-start.sh`
(resolved the same way as `orca-base-ref.sh` in "Invariants") does the header
check and the single retry in one step: exit 0 started, 3 no header (not
called), 4 failed twice, 1 other failure.

```sh
sh "${CLAUDE_PLUGIN_ROOT}/scripts/orca-mailbox.sh" ensure   # once per session: {"terminal": "<M>", "run": "<run_id>"}
orca worktree create --name cc-<topic> --base-branch <base ref> \
  --comment "agent:claude model:<model> effort:<grade> scope:<files>" --json
sh "${CLAUDE_PLUGIN_ROOT}/scripts/orca-terminal-create.sh" --worktree name:cc-<topic> --title agent \
  --command "claude --dangerously-skip-permissions --settings '${CLAUDE_PLUGIN_ROOT}/templates/child-settings.json' --model <model> --effort <level>"
orca terminal wait --terminal <handle> --for tui-idle --timeout-ms 120000
sh "${CLAUDE_PLUGIN_ROOT}/scripts/orca-mailbox.sh" exec task-create --run <run_id> --task-title "<topic>" \
  --spec "Read <absolute prompt-file path> and execute it." --json
sh "${CLAUDE_PLUGIN_ROOT}/scripts/orca-worker-start.sh" --from <M> --run <run_id> --task <task_id> \
  --terminal <handle> --worktree name:cc-<topic>
```

The `--settings` file turns off Claude Code push notifications for the child
only; it is required on every Claude child launch or restart like the other
flags. Orca app notifications (banners/sounds) are not covered, because Orca
1.4.232 has no CLI to mute a worktree. Codex children need nothing (Codex
sends no push notification here).

For Codex, the script works the same way with `--command "codex -a never -s workspace-write --add-dir
<worktree git dir> -c sandbox_workspace_write.network_access=true -m <model>
-c model_reasoning_effort=<level>"`, where `<worktree git dir>` is
`git -C <worktree> rev-parse --absolute-git-dir` (the per-worktree
`.git/worktrees/<name>`, not the common `.git`).

- First launch in a repository the agent has not trusted blocks at stage
  `agent_readiness`, and Codex may separately show an update prompt; never
  accept either on the coordinator's own initiative (see "Known
  constraints").
- Never change approval policy, sandbox, network, extra writable dirs, or hook
  enablement to shorten a launch command; the flags above are required for
  every launch or restart of that agent, not optional defaults.
- Model/effort: check available values (`claude --help`; `codex debug models`
  for slugs and `supported_reasoning_levels`). Never derive a model ID from a
  display name. Check the grade -> effort mapping below against the chosen
  model; if the requested value is invalid for that model, stop and ask —
  never substitute silently.
- Launch mode `ask` (the default, and whenever the settings file is missing
  or invalid): always ask for the agent, model, and effort after plan
  approval, before every launch, even when the user already named them: one
  question each with header `Agent`, `Model`, and `Effort` (AskUserQuestion
  in Claude, `request_user_input` in Codex; the async
  `request_user_input_async` has no header, so start each title with
  `[Agent]`, `[Model]`, `[Effort]`). Put the recommended option first with a
  label ending in "(Recommended)"; values the user already named are that
  option, otherwise the settings' `launch.agent`/`model`/`effort` when set.
  Never infer or pick the values yourself. The launch gate hook blocks a
  launch until these answers exist in this session after the last successful
  launch; retrying a failed launch needs no new question.
- Launch mode `semi-auto`: do not ask; launch with exactly the configured
  `launch.agent`, `launch.model`, and `launch.effort` (the effort mapping
  below does not apply; the value is passed as is). The gate denies any other
  value. If the task needs different values, ask the user (with the questions
  above) and have them change the settings; do not work around the gate.
  With `launch.escalate` set, a task that meets an escalation criterion (see
  "Model selection guidance") gets one question with header `Model`: the
  escalate model first, labeled "(Recommended)", then the default model. Launch
  with the model the user answered, with the configured `launch.escalate`
  values for the escalate model; never raise the model without the answer. A
  task that meets no criterion launches with the default values and no
  question.
- Launch mode `auto`: do not ask; launch with exactly the configured
  `launch.agent`, `launch.model`, and `launch.effort`, or, with
  `launch.escalate` set and a task that meets an escalation criterion (see
  "Model selection guidance"), with `launch.agent` and the configured
  `launch.escalate` model and effort. The coordinator decides the tier; the
  values are passed as is, and the gate denies any other value. Record the
  decision in the worktree `--comment` (`tier:escalate reason:(<criterion
  letter>)`, e.g. `tier:escalate reason:(b)`, or `tier:default`) and state the
  chosen tier and criterion in the launch report to the user. If the task
  needs values outside both tiers, ask the user (with the questions above) and
  have them change the settings; do not work around the gate. Without
  `launch.escalate`, `auto` behaves like `semi-auto`.
- After start, compare requested vs effective settings. With `--terminal`,
  `worker-start` reports `launch.effective` as null, so confirm from the
  child's screen header instead (Claude: the model line; Codex: the status
  line shows model, approval, and sandbox), or report the value as
  unconfirmed if the screen does not show it — including when the screen
  shows a value that does not change with the requested effort (see "Known
  constraints"). Have the child's first `status`
  message confirm it read the repository's Orca worktree rules; for Claude
  children also confirm the guard is active (e.g. the child runs
  `git commit --dry-run -m probe` and reports that the guard denied it).

Effort mapping (the only part to update when the CLIs change):

| Grade | Claude `--effort` (low, medium, high, xhigh, max) | Codex `model_reasoning_effort` (low, medium, high, xhigh, max, ultra; model-dependent) |
|---|---|---|
| max | `max` | `max`; `xhigh` when the model lacks `max` |
| high | `high` | `high` |
| normal | `medium` | `medium` |
| low | `low` | `low` |

### Model selection guidance

Guidance for the user's choice when the launch mode is `ask` or when editing
`launch` settings. In `semi-auto` and `auto` modes the configured values apply
and the gate denies others, except the `launch.escalate` tier described below:
in `semi-auto` the user picks it with one `Model` question, in `auto` the
coordinator picks it without a question.

- Well-scoped implementation and bug-fix tasks: Claude Sonnet 5.5 is the
  default choice (comparable to Opus 5.5 on coding benchmarks at half the
  price).
- Complex, open-ended, long-running work that needs sustained judgment, large
  refactors, and systems design: Opus 5.5.
- High-volume investigation, classification, extraction, summarization, and
  subagent exploration: Haiku 5.5. Not for complex agentic coding.

Escalation (launch mode `semi-auto` or `auto` with `launch.escalate`): the
default model stays the default; the escalate tier is for tasks that meet one
of these criteria:

- (a) Design decisions remain open, or the spec is ambiguous.
- (b) The changes span several modules, or change the meaning of safety
  mechanisms such as hooks and the launch gate.
- (c) A long, multi-step verification loop is expected.
- (d) The same child needed two rework Dispatches on the default model.

In `semi-auto`, when a criterion is met, ask one question with header `Model`;
the options are the escalate model first with "(Recommended)", then the
default model. The user's answer decides. The gate checks that a `Model`
question was answered after the last successful launch, not which option was
chosen, so the coordinator itself must launch with the model the user
selected.

In `auto`, ask nothing: the coordinator applies the same criteria (a)-(d)
itself and launches on the escalate tier when one is met, on the default tier
otherwise. The gate allows either tier without reading the transcript, so the
decision rests on the coordinator; record it in the worktree `--comment` and
the launch report (see "Starting a child").

Sources (primary):

- https://www.anthropic.com/claude-sonnet-5-5 (2026-09-28): Terminal-Bench
  4.0 Sonnet 5.5 70.6% vs Opus 5.5 66.4%; CursorBench 4.0 55.5% vs 57.8%.
  Anthropic states Opus 5.5 "remains clearly stronger at complex, open-ended
  work requiring sustained judgment".
- https://www.anthropic.com/claude-haiku-5-5 (2026-10-07): Haiku 5.5
  Terminal-Bench 4.0 39.2%; recommended for subagent tasks, with Sonnet 5.5 /
  Opus 5.5 for complex agentic coding.
- https://platform.claude.com/docs/en/about-claude/models/choosing-a-model

Benchmark conditions (effort levels) differ between models, so measure on your
own tasks before changing defaults.

Write the task prompt to the scratchpad: the approved plan, the allowed
files, done-when conditions (including which verification must pass —
required, never send a prompt without it), verification commands, and the
repository's "Orca worktree rules". Use `--setup skip` on `orca worktree
create` for documentation-only tasks that need no dependency install. Before
the first multi-step task in a repository, add `TASKS.md` to its
`.git/info/exclude` from the master checkout once; it covers every worktree,
and Codex children cannot write the common `.git` from the sandbox.

## Communication and state

The Orca guide owns the lifecycle rules: Delivery processing and `--ack`,
once-per-Dispatch `worker_done`, heartbeat vs progress, and completion
accounting (reuse, retain, or release). This section adds only this
workflow's choices and what live tests showed.

- Keep Task, Dispatch, worktree, and terminal IDs separate in the plan/notes.
  Use one Run per coordinator session, owned by the mailbox terminal M: run
  `orca-mailbox.sh ensure` once per session (it reuses the Run bound to M
  and creates one only when none is bound) instead of `run-current` or
  `run-create` on the coordinator's own terminal, and send every coordinator
  verb as M: `orca-mailbox.sh exec task-create|send|reply ...`,
  `orca-worker-start.sh --from <M>`, `orca-wait.sh --terminal <M>` (see
  "Starting a child" and "Known constraints").
- Orchestration messages first; `orca terminal read/send` for supplementary
  input and recovery. Sending text to a terminal is not acceptance: confirm by
  the child's screen or its next message.
- A child sometimes sends a heartbeat or repeats an earlier question instead
  of the first `status`; answer duplicates consistently and ask again for the
  status if it never arrives (see "Known constraints").
- The child's `worker_done` body follows the preamble (three sentences); the
  verification commands and output come in the `status` just before it, and
  changed paths in `--files-modified`. Review against those, not the summary.
- Review fixes and follow-ups reuse the same terminal/worktree through a new
  Task + Dispatch (`orca-mailbox.sh exec task-create` +
  `orca-worker-start.sh --from <M> --terminal <handle>`). Ignore any
  message whose payload dispatchId is not the active Dispatch.
- Monitoring must match what this coordinator session can actually do:
  - Claude Code: arm a background
    `sh "${CLAUDE_PLUGIN_ROOT}/scripts/orca-wait.sh" --run <run_id> --terminal <M> --out <scratchpad>/orca-wait-<run_id>.json`
    (the plugin's `scripts/orca-wait.sh`, resolved the same way as
    `orca-base-ref.sh` in "Invariants") whose completion re-invokes the
    session; when re-invoked, read the `--out` file, not the background
    task's output file (see "Known constraints"):
    ```sh
    jq -r '.delivery.result.deliveryId, (.delivery.result.messages[]? | "[\(.type)] \(.subject // "")\n\(.body)\n\(.payload)"), (.deferred[]? | "[deferred status] \(.body)"), (.error // empty | "[error] \(.)")' <scratchpad>/orca-wait-<run_id>.json
    ```
    It wraps `check --terminal <M> --wait` with no `--types`, so the wait
    covers every message type; it acknowledges
    batches of only heartbeats and statuses and keeps waiting, and exits 0
    with `{"delivery": ..., "deferred": [...]}` on a Delivery that holds a
    `worker_done`, `escalation`, `question`, or another type, 2 on timeout
    (`delivery` null), 1 on an Orca error. `deferred` holds the `status`
    messages it already acknowledged; read them, they are not delivered
    again. The returned Delivery is not acknowledged: handle every message in
    it, `--ack` its deliveryId (e.g. `orca-mailbox.sh exec check --run
    <run_id> --ack <deliveryId> --json`), then re-arm. The timeout and whether status
    wakes come from `monitor` in the settings (default 590000 ms, statuses
    deferred). The first wait after a start uses `--wake-on-status`, so the
    first `status` is read without waiting for `worker_done`.
  - An agent without background re-invocation (e.g. Codex): the same
    `orca-mailbox.sh exec check --run <id> --wait` (no `--types`) in the
    foreground with a timeout below its tool-call limit, repeated while the
    turn lasts; when the turn must end, say that supervision pauses and how
    to resume (`orca-mailbox.sh exec check --run <id>` on the next turn).
  - Orca types "You have N (new) orchestration message(s)..." into the
    terminal that owns the Run inbox when its agent status is idle and no
    untyped `check --wait` is live, and sends Enter 500 ms later. It does not
    check whether the user is typing, so the text can land in the user's
    draft and submit it; a waiter that registers within the 500 ms (the gap
    between two waits of `orca-wait.sh`) skips the Enter but leaves the text
    in the prompt (see "Known constraints"). The mailbox terminal avoids
    this: it runs no agent, so it has no agent status and nothing is typed
    into it, and the coordinator's own terminal no longer owns the inbox.
    Closing the mailbox terminal fences its Run; close it only when no
    Dispatch of the Run is live (the next `ensure` creates a new terminal
    and Run).
  - Do not assume backgrounding a shell command re-invokes any agent.
  - On timeout: check `worker-show` (state, `observation.agentWait`,
    `lastHeartbeatAt`) and the child's screen; `TASKS.md` is a checklist, not
    a liveness or completion signal. `orca terminal wait --for tui-idle` is
    not a substitute for this with Codex (see "Known constraints").

Send spec additions and mid-run corrections with `orca-mailbox.sh exec send
--to dispatch:<dispatch_id>`; the child picks them up with `check` at its next
checkpoint (the enqueue does not interrupt it). Fall back to `orca terminal
send` only when the child's messages and screen show it has not picked the
follow-up up and is not checking. Do not recreate the worktree or restart the
agent for a course correction. Ask the
user only about decisions outside the approved plan. Never open a second
agent session in the same task.

## Review, integration, cleanup

- A child's success report is not review, and review is not integration.
- Check: the requested verification output; scope and spec fit;
  `git -C <wt> status --porcelain=v1 --untracked-files=all` (staged, unstaged,
  untracked); no unrelated files; for a Codex worktree,
  `orca terminal list --worktree <child>` for terminals the coordinator did
  not create (see "Known constraints"). Stage explicit reviewed paths; never
  a blanket `git add -A`. After a rebase that changed the tested content,
  rerun the required verification through a new Dispatch.
- Children keep changes uncommitted; the coordinator commits and integrates.
- After reviewing a `worker_done`, include the output of the plugin's
  `scripts/orca-usage.sh <worktree path>` (resolved the same way as
  `orca-base-ref.sh` in "Invariants") in the report to the user. Run it
  before removing the worktree. Exit 3 means "usage unavailable", not a
  failure.
- `worker-release` (per the guide's completion accounting) and worktree
  removal are separate steps. Before removal, check terminal ownership and
  other live Dispatches in that worktree. See "Known constraints" for the two
  `retained` reasons observed live.
- Remove a worktree only when: no live worker or writes remain; review,
  verification, and integration are done; no unsaved or unintegrated work
  would be lost; the user did not ask to keep it; the repo/worktree/branch to
  remove is confirmed. On failure, abort, or push failure: keep the work,
  report state and how to resume; discarding needs explicit approval. Never
  use `--force`, `rm -rf`, broad terminal closes, or `orca orchestration
  reset` as routine cleanup. `orca worktree rm` refuses on its own while
  untracked files remain; delete only the reviewed test files first, with
  approval (see "Known constraints").

## Small changes

Direct edits in the master checkout are allowed within these limits (the PreToolUse guard enforces them):

- Documentation (`*.md` at any depth, `docs/`, `references/`, `.claude/`): any tool, any size.
- Other files: Edit only (no Write), at most `limits.smallChangeFiles` files (default 2) and `limits.smallChangeLines` changed lines (default 20) of uncommitted non-documentation change in total, counting existing uncommitted and untracked files.

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

## Known constraints (verified 2026-09-23 and 2026-09-24, Orca 1.4.206 and 1.4.209, codex-cli 0.156.0, Claude Code 2.1.280 and 2.1.281)

Confirmed by live tests in both directions (Claude coordinator with a Codex
child, and Codex coordinator with a Claude child), each completing start ->
status -> ask/reply -> worker_done -> a review-fix Dispatch -> review ->
release -> worktree removal.

- A repository under `/tmp` or `$TMPDIR` is writable from any Codex sandbox
  even with `-s workspace-write`, which otherwise blocks writes to `$HOME`
  and the main checkout. Never place a repository or worktree there.
- The Orca CLI is reachable from inside the Codex sandbox, and terminals
  created through Orca run outside it. A Codex coordinator whose sandbox
  makes the common `.git` read-only can use a worktree-scoped Orca terminal
  to commit or delete files — deliberate work outside its own sandbox, and
  it must say so. A Codex child could do the same; only the `AGENTS.md`
  rules stop it (a Claude child is stopped by the guard).
- First launch in a repository the agent has not trusted shows a trust
  prompt (both Codex and Claude); Orca reports
  `blockedReason: agent-trust-workspace` and `worker-start` fails at stage
  `agent_readiness`. The coordinator never accepts trust on its own — it is
  a global setting the user grants once. On codex-cli 0.156.0, a session-level
  `-c projects."<path>".trust_level` override did not take effect.
- Codex may show an update prompt at launch; dismiss it with Esc, never
  "Update now" (a global install change).
- `orca terminal wait --for tui-idle` can report idle while Codex is still
  working; do not use it alone to decide a Codex session stopped.
- With `--terminal` binding, the Claude screen's effort indicator showed
  `[medium]` for both `--effort low` and `--effort high`; treat effort as
  unconfirmed from the screen alone unless another source shows it.
- Read from Orca 1.4.243/1.4.244's bundled code: Orca writes "You have N
  (new) orchestration message(s)..." into the terminal that owns a Run inbox
  (`run.coordinator_handle`) whenever that terminal's agent status is idle
  and no untyped `check --wait` is live, then Enter 500 ms later. It does not
  look at whether the user is typing, so it can splice the text into the
  user's draft and submit it. When a waiter registers inside those 500 ms
  (the gaps between consecutive `check --wait` calls of `orca-wait.sh`), it
  skips the Enter but leaves the text in the prompt. There is no Orca
  setting to turn this off.
- Hence the mailbox pane (verified live on Orca 1.4.243): a plain shell split
  off the coordinator's pane (`orca terminal split --terminal
  $ORCA_TERMINAL_HANDLE`, then `orca terminal set-pane-title --title
  orca-mailbox`; `terminal list` shows it as `paneTitle`, while `title` is
  the tab's) owns the Run. A message sent to `run:<id>`
  put no text into it (it has no agent status) nor into the coordinator's
  agent terminal; `check --terminal <M> --run <id>` returned the Delivery and
  `--ack` worked the same way. Closing the mailbox pane fences its Run.
  `check` takes `--terminal`, never `--from`; every other coordinator verb
  (`run-create`, `run-current`, `task-create`, `worker-start`, `send`,
  `reply`, `ask`) takes `--from`.
- `run-create --from <M>` from another terminal fails with `consumer_fenced`
  ("This terminal is attested as <own> and cannot act as <M>") while the
  Orca terminal environment is present, and succeeds with
  `ORCA_TERMINAL_HANDLE ORCA_PANE_KEY ORCA_AGENT_PANE ORCA_AGENT_LAUNCH
  ORCA_AGENT_LAUNCH_TOKEN ORCA_TAB_ID` removed. Removing those attestation
  variables lets any terminal act as any other; that is an Orca property this
  plugin cannot close. The coordinator uses it only for its mailbox
  (`orca-mailbox.sh`, `orca-wait.sh --terminal`, `orca-worker-start.sh
  --from`); children are kept off it by the role guard (Claude) and the
  AGENTS.md rules (Codex).
- Children sometimes send a heartbeat or repeat an earlier question instead
  of the first `status` message; answer duplicates consistently, and ask
  again for the status if it never arrives.
- `orca worktree rm` refuses while untracked files remain (never `--force`;
  delete only the reviewed test files first, with approval). It deletes a
  task branch with no commits of its own but keeps one with commits.
  `worker-release` returns `retained/external_terminal` for a
  `--terminal`-bound dispatch and `retained/no_owned_resource` for one that
  failed before start.
- A coordinator terminal is bound to one Run at a time: `run-create` rebinds
  it, and `task-create`/`worker-start` on the previous Run then fail with
  `consumer_fenced`. Use one Run per coordinator session (`orca-mailbox.sh
  ensure` reuses the Run bound to the mailbox terminal); start a new Run
  only when no Dispatch of the current Run is still live.
- Observed on Orca 1.4.209: `check --wait --json` emits keepalive JSON lines
  (`{"_keepalive":true,"_heartbeat":true,...}`) on stderr every 15 s and the
  pretty-printed Delivery JSON on stdout, so a background shell's combined
  output file is not one JSON document. Hence the `2>/dev/null` redirect and
  the re-check without `--wait`, which returned the same deliveryId and
  messages until `--ack`.
- On Orca 1.4.209 with Claude Code 2.1.281, `worker-start --terminal` right
  after `terminal wait --for tui-idle` returned `satisfied: true` failed 2 of
  2 times with "Terminal term_... is not running a recognized agent."; the
  same `worker-start` with the same task ID succeeded a few seconds later.
- On Orca 1.4.209, a background `check --wait --types
  "worker_done,escalation,question"` repeatedly returned when only a
  `heartbeat` had arrived; the type filter does not reliably exclude
  heartbeats.
- On Orca 1.4.209, `check --wait --json` also wrote the keepalive lines to
  stdout (one single-line object every ~15 s, e.g.
  `{"_keepalive":true,"_heartbeat":true,"elapsedMs":15000,"deadlineMs":590000}`)
  before the pretty-printed result, so piping stdout straight into
  `jq '.result...'` fails or yields empty objects; filter with
  `jq -s 'map(select(._keepalive | not)) | last'`.
- The Claude Code background task output file is not pure JSON: it ends
  with an `[exited with code N]` trailer, so `jq` on it fails. Never pipe it
  to `jq` directly; read the `--out` file of `orca-wait.sh` instead.
- `orca-usage.sh` sums local transcripts (Claude `~/.claude/projects`, Codex
  `~/.codex/sessions`), not a billing record. Claude writes one line per
  content block with the same usage, so lines are deduplicated by
  `message.id`; Codex `input_tokens` includes cached input.
- Observed on Orca 1.4.225 with Claude Code (2026-10-16): `terminal create
  --command` into a worktree created moments earlier returned "Timed out
  waiting for terminal handle after creation" 3 of 3 times while the agent
  started minutes later; `terminal list` right after showed no terminal or a
  plain shell; recreating produced three agent sessions in one task. Existing
  worktrees did not time out at the same time. Hence
  `scripts/orca-terminal-create.sh`.
