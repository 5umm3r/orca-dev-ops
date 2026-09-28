---
description: Install the generic "Orca worktree rules" block and the Codex launch gate in this repository
allowed-tools: Bash(sh:*), Read
---

Read `${CLAUDE_PLUGIN_ROOT}/skills/orca-init/SKILL.md` and follow its shared
initialization procedure. Use `${CLAUDE_PLUGIN_ROOT}` as the plugin root and
the user's requested repository (otherwise the session's project directory)
as the target. Preserve any supplied initialization options.

If the skill file is missing, report that exact path and stop.
