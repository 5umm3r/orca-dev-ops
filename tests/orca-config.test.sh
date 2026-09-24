#!/bin/sh
# Tests for the settings loader in hooks/orca-lib.sh through scripts/orca-config.sh show.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"
script="$root/scripts/orca-config.sh"

repo="$tmp/dev/my repo"; mkdir -p "$repo"; new_repo "$repo"
child="$tmp/work trees/task one"; mkdir -p "$tmp/work trees"
git -C "$repo" worktree add -q -b task-one "$child" || exit 1
cfg="$repo/.orca-dev-ops.json"
defaults='{"launch":{"mode":"ask"},"limits":{"maxWorktrees":3,"smallChangeFiles":2,"smallChangeLines":20},"monitor":{"wakeOnStatus":false,"timeoutMs":590000}}'

# show [<path>]: runs `orca-config.sh show`, stdout in $out (compact JSON), stderr in $err, exit code in $rc.
show() {
  sh "$script" show "$@" > "$tmp/out" 2> "$tmp/err"; rc=$?
  out=$(jq -c . "$tmp/out" 2>/dev/null) err=$(cat "$tmp/err")
}
has() { result "$1" yes "$(printf '%s' "$2" | grep -qF -- "$3" && echo yes || echo no)"; }

# --- missing file: defaults, exit 0
show "$repo"
result "missing: exit 0" 0 "$rc"
result "missing: defaults" "$defaults" "$out"
has "missing: stderr names the defaults" "$err" "built-in defaults"
(cd "$repo" && sh "$script" show > "$tmp/cwd-out" 2>/dev/null)
result "missing: default path is the cwd" "$defaults" "$(jq -c . "$tmp/cwd-out")"

# --- valid files: merged over the defaults
printf '{}\n' > "$cfg"; show "$repo"
result "empty object: exit 0" 0 "$rc"
result "empty object: defaults" "$defaults" "$out"
has "valid: stderr names the source" "$err" "source: $cfg"

printf '{"limits":{"maxWorktrees":5},"monitor":{"wakeOnStatus":true}}\n' > "$cfg"; show "$repo"
result "partial: exit 0" 0 "$rc"
result "partial: merged" '{"launch":{"mode":"ask"},"limits":{"maxWorktrees":5,"smallChangeFiles":2,"smallChangeLines":20},"monitor":{"wakeOnStatus":true,"timeoutMs":590000}}' "$out"

full='{"launch":{"mode":"auto","agent":"codex","model":"gpt-sol","effort":"xhigh"},"limits":{"maxWorktrees":1,"smallChangeFiles":0,"smallChangeLines":0},"monitor":{"wakeOnStatus":true,"timeoutMs":60000}}'
printf '%s\n' "$full" > "$cfg"; show "$repo"
result "full: exit 0" 0 "$rc"
result "full: every key taken" "$full" "$out"
printf '{"launch":{"agent":"claude","model":"claude-opus-5-5","effort":"high"}}\n' > "$cfg"; show "$repo"
result "ask with recommendations: exit 0" 0 "$rc"
result "ask with recommendations: mode stays ask" ask "$(printf '%s' "$out" | jq -r .launch.mode)"

# --- read from the main checkout, never from the worktree
printf '{"limits":{"maxWorktrees":7}}\n' > "$cfg"
printf '{"limits":{"maxWorktrees":99}}\n' > "$child/.orca-dev-ops.json"
show "$child"
result "worktree: main checkout's file wins" 7 "$(printf '%s' "$out" | jq .limits.maxWorktrees)"
has "worktree: source is the main checkout" "$err" "source: $cfg"
rm -f "$cfg"; show "$child"
result "worktree: its own copy is ignored" "$defaults" "$out"
rm -f "$child/.orca-dev-ops.json"

# --- invalid files: ignored as a whole, defaults, exit 3, the reason on stderr
# invalid <name> <file content> <expected reason fragment>
invalid() {
  printf '%s' "$2" > "$cfg"; show "$repo"
  result "invalid $1: exit 3" 3 "$rc"
  result "invalid $1: defaults" "$defaults" "$out"
  has "invalid $1: reason" "$err" "$3"
}
invalid "bad JSON" '{"limits": ' "not valid JSON"
invalid "empty file" '' "exactly one JSON object"
invalid "two values" '{} {}' "exactly one JSON object"
invalid "array" '[]' "top level must be a JSON object"
invalid "unknown top-level key" '{"limits":{"maxWorktrees":9},"sandbox":{}}' "unknown key sandbox"
invalid "unknown nested key" '{"launch":{"mode":"ask","dangerouslySkipPermissions":true}}' "unknown key launch.dangerouslySkipPermissions"
invalid "section not an object" '{"monitor":true}' "monitor must be an object"
invalid "bad mode" '{"launch":{"mode":"yolo"}}' 'launch.mode must be "ask" or "auto"'
invalid "bad agent" '{"launch":{"agent":"gemini"}}' 'launch.agent must be "claude" or "codex"'
invalid "empty model" '{"launch":{"model":""}}' "launch.model must be a non-empty string"
invalid "model with a space" '{"launch":{"model":"opus --dangerously-skip-permissions"}}' "launch.model must be a non-empty string"
invalid "numeric effort" '{"launch":{"effort":3}}' "launch.effort must be a non-empty string"
invalid "auto without effort" '{"launch":{"mode":"auto","agent":"claude","model":"claude-opus-5-5"}}' 'mode "auto" needs agent, model, and effort'
invalid "auto alone" '{"launch":{"mode":"auto"}}' 'mode "auto" needs agent, model, and effort'
invalid "maxWorktrees 0" '{"limits":{"maxWorktrees":0}}' "limits.maxWorktrees must be an integer >= 1"
invalid "maxWorktrees fraction" '{"limits":{"maxWorktrees":2.5}}' "limits.maxWorktrees must be an integer >= 1"
invalid "negative smallChangeFiles" '{"limits":{"smallChangeFiles":-1}}' "limits.smallChangeFiles must be an integer >= 0"
invalid "string smallChangeLines" '{"limits":{"smallChangeLines":"20"}}' "limits.smallChangeLines must be an integer >= 0"
invalid "wakeOnStatus string" '{"monitor":{"wakeOnStatus":"true"}}' "monitor.wakeOnStatus must be true or false"
invalid "timeoutMs 0" '{"monitor":{"timeoutMs":0}}' "monitor.timeoutMs must be an integer > 0"
invalid "several problems" '{"x":1,"limits":{"maxWorktrees":0}}' "unknown key x; limits.maxWorktrees"
has "invalid: stderr says the defaults apply" "$err" "built-in defaults apply"
rm -f "$cfg"; mkdir "$cfg"; show "$repo"
result "invalid directory: exit 3" 3 "$rc"
has "invalid directory: reason" "$err" "not a readable regular file"
rmdir "$cfg"

# --- usage
usage() { sh "$script" "$@" >/dev/null 2>&1; echo "$?"; }
result "no command" 64 "$(usage)"
result "unknown command" 64 "$(usage set x)"
result "too many arguments" 64 "$(usage show "$repo" extra)"
result "not a repository" 65 "$(usage show "$tmp/scratch")"

exit "$fail"
