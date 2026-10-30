#!/bin/sh
# Tests for scripts/orca-worker-start.sh with a stub orca that scripts `terminal read` and
# `orchestration worker-start`.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"
script="$root/scripts/orca-worker-start.sh"
export ORCA_STUB_LOG="$tmp/calls"

# start [<option>...]: runs the script with the required options plus <option>...; prints
# "<exit code> <worker-start calls> <task-create calls>" and keeps stdout in $tmp/out.
start() {
  : > "$ORCA_STUB_LOG"
  sh "$script" --run run_1 --task task_1 --terminal term_stub --worktree 'path:/w' \
    --retry-delay 0 --header-timeout 2 "$@" > "$tmp/out" 2> "$tmp/err"
  printf '%s %s %s' "$?" "$(grep -c '^orchestration worker-start' "$ORCA_STUB_LOG")" \
    "$(grep -c 'task-create' "$ORCA_STUB_LOG")"
}
ok_json() { jq -e '.ok == true' "$tmp/out" >/dev/null 2>&1 && echo yes || echo no; }

result "header present, start ok" "0 1 0" "$(start)"
result "header present, start ok: JSON on stdout" yes "$(ok_json)"
result "worker-start gets the given IDs" 1 "$(grep -c -- '--run run_1 --task task_1 --terminal term_stub --worktree path:/w --json' "$ORCA_STUB_LOG")"
result "header after 2 polls" "0 1 0" "$(ORCA_STUB_HEADER_AFTER=3 start)"
result "header after 2 polls: 3 reads" 3 "$(grep -c '^terminal read' "$ORCA_STUB_LOG")"
result "header never appears" "3 0 0" "$(ORCA_STUB_HEADER_AFTER=never start)"
result "header never appears: message" yes "$(grep -q 'worker-start not called' "$tmp/err" && echo yes || echo no)"
result "custom --expect" "0 1 0" "$(start --expect 'cc-task')"
result "custom --expect never matches" "3 0 0" "$(start --expect 'OpenAI Codex')"
result "race once, then ok" "0 2 0" "$(ORCA_STUB_START='race ok' start)"
result "race once, then ok: only the success JSON" yes "$(ok_json)"
result "race on stderr once, then ok" "0 2 0" "$(ORCA_STUB_START='race-stderr ok' start)"
result "race twice" "4 2 0" "$(ORCA_STUB_START='race race' start)"
result "race twice: second receipt on stdout" '"invalid_argument"' "$(jq '.error.code' "$tmp/out")"
result "race twice: reason on stderr" yes "$(grep -q 'failed twice' "$tmp/err" && echo yes || echo no)"
result "other error: no retry" "1 1 0" "$(ORCA_STUB_START='other ok' start)"
result "other error: receipt on stdout" '"not_found"' "$(jq '.error.code' "$tmp/out")"
result "race, then other error" "4 2 0" "$(ORCA_STUB_START='race other' start)"

# usage [<arg>...]: exit code of the script run with exactly <arg>...
usage() { sh "$script" "$@" >/dev/null 2>&1; echo "$?"; }
result "no arguments" 64 "$(usage)"
result "missing --worktree" 64 "$(usage --run r --task t --terminal x)"
result "unknown option" 64 "$(usage --run r --task t --terminal x --worktree w --bogus 1)"
result "missing option value" 64 "$(usage --run r --task t --terminal x --worktree)"
result "non-numeric --retry-delay" 64 "$(usage --run r --task t --terminal x --worktree w --retry-delay soon)"
result "empty --header-timeout" 64 "$(usage --run r --task t --terminal x --worktree w --header-timeout '')"

exit "$fail"
