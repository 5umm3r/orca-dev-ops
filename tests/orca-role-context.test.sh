#!/bin/sh
# Tests for hooks/orca-role-context.sh (SessionStart context per role) with a stub orca.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"
hook="$root/hooks/orca-role-context.sh"

repo="$tmp/dev/my repo"; mkdir -p "$repo"; marker "$repo"; new_repo "$repo"
child="$tmp/work trees/task one"; mkdir -p "$tmp/work trees"
git -C "$repo" worktree add -q -b task-one "$child" || exit 1
plain="$tmp/plain"; mkdir -p "$plain"; new_repo "$plain"
broken="$tmp/broken"; marker "$broken"; printf 'gitdir: %s\n' "$tmp/nowhere" > "$broken/.git"
orca_knows "$repo" main
orca_knows "$child" linked
orca_knows "$plain" main

# ctx <cwd>: the additionalContext the hook injects (empty when it prints nothing).
ctx() { jq -n --arg cwd "$1" '{cwd:$cwd,hook_event_name:"SessionStart"}' | sh "$hook" | jq -r '.hookSpecificOutput.additionalContext // empty'; }
# has <name> <text> <fixed string>
has() { result "$1" yes "$(printf '%s' "$2" | grep -qF -- "$3" && echo yes || echo no)"; }
lacks() { result "$1" no "$(printf '%s' "$2" | grep -qF -- "$3" && echo yes || echo no)"; }

m=$(ctx "$repo")
has "master: coordinator" "$m" "coordinator"
has "master: orca-dev-ops skill" "$m" "orca-dev-ops"
has "master: base ref helper next to the hooks" "$m" "$root/scripts/orca-base-ref.sh"
lacks "master: no AskUserQuestion" "$m" "AskUserQuestion"
lacks "master: no origin/master" "$m" "origin/master"
result "master: a few lines" yes "$([ "$(printf '%s\n' "$m" | wc -l)" -le 6 ] && [ ${#m} -le 900 ] && echo yes || echo no)"
m=$(CLAUDE_PLUGIN_ROOT="$tmp/plugin root" ctx "$repo")
has "master: base ref helper under CLAUDE_PLUGIN_ROOT" "$m" "$tmp/plugin root/scripts/orca-base-ref.sh"
has "master, no settings: launch mode ask" "$(ctx "$repo")" "Launch mode: ask"
lacks "master, no settings: no warning" "$(ctx "$repo")" "Settings warning"

# .orca-dev-ops.json in the main checkout
printf '%s\n' '{"launch":{"mode":"auto","agent":"codex","model":"gpt-sol","effort":"xhigh"}}' > "$repo/.orca-dev-ops.json"
m=$(ctx "$repo")
has "master, auto: mode and values" "$m" "Launch mode: auto (agent codex, model gpt-sol, effort xhigh;"
result "master, auto: a few lines" yes "$([ "$(printf '%s\n' "$m" | wc -l)" -le 6 ] && [ ${#m} -le 900 ] && echo yes || echo no)"
printf '%s\n' '{"launch":{"mode":"auto"}}' > "$repo/.orca-dev-ops.json"
m=$(ctx "$repo")
has "master, invalid: launch mode ask" "$m" "Launch mode: ask"
has "master, invalid: warning" "$m" "Settings warning: Ignored $repo/.orca-dev-ops.json"
rm -f "$repo/.orca-dev-ops.json"

c=$(ctx "$child")
has "child: uncommitted" "$c" "uncommitted"
has "child: orca orchestration" "$c" "orca orchestration"
has "child: worker_done" "$c" "worker_done"
has "child: Orca worktree rules" "$c" "Orca worktree rules"
lacks "child: no AskUserQuestion" "$c" "AskUserQuestion"
c=$(ORCA_STUB=fail ctx "$child/sub")
has "child, Orca down, git fallback" "$c" "orca orchestration"

u=$(ORCA_STUB=fail ctx "$broken")
has "unknown: role could not be determined" "$u" "could not be determined"
result "unknown: one line" 1 "$(printf '%s\n' "$u" | wc -l | tr -d ' ')"

result "none: out-of-scope repo" "" "$(ctx "$plain")"
result "none: not a repository" "" "$(ctx "$tmp/scratch")"
result "none: no cwd" "" "$(printf '{}' | sh "$hook")"

exit "$fail"
