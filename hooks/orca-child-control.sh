#!/bin/sh
# PostToolUse(Bash): after a child-start command, remind the master session that it owns the child end to end.
cmd=$(jq -r '.tool_input.command // empty')
printf '%s' "$cmd" | grep -Eq "(^|[;&|(\`[:space:]])orca[[:space:]]+worktree[[:space:]]+create([[:space:]]|\$)" && matched=1
printf '%s' "$cmd" | grep -Eq "(^|[;&|(\`[:space:]])orca[[:space:]]+orchestration[[:space:]]+worker-start([[:space:]]|\$)" && matched=1
[ -n "$matched" ] || exit 0
ctx='[orca-child-control] The master session (this one) owns this child worktree until cleanup; never hand approval or follow-ups back to the user.
- Start it with the orca-dev-ops skill'\''s "Starting a child" sequence, not a shortcut.
- Keep a monitor running per the skill'\''s "Communication and state" while the child is active; never end a turn without it armed.
- Review before integrating, per the skill'\''s "Review, integration, cleanup"; a success report is not review.'
jq -n --arg ctx "$ctx" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}'
