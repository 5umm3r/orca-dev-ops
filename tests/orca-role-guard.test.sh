#!/bin/sh
# Tests for hooks/orca-role-guard.sh in a throwaway HOME with a stub orca and throwaway git repos.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"
guard="$root/hooks/orca-role-guard.sh"

# Main checkout of an in-scope repository; the path has a space and is outside ~/orca/workspaces.
repo="$tmp/dev/my repo"
mkdir -p "$repo/src" "$repo/docs"
for f in src/a.sh src/b.sh src/c.sh README.md; do lines 30 > "$repo/$f"; done
marker "$repo"
new_repo "$repo"
# Its linked worktrees: the child session's own, reached directly and through a symlink, and a sibling.
child="$HOME/work trees/task one"
sibling="$tmp/elsewhere/task two"
mkdir -p "$HOME/work trees" "$tmp/elsewhere"
git -C "$repo" worktree add -q -b task-one "$child" && git -C "$repo" worktree add -q -b task-two "$sibling" || exit 1
ln -s "$HOME/work trees" "$tmp/wt-link"
child_link="$tmp/wt-link/task one"
# Another in-scope repository with a linked worktree.
other="$tmp/other"; mkdir -p "$other"; marker "$other"; new_repo "$other"
git -C "$other" worktree add -q -b t "$tmp/other-task" || exit 1
# A repository that did not opt in; Orca still lists it and its linked worktree.
plain="$tmp/plain"; mkdir -p "$plain"; lines 3 > "$plain/a.sh"; new_repo "$plain"
git -C "$plain" worktree add -q -b t "$tmp/plain-task" || exit 1
# An in-scope worktree whose .git points nowhere: git cannot tell its kind.
broken="$tmp/broken"; marker "$broken"; printf 'gitdir: %s\n' "$tmp/nowhere" > "$broken/.git"
# In-scope checkouts where Orca and git disagree.
git -C "$repo" worktree add -q -b liar "$tmp/liar" || exit 1
liar_main="$tmp/liar-main"; mkdir -p "$liar_main"; marker "$liar_main"; new_repo "$liar_main"

orca_knows "$repo" main
orca_knows "$child" linked
orca_knows "$sibling" linked
orca_knows "$other" main
orca_knows "$tmp/other-task" linked
orca_knows "$plain" main
orca_knows "$tmp/plain-task" linked
orca_knows "$tmp/liar" main
orca_knows "$liar_main" linked

reset() { git -C "$repo" reset -q --hard && git -C "$repo" clean -qfd; }
# Rewrites the first $2 lines of tracked file $1.
change() { awk -v n="$2" 'NR <= n { print "changed " NR; next } { print }' "$repo/$1" > "$tmp/x" && mv "$tmp/x" "$repo/$1"; }

# check <name> <allow|deny> <json>
check() {
  out=$(printf '%s' "$3" | sh "$guard")
  if printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then got=deny
  elif [ -z "$out" ]; then got=allow
  else got="unexpected: $out"
  fi
  result "$1" "$2" "$got"
}
# reason <json>: the deny reason the guard gives.
reason() { printf '%s' "$1" | sh "$guard" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'; }
write() { jq -n --arg cwd "${2:-$repo}" --arg f "$1" '{cwd:$cwd,tool_name:"Write",tool_input:{file_path:$f,content:"x"}}'; }
# edit <path> <new_string line count> [replace_all]
edit() { jq -n --arg cwd "$repo" --arg f "$1" --arg s "$(lines "$2")" --argjson all "${3:-false}" '{cwd:$cwd,tool_name:"Edit",tool_input:{file_path:$f,old_string:"line 1",new_string:$s,replace_all:$all}}'; }
run() { jq -n --arg cwd "${2:-$child}" --arg c "$1" '{cwd:$cwd,tool_name:"Bash",tool_input:{command:$c}}'; }

# --- master: direct-edit limits in the main checkout
check "Write README.md" allow "$(write "$repo/README.md")"
check "Write docs/x.txt" allow "$(write "$repo/docs/x.txt")"
check "Write a/b/SKILL.md" allow "$(write "$repo/a/b/SKILL.md")"
check "Write .claude/settings.json" allow "$(write "$repo/.claude/settings.json")"
check "Write src/new.sh" deny "$(write "$repo/src/new.sh")"
check "Write relative src/rel.sh" deny "$(write src/rel.sh)"
msg=$(reason "$(write "$repo/src/new.sh")")
result "master limit message says base branch" yes "$(printf '%s' "$msg" | grep -q 'base branch' && echo yes)"
result "master limit message never names master as a branch" no "$(printf '%s' "$msg" | grep -Eq 'on master|master checkout' && echo yes || echo no)"

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

# --- master: other checkouts
check "master Edit into linked worktree" deny "$(edit "$child/src/a.sh" 1)"
check "master Write into linked worktree README" deny "$(write "$sibling/README.md")"
check "master Edit into linked worktree via symlink" deny "$(edit "$child_link/src/a.sh" 1)"
check "master Write into other repo's linked worktree" deny "$(write "$tmp/other-task/x.md")"
check "master Write src into other in-scope main checkout" deny "$(write "$other/src/x.sh")"
check "master Write docs into other in-scope main checkout" allow "$(write "$other/docs/x.md")"
check "master Write into out-of-scope repo" allow "$(write "$plain/x.sh")"
check "master Write into scratch dir" allow "$(write "$tmp/scratch/x.sh")"
check "master git reset --hard" allow "$(run 'git reset --hard' "$repo")"
check "master rm -rf /tmp/x" allow "$(run 'rm -rf /tmp/x' "$repo")"
check "master git worktree add" deny "$(run 'git worktree add ../x' "$repo")"
check "master orca orchestration worker-start" allow "$(run 'orca orchestration worker-start --task t' "$repo")"

# --- child: Bash
check "child Bash git commit" deny "$(run 'git commit -m x')"
check "child rm -rf node_modules dist" allow "$(run 'rm -rf node_modules dist')"
check "child rm -rf <own>/dist (quoted, space)" allow "$(run "rm -rf \"$child/dist\"")"
check "child rm -rf \$HOME path inside own" allow "$(run 'rm -rf "$HOME/work trees/task one/dist"')"
check "child rm -rf own via symlink" allow "$(run "rm -rf '$child_link/dist'")"
check "child rm -rf dist, cwd via symlink" allow "$(run 'rm -rf dist' "$child_link")"
check "child rm -rf /tmp/x" deny "$(run 'rm -rf /tmp/x')"
check "child rm -r ~/x" deny "$(run 'rm -r ~/x')"
check "child rm --recursive --force \$HOME/orca" deny "$(run 'rm --recursive --force $HOME/orca')"
check "child rm -fr ../other" deny "$(run 'rm -fr ../other')"
check "child rm -rf <own> root" deny "$(run "rm -rf \"$child\"")"
check "child rm -rf main checkout" deny "$(run "rm -rf \"$repo/src\"")"
check "child npm test && rm -rf /" deny "$(run 'npm test && rm -rf /')"
# Backslash-newline is a line continuation outside single quotes, literal inside them.
cont=$(printf '\\\nX'); cont=${cont%X}
check "child rm -rf continued onto /tmp/x" deny "$(run "rm -rf $cont/tmp/x")"
check "child rm -rf \"/tmp/<continued>x\"" deny "$(run "rm -rf \"/tmp/$cont""x\"")"
check "child git -C <main> continued onto checkout" deny "$(run "git -C \"$repo\" ${cont}checkout -b x")"
check "child git continued onto commit" deny "$(run "git ${cont}commit -m x")"
check "child continued rm -rf inside own" allow "$(run "rm -rf $cont\"$child/dist\"")"
check "child continuation inside single quotes stays literal" allow "$(run "printf '%s\\n' 'git ${cont}commit'")"

check "child git status" allow "$(run 'git status')"
check "child git diff" allow "$(run 'git diff')"
check "child git branch -a" allow "$(run 'git branch -a')"
check "child git clean -n" allow "$(run 'git clean -n')"
check "child git push" deny "$(run 'git push origin HEAD')"
check "child git merge" deny "$(run 'git merge main')"
check "child git rebase" deny "$(run 'git rebase origin/main')"
check "child git cherry-pick" deny "$(run 'git cherry-pick abc')"
check "child git am" deny "$(run 'git am x.patch')"
check "child git revert" deny "$(run 'git revert HEAD')"
check "child git reset --hard" deny "$(run 'git reset --hard')"
check "child git reset HEAD~1 --hard" deny "$(run 'git reset HEAD~1 --hard')"
check "child git clean -fd" deny "$(run 'git clean -fd')"
check "child git branch -D x" deny "$(run 'git branch -D x')"
check "child git branch -d x" deny "$(run 'git branch -d x')"
check "child git branch --delete x" deny "$(run 'git branch --delete x')"
check "child git stash drop" deny "$(run 'git stash drop')"
check "child git stash clear" deny "$(run 'git stash clear')"
check "child git update-ref" deny "$(run 'git update-ref -d refs/heads/x')"

check "child git -C <own> status" allow "$(run "git -C \"$child\" status")"
check "child git -C <own> add" allow "$(run "git -C \"$child\" add -A")"
check "child git -C <own via symlink> add" allow "$(run "git -C '$child_link' add -A")"
check "child git -C <other> log" allow "$(run "git -C \"$repo\" log")"
check "child git -C <other> checkout" deny "$(run "git -C \"$repo\" checkout -b x")"
check "child git -C <other, spaces> commit" deny "$(run "git -C \"$repo\" commit -m x")"
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

# --- child: orca CLI
for s in ask send check reply dispatch-show worker-show run-current task-list inbox request-show; do
  check "child orca orchestration $s" allow "$(run "orca orchestration $s --json")"
done
check "child orca orchestration --help" allow "$(run 'orca orchestration --help')"
for s in worker-start dispatch run-create run-use reset worker-stop worker-abandon worker-release worker-retain task-create task-update gate-create gate-resolve gate-list run-list worker-read; do
  check "child orca orchestration $s" deny "$(run "orca orchestration $s --json")"
done
check "child chained orca orchestration worker-start" deny "$(run 'orca orchestration check --json && orca orchestration worker-start --worktree new-child')"
check "child /usr/local/bin/orca orchestration reset" deny "$(run '/usr/local/bin/orca orchestration reset --all')"
for s in create rm remove set; do
  check "child orca worktree $s" deny "$(run "orca worktree $s --worktree name:x")"
done
for s in current list show ps; do
  check "child orca worktree $s" allow "$(run "orca worktree $s --json")"
done
for s in create close send split; do
  check "child orca terminal $s" deny "$(run "orca terminal $s --terminal t")"
done
for s in read list show wait; do
  check "child orca terminal $s" allow "$(run "orca terminal $s --terminal t")"
done

# --- child: edits
check "child Write own" allow "$(write "$child/src/new.sh" "$child")"
check "child Write own, relative" allow "$(write src/rel.sh "$child")"
check "child Write own via symlink" allow "$(write "$child_link/src/new.sh" "$child")"
check "child Write own, cwd via symlink" allow "$(write "$child_link/src/new.sh" "$child_link")"
check "child Write main checkout" deny "$(write "$repo/src/a.sh" "$child")"
check "child Write main checkout README" deny "$(write "$repo/README.md" "$child")"
check "child Write main checkout, relative .." deny "$(write "../../../dev/my repo/x.sh" "$child")"
check "child Write sibling worktree" deny "$(write "$sibling/x.sh" "$child")"
check "child Write other in-scope repo" deny "$(write "$other/x.sh" "$child")"
check "child Write other repo's linked worktree" deny "$(write "$tmp/other-task/x.sh" "$child")"
check "child Write out-of-scope repo" allow "$(write "$plain/x.sh" "$child")"
check "child Write /tmp" allow "$(write /tmp/orca-guard-test.txt "$child")"
check "child Write scratch dir" allow "$(write "$tmp/scratch/new/x.txt" "$child")"

# --- applicability and role detection
check "out-of-scope main: Write" allow "$(write "$plain/src/x.sh" "$plain")"
check "out-of-scope main: git worktree add" allow "$(run 'git worktree add ../y' "$plain")"
check "out-of-scope linked: git commit" allow "$(run 'git commit -m x' "$tmp/plain-task")"
check "out-of-scope linked: orca worktree create" allow "$(run 'orca worktree create x' "$tmp/plain-task")"
check "non-repo cwd: Write" allow "$(write "$repo/src/x.sh" "$tmp/scratch")"

export ORCA_STUB=fail
check "Orca down, git fallback: child git commit" deny "$(run 'git commit -m x')"
check "Orca down, git fallback: child Write own" allow "$(write "$child/x.sh" "$child")"
check "Orca down, git fallback: child Write main" deny "$(write "$repo/x.sh" "$child")"
check "Orca down, git fallback: master Write src" deny "$(write "$repo/src/new.sh")"
check "Orca down, git fallback: master Write README" allow "$(write "$repo/README.md")"
check "Orca down, out-of-scope linked: git commit" allow "$(run 'git commit -m x' "$tmp/plain-task")"
check "Orca down, git broken: Write own" deny "$(write "$broken/x.sh" "$broken")"
check "Orca down, git broken: Write scratch" deny "$(write "$tmp/scratch/x.sh" "$broken")"
check "Orca down, git broken: ls" allow "$(run 'ls -la' "$broken")"
check "Orca down, git broken: git status" allow "$(run 'git status' "$broken")"
check "Orca down, git broken: git commit" deny "$(run 'git commit -m x' "$broken")"
check "Orca down, git broken: git push" deny "$(run 'git push' "$broken")"
check "Orca down, git broken: rm -rf /tmp/x" deny "$(run 'rm -rf /tmp/x' "$broken")"
check "Orca down, git broken: orca orchestration worker-start" deny "$(run 'orca orchestration worker-start' "$broken")"
msg=$(reason "$(write "$broken/x.sh" "$broken")")
result "unknown message explains the role" yes "$(printf '%s' "$msg" | grep -q 'could not be determined' && echo yes)"
export ORCA_STUB=garbage
check "Orca garbage, git fallback: child git commit" deny "$(run 'git commit -m x')"
check "Orca garbage, git fallback: master Write README" allow "$(write "$repo/README.md")"
unset ORCA_STUB
check "Orca not-found, git broken: Write own" deny "$(write "$broken/x.sh" "$broken")"
check "Orca main vs git linked: Write own" deny "$(write "$tmp/liar/x.md" "$tmp/liar")"
check "Orca main vs git linked: git commit" deny "$(run 'git commit -m x' "$tmp/liar")"
check "Orca linked vs git main: Write README" deny "$(write "$liar_main/README.md" "$liar_main")"

# --- .orca-dev-ops.json limits (read from the main checkout)
# The main repo already has 3 task worktrees (child, sibling, liar): the default limit is reached.
check "maxWorktrees default 3 reached: orca worktree create" deny "$(run 'orca worktree create --name cc-x --json' "$repo")"
has() { result "$1" yes "$(printf '%s' "$2" | grep -qF -- "$3" && echo yes || echo no)"; }
has "maxWorktrees reached: message" "$(reason "$(run 'orca worktree create --name cc-x' "$repo")")" "already has 3 task worktree(s) and the limit is 3"
check "maxWorktrees reached: orca worktree list passes" allow "$(run 'orca worktree list --json' "$repo")"
check "maxWorktrees reached: create only mentioned passes" allow "$(run 'echo "orca worktree create"' "$repo")"

lim="$tmp/lim repo"; mkdir -p "$lim/src"; lines 30 > "$lim/src/a.sh"; lines 30 > "$lim/src/b.sh"; marker "$lim"
printf '%s\n' '{"limits":{"maxWorktrees":1,"smallChangeFiles":1,"smallChangeLines":5}}' > "$lim/.orca-dev-ops.json"
new_repo "$lim"; orca_knows "$lim" main
# setcfg <json>: commits <json> as the lim repo's settings, so it is not an uncommitted change.
setcfg() { printf '%s\n' "$1" > "$lim/.orca-dev-ops.json" && git -C "$lim" add .orca-dev-ops.json && git -C "$lim" commit -q -m cfg; }
edit_in() { jq -n --arg cwd "$1" --arg f "$2" --arg s "$(lines "$3")" '{cwd:$cwd,tool_name:"Edit",tool_input:{file_path:$f,old_string:"line 1",new_string:$s}}'; }
check "custom limit: Edit 5 lines allows" allow "$(edit_in "$lim" "$lim/src/a.sh" 5)"
check "custom limit: Edit 6 lines denies" deny "$(edit_in "$lim" "$lim/src/a.sh" 6)"
has "custom limit: message names the limits" "$(reason "$(edit_in "$lim" "$lim/src/a.sh" 6)")" "at most 1 file and 5 changed lines"
awk 'NR == 1 { print "changed"; next } { print }' "$lim/src/a.sh" > "$tmp/x" && mv "$tmp/x" "$lim/src/a.sh"
check "custom limit: second file denies" deny "$(edit_in "$lim" "$lim/src/b.sh" 1)"
check "custom limit: same file allows" allow "$(edit_in "$lim" "$lim/src/a.sh" 1)"
git -C "$lim" checkout -q -- src/a.sh
check "maxWorktrees 1, none yet: create allows" allow "$(run 'orca worktree create --name cc-x' "$lim")"
git -C "$lim" worktree add -q -b t1 "$tmp/lim-task" || exit 1
check "maxWorktrees 1 reached: create denies" deny "$(run 'cd x && orca worktree create --name cc-y' "$lim")"
printf '%s\n' '{"limits":{"maxWorktrees":2}}' > "$tmp/lim-task/.orca-dev-ops.json"
check "maxWorktrees: the worktree's copy is ignored" deny "$(run 'orca worktree create --name cc-y' "$lim")"
setcfg '{"limits":{"maxWorktrees":2}}'
check "maxWorktrees 2, one task worktree: create allows" allow "$(run 'orca worktree create --name cc-y' "$lim")"
export ORCA_STUB=fail
check "count failure (Orca down): create denies" deny "$(run 'orca worktree create --name cc-y' "$lim")"
has "count failure: message" "$(reason "$(run 'orca worktree create --name cc-y' "$lim")")" "Could not count this repository's task worktrees"
unset ORCA_STUB
export ORCA_STUB_WORKTREE_LIST=truncated
check "count failure (truncated list): create denies" deny "$(run 'orca worktree create --name cc-y' "$lim")"
unset ORCA_STUB_WORKTREE_LIST
setcfg '{"limits":{"maxWorktrees":0}}'
check "invalid config: default limit 3 applies" allow "$(run 'orca worktree create --name cc-y' "$lim")"
check "invalid config: default small-change limit applies" allow "$(edit_in "$lim" "$lim/src/a.sh" 20)"
has "invalid config: deny carries the warning" "$(reason "$(edit_in "$lim" "$lim/src/a.sh" 21)")" "Settings warning: Ignored $lim/.orca-dev-ops.json"
git -C "$lim" rm -q .orca-dev-ops.json && git -C "$lim" commit -q -m cfg
check "no config: default small-change limit applies" allow "$(edit_in "$lim" "$lim/src/a.sh" 20)"

# A child never edits .orca-dev-ops.json, not even its own copy.
check "child Write own .orca-dev-ops.json" deny "$(write "$child/.orca-dev-ops.json" "$child")"
check "child Write own .orca-dev-ops.json, relative" deny "$(write .orca-dev-ops.json "$child")"
check "child Edit own .orca-dev-ops.json" deny "$(jq -n --arg cwd "$child" --arg f "$child/.orca-dev-ops.json" '{cwd:$cwd,tool_name:"Edit",tool_input:{file_path:$f,old_string:"a",new_string:"b"}}')"
check "child Write .orca-dev-ops.json in a subdirectory" allow "$(write "$child/sub/.orca-dev-ops.json" "$child")"
check "master Edit .orca-dev-ops.json within the limits" allow "$(edit_in "$lim" "$lim/.orca-dev-ops.json" 3)"

exit "$fail"
