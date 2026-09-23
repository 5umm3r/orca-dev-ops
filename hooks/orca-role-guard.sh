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
# Matches a command at a command boundary.
cmd_has() { printf '%s' "$cmd" | grep -Eq "(^|[;&|(\`[:space:]])($1)([[:space:]]|\$)"; }
# Absolute, lexically normalized form of path $1: ~ and $HOME expanded, relative paths resolved against $cwd.
abspath() {
  p=$1
  case "$p" in
  '~' | '~/'*) p=$HOME${p#?} ;;
  '$HOME' | '$HOME/'*) p=$HOME${p#?????} ;;
  '${HOME}' | '${HOME}/'*) p=$HOME${p#???????} ;;
  esac
  case "$p" in /*) ;; *) p=$cwd/$p ;; esac
  printf '%s\n' "$p" | awk -F / '{ n = 0
    for (i = 1; i <= NF; i++) { if ($i == "" || $i == ".") continue; if ($i == "..") { if (n) n--; continue } s[++n] = $i }
    o = ""; for (i = 1; i <= n; i++) o = o "/" s[i]; print (o == "" ? "/" : o) }'
}
# True when normalized path $1 is inside the own worktree; $2 = root also accepts the worktree root itself.
in_own() {
  for o in "$own" "$own_l"; do
    [ -n "$o" ] && orca_under "$1" "$o" && { [ "$2" = root ] || [ "$1" != "$o" ]; } && return 0
  done
  return 1
}
# Targets of every `rm` that has -r, -R, -f, --recursive, or --force, one per line, quotes stripped.
rm_targets() {
  printf '%s\n' "$cmd" | awk '{ gsub(/&&|\|\||[;&|()`]/, "\n"); print }' | awk '{
    i = 1
    while (i <= NF && ($i ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || $i ~ /^(sudo|command|env|nohup|time|exec|\{|!)$/)) i++
    w = $i; gsub(/["\047]/, "", w); sub(/.*\//, "", w)
    if (w != "rm") next
    force = 0; n = 0; opts = 1
    for (i++; i <= NF; i++) {
      t = $i; gsub(/["\047]/, "", t)
      if (opts && t == "--") { opts = 0; continue }
      if (opts && t ~ /^--(recursive|force)$/) { force = 1; continue }
      if (opts && t ~ /^-[A-Za-z]+$/) { if (t ~ /[rRf]/) force = 1; continue }
      if (opts && t ~ /^-/) continue
      a[++n] = t
    }
    if (force) for (i = 1; i <= n; i++) print a[i]
  }'
}

case "$tool" in
Bash)
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
  if [ "$role" = child ]; then
    git_sub 'commit|push|merge|rebase|cherry-pick|am|revert' && deny "Child worktree sessions do not commit, push, merge, or rebase. Leave the changes uncommitted and report; the master session reviews, commits, rebases, merges, and pushes."
    printf '%s' "$cmd" | grep -Eq '(^|[;&|(`[:space:]])orca[[:space:]]+worktree[[:space:]]+(create|rm|remove)([[:space:]]|$)' && deny "Only the master session creates or removes worktrees."

    # Destructive and external operations. String matching is best effort, not a sandbox:
    # it catches the usual spellings of these commands, not every way to run them.
    ask='Ask the master session if this is really needed.'
    git_sub 'reset[[:space:]]+([^;&|]*[[:space:]])?--hard' && deny "Blocked git reset --hard in a child worktree. $ask"
    git_sub 'clean[[:space:]]+([^;&|]*[[:space:]])?(-[[:alpha:]]*f[[:alpha:]]*|--force)' && deny "Blocked git clean -f in a child worktree. $ask"
    git_sub 'branch[[:space:]]+([^;&|]*[[:space:]])?(-[[:alpha:]]*[dD][[:alpha:]]*|--delete)' && deny "Blocked git branch deletion in a child worktree. $ask"
    git_sub 'stash[[:space:]]+(drop|clear)' && deny "Blocked git stash drop/clear; the stash is shared by every worktree. $ask"
    git_sub 'update-ref' && deny "Blocked git update-ref in a child worktree. $ask"

    # Own worktree: physical path from git, plus the logical path the session sees through $cwd.
    own=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
    own_l=
    if [ -n "$own" ]; then
      prefix=$(git -C "$cwd" rev-parse --show-prefix 2>/dev/null)
      own_l=${cwd%/}
      own_l=${own_l%/"${prefix%/}"}
    fi

    # git -C <path>: a path outside the own worktree is allowed only for read-only subcommands.
    outside=$(printf '%s' "$cmd" | grep -Eo "(^|[;&|(\`[:space:]])git[[:space:]]+-C[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:];&|)]+" | tr -d "\"'" | while read -r _ _ p sub; do
      case "$sub" in (status | diff | log | show | rev-parse | ls-files | blame | grep) continue ;; esac
      in_own "$(abspath "$p")" root || { printf '%s\n' "$p"; break; }
    done)
    [ -n "$outside" ] && deny "Blocked git -C $outside: it is outside this worktree ($own) and the subcommand is not read-only. $ask"

    # rm -r/-f: relative targets without .. are fine; absolute, ~, $HOME, or .. targets must resolve inside the own worktree.
    outside=$(rm_targets | while IFS= read -r t; do
      case "$t" in
      ('~'[!/]*) printf '%s\n' "$t"; break ;;
      (/* | '~'* | '$HOME'* | '${HOME}'* | *..*) ;;
      (*) continue ;;
      esac
      in_own "$(abspath "$t")" || { printf '%s\n' "$t"; break; }
    done)
    [ -n "$outside" ] && deny "Blocked rm -r/-f on $outside: it is not inside this worktree ($own). $ask"

    cmd_has '(npm|pnpm|yarn)[[:space:]]+publish' && deny "Blocked package publish. $ask"
    cmd_has 'gh[[:space:]]+pr[[:space:]]+merge' && deny "Blocked gh pr merge; the master session merges. $ask"
    cmd_has 'gh[[:space:]]+repo[[:space:]]+delete' && deny "Blocked gh repo delete. $ask"
    cmd_has 'gh[[:space:]]+release[[:space:]]+(create|delete|upload|edit)' && deny "Blocked gh release changes. $ask"
    cmd_has 'supabase[[:space:]]+db[[:space:]]+(reset|push)' && deny "Blocked supabase db reset/push. $ask"
    cmd_has 'wrangler[[:space:]]+(deploy|delete)' && deny "Blocked wrangler deploy/delete. $ask"
    cmd_has 'firebase[[:space:]]+deploy' && deny "Blocked firebase deploy. $ask"
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
  limit="Implementation happens in a child worktree (orca worktree create). The master checkout allows documentation (*.md, docs/, references/, .claude/) at any size; other files Edit only, at most 2 files and 20 changed lines uncommitted in total. Documentation-only commits go directly on master and push; a commit with any non-documentation file goes on a task branch, never directly on master."
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
