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
edit it. An existing file, valid or invalid, is never modified; `/orca-init`
only validates and reports it. `--no-settings` skips the creation (an existing
file is still validated). A write failure is reported on stderr and does not
change the exit code.

## Full example

```json
{
  "launch":  { "mode": "ask", "agent": "claude", "model": "claude-opus-5-5", "effort": "high" },
  "limits":  { "maxWorktrees": 3, "smallChangeFiles": 2, "smallChangeLines": 20 },
  "monitor": { "wakeOnStatus": false, "timeoutMs": 590000 }
}
```

Every key is optional; a missing key takes its default. `{}` is the same as
no file.

## Keys

### `launch`

| Key | Type | Default | Behavior |
| --- | --- | --- | --- |
| `launch.mode` | `"ask"` or `"auto"` | `"ask"` | How the coordinator chooses the child's agent, model, and effort (below) |
| `launch.agent` | `"claude"` or `"codex"` | unset | The child agent |
| `launch.model` | non-empty string without spaces | unset | The agent's own model value: Claude `--model`, Codex `-m` / `--model` |
| `launch.effort` | non-empty string without spaces | unset | The agent's own effort value: Claude `--effort`, Codex `-c model_reasoning_effort=<value>` |

`ask` (the default) keeps the launch gate as it is: before every child launch
the coordinator asks the user one question each with header `Agent`, `Model`,
and `Effort`, and the launch gate blocks the launch until the session
transcript holds the answers after the last successful launch. In this mode
`launch.agent`, `launch.model`, and `launch.effort` are only the
"(Recommended)" option of those questions; the gate's deny message names them.

`auto` removes the questions. The user decides the agent, model, and effort
once, in this file, and `launch.agent`, `launch.model`, and `launch.effort`
are then required (`auto` without all three makes the file invalid). The
launch gate reads no transcript; it parses every launch in the command and
allows it only when all three values equal the configured ones:

- `orca terminal create --command "<value>"`: each `claude` or `codex` command
  in `<value>`. Claude: `--model <m>` and `--effort <e>`. Codex: `-m <m>` or
  `--model <m>`, and `-c model_reasoning_effort=<e>` or
  `--config model_reasoning_effort=<e>`. The `--flag=value` spellings work
  too, and the last occurrence of a flag wins.
- `orca orchestration worker-start --agent <a> --model <m> --effort <e>`
  (without `--terminal`).

A different value, or a value the command does not set, is denied with a
message naming the expected values. The values are compared as written: the
grade-to-effort mapping of the skill does not apply in `auto`.

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

The small-change limits apply to the coordinator's Edit and MultiEdit in the
main checkout, counting existing uncommitted and untracked changes;
documentation (`*.md`, `docs/`, `references/`, `.claude/`) is not counted and
Write stays blocked for other files. `0` blocks every direct
non-documentation edit.

### `monitor`

| Key | Type | Default | Behavior |
| --- | --- | --- | --- |
| `monitor.wakeOnStatus` | boolean | `false` | Whether `scripts/orca-wait.sh` also wakes on `status` messages |
| `monitor.timeoutMs` | integer > 0 | `590000` | Total time `scripts/orca-wait.sh` waits before it gives up |

`scripts/orca-wait.sh --run <run_id> [--timeout-ms <n>] [--wake-on-status]`
is the coordinator's wait. It runs `orca orchestration check --wait` and wakes
only on actionable mail:

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
- `launch.mode` is `"auto"` without `launch.agent`, `launch.model`, and
  `launch.effort`.

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
