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
  rel=${f#"$repo"/}
  # Documentation: any tool, any size.
  case "$rel" in .claude/*|references/*|docs/*|*.md) exit 0 ;; esac
  limit="Implementation happens in a child worktree (orca worktree create). The master checkout allows documentation (*.md, docs/, references/, .claude/) at any size; other files Edit only, at most 2 files and 20 changed lines uncommitted in total. Commit on a task branch, never on master; otherwise use a child worktree."
  case "$tool" in Edit|MultiEdit) ;; *) deny "$limit" ;; esac
  # Lines this edit changes; empty when any edit uses replace_all.
  n=$(printf '%s' "$input" | jq '[(.tool_input.edits // [.tool_input]) | .[] | select(.replace_all != true) | [.old_string, .new_string] | map(. // "" | split("\n") | length) | max] as $n | if ($n | length) == ((.tool_input.edits // [.tool_input]) | length) then ($n | add // 0) else empty end')
  [ -z "$n" ] && deny "$limit"
  # Existing uncommitted changes (tracked and untracked) as "added<TAB>deleted<TAB>path"; skipped when git fails.
  if existing=$(git -C "$repo" diff HEAD --numstat 2>/dev/null); then
    untracked=$(git -C "$repo" ls-files --others --exclude-standard 2>/dev/null | while IFS= read -r u; do
      [ -f "$repo/$u" ] && printf '%s\t0\t%s\n' "$(wc -l < "$repo/$u" | tr -d ' ')" "$u"
    done)
  else
    existing= untracked=
  fi
  # Non-doc files: per-file max(added, deleted), binary ("-") is over the limit.
  fits=$(printf '%s\n%s\n%s\t0\t%s\n' "$existing" "$untracked" "$n" "$rel" | awk -F '\t' '
    NF < 3 || $3 ~ /^(\.claude|references|docs)\// || $3 ~ /\.md$/ { next }
    { c = ($1 == "-" || $2 == "-") ? 21 : ($1 + 0 > $2 + 0 ? $1 + 0 : $2 + 0)
      if (!($3 in seen)) { seen[$3] = 1; files++ }
      total += c }
    END { print (files <= 2 && total <= 20) ? "yes" : "no" }')
  [ "$fits" = yes ] && exit 0
  deny "$limit"
  ;;
esac
exit 0
