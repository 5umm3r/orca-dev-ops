#!/bin/sh
# PreToolUse guard: master plans, reviews, commits and pushes; child worktrees only implement.
# Misoperation prevention by string and path matching, not a sandbox. It applies to Claude
# sessions only; Codex is limited by its own sandbox flags and the AGENTS.md rules.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/orca-lib.sh"
input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
role=$(orca_role "$cwd")
# Out of scope: this repository did not opt into the Orca worktree rules.
[ "$role" = none ] && exit 0

unknown="The Orca role of this session could not be determined: Orca did not identify this checkout and git could not tell the main checkout from a linked worktree, or the two disagreed. Edits and mutating commands are blocked until the role is known. Start Orca, or run the session inside the right checkout (the main checkout for the coordinator, the task worktree for a worker)."
deny() {
  jq -n --arg r "[orca-guard] $1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}
# Deny for the child rules; an unknown role gets the same denies with the role explanation first.
cdeny() { [ "$role" = unknown ] && deny "$unknown Blocked: $1"; deny "$1"; }
# Matches a git subcommand at a command boundary, with an optional -C <path> (quoted or not).
git_sub() { printf '%s' "$cmd" | grep -Eq "(^|[;&|(\`[:space:]])git([[:space:]]+-C[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:]]+))?[[:space:]]+($1)([[:space:]]|\$)"; }
# Matches a command at a command boundary.
cmd_has() { printf '%s' "$cmd" | grep -Eq "(^|[;&|(\`[:space:]])($1)([[:space:]]|\$)"; }
# Subcommands given to every `orca <group>` in the command, one per line (empty line: none).
orca_subs() {
  printf '%s' "$cmd" | grep -Eo "(^|[;&|(\`[:space:]/])orca[[:space:]]+$1([[:space:]]+[^[:space:];&|)]+)?" \
    | sed -E "s/.*orca[[:space:]]+$1[[:space:]]*//"
}
# Joins backslash-newline line continuations outside single quotes, as the shell does, so
# every later check sees `rm -rf \<newline>/x` as `rm -rf /x`.
join_lines() {
  awk 'BEGIN { q = "" }
    { out = ""; cont = 0
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (q == "\047") { if (c == q) q = ""; out = out c; continue }
        if (c == "\\") { if (i == length($0)) { cont = 1; break }; out = out c substr($0, i + 1, 1); i++; continue }
        if (q == "\"") { if (c == q) q = ""; out = out c; continue }
        if (c == "\047" || c == "\"") q = c
        out = out c
      }
      printf "%s%s", out, (cont ? "" : "\n")
    }'
}
# The simple commands in $cmd, one per line, words separated by \037, with quotes and
# backslashes resolved (no expansion). Splits on ; & | ( ) ` and unquoted newlines.
commands() {
  printf '%s\n' "$cmd" | awk 'BEGIN { US = sprintf("%c", 31); q = "" }
    function word() { if (inw) { out = out (n++ ? US : "") w; w = ""; inw = 0 } }
    function flush() { word(); if (n) print out; out = ""; n = 0 }
    { for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (q != "") {
          if (c == q) q = ""
          else if (c == "\\" && q == "\"" && i < length($0)) { i++; w = w substr($0, i, 1) }
          else w = w c
          continue
        }
        if (c == "\047" || c == "\"") { q = c; inw = 1; continue }
        if (c == "\\") { if (i < length($0)) { i++; w = w substr($0, i, 1) }; inw = 1; continue }
        if (c == " " || c == "\t") { word(); continue }
        if (index(";&|()`", c)) { flush(); continue }
        w = w c; inw = 1
      }
      if (q == "") flush(); else w = w "\n"
    }
    END { flush() }'
}
# Word index of the command name after assignments and wrappers such as sudo or env.
skip_prefix='i = 1; while (i <= NF && ($i ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || $i ~ /^(sudo|command|env|nohup|time|exec|\{|!)$/)) i++; w = $i; sub(/.*\//, "", w)'
# Targets of every `rm` that has -r, -R, -f, --recursive, or --force, one per line.
rm_targets() {
  commands | awk "BEGIN { FS = sprintf(\"%c\", 31) } { $skip_prefix"'
    if (w != "rm") next
    force = 0; n = 0; opts = 1
    for (i++; i <= NF; i++) {
      t = $i
      if (opts && t == "--") { opts = 0; continue }
      if (opts && t ~ /^--(recursive|force)$/) { force = 1; continue }
      if (opts && t ~ /^-[A-Za-z]+$/) { if (t ~ /[rRf]/) force = 1; continue }
      if (opts && t ~ /^-/) continue
      a[++n] = t
    }
    if (force) for (i = 1; i <= n; i++) print a[i]
  }'
}
# "<subcommand><TAB><path>" for every `git -C <path> <subcommand>`.
git_c() {
  commands | awk "BEGIN { FS = sprintf(\"%c\", 31) } { $skip_prefix"'
    if (w == "git" && $(i + 1) == "-C" && i + 2 <= NF) print $(i + 3) "\t" $(i + 2)
  }'
}
# True when physical path $1 is inside the own worktree; $2 = root also accepts the worktree root itself.
in_own() { [ -n "$own" ] && orca_under "$1" "$own" && { [ "$2" = root ] || [ "$1" != "$own" ]; }; }

# The own checkout: top level of the session's cwd, physical.
own=$(orca_top "$(orca_abspath "$cwd" /)")

case "$tool" in
Bash)
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' | join_lines)
  if [ "$role" = master ]; then
    git_sub 'worktree[[:space:]]+(add|remove|prune)' && deny "Use the orca CLI (orca worktree create / orca worktree rm) instead of raw git worktree commands."
    exit 0
  fi
  # child, or unknown in scope.
  git_sub 'commit|push|merge|rebase|cherry-pick|am|revert' && cdeny "Child worktree sessions do not commit, push, merge, or rebase. Leave the changes uncommitted and report; the master session reviews, commits, rebases, merges, and pushes."

  # orca CLI: a worker talks to its coordinator and reads state; the master session creates
  # worktrees, terminals, runs, tasks, and dispatches.
  bad=$(orca_subs worktree | while IFS= read -r s; do
    case "$s" in (create | rm | remove | set) printf '%s\n' "$s"; break ;; esac
  done)
  [ -n "$bad" ] && cdeny "Only the master session creates, removes, or updates worktrees (orca worktree $bad)."
  bad=$(orca_subs terminal | while IFS= read -r s; do
    case "$s" in (create | close | send | split) printf '%s\n' "$s"; break ;; esac
  done)
  [ -n "$bad" ] && cdeny "Only the master session creates, closes, or sends input to terminals (orca terminal $bad). Talk to the coordinator with orca orchestration ask / send."
  bad=$(orca_subs orchestration | while IFS= read -r s; do
    case "$s" in
    ('' | -h | --help | ask | send | check | reply | dispatch-show | worker-show | run-current | task-list | inbox | request-show) ;;
    (*) printf '%s\n' "$s"; break ;;
    esac
  done)
  [ -n "$bad" ] && cdeny "A worker uses only orca orchestration ask, send, check, reply, dispatch-show, worker-show, run-current, task-list, inbox, and request-show; orca orchestration $bad belongs to the master session."

  # Destructive and external operations. String matching is best effort, not a sandbox:
  # it catches the usual spellings of these commands, not every way to run them.
  ask='Ask the master session if this is really needed.'
  git_sub 'reset[[:space:]]+([^;&|]*[[:space:]])?--hard' && cdeny "Blocked git reset --hard in a child worktree. $ask"
  git_sub 'clean[[:space:]]+([^;&|]*[[:space:]])?(-[[:alpha:]]*f[[:alpha:]]*|--force)' && cdeny "Blocked git clean -f in a child worktree. $ask"
  git_sub 'branch[[:space:]]+([^;&|]*[[:space:]])?(-[[:alpha:]]*[dD][[:alpha:]]*|--delete)' && cdeny "Blocked git branch deletion in a child worktree. $ask"
  git_sub 'stash[[:space:]]+(drop|clear)' && cdeny "Blocked git stash drop/clear; the stash is shared by every worktree. $ask"
  git_sub 'update-ref' && cdeny "Blocked git update-ref in a child worktree. $ask"

  # git -C <path>: a path outside the own worktree is allowed only for read-only subcommands.
  outside=$(git_c | while IFS="$(printf '\t')" read -r sub p; do
    case "$sub" in (status | diff | log | show | rev-parse | ls-files | blame | grep) continue ;; esac
    in_own "$(orca_abspath "$p" "$cwd")" root || { printf '%s\n' "$p"; break; }
  done)
  [ -n "$outside" ] && cdeny "Blocked git -C $outside: it is outside this worktree ($own) and the subcommand is not read-only. $ask"

  # rm -r/-f: relative targets without .. are fine; absolute, ~, $HOME, or .. targets must resolve inside the own worktree.
  outside=$(rm_targets | while IFS= read -r t; do
    case "$t" in
    ('~'[!/]*) printf '%s\n' "$t"; break ;;
    (/* | '~'* | '$HOME'* | '${HOME}'* | *..*) ;;
    (*) continue ;;
    esac
    in_own "$(orca_abspath "$t" "$cwd")" || { printf '%s\n' "$t"; break; }
  done)
  [ -n "$outside" ] && cdeny "Blocked rm -r/-f on $outside: it is not inside this worktree ($own). $ask"

  cmd_has '(npm|pnpm|yarn)[[:space:]]+publish' && cdeny "Blocked package publish. $ask"
  cmd_has 'gh[[:space:]]+pr[[:space:]]+merge' && cdeny "Blocked gh pr merge; the master session merges. $ask"
  cmd_has 'gh[[:space:]]+repo[[:space:]]+delete' && cdeny "Blocked gh repo delete. $ask"
  cmd_has 'gh[[:space:]]+release[[:space:]]+(create|delete|upload|edit)' && cdeny "Blocked gh release changes. $ask"
  cmd_has 'supabase[[:space:]]+db[[:space:]]+(reset|push)' && cdeny "Blocked supabase db reset/push. $ask"
  cmd_has 'wrangler[[:space:]]+(deploy|delete)' && cdeny "Blocked wrangler deploy/delete. $ask"
  cmd_has 'firebase[[:space:]]+deploy' && cdeny "Blocked firebase deploy. $ask"
  ;;
Edit|MultiEdit|Write|NotebookEdit)
  f=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
  [ -z "$f" ] && exit 0
  [ "$role" = unknown ] && deny "$unknown"
  f=$(orca_abspath "$f" "$cwd")
  ftop=$(orca_top "$f")
  # Outside any checkout (scratch dirs, /tmp): allowed.
  [ -z "$ftop" ] && exit 0
  # Checkouts of the session's own repository: the main checkout first, then linked worktrees.
  same=$(orca_worktrees "$own" | grep -Fx -- "$ftop")
  if [ "$role" = child ]; then
    [ "$ftop" = "$own" ] && exit 0
    if [ -n "$same" ] || orca_scoped "$ftop"; then
      deny "A child worktree session edits only its own worktree ($own), not $ftop."
    fi
    exit 0
  fi
  # master
  if [ "$ftop" != "$own" ]; then
    [ -n "$same" ] && deny "The master session does not edit linked worktrees ($ftop). Send instructions to the child through orca orchestration."
    orca_scoped "$ftop" || exit 0
    [ "$(orca_git_kind "$ftop")" = master ] || deny "The master session does not edit linked worktrees ($ftop)."
  fi
  repo=$ftop
  rel=${f#"$repo"/}
  # Documentation: any tool, any size.
  case "$rel" in .claude/*|references/*|docs/*|*.md) exit 0 ;; esac
  limit="Implementation happens in a child worktree (orca worktree create). This main checkout allows documentation (*.md, docs/, references/, .claude/) at any size; other files Edit only, at most 2 files and 20 changed lines uncommitted in total. Documentation-only commits go directly on the base branch and push; a commit with any non-documentation file goes on a task branch, never directly on the base branch."
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
