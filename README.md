English | [日本語](README.ja.md)

# orca-dev-ops

A repository that distributes, as a Claude Code plugin, the master-session
procedure for multi-device development with Orca (the Orca CLI). It assumes a
division of work: planning happens in the parent worktree, and implementation
is delegated to child worktrees running either Claude or Codex.

## Layout

| Path | Role |
| --- | --- |
| `skills/orca-dev-ops/SKILL.md` | The master-session procedure itself |
| `hooks/orca-role-context.sh` | SessionStart. Tells the session whether it is the master or a child |
| `hooks/orca-role-guard.sh` | PreToolUse. Blocks direct edits by the master and commits by children |
| `hooks/orca-child-control.sh` | PostToolUse. Injects the control procedure after `orca worktree create` |
| `hooks/orca-launch-gate.sh` | PreToolUse. Blocks a child agent launch until the user answered the Agent, Model, and Effort questions in this session (Claude and Codex) |
| `hooks/orca-lib.sh` | Shared functions for role detection and the settings loader |
| `commands/orca-init.md` | The `/orca-init` slash command |
| `scripts/orca-init.sh` | Script that installs the worktree rules and the Codex launch gate |
| `scripts/orca-worker-start.sh` | Starts a dispatched worker on a child terminal once the agent header is on screen, retrying once on the start-up race |
| `scripts/orca-config.sh` | Prints the effective repository settings (`.orca-dev-ops.json`) and reports validation errors |
| `scripts/orca-wait.sh` | Coordinator wait: wakes on actionable mail, acknowledges heartbeat- and status-only batches and keeps the statuses |
| `docs/config.md` | Reference for the repository settings file |
| `templates/worktree-rules.md` | The generic rules block that gets installed |

The hooks are launched through `${CLAUDE_PLUGIN_ROOT}` and resolve
`orca-lib.sh` relative to their own location. No entries in
`~/.claude/settings.json` are needed.
Codex plugins cannot ship hooks, so for Codex the launch gate is installed into
each repository by `/orca-init` (see below).

## Installation

```
/plugin marketplace add https://github.com/5umm3r/orca-dev-ops
/plugin install orca-dev-ops@orca-dev-ops
```

## Applying to a repository

Running `/orca-init` in a target repository installs the generic rules block
for child worktrees in `.claude/CLAUDE.md` and links `AGENTS.md` to it.

- If the file does not exist: it is created.
- If a marker block exists: only the inside of the block is replaced (for
  redistribution when the plugin is updated).
- If the file exists without markers: the diff is shown and confirmation for
  `--apply` is requested.

It also installs the launch gate for Codex coordinators: copies of
`orca-launch-gate.sh` and `orca-lib.sh` in `.codex/hooks/` (refreshed on every
run) and a `PreToolUse` `Bash` entry in `.codex/hooks.json`. A missing
`hooks.json` is created; an existing one without the entry needs `--apply` and
keeps its other hooks; malformed JSON is reported and left unchanged. Codex
asks the user once to trust new or changed hooks at its next start.

When the main checkout has no `.orca-dev-ops.json`, it creates one with every
default setting (see "Settings"); `--no-settings` skips this. An existing
settings file is never changed, only validated.

Only the generic block is installed. Repository-specific rules, such as the
list of files that must not be edited in parallel or the verification
commands, are added by hand outside the markers.

## Settings

A repository can place an optional `.orca-dev-ops.json` at its top level to
choose the launch mode (`ask`: questions before every launch, the default;
`auto`: a fixed agent, model, and effort without questions), the worktree and
small-change limits, and the coordinator's wait. It is read from the main
checkout only, and an invalid file is ignored with a warning. Without it,
behavior is unchanged. `/orca-init` creates it with every default; the
written values stay as they are when a later plugin version changes a
default. See [docs/config.md](docs/config.md);
`scripts/orca-config.sh show` prints the effective settings.

## Prerequisites

- The `orca` CLI is on the `PATH`.
- `jq` is available.

What is Orca: Orca is the multi-agent app that manages worktrees and agent
terminals; this plugin drives its `orca` CLI. The skill was verified with
Orca 1.4.206 and 1.4.209 (see "Known constraints" in `skills/orca-dev-ops/SKILL.md`).

## Upgrading

When a plugin update changes the worktree-rules template or the hooks, run
`/orca-init` again in every repository that uses it. Only the marker block and
the Codex hook copies are replaced; content outside the markers and other
Codex hooks are kept.

## How it behaves

- The hooks act only in repositories whose `.claude/CLAUDE.md` or `AGENTS.md`
  has the marker block; repositories without it are not restricted. Inside
  that scope, when the role cannot be determined, write operations are
  blocked (fail closed).
- The integration target (integration ref) is the value returned by
  `scripts/orca-base-ref.sh` (Orca's base ref, or the remote HEAD if there is
  none). If it cannot be determined, set it with `orca repo set-base-ref`.
- Children are started as dispatched workers through
  `orca orchestration worker-start --terminal`. Fixes for review findings are
  handed over as a new Dispatch.
- In launch mode `ask` (the default, see "Settings"), before every child launch, the coordinator asks the user one question each
  about the child's agent, model, and effort (headers `Agent`, `Model`,
  `Effort`). The launch gate reads the session transcript and blocks the launch
  until those answers exist after the last successful launch; a failed launch
  can be retried without asking again. It applies to Claude and, through
  `/orca-init`, to Codex coordinators.
- Apart from the launch gate, Claude hooks do not apply to Codex agents. The
  sandbox flags and the rules in `AGENTS.md` are the only guards for Codex
  child agents.
- Before starting the first child, trust each repository once in both Claude
  and Codex. Do not place repositories under `/tmp` or `$TMPDIR` (they are
  writable even from the Codex sandbox).

## Running the tests

```sh
for t in tests/*.test.sh; do sh "$t"; done
```

## License

MIT. See [LICENSE](LICENSE).
