---
description: Install the generic "Orca worktree rules" block in this repository
allowed-tools: Bash(sh:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/scripts/orca-init.sh` to install the generic rules
block for child worktrees in the current repository's `.claude/CLAUDE.md`.

Steps:

1. Run it without arguments.

   ```sh
   sh "${CLAUDE_PLUGIN_ROOT}/scripts/orca-init.sh"
   ```

2. Branch on the exit code.

   - `0` — `.claude/CLAUDE.md` was created, updated, or left unchanged. Report
     the output to the user as is and finish. Always check whether the output
     includes a note about `AGENTS.md` (step 3 below).
   - `2` — `.claude/CLAUDE.md` exists without a marker block. Read the existing
     file and check whether it already has hand-written worktree rules. If
     anything duplicates or contradicts the block, point it out and ask the
     user whether to append the block. After approval, run
     `sh "${CLAUDE_PLUGIN_ROOT}/scripts/orca-init.sh" --apply`.
   - `64` – unknown option. `66` – template missing. `65` – outside a git
     repository. Report the cause and finish.
   - `67` — the marker block in `.claude/CLAUDE.md` is broken (a start marker
     without an end marker, an end marker only, or multiple blocks). The file
     was not changed. Report the error output to the user and tell them to fix
     the affected lines by hand, then run the command again.

3. Check the report about `AGENTS.md` in the output.
   - `linked: AGENTS.md -> .claude/CLAUDE.md` — a new link was created. No
     action needed.
   - `updated` / `up to date` — the marker block in the regular file was
     updated the same way as `.claude/CLAUDE.md`. No action needed.
   - `note: AGENTS.md is a symlink to ...` (a link to something other than
     `.claude/CLAUDE.md`) — not changed. Check in the output whether the link
     target already has a marker block; if not, tell the user that Codex child
     agents cannot read the rules.
   - `note: AGENTS.md exists as a regular file without an orca-worktree-rules
     marker` — not changed. Ask the user whether to append the block to
     `AGENTS.md` too so Codex child agents read the same rules; after
     approval, run again with `--apply`.
   - `note: AGENTS.md has an unterminated ...` — the marker block in
     `AGENTS.md` is broken. As with `67` in step 2, tell the user to fix the
     affected lines by hand (this does not affect the script's overall exit
     code).
   - Use the final `in sync` / `out of sync` line to confirm that Claude and
     Codex reach the same block; if `out of sync`, tell the user why.

Only the generic block is installed. Repository-specific rules, such as the
list of files that must not be edited in parallel or the verification
commands, are added by hand outside the marker block.
