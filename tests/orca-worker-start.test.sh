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

# Wrong-ID guard: --task must be a task ID listed in the Run, checked before anything else.
calls_of() { grep -c -- "$1" "$ORCA_STUB_LOG"; }
result "task-list is asked for the Run" 1 "$(start >/dev/null; calls_of '^orchestration task-list --run run_1 --json')"
result "task-list runs before terminal read" 1 "$(sed -n 1p "$ORCA_STUB_LOG" | grep -c '^orchestration task-list')"
result "task ID is a UUID" "5 0 0" "$(start --task 7d1c9b52-1f0e-4c8a-9d2e-3a5b6c7d8e9f)"
result "UUID: no orca call at all" 0 "$(calls_of .)"
result "UUID: message on stderr" yes "$(grep -q 'is not a task ID' "$tmp/err" && echo yes || echo no)"
result "task ID is a run ID" "5 0 0" "$(start --task run_1)"
result "task ID has a suffix with a dash" "5 0 0" "$(start --task task_a-b)"
result "task ID is task_ alone" "5 0 0" "$(start --task task_)"
result "task ID with a newline" "5 0 0" "$(start --task 'task_1
x')"
result "wrong task ID: no task-list, no terminal read" 0 "$(calls_of .)"
result "task absent from task-list" "5 0 0" "$(ORCA_STUB_TASKS='task_2 task_3' start)"
result "task absent: no worker-start call" 0 "$(calls_of '^orchestration worker-start')"
result "task absent: no terminal read" 0 "$(calls_of '^terminal read')"
result "task absent: message on stderr" yes "$(grep -q 'not listed in run run_1' "$tmp/err" && echo yes || echo no)"
result "empty task-list" "5 0 0" "$(ORCA_STUB_TASKS= start)"
result "task listed among others" "0 1 0" "$(ORCA_STUB_TASKS='task_2 task_1' start)"
result "task-list fails" "1 0 0" "$(ORCA_STUB_TASK_LIST=fail start)"
result "task-list fails: receipt on stderr" yes "$(grep -q 'Run not found' "$tmp/err" && echo yes || echo no)"
result "task-list fails: no worker-start call" 0 "$(calls_of '^orchestration worker-start')"
result "ok receipt without a dispatch ID" "6 1 0" "$(ORCA_STUB_START=no-dispatch start)"
result "no dispatch ID: nothing on stdout" "" "$(cat "$tmp/out")"
result "no dispatch ID: receipt on stderr" yes "$(grep -q '"state":"ready"' "$tmp/err" && echo yes || echo no)"
result "no dispatch ID: message" yes "$(grep -q 'without a dispatch ID' "$tmp/err" && echo yes || echo no)"
result "ok receipt with an empty dispatch ID" "6 1 0" "$(ORCA_STUB_START=empty-dispatch start)"
result "race, then ok without a dispatch ID" "6 2 0" "$(ORCA_STUB_START='race no-dispatch' start)"
result "dispatch ID in the normal receipt" '"ctx_stub"' "$(start >/dev/null; jq '.result.dispatchId' "$tmp/out")"

# --from: worker-start acts as the given coordinator terminal, without the attestation variables.
export ORCA_STUB_ENV_LOG="$tmp/env" ORCA_TERMINAL_HANDLE=term_own ORCA_PANE_KEY=pane \
  ORCA_AGENT_PANE=1 ORCA_AGENT_LAUNCH=1 ORCA_AGENT_LAUNCH_TOKEN=tok ORCA_TAB_ID=tab
attested="ORCA_TERMINAL_HANDLE ORCA_PANE_KEY ORCA_AGENT_PANE ORCA_AGENT_LAUNCH ORCA_AGENT_LAUNCH_TOKEN ORCA_TAB_ID"
# env_of <prefix>: the attestation variables seen by each call starting with <prefix>, space-joined.
env_of() {
  grep -n -- "^$1" "$ORCA_STUB_LOG" | cut -d: -f1 | while read -r n; do sed -n "${n}p" "$ORCA_STUB_ENV_LOG"; done \
    | tr '\n' ' ' | sed 's/ $//'
}
: > "$ORCA_STUB_ENV_LOG"
result "--from: start ok" "0 1 0" "$(start --from term_mail)"
result "--from: passed to worker-start" 1 "$(grep -c -- '^orchestration worker-start --from term_mail --run run_1 --task task_1 --terminal term_stub --worktree path:/w --json' "$ORCA_STUB_LOG")"
result "--from: worker-start unattested" - "$(env_of 'orchestration worker-start')"
result "--from: terminal read stays attested" "$attested" "$(env_of 'terminal read')"
result "--from: task-list as the terminal" 1 "$(grep -c -- '^orchestration task-list --from term_mail --run run_1 --json' "$ORCA_STUB_LOG")"
result "--from: task-list unattested" - "$(env_of 'orchestration task-list')"
: > "$ORCA_STUB_ENV_LOG"
result "--from: race once, then ok" "0 2 0" "$(ORCA_STUB_START='race ok' start --from term_mail)"
result "--from: retry also as the terminal" 2 "$(grep -c -- '^orchestration worker-start --from term_mail ' "$ORCA_STUB_LOG")"
result "--from: retry unattested" "- -" "$(env_of 'orchestration worker-start')"
: > "$ORCA_STUB_ENV_LOG"
result "without --from: start ok" "0 1 0" "$(start)"
result "without --from: no --from" 0 "$(grep -c -- '--from' "$ORCA_STUB_LOG")"
result "without --from: worker-start attested" "$attested" "$(env_of 'orchestration worker-start')"
result "without --from: task-list attested" "$attested" "$(env_of 'orchestration task-list')"
unset ORCA_STUB_ENV_LOG ORCA_TERMINAL_HANDLE ORCA_PANE_KEY ORCA_AGENT_PANE ORCA_AGENT_LAUNCH ORCA_AGENT_LAUNCH_TOKEN ORCA_TAB_ID

# usage [<arg>...]: exit code of the script run with exactly <arg>...
usage() { sh "$script" "$@" >/dev/null 2>&1; echo "$?"; }
result "no arguments" 64 "$(usage)"
result "missing --worktree" 64 "$(usage --run r --task t --terminal x)"
result "unknown option" 64 "$(usage --run r --task t --terminal x --worktree w --bogus 1)"
result "missing option value" 64 "$(usage --run r --task t --terminal x --worktree)"
result "non-numeric --retry-delay" 64 "$(usage --run r --task t --terminal x --worktree w --retry-delay soon)"
result "empty --header-timeout" 64 "$(usage --run r --task t --terminal x --worktree w --header-timeout '')"
result "empty --from" 64 "$(usage --run r --task t --terminal x --worktree w --from '')"

exit "$fail"
