#!/bin/sh
# Tests for hooks/orca-role-guard.sh in a throwaway HOME, cache, and git repo.
guard="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/hooks/orca-role-guard.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" XDG_CACHE_HOME="$tmp/cache" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
mkdir -p "$HOME/orca/workspaces/proj/task" "$XDG_CACHE_HOME/orca-dev-ops"

repo="$tmp/repo"
mkdir -p "$repo/src" "$repo/docs"
lines() { awk -v n="$1" 'BEGIN { for (i = 1; i <= n; i++) print "line " i }'; }
for f in src/a.sh src/b.sh src/c.sh README.md; do lines 30 > "$repo/$f"; done
git -C "$repo" init -q && git -C "$repo" add -A && git -C "$repo" commit -qm init || exit 1
printf '%s\n' "$repo" > "$XDG_CACHE_HOME/orca-dev-ops/repos"

reset() { git -C "$repo" reset -q --hard && git -C "$repo" clean -qfd; }
# Rewrites the first $2 lines of tracked file $1.
change() { awk -v n="$2" 'NR <= n { print "changed " NR; next } { print }' "$repo/$1" > "$tmp/x" && mv "$tmp/x" "$repo/$1"; }

fail=0
# check <name> <allow|deny> <json>
check() {
  out=$(printf '%s' "$3" | sh "$guard")
  if printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then got=deny
  elif [ -z "$out" ]; then got=allow
  else got="unexpected: $out"
  fi
  if [ "$got" = "$2" ]; then echo "PASS $1"; else echo "FAIL $1 (expected $2, got $got)"; fail=1; fi
}
write() { jq -n --arg cwd "${2:-$repo}" --arg f "$1" '{cwd:$cwd,tool_name:"Write",tool_input:{file_path:$f,content:"x"}}'; }
# edit <path> <new_string line count> [replace_all]
edit() { jq -n --arg cwd "$repo" --arg f "$1" --arg s "$(lines "$2")" --argjson all "${3:-false}" '{cwd:$cwd,tool_name:"Edit",tool_input:{file_path:$f,old_string:"line 1",new_string:$s,replace_all:$all}}'; }

check "Write README.md" allow "$(write "$repo/README.md")"
check "Write docs/x.txt" allow "$(write "$repo/docs/x.txt")"
check "Write a/b/SKILL.md" allow "$(write "$repo/a/b/SKILL.md")"
check "Write src/new.sh" deny "$(write "$repo/src/new.sh")"

check "Edit 20 lines, clean tree" allow "$(edit "$repo/src/a.sh" 20)"
check "Edit 21 lines, clean tree" deny "$(edit "$repo/src/a.sh" 21)"
check "Edit replace_all non-doc" deny "$(edit "$repo/src/a.sh" 1 true)"

change src/a.sh 15
check "15 existing + Edit same file 6 lines" deny "$(edit "$repo/src/a.sh" 6)"
check "15 existing + Edit same file 5 lines" allow "$(edit "$repo/src/a.sh" 5)"
reset

change src/a.sh 1; change src/b.sh 1
check "a+b changed + Edit c 1 line" deny "$(edit "$repo/src/c.sh" 1)"
check "a+b changed + Edit a 1 line" allow "$(edit "$repo/src/a.sh" 1)"
reset

change README.md 30; lines 70 >> "$repo/README.md"
check "large docs-only change + Edit src 3 lines" allow "$(edit "$repo/src/a.sh" 3)"
reset

lines 10 > "$repo/src/new.sh"; change src/a.sh 1
check "untracked + a changed + Edit b" deny "$(edit "$repo/src/b.sh" 1)"
reset

check "master Edit under workspaces" deny "$(edit "$HOME/orca/workspaces/proj/task/src/a.sh" 1)"
check "child Bash git commit" deny "$(jq -n --arg cwd "$HOME/orca/workspaces/proj/task" '{cwd:$cwd,tool_name:"Bash",tool_input:{command:"git commit -m x"}}')"

exit "$fail"
