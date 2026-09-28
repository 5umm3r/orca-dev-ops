---
name: orca-init
description: Use when a user asks to initialize a repository for Orca dev ops or refresh its worktree rules and Codex launch gate after a plugin update, including invoking orca-init.
---

# Initialize Orca dev ops

Install the generic child-worktree rules in `.claude/CLAUDE.md` and
`AGENTS.md`, the Codex launch gate in `.codex/`, and default repository
settings when missing. This is the shared procedure for Claude's
`/orca-init` command and Codex's `$orca-init` skill (also selectable through
`/skills`). Follow it in the repository's coordinator session.

## Resolve the installed package and target

Use the absolute path of this loaded `SKILL.md`, as supplied by the skill
catalog. Expand any catalog root alias (such as `r7`) using that catalog's
root table before accessing it. The plugin root is `../..` **from the
directory containing this file**, not from the current working directory.
When entered through Claude's command, its supplied `CLAUDE_PLUGIN_ROOT`
identifies the same package.

The package layout is:

```text
<plugin-root>/skills/orca-init/SKILL.md
<plugin-root>/scripts/orca-init.sh
<plugin-root>/templates/worktree-rules.md
<plugin-root>/hooks/orca-launch-gate.sh
<plugin-root>/hooks/orca-lib.sh
```

Use the user's requested repository, or the session's project directory
when none was specified. Resolve it to its absolute Git checkout root.
Keep it separate from the plugin root; entering the plugin directory must
not change the initialization target.

For Codex, substitute the actual absolute paths below, then run:

```sh
orca_skill_file='/absolute/plugin-root/skills/orca-init/SKILL.md'
orca_repo_path='/absolute/target-repository'
orca_plugin_root=$(CDPATH= cd -- "$(dirname -- "$orca_skill_file")/../.." && pwd) || exit 1
orca_target_repo=$(git -C "$orca_repo_path" rev-parse --show-toplevel) || exit 65
```

Before running, check that the five files shown above exist in that package.
If the catalog path is missing, check its alias expansion and the matching
plugin's catalog entry. If it remains unresolved, report the supplied path
and missing files and stop. Do not select a cache version or a different
plugin installation by guessing. The script is not expected on `PATH`.

## Initialize and inspect the result

Keep the resolved paths when running subsequent commands, including retries;
shell variables may not persist across tool calls.

1. Run the script with the explicit target path. If the user asked not to
   create the repository settings file, add `--no-settings` to this and
   every retry.

   ```sh
   sh "$orca_plugin_root/scripts/orca-init.sh" "$orca_target_repo"
   ```

   Capture stdout, stderr, and the script's exit code.

2. Branch on the exit code.

   - `0` — `.claude/CLAUDE.md` was created, updated, or left unchanged.
     Check the `AGENTS.md` notes (step 3), Codex launch gate lines
     (step 4), and settings lines (step 5) before reporting completion.
     Exit 0 alone does not mean Claude and Codex rules are in sync.
   - `2` — `.claude/CLAUDE.md` exists without a marker block. Read the existing
     file and check whether it already has hand-written worktree rules. If
     anything duplicates or contradicts the block, point it out and ask the
     user whether to append the block. After approval, run
     `sh "$orca_plugin_root/scripts/orca-init.sh" --apply "$orca_target_repo"`.
   - `3` — `.codex/hooks.json` exists without the launch gate entry (the rules
     step already finished). Read the file, tell the user which hooks it
     already has and show the entry the output would add; after approval, run
     `sh "$orca_plugin_root/scripts/orca-init.sh" --apply "$orca_target_repo"`.
     The merge keeps the other hooks. `--apply` also appends the block to an `AGENTS.md`
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
     approval, rerun the same resolved script with `--apply` and the same
     target path.
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
