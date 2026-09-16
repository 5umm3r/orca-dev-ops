#!/bin/sh
# PostToolUse(Bash): after `orca worktree create`, remind the master session that it owns the child end to end.
cmd=$(jq -r '.tool_input.command // empty')
case "$cmd" in
  *"orca worktree create"*) ;;
  *) exit 0 ;;
esac
ctx='[orca-child-control] The master session controls this child worktree itself; never hand approval or follow-ups back to the user.
1. Find the agent terminal: orca terminal list --worktree name:<name>.
2. Run `orca terminal wait --terminal <handle> --for tui-idle --timeout-ms 3600000` in the background (run_in_background), then read the screen with `orca terminal read --terminal <handle> --screen | tail`. Answer questions with `orca terminal send --terminal <handle> --text "..." --enter --wait-submit 20`; ask the user only for decisions outside the approved plan.
3. When the four-line report arrives, do the final review in the master: `git -C <worktree> status --short` and `git -C <worktree> diff` against the declared scope. Send fixes back to the child if needed.
4. Commit and ship from the master: `git -C <worktree> add -A && git -C <worktree> commit`, `git fetch origin && git -C <worktree> rebase origin/master` (rerun the required tests in the child if the base moved), `git merge --ff-only <branch>` in the master checkout, `git push origin master`.
5. Clean up: `orca worktree rm --worktree name:<name>`.'
jq -n --arg ctx "$ctx" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}'
