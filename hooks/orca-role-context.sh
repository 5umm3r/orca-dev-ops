#!/bin/sh
# SessionStart: tell the session which side of the Orca workflow it is on.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/orca-lib.sh"
cwd=$(jq -r '.cwd // empty')
case "$(orca_role "$cwd")" in
master)
  ctx='[orca-workflow] This is the MASTER session of an Orca-managed repository. Mandatory procedure (orca-dev-ops skill):
- The master plans with the user and does the final review. Implementation always runs in a child worktree started with `orca worktree create`.
- The master controls every child through the orca CLI (orca worktree / terminal / orchestration) and never hands approval or follow-ups back to the user.
- The plan recommends an agent+model and an effort grade (max / high / normal / low) with a one-line reason. After the user explicitly approves the plan, the master asks the user once via AskUserQuestion (agent+model, effort) before starting the child; this is the one allowed user question besides decisions outside the approved plan.
- Children leave their changes uncommitted. The master reviews the diff, commits on the child branch with `git -C <worktree>`, rebases onto origin/master, fast-forwards master, pushes, and removes the worktree with `orca worktree rm`.
- Direct edits in this checkout are limited to documentation (*.md, docs/, references/, .claude/) at any size, or Edit changes to other files of at most 2 files and 20 changed lines uncommitted in total, committed on a task branch; a PreToolUse guard blocks everything else.' ;;
child)
  ctx='[orca-workflow] This is a CHILD worktree session. Implement the plan the master session sent, run the required tests, and leave all changes uncommitted. Do not commit, push, merge, rebase, or create/remove worktrees; the master session does that. Ask the master through `orca orchestration ask` when the plan is unclear, and report in four lines (result / changed files / test results / open issues) through `orca orchestration send`.' ;;
*) exit 0 ;;
esac
jq -n --arg ctx "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
