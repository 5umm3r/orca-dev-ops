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

# Child Bash: destructive and external operations. The own-worktree check needs a git repo.
child="$HOME/orca/workspaces/proj/task"
git -C "$child" init -q || exit 1
run() { jq -n --arg cwd "${2:-$child}" --arg c "$1" '{cwd:$cwd,tool_name:"Bash",tool_input:{command:$c}}'; }

check "child rm -rf node_modules dist" allow "$(run 'rm -rf node_modules dist')"
check "child rm -rf <own>/dist" allow "$(run "rm -rf $child/dist")"
check "child rm -rf \$HOME path inside own" allow "$(run 'rm -rf "$HOME/orca/workspaces/proj/task/dist"')"
check "child rm -rf /tmp/x" deny "$(run 'rm -rf /tmp/x')"
check "child rm -r ~/x" deny "$(run 'rm -r ~/x')"
check "child rm --recursive --force \$HOME/orca" deny "$(run 'rm --recursive --force $HOME/orca')"
check "child rm -fr ../other" deny "$(run 'rm -fr ../other')"
check "child rm -rf <own> root" deny "$(run "rm -rf $child")"
check "child npm test && rm -rf /" deny "$(run 'npm test && rm -rf /')"

check "child git status" allow "$(run 'git status')"
check "child git diff" allow "$(run 'git diff')"
check "child git branch -a" allow "$(run 'git branch -a')"
check "child git clean -n" allow "$(run 'git clean -n')"
check "child git reset --hard" deny "$(run 'git reset --hard')"
check "child git reset HEAD~1 --hard" deny "$(run 'git reset HEAD~1 --hard')"
check "child git clean -fd" deny "$(run 'git clean -fd')"
check "child git branch -D x" deny "$(run 'git branch -D x')"
check "child git branch -d x" deny "$(run 'git branch -d x')"
check "child git branch --delete x" deny "$(run 'git branch --delete x')"
check "child git stash drop" deny "$(run 'git stash drop')"
check "child git stash clear" deny "$(run 'git stash clear')"
check "child git update-ref" deny "$(run 'git update-ref -d refs/heads/x')"

check "child git -C <own> status" allow "$(run "git -C $child status")"
check "child git -C <own> add" allow "$(run "git -C $child add -A")"
check "child git -C <other> log" allow "$(run "git -C $repo log")"
check "child git -C <other> checkout" deny "$(run "git -C $repo checkout -b x")"
check "child git -C ../other add" deny "$(run 'git -C ../other add -A')"

check "child npm test" allow "$(run 'npm test')"
check "child npm publish" deny "$(run 'npm publish')"
check "child pnpm publish" deny "$(run 'pnpm publish --no-git-checks')"
check "child yarn publish" deny "$(run 'yarn publish')"
check "child gh pr merge" deny "$(run 'gh pr merge 1 --squash')"
check "child gh pr view" allow "$(run 'gh pr view 1')"
check "child gh repo delete" deny "$(run 'gh repo delete x --yes')"
check "child gh release create" deny "$(run 'gh release create v1')"
check "child gh release upload" deny "$(run 'gh release upload v1 a.zip')"
check "child supabase db reset" deny "$(run 'supabase db reset')"
check "child npx supabase db push" deny "$(run 'npx supabase db push')"
check "child wrangler deploy" deny "$(run 'npx wrangler deploy')"
check "child wrangler delete" deny "$(run 'wrangler delete')"
check "child firebase deploy" deny "$(run 'firebase deploy --only hosting')"

check "master git reset --hard" allow "$(run 'git reset --hard' "$repo")"
check "master rm -rf /tmp/x" allow "$(run 'rm -rf /tmp/x' "$repo")"

exit "$fail"
