English | [日本語](config.ja.md)

# Repository settings (`.orca-dev-ops.json`)

A repository can tune the orca-dev-ops workflow with an optional settings file.
Without it, every hook and script behaves exactly as it does without settings:
child agents implement in task worktrees (workflow mode `worktree`), the
coordinator asks for the agent, model, and effort before every launch, at
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
checkout takes effect for the next hook call; no restart is needed. The
coordinator's session-start context is the exception: it is written once at
session start, so after a change run `scripts/orca-config.sh show` (below) to
confirm the effective values.

## Editor support (`$schema`)

The plugin ships a JSON Schema for this file,
[`schemas/orca-dev-ops.schema.json`](../schemas/orca-dev-ops.schema.json)
(draft 2020-12). It lists every key with its type, allowed values, default,
and an English description, rejects unknown keys at every level, and encodes
the conditional rules below (`semi-auto`/`auto` need `agent`, `model`, and
`effort`; `escalate` needs `semi-auto` or `auto`; `top` needs `escalate`).
The schema and the loader are meant to accept the same files: the test suite
runs a set of valid and invalid sample files through both and expects the
same verdict for each.

A top-level `"$schema"` key points an editor at it:

```json
"$schema": "https://raw.githubusercontent.com/5umm3r/orca-dev-ops/main/schemas/orca-dev-ops.schema.json"
```

Editors that read `$schema` (VS Code, JetBrains IDEs, and others with a JSON
language server) then offer completion, show the descriptions on hover, and
mark invalid values while you edit. The URL is the schema on the plugin's
`main` branch, so it follows the latest release; to pin a version, point
`$schema` at a local copy instead. The loader accepts any
non-empty string as `$schema` and otherwise ignores it: it is not part of the
effective settings and `scripts/orca-config.sh show` does not print it. JSON
has no comments, and the loader (jq) rejects them, so the schema's
descriptions take their place; do not use JSONC.

## Creation by `/orca-init`

When the main checkout has no `.orca-dev-ops.json`, `/orca-init` creates it
with `$schema` first and then every key that has a default (the values in the
table below), without needing `--apply`, and prints `created: <path>`. It runs
from a linked worktree too and then writes the file into the main checkout.
`launch.agent`, `launch.model`, and `launch.effort` have no default and are
not written.

```json
{
  "$schema":  "https://raw.githubusercontent.com/5umm3r/orca-dev-ops/main/schemas/orca-dev-ops.schema.json",
  "workflow": { "mode": "worktree" },
  "launch":   { "mode": "ask" },
  "limits":   { "maxWorktrees": 3, "smallChangeFiles": 2, "smallChangeLines": 20 }
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
  default applies anyway; adding it pins the current value. `$schema` is
  reported this way too (`settings: missing key $schema (default "<URL>")`);
  it changes no behavior and only enables the editor support above. A file
  with a `$schema` of its own is not reported as missing it.
- `settings: missing key <key> (suggested <value>)`: an opt-in key with a
  suggested value that keeps the file valid. Two keys have one:
  `launch.escalate` is `{"model": "claude-opus-5-5", "effort": "high"}`,
  offered when the file has `launch.mode` `"semi-auto"` or `"auto"` and
  `launch.agent: "claude"`; `launch.top` is
  `{"model": "claude-fable-5-2", "effort": "high"}`, offered under the same
  conditions when the file already has `launch.escalate`. A file without
  `escalate` therefore gets `escalate` from one `--settings=add` and is offered
  `top` only on the next run, so the costlier tier is always a separate choice.
- `settings: available key <key> (no default; set by hand, see docs/config.md)`:
  an opt-in key the file lacks with no applicable suggestion (`launch.agent`,
  `launch.model`, `launch.effort`, and `launch.escalate` and `launch.top`
  otherwise). It is never added automatically.
- `settings: reset would change <key> (<old> -> <new or removed>)`: every value
  in the file that `--settings=reset` would change or remove.

When at least one key is missing, it asks to rerun with one of these
(`/orca-init` asks the user which; `--no-settings` cannot be combined with them):

- `--settings=add` adds every `missing key` with the value shown and keeps every
  existing value (`updated: <path> (added: ...)`, or `up to date: <path>`). The
  added values are pinned like created ones: a later default change does not
  update them. The rewritten file has `$schema` first, then `workflow`,
  `launch`, and `limits`; a `$schema` of the file's own is kept as it is. An
  invalid file is not changed; only a reset replaces it.
- `--settings=reset` copies the file to `.orca-dev-ops.json.bak` next to it and
  writes the defaults exactly as a newly created file (`reset: <path> (backup:
  <bak>)`), including the plugin's `$schema` URL and `workflow.mode`
  `"worktree"`. It works on an invalid file too. When the `.bak` file already
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
  "$schema":  "https://raw.githubusercontent.com/5umm3r/orca-dev-ops/main/schemas/orca-dev-ops.schema.json",
  "workflow": { "mode": "worktree" },
  "launch":   { "mode": "auto", "agent": "claude", "model": "claude-sonnet-5-5", "effort": "medium",
                "escalate": { "model": "claude-opus-5-5", "effort": "high" },
                "top":      { "model": "claude-fable-5-2", "effort": "high" } },
  "limits":   { "maxWorktrees": 3, "smallChangeFiles": 2, "smallChangeLines": 20 }
}
```

Every key is optional; a missing key takes its default. `{}` is the same as
no file. With `"mode": "auto"` as here, the coordinator launches the escalate
tier without a question when a task meets an escalation criterion, and the
top tier when it meets one of the stricter top criteria; use `"semi-auto"` to
have the user answer a `Model` question first. With `"workflow": { "mode":
"direct" }` the coordinator implements in the main checkout instead and no
child is launched; `launch` and `limits` stay valid and apply again after
switching back.

## Keys

### `$schema`

| Key | Type | Default | Behavior |
| --- | --- | --- | --- |
| `$schema` | non-empty string | the plugin's schema URL (written by `/orca-init`) | Only for editors (see "Editor support"); the loader ignores the value |

### `workflow`

| Key | Type | Default | Behavior |
| --- | --- | --- | --- |
| `workflow.mode` | `"worktree"` or `"direct"` | `"worktree"` | Where implementation happens (below) |

`worktree` (the default) is the workflow the rest of this document and the
`orca-dev-ops` skill describe: child agents implement in Orca task
worktrees, the coordinator plans, reviews, and integrates, and its own direct
edits in the main checkout stay within the `limits` below.

`direct` is for repositories that want the coordinator to implement by
itself, without child worktrees:

- The role guard lets the coordinator edit any file in its own main checkout
  with any tool (Write, Edit, NotebookEdit) and any size: the small-change
  limits and the Write block do not apply there. Editing a linked worktree,
  or another repository's main checkout, stays as before.
- The coordinator commits directly on the base ref after the repository's
  verification, then pushes (a rule of the skill; the guard does not check
  commits).
- `orca worktree create` is blocked, with a message naming
  `workflow.mode`; raw `git worktree add`/`remove` stay blocked as always.
- The coordinator's session context says so instead of the child-worktree
  lines. Child sessions, the launch gate, and the child rules do not change.

`launch` and `limits` stay valid together with `direct` and keep their values
for switching back. The mode is changed only by the user, by editing
`workflow.mode`; the coordinator never edits it on its own (the guard's deny
message says so too). Before switching to `direct`, integrate and remove the
existing task worktrees: worktrees that remain keep the child rules, and the
coordinator still cannot edit them. The session-start context is not
updated by a switch; run `scripts/orca-config.sh show` to confirm the mode in
effect.

### `launch`

| Key | Type | Default | Behavior |
| --- | --- | --- | --- |
| `launch.mode` | `"ask"`, `"semi-auto"`, or `"auto"` | `"ask"` | How the coordinator chooses the child's agent, model, and effort (below) |
| `launch.agent` | `"claude"` or `"codex"` | unset | The child agent |
| `launch.model` | non-empty string without spaces | unset | The agent's own model value: Claude `--model`, Codex `-m` / `--model` |
| `launch.effort` | non-empty string without spaces | unset | The agent's own effort value: Claude `--effort`, Codex `-c model_reasoning_effort=<value>` |
| `launch.escalate` | object `{model, effort}` | unset | A second launch tier for the same agent, valid only with `launch.mode` `"semi-auto"` or `"auto"`; `model` and `effort` are non-empty strings without spaces (below) |
| `launch.top` | object `{model, effort}` | unset | A third, highest launch tier for the same agent, valid only together with `launch.escalate` (so only with `"semi-auto"` or `"auto"`); the same shape as `launch.escalate` (below) |

`ask` (the default) keeps the launch gate as it is: before every child launch
the coordinator asks the user one question each with header `Agent`, `Model`,
and `Effort`, and the launch gate blocks the launch until the session
transcript holds the answers after the last successful launch. In this mode
`launch.agent`, `launch.model`, and `launch.effort` are only the
"(Recommended)" option of those questions; the gate's deny message names them.

`semi-auto` and `auto` remove the questions (`semi-auto` keeps only the
`Model` question of `launch.escalate` and `launch.top`; `auto` asks nothing). The user decides
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
differ only in how the escalate and top tiers are chosen (below).

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

#### `launch.top`

`launch.top` is an optional `{model, effort}` that adds a third, highest tier
on top of `launch.escalate`, for example
`{"model": "claude-fable-5-2", "effort": "high"}` (Fable 5.2 costs twice Opus
5.5). It has the same shape and rules as `escalate` (only `model` and
`effort`, the agent is `launch.agent`), and it is valid only when
`launch.escalate` is also set, which in turn needs `launch.mode` `"semi-auto"`
or `"auto"`.

- The top tier is chosen only under stricter criteria. A task that meets only
  (a)-(d) above stays on the escalate tier; the top tier needs one of: (e) the
  same child needed two rework Dispatches on the escalate tier; (f) the change
  alters the meaning of a safety mechanism (hooks, the launch gate, the guard)
  while design decisions about it remain open, that is (a) together with the
  safety part of (b); (g) the result is hard to verify by tests and a mistake
  is costly: concurrency, permission boundaries, data migration.
- The gate treats it exactly like the escalate tier. A launch of
  `launch.agent` with exactly the `top` model and effort is allowed in `auto`
  without reading the transcript, and in `semi-auto` only after an answered
  `Model` question since the last successful launch. It is the same `Model`
  question as for escalate: when (e)-(g) holds, its options are the top model
  first, labeled "(Recommended)", then the escalate model, then the default
  model; when only (a)-(d) holds, the options stay as above.
- In `auto` the coordinator records `tier:top reason:(<letter>)` in the
  worktree comment, next to `tier:escalate ...` and `tier:default`.
- The deny message of the gate lists the third tier and its flags after the
  second.
- The limitation above applies too: the gate cannot tell which of the three
  models the user chose in `semi-auto`.

From v1.14.0, `top` is accepted. A file without `top` behaves exactly as
before: the third tier does not exist and a launch with its values is denied.

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
non-documentation edit. With `workflow.mode` `"direct"` none of these limits
applies to the coordinator's own main checkout, and `orca worktree create`
is blocked before any count.

### `heavy` (opt-in, since 1.17.0)

Limits how many heavy commands (test suites, builds) the worktrees of the
repository run at once on one machine, so parallel children do not make the
Mac unresponsive. `/orca-init` does not write this section; every key falls
back to the default below.

| Key | Type | Default | Behavior |
| --- | --- | --- | --- |
| `heavy.concurrency` | `"auto"` or integer >= 1 | `"auto"` | Slots: how many heavy commands may run at once. `"auto"` is `max(1, min(cores / coresPerSlot, memory GB / memoryGBPerSlot))`, rounded down, computed on each machine |
| `heavy.coresPerSlot` | integer >= 1 | `6` | With `"auto"`: CPU cores (`hw.ncpu`) per slot |
| `heavy.memoryGBPerSlot` | integer >= 1 | `16` | With `"auto"`: GB of memory per slot |
| `heavy.maxLoad` | number > 0 | `0.8` | Wait before starting while the 1-minute load average exceeds cores * `maxLoad` |
| `heavy.minFreeMemory` | integer 0-100 | `20` | Wait before starting while the free memory (`memory_pressure`) is below this percentage; `0` turns the check off |
| `heavy.maxWaitSeconds` | integer >= 0 | `1800` | After waiting this long in total, run anyway without a slot, with a warning |
| `heavy.priority` | `"normal"`, `"low"`, `"background"` | `"low"` | `low`: `nice -n 10`. `background`: macOS `taskpolicy -b` (efficiency cores only; much slower, keeps the machine responsive) |
| `heavy.commands` | array of non-empty strings | `[]` | Command texts that count as heavy here, e.g. `"sh tests/run_all.sh"`, `"xcodebuild"` |

Examples with the defaults: 12 cores and 32 GB give 2 slots; 8 cores and
16 GB give 1; 24 cores and 128 GB give 4.

A heavy command runs through the plugin's wrapper:

```sh
sh "<plugin root>/scripts/orca-heavy.sh" run -- sh tests/run_all.sh
sh "<plugin root>/scripts/orca-heavy.sh" status
```

- Slots are directories `<git common dir>/orca-heavy/slot-<n>`, shared by
  every worktree of the repository. A slot whose holder process is gone is
  freed.
- While waiting, it prints why on stderr (`orca-heavy: waiting (40s): all 1
  slot(s) held: cc-alpha (sh tests/run_all.sh)`, or the load or memory
  figure) and records itself in `<git common dir>/orca-heavy/waiting/`.
- `status` prints the slots, the machine figures, the holders, and the
  waiters as JSON; the progress report includes them.
- After `maxWaitSeconds` it starts anyway: in a free slot when only the load
  or memory check held it back, otherwise without a slot.
- A child runs the wrapped command in the background (the worktree rules),
  because a wait can outlast a foreground command.
- Codex children: the slot directory must be writable from the sandbox. The
  coordinator creates it and adds `--add-dir <git common dir>/orca-heavy` to
  the Codex launch (see "Starting a child" in `skills/orca-dev-ops/SKILL.md`).
  Without it the wrapper warns and runs the command without a slot.

With `heavy.commands` set, the role guard denies a Claude child's Bash
command that contains one of them unless it runs through `orca-heavy.sh
run`; the deny message gives the wrapper's path. Codex children follow the
worktree rules and the Dispatch instead (Claude hooks do not apply to them).
The coordinator is not limited.

Per machine: `${XDG_CONFIG_HOME:-~/.config}/orca-dev-ops/heavy.json` holds
the same keys except `commands`, as a flat object
(`{"concurrency": 1, "priority": "background"}`), and overrides the
repository's values on that machine only. An invalid file is ignored with a
warning. It is not part of the repository.

### `monitor` (deprecated, ignored since 1.12.0)

Versions before 1.12.0 used `monitor.wakeOnStatus` and `monitor.timeoutMs` to
configure `scripts/orca-wait.sh`, the coordinator's foreground wait. 1.12.0
removed that script: Orca 1.4.246 wakes the coordinator itself, by typing the
`check` command into the coordinator's own terminal when a worker reports
(see "Communication and state" in `skills/orca-dev-ops/SKILL.md`), so there is
nothing left to configure.

The section is still accepted so that existing files stay valid, and its
values are still checked as before (`wakeOnStatus` true or false, `timeoutMs`
an integer > 0). It is left out of the effective settings, `/orca-init` no
longer writes it, `--settings=add` keeps it as it is, and `--settings=reset`
removes it. A valid file that has it gets the settings warning
`monitor is ignored since 1.12.0; remove it from <path>.` in the coordinator's
session context, in every deny of the launch gate and the role guard, from
`scripts/orca-config.sh show` (`orca-config: warning: ...` on stderr, exit 0),
and from `/orca-init` (`settings: warning: ...`). Remove the section; a later
major version will reject it as an unknown key.

## Validation and fallback

The whole file is checked on every read. It is invalid when:

- it is not valid JSON, is empty, holds more than one JSON value, or its top
  level is not an object;
- it has a key not listed above (at any level; the deprecated `monitor`
  section is still listed and accepted);
- a value has the wrong type or is out of range;
- `$schema` is not a non-empty string (`$schema must be a non-empty string`);
- `workflow` is not an object, or `workflow.mode` is neither `"worktree"` nor
  `"direct"`;
- `launch.mode` is `"semi-auto"` or `"auto"` without `launch.agent`,
  `launch.model`, and `launch.effort`;
- `launch.escalate` is not an object with only `model` and `effort`, either
  value is not a non-empty string without spaces, or `launch.mode` is neither
  `"semi-auto"` nor `"auto"`;
- `launch.top` is not an object with only `model` and `effort`, either value
  is not a non-empty string without spaces, or `launch.escalate` is not set
  (`launch.top is only valid together with escalate`);
- a `heavy` key is out of range (see `heavy`), or `heavy.commands` is not an
  array of non-empty strings.

An invalid file is ignored as a whole; nothing is taken from it. The built-in
defaults apply, including workflow mode `worktree` with the limits and launch
mode `ask`, which is the strictest behavior. The problem is reported:

- in the coordinator's session context at start;
- in every deny message of the launch gate and the role guard;
- by `scripts/orca-config.sh show` (exit 3) and `/orca-init`.

## Migration to 1.15.0 (`workflow`, `$schema`)

1.15.0 adds the `workflow` section and the `$schema` key. A file without them
behaves exactly as before (workflow mode `worktree`); `/orca-init` reports
them as missing keys, and `--settings=add` adds them.

- After upgrading the plugin, rerun `/orca-init` in every repository that
  uses it. Besides the settings report, this refreshes the Codex launch gate's
  copy of the loader, `.codex/hooks/orca-lib.sh`; an older copy treats a file
  with `workflow` or `$schema` as invalid, so Codex coordinators would fall
  back to launch mode `ask`.
- An older plugin on another device does the same: it treats `workflow` and
  `$schema` as unknown keys, ignores the whole file, and applies its built-in
  defaults (worktree mode with the default limits and launch mode `ask`),
  with a settings warning. Upgrade the plugin on every device that works on
  the repository before adding either key or running `--settings=add`.

## Migration to 1.17.0 (`heavy`)

1.17.0 adds the optional `heavy` section. A file without it behaves exactly as
before. An older plugin on another device treats `heavy` as an unknown key and
ignores the whole file, as described for 1.15.0: upgrade the plugin on every
device and rerun `/orca-init` (the worktree rules and the Codex copy of the
loader change) before adding it.

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
It prints the effective settings (the file merged over the defaults, with
`workflow.mode` and without `$schema` or `monitor`) as JSON
on stdout; stderr names the source file and, when the file is invalid, the
reason, or, for a valid file, the settings warning (the `monitor` deprecation
notice). Exit codes: 0 valid or missing, 3 invalid (the defaults are printed),
64 usage error, 65 not a git repository. The coordinator runs it once per
session, before the first launch.
