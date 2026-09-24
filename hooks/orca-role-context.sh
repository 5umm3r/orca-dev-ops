#!/bin/sh
# SessionStart: tell the session which side of the Orca workflow it is on.
here="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$here/orca-lib.sh"
cwd=$(jq -r '.cwd // empty')
base_ref="${CLAUDE_PLUGIN_ROOT:-$(dirname -- "$here")}/scripts/orca-base-ref.sh"
case "$(orca_role "$cwd")" in
master)
  orca_config_load "$cwd"
  if [ "$(orca_config .launch.mode)" = auto ]; then
    launch="auto (agent $(orca_config .launch.agent), model $(orca_config .launch.model), effort $(orca_config .launch.effort); no Agent/Model/Effort questions)"
  else
    launch='ask (Agent/Model/Effort questions before every launch)'
  fi
  ctx="[orca-workflow] This is the coordinator (master) session of a repository that uses the Orca worktree rules. Follow the \`orca-dev-ops\` skill.
- Implementation runs in child task worktrees, not in this checkout.
- The base ref is what \`sh \"$base_ref\"\` prints; do not assume a branch name.
- The PreToolUse guard enforces the direct-edit limits of this checkout.
- Launch mode: $launch.${ORCA_CONFIG_ERROR:+ Settings warning: $ORCA_CONFIG_ERROR}" ;;
child)
  ctx="[orca-workflow] This is a child (worker) session in an Orca task worktree. Implement the plan the coordinator sent and leave all changes uncommitted.
- Talk to the coordinator only through \`orca orchestration\`: \`ask\` for questions, \`send\` for status, and \`send --type worker_done\` once to report.
- Follow the repository's \"Orca worktree rules\"." ;;
unknown)
  ctx='[orca-workflow] The Orca role of this session (coordinator or worker) could not be determined; edits and mutating commands are blocked until it is (start Orca, or open the session in the right checkout).' ;;
*) exit 0 ;;
esac
jq -n --arg ctx "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
