#!/bin/sh
# PreToolUse guard: master plans, reviews, commits and pushes; child worktrees only implement.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/orca-lib.sh"
input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
role=$(orca_role "$cwd")
[ "$role" = none ] && exit 0

deny() {
  jq -n --arg r "[orca-guard] $1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}
# Matches a git subcommand at a command boundary, with an optional -C <path>.
git_sub() { printf '%s' "$cmd" | grep -Eq "(^|[;&|(\`[:space:]])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+($1)([[:space:]]|\$)"; }

case "$tool" in
Bash)
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
  if [ "$role" = child ]; then
    git_sub 'commit|push|merge|rebase|cherry-pick|am|revert' && deny "Child worktree sessions do not commit, push, merge, or rebase. Leave the changes uncommitted and report; the master session reviews, commits, rebases, merges, and pushes."
    printf '%s' "$cmd" | grep -Eq '(^|[;&|(`[:space:]])orca[[:space:]]+worktree[[:space:]]+(create|rm|remove)([[:space:]]|$)' && deny "Only the master session creates or removes worktrees."
  else
    git_sub 'worktree[[:space:]]+(add|remove|prune)' && deny "Use the orca CLI (orca worktree create / orca worktree rm) instead of raw git worktree commands."
  fi
  ;;
Edit|MultiEdit|Write|NotebookEdit)
  f=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
  [ -z "$f" ] && exit 0
  if [ "$role" = child ]; then
    own=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
    [ -n "$own" ] && orca_under "$f" "$own" && exit 0
    if orca_under "$f" "$ORCA_WS" || [ -n "$(orca_repo_of "$f")" ]; then
      deny "A child worktree session edits only its own worktree ($own)."
    fi
    exit 0
  fi
  orca_under "$f" "$ORCA_WS" && deny "The master session does not edit child worktrees. Send instructions with orca terminal send."
  repo=$(orca_repo_of "$f")
  [ -z "$repo" ] && exit 0
  case "${f#"$repo"/}" in .claude/*|references/*) exit 0 ;; esac
  case "$tool" in
  Edit|MultiEdit)
    small=$(printf '%s' "$input" | jq '[(.tool_input.edits // [.tool_input]) | .[] | select(.replace_all != true) | [.old_string, .new_string] | map(split("\n") | length) | max] as $n | ($n | length) == ((.tool_input.edits // [.tool_input]) | length) and ($n | add) <= 5')
    [ "$small" = true ] && exit 0
    ;;
  esac
  deny "Implementation happens in a child worktree (orca worktree create). The master checkout allows direct edits only under .claude/ or references/, or Edit changes of at most 5 lines; commit those on a task branch, never on master."
  ;;
esac
exit 0
