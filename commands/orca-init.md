---
description: Install the generic "Orca worktree rules" block and the Codex launch gate in this repository
allowed-tools: Bash(sh:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/scripts/orca-init.sh` to install the generic rules
block for child worktrees in the current repository's `.claude/CLAUDE.md`, and
the launch gate hook for Codex coordinators in `.codex/` (Codex plugins cannot
ship hooks).

Steps:

1. Run it without arguments. If the user asked not to create the
   repository settings file, add `--no-settings`.

   ```sh
   sh "${CLAUDE_PLUGIN_ROOT}/scripts/orca-init.sh"
   ```

2. Branch on the exit code.

   - `0` — `.claude/CLAUDE.md` was created, updated, or left unchanged. Report
     the output to the user as is and finish. Always check whether the output
     includes a note about `AGENTS.md` (step 3 below) and read the Codex launch
     gate lines (step 4).
   - `2` — `.claude/CLAUDE.md` exists without a marker block. Read the existing
     file and check whether it already has hand-written worktree rules. If
     anything duplicates or contradicts the block, point it out and ask the
     user whether to append the block. After approval, run
     `sh "${CLAUDE_PLUGIN_ROOT}/scripts/orca-init.sh" --apply`.
   - `3` — `.codex/hooks.json` exists without the launch gate entry (the rules
     step already finished). Read the file, tell the user which hooks it
     already has and show the entry the output would add; after approval, run
     `sh "${CLAUDE_PLUGIN_ROOT}/scripts/orca-init.sh" --apply`. The merge keeps
     the other hooks. `--apply` also appends the block to an `AGENTS.md`
     without markers, so check step 3 first and ask about both together.
   - `64` – unknown option. `66` – template or plugin hook missing. `65` –
     outside a git repository. Report the cause and finish.
   - `67` — the marker block in `.claude/CLAUDE.md` is broken (a start marker
     without an end marker, an end marker only, or multiple blocks). The file
     was not changed. Report the error output to the user and tell them to fix
     the affected lines by hand, then run the command again.
   - `68` — `.codex/hooks.json` is not valid JSON or not a hooks file. Nothing
     under `.codex` was changed. Report the error output and tell the user to
     fix the file by hand, then run the command again.

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
   - Use the `in sync` / `out of sync` line to confirm that Claude and
     Codex reach the same block; if `out of sync`, tell the user why.

4. Check the Codex launch gate lines in the output.
   - `installed` / `updated` / `up to date: .codex/hooks/...` — the copies of
     `orca-launch-gate.sh` and `orca-lib.sh` are refreshed on every run; they
     are plugin-owned, so tell the user not to edit them.
   - `created` / `updated` / `merged` / `up to date: .codex/hooks.json` — the
     `PreToolUse` `Bash` entry runs the gate from the checkout's top level.
   - `note: Codex asks the user to trust new or changed hooks` — tell the user
     that Codex asks once at its next start and the gate runs only after they
     trust the hooks.

5. Check the repository settings line. When the main checkout has no
   `.orca-dev-ops.json`, the script creates it with every default (without
   `--apply`); an existing file is never changed (see `docs/config.md` in the
   plugin).
   - `created: <path>` — the file was created in the main checkout with the
     built-in defaults. Tell the user it can be committed and edited, and
     that the written values stay as they are when a later plugin version
     changes a default (delete a key to follow the plugin's default).
   - `SETTINGS NOT CREATED: ...` (stderr, exit code unchanged) — the file
     could not be written; the built-in defaults apply. Report it to the
     user.
   - No line — `--no-settings` was given, or git cannot name the main
     checkout; the built-in defaults apply.
   - `settings: ... is valid` — no action needed.
   - `INVALID SETTINGS: ...` (stderr, exit code unchanged) — the hooks ignore
     the file and use the defaults (launch mode `ask`). Report the reason to
     the user and tell them to fix the file by hand.

Only the generic block is installed. Repository-specific rules, such as the
list of files that must not be edited in parallel or the verification
commands, are added by hand outside the marker block.
