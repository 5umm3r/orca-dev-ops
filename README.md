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
| `hooks/orca-lib.sh` | Shared functions for role detection |
| `commands/orca-init.md` | The `/orca-init` slash command |
| `scripts/orca-init.sh` | Script that installs the worktree rules |
| `templates/worktree-rules.md` | The generic rules block that gets installed |

The hooks are launched through `${CLAUDE_PLUGIN_ROOT}` and resolve
`orca-lib.sh` relative to their own location. No entries in
`~/.claude/settings.json` are needed.

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

Only the generic block is installed. Repository-specific rules, such as the
list of files that must not be edited in parallel or the verification
commands, are added by hand outside the markers.

## Prerequisites

- The `orca` CLI is on the `PATH`.
- `jq` is available.

What is Orca: Orca is the multi-agent app that manages worktrees and agent
terminals; this plugin drives its `orca` CLI. The skill was verified with
Orca 1.4.206 (see "Known constraints" in `skills/orca-dev-ops/SKILL.md`).

## Migrating to v2.0.0

- After updating the plugin, run `/orca-init` again in every repository you
  want guarded. Scope is now decided only by whether `.claude/CLAUDE.md` or
  `AGENTS.md` has a marker block. Repositories without the marker are no
  longer restricted. Conversely, when the role cannot be determined inside
  the scope, sessions used to run unrestricted; write operations are now
  blocked (fail closed).
- The integration target (integration ref) is the value returned by
  `scripts/orca-base-ref.sh` (Orca's base ref, or the remote HEAD if there is
  none). If it cannot be determined, set it with `orca repo set-base-ref`.
- Children are started as dispatched workers through
  `orca orchestration worker-start --terminal`. Fixes for review findings are
  handed over as a new Dispatch.
- Claude hooks do not apply to Codex child agents. The sandbox flags and the
  rules in `AGENTS.md` are the only guards.
- Before starting the first child, trust each repository once in both Claude
  and Codex. Do not place repositories under `/tmp` or `$TMPDIR` (they are
  writable even from the Codex sandbox).

## Running the tests

```sh
for t in tests/*.test.sh; do sh "$t"; done
```

## License

MIT. See [LICENSE](LICENSE).
