English | [日本語](config.ja.md)

# Repository settings (`.orca-dev-ops.json`)

A repository can tune the orca-dev-ops workflow with an optional settings file.
Without it, every hook and script behaves exactly as it does without settings:
the coordinator asks for the agent, model, and effort before every launch, at
most 3 task worktrees exist at once, the main checkout allows 2 files and 20
lines of direct non-documentation change, and a coordinator wait lasts
590000 ms.

## Location

The file is `.orca-dev-ops.json` at the top level of the repository. It is
always read from the **main checkout**, also when a hook or script runs inside
a linked (child) worktree: git names the main checkout as the first entry of
`git worktree list`. A copy in a child worktree is ignored, so a child cannot
loosen its own limits by editing it; the guard also blocks a child's Write or
Edit of its own copy.

Commit the file like any other repository file. A change made in the main
checkout takes effect for the next hook call; no restart is needed.

## Creation by `/orca-init`

When the main checkout has no `.orca-dev-ops.json`, `/orca-init` creates it
with every key that has a default (the values in the table below), without
needing `--apply`, and prints `created: <path>`. It runs from a linked worktree
too and then writes the file into the main checkout. `launch.agent`,
`launch.model`, and `launch.effort` have no default and are not written.

```json
{
  "launch":  { "mode": "ask" },
  "limits":  { "maxWorktrees": 3, "smallChangeFiles": 2, "smallChangeLines": 20 },
  "monitor": { "wakeOnStatus": false, "timeoutMs": 590000 }
}
```

The written values are the defaults at creation time. A later plugin version
that changes a default does not update the file, so the written value keeps
applying; to follow the plugin's defaults, delete that key (or the file) or
edit it. `--no-settings` skips the creation (an existing file is still
validated). A write failure is reported on stderr and does not change the exit
code.

## An existing file: `/orca-init` reports, `--settings=` changes

An existing file is validated and, by default, left unchanged. An invalid file
is reported (`INVALID SETTINGS: ...` on stderr). For a valid file, `/orca-init`
also reports what a newer plugin offers and what a reset would lose:

- `settings: missing key <key> (default <value>)`: a key with a default that
  the file lacks, at leaf level (for example `limits.smallChangeLines`). The
  default applies anyway; adding it pins the current value.
- `settings: missing key <key> (suggested <value>)`: an opt-in key with a
  suggested value that keeps the file valid. Only `launch.escalate` has one:
  `{"model": "claude-opus-5-5", "effort": "high"}`, offered when the file has
  `launch.mode` `"semi-auto"` or `"auto"` and `launch.agent: "claude"`.
- `settings: available key <key> (no default; set by hand, see docs/config.md)`:
  an opt-in key the file lacks with no applicable suggestion (`launch.agent`,
  `launch.model`, `launch.effort`, and `launch.escalate` otherwise). It is never
  added automatically.
- `settings: reset would change <key> (<old> -> <new or removed>)`: every value
  in the file that `--settings=reset` would change or remove.

When at least one key is missing, it asks to rerun with one of these
(`/orca-init` asks the user which; `--no-settings` cannot be combined with them):

- `--settings=add` adds every `missing key` with the value shown and keeps every
  existing value (`updated: <path> (added: ...)`, or `up to date: <path>`). The
  added values are pinned like created ones: a later default change does not
  update them. An invalid file is not changed; only a reset replaces it.
- `--settings=reset` copies the file to `.orca-dev-ops.json.bak` next to it and
  writes the defaults exactly as a newly created file (`reset: <path> (backup:
  <bak>)`). It works on an invalid file too. When the `.bak` file already
  exists, nothing is changed (`SETTINGS NOT RESET: ...`); move the backup away
  first.

Both write through a temp file and replace the file only when the result passes
the same check as the hooks; otherwise the file is left unchanged and the reason
is printed on stderr (`SETTINGS NOT UPDATED: ...` or `SETTINGS NOT RESET: ...`).
Neither changes the exit code. The rewritten file uses the layout above, one
line per section.

## Full example

```json
{
  "launch":  { "mode": "auto", "agent": "claude", "model": "claude-sonnet-5-5", "effort": "medium",
               "escalate": { "model": "claude-opus-5-5", "effort": "high" } },
  "limits":  { "maxWorktrees": 3, "smallChangeFiles": 2, "smallChangeLines": 20 },
  "monitor": { "wakeOnStatus": false, "timeoutMs": 590000 }
}
```

Every key is optional; a missing key takes its default. `{}` is the same as
no file. With `"mode": "auto"` as here, the coordinator launches the escalate
tier without a question when a task meets an escalation criterion; use
`"semi-auto"` to have the user answer a `Model` question first.

## Keys

### `launch`

| Key | Type | Default | Behavior |
| --- | --- | --- | --- |
| `launch.mode` | `"ask"`, `"semi-auto"`, or `"auto"` | `"ask"` | How the coordinator chooses the child's agent, model, and effort (below) |
| `launch.agent` | `"claude"` or `"codex"` | unset | The child agent |
| `launch.model` | non-empty string without spaces | unset | The agent's own model value: Claude `--model`, Codex `-m` / `--model` |
| `launch.effort` | non-empty string without spaces | unset | The agent's own effort value: Claude `--effort`, Codex `-c model_reasoning_effort=<value>` |
| `launch.escalate` | object `{model, effort}` | unset | A second launch tier for the same agent, valid only with `launch.mode` `"semi-auto"` or `"auto"`; `model` and `effort` are non-empty strings without spaces (below) |

`ask` (the default) keeps the launch gate as it is: before every child launch
the coordinator asks the user one question each with header `Agent`, `Model`,
and `Effort`, and the launch gate blocks the launch until the session
transcript holds the answers after the last successful launch. In this mode
`launch.agent`, `launch.model`, and `launch.effort` are only the
"(Recommended)" option of those questions; the gate's deny message names them.

`semi-auto` and `auto` remove the questions (`semi-auto` keeps only the
`Model` question of `launch.escalate`; `auto` asks nothing). The user decides
the agent, model, and effort once, in this file, and `launch.agent`,
`launch.model`, and `launch.effort` are then required (`semi-auto` or `auto`
without all three makes the file invalid). For the default tier the launch
gate reads no transcript; it parses every launch in the command and allows it
only when all three values equal the configured ones:

- `orca terminal create --command "<value>"`: each `claude` or `codex` command
  in `<value>`. Claude: `--model <m>` and `--effort <e>`. Codex: `-m <m>` or
  `--model <m>`, and `-c model_reasoning_effort=<e>` or
  `--config model_reasoning_effort=<e>`. The `--flag=value` spellings work
  too, and the last occurrence of a flag wins.
- `orca orchestration worker-start --agent <a> --model <m> --effort <e>`
  (without `--terminal`).

A different value, or a value the command does not set, is denied with a
message naming the expected values. The values are compared as written: the
grade-to-effort mapping of the skill does not apply in `semi-auto` or
`auto`. Without `launch.escalate`, `semi-auto` and `auto` behave the same; they
differ only in how the escalate tier is chosen (below).

#### `launch.escalate`

`launch.escalate` is an optional `{model, effort}` that adds a second tier to
`semi-auto` and `auto`. The agent is shared: it is `launch.agent`, and
`escalate` has no `agent` key. `escalate` with any other `launch.mode` makes
the file invalid.

- Default launches use `launch.model` and `launch.effort`, with no question.
- The escalate tier is for tasks that meet an escalation criterion: (a) design
  decisions remain open or the spec is ambiguous; (b) the changes span several
  modules, or change the meaning of safety mechanisms such as hooks and the
  launch gate; (c) a long, multi-step verification loop is expected; (d) the
  same child needed two rework Dispatches on the default model. A task that
  meets no criterion launches with the default values.
- `semi-auto`: the user decides. A launch of `launch.agent` with exactly the
  `escalate` model and effort is allowed only when the session transcript
  holds an answered question with header `Model` after the last successful
  launch (the same transcript logic as `ask`, `Model` only; no `Agent` or
  `Effort` question is needed). Without that answer the launch is denied. A
  failed launch does not reset the window, so its retry needs no new question.
  The coordinator asks that one `Model` question only when the task meets a
  criterion; the options are the escalate model first, labeled
  "(Recommended)", then the default model. The coordinator never raises the
  model on its own.
- `auto`: the coordinator decides, with no question. It applies the same
  criteria itself and launches on the escalate tier when one is met. The gate
  allows a launch of `launch.agent` with exactly the `escalate` model and
  effort without reading the transcript. The coordinator records the chosen
  tier and criterion in the worktree comment and in its launch report.
- Limitation: in `semi-auto` the gate checks that a `Model` question was
  answered, not which option the user chose, so it cannot tell an answer of
  the default model from an answer of the escalate model. In `auto` the gate
  allows either tier, so whether a criterion was met rests on the
  coordinator's judgment.

Migration: from v1.11.0, a file with `"mode": "auto"` and `escalate` launches
the escalate tier without a question when the coordinator judges a criterion
met. Set `"mode": "semi-auto"` to keep the previous behavior (one `Model`
question before every escalate launch).

### `limits`

| Key | Type | Default | Behavior |
| --- | --- | --- | --- |
| `limits.maxWorktrees` | integer >= 1 | `3` | The most task worktrees (linked worktrees, the main checkout excluded) the repository may have when the coordinator runs `orca worktree create` |
| `limits.smallChangeFiles` | integer >= 0 | `2` | Direct edits in the main checkout: the most non-documentation files with uncommitted changes |
| `limits.smallChangeLines` | integer >= 0 | `20` | Direct edits in the main checkout: the most changed lines in those files |

The role guard counts the worktrees with `orca worktree list --repo
path:<main checkout> --json` and blocks `orca worktree create` when the count
is at the limit. When Orca cannot answer, or answers with a truncated list,
the create is blocked as well (fail closed).

The small-change limits apply to the coordinator's Edit in the main
checkout, counting existing uncommitted and untracked changes;
documentation (`*.md`, `docs/`, `references/`, `.claude/`) is not counted and
Write stays blocked for other files. `0` blocks every direct
non-documentation edit.

### `monitor`

| Key | Type | Default | Behavior |
| --- | --- | --- | --- |
| `monitor.wakeOnStatus` | boolean | `false` | Whether `scripts/orca-wait.sh` also wakes on `status` messages |
| `monitor.timeoutMs` | integer > 0 | `590000` | Total time `scripts/orca-wait.sh` waits before it gives up |

`scripts/orca-wait.sh --run <run_id> [--terminal <handle>] [--timeout-ms <n>] [--wake-on-status] [--out <path>]`
is the coordinator's wait. It runs `orca orchestration check --wait` and wakes
only on actionable mail. It passes no `--types`, so the wait covers every
message type: Orca writes "You have N (new) orchestration message(s)..." into
the terminal that owns the Run inbox when its agent status is idle and no
untyped `check --wait` is live, and a typed wait would leave the other types
to that injection. Orca sends Enter 500 ms later without checking whether the
user is typing, so the text can land in a draft and submit it; a waiter that
registers within the 500 ms (the gap between two waits of this script) skips
the Enter but leaves the text in the prompt (read from Orca 1.4.243's bundled
code; there is no setting to turn it off). The coordinator therefore owns its
Run from a mailbox terminal that runs no agent and so gets no injection
(`scripts/orca-mailbox.sh ensure`), and passes its handle as `--terminal`:
every check then runs as that terminal, without the Orca attestation
variables (`ORCA_TERMINAL_HANDLE`, `ORCA_PANE_KEY`, `ORCA_AGENT_PANE`,
`ORCA_AGENT_LAUNCH`, `ORCA_AGENT_LAUNCH_TOKEN`, `ORCA_TAB_ID`). Removing them
lets any terminal act as another, an Orca property; children are kept off it
by the role guard and the AGENTS.md rules. Closing the mailbox terminal
fences its Run. `--wake-on-status` and
`monitor.wakeOnStatus` only change which batches wake the caller. With
`--out`, it also writes the printed object to `<path>` atomically (an earlier
file there is removed at startup), for callers whose captured stdout is not
pure JSON:

- A Delivery that holds a `worker_done`, `escalation`, `question`, or any
  other type except `heartbeat` and `status` (and `status` too with
  `--wake-on-status`) is printed as `{"delivery": ..., "deferred": [...]}`,
  exit 0. It is not acknowledged: the coordinator handles every message in it
  and acknowledges it with `--ack <deliveryId>`.
- A Delivery of only heartbeats and statuses is acknowledged and the wait
  continues with the remaining time. Its `status` messages are kept in
  `deferred` and printed when the script ends; they are not delivered again,
  so the coordinator must read them there.
- When the time is up or the result is empty, it prints the object with
  `"delivery": null`, exit 2. An Orca error exits 1 with an `error` field.

The command-line options override the settings; the skill tells the
coordinator to use `--wake-on-status` for the first wait after a start, so
the child's first `status` is read right away.

The trade-off of a long `timeoutMs`: the wait wakes less often, which saves
coordinator turns, but deferred statuses and a child that stopped without
reporting are noticed only when the wait ends. The default, 590000 ms, stays
just under the 10-minute limit of a single tool call, so the same value also
works for a wait run in the foreground. A short `timeoutMs` notices problems
sooner at the cost of more wake-ups.

## Validation and fallback

The whole file is checked on every read. It is invalid when:

- it is not valid JSON, is empty, holds more than one JSON value, or its top
  level is not an object;
- it has a key not listed above (at any level);
- a value has the wrong type or is out of range;
- `launch.mode` is `"semi-auto"` or `"auto"` without `launch.agent`,
  `launch.model`, and `launch.effort`;
- `launch.escalate` is not an object with only `model` and `effort`, either
  value is not a non-empty string without spaces, or `launch.mode` is neither
  `"semi-auto"` nor `"auto"`.

An invalid file is ignored as a whole; nothing is taken from it. The built-in
defaults apply, including launch mode `ask`, which is the strictest behavior.
The problem is reported:

- in the coordinator's session context at start;
- in every deny message of the launch gate and the role guard;
- by `scripts/orca-config.sh show` (exit 3) and `/orca-init`.

## What is not configurable

Some rules are invariants of the workflow, not preferences, and the loader
rejects any key for them:

- the Codex sandbox, approval policy, extra writable directories, and network
  flags, and Claude's `--dangerously-skip-permissions`: they are what keeps a
  child inside its worktree and running without prompts; making them optional
  would let a single setting widen what a child can reach;
- trust prompts: trusting a repository is a global decision the user makes
  once, never the coordinator;
- base-ref resolution: the integration target always comes from
  `scripts/orca-base-ref.sh`, never from a guessed or configured branch name;
- fast-forward-only integration and the `--force` rules: they are what
  prevents lost or rewritten history.

## Checking the settings

```sh
sh scripts/orca-config.sh show [<path>]
```

Run it from the plugin (in Claude, `sh "${CLAUDE_PLUGIN_ROOT}/scripts/orca-config.sh" show`).
It prints the effective settings (the file merged over the defaults) as JSON
on stdout; stderr names the source file and, when the file is invalid, the
reason. Exit codes: 0 valid or missing, 3 invalid (the defaults are printed),
64 usage error, 65 not a git repository. The coordinator runs it once per
session, before the first launch.
