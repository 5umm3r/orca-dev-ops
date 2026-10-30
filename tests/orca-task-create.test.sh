#!/bin/sh
# Tests for scripts/orca-task-create.sh with a stub orca that scripts `terminal list` (the mailbox
# pane) and `orchestration task-create` (never a live Run).
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"
script="$root/scripts/orca-task-create.sh"
export ORCA_STUB_LOG="$tmp/calls" ORCA_STUB_ENV_LOG="$tmp/env"
repo="$tmp/dev/my repo"; mkdir -p "$repo"; new_repo "$repo"
cd "$repo" || exit 1
export ORCA_TERMINAL_HANDLE=term_own ORCA_PANE_KEY=pane ORCA_AGENT_PANE=1 ORCA_AGENT_LAUNCH=1 \
  ORCA_AGENT_LAUNCH_TOKEN=tok ORCA_TAB_ID=tab

# create <ORCA_STUB_TERMINALS> <arg>...: runs the script; prints its exit code and keeps stdout and
# stderr in $tmp/out and $tmp/err.
create() {
  : > "$ORCA_STUB_LOG"; : > "$ORCA_STUB_ENV_LOG"
  ORCA_STUB_TERMINALS=$1; export ORCA_STUB_TERMINALS; shift
  sh "$script" "$@" > "$tmp/out" 2> "$tmp/err"
  echo "$?"
}
good="--run run_1 --title topic --spec spec"
count() { grep -c -- "$1" "$ORCA_STUB_LOG"; }
call() { grep -- "^$1" "$ORCA_STUB_LOG" | sed -n 1p; }
has() { result "$1" yes "$(printf '%s' "$2" | grep -qF -- "$3" && echo yes || echo no)"; }

# --- normal
# shellcheck disable=SC2086 # split on purpose
result "task-create ok" 0 "$(create mailbox $good)"
result "task-create ok: the task ID only on stdout" "task_stub" "$(cat "$tmp/out")"
result "task-create ok: nothing on stderr" "" "$(cat "$tmp/err")"
result "task-create ok: acts as the mailbox, --json" "orchestration task-create --from term_1 --run run_1 --task-title topic --spec spec --json" "$(call 'orchestration task-create')"
result "task-create ok: unattested" - "$(n=$(grep -n '^orchestration task-create' "$ORCA_STUB_LOG" | sed -n '1s/:.*//p'); sed -n "${n}p" "$ORCA_STUB_ENV_LOG")"
# shellcheck disable=SC2086
result "options are passed on" 0 "$(create mailbox $good --deps '["task_a"]' --parent task_p --display-name 'Shown')"
has "--deps is passed on" "$(call 'orchestration task-create')" '--deps ["task_a"]'
has "--parent is passed on" "$(call 'orchestration task-create')" "--parent task_p"
has "--display-name is passed on" "$(call 'orchestration task-create')" "--display-name Shown"
result "a spec with spaces and quotes stays one argument" 0 "$(create mailbox --run run_1 --title 't t' --spec "Read 'a b' and run.")"
has "spec with quotes" "$(call 'orchestration task-create')" "--spec Read 'a b' and run. --json"

# --- the receipt holds no valid task ID: exit 1, receipt on stderr, nothing on stdout
# shellcheck disable=SC2086
result "UUID id at the top, no .result.task.id" 1 "$(ORCA_STUB_TASK_CREATE=uuid create mailbox $good)"
result "UUID id: nothing on stdout" "" "$(cat "$tmp/out")"
has "UUID id: receipt on stderr" "$(cat "$tmp/err")" "7d1c9b52-1f0e-4c8a-9d2e-3a5b6c7d8e9f"
# shellcheck disable=SC2086
result "task ID not starting with task_" 1 "$(ORCA_STUB_TASK_CREATE=badid create mailbox $good)"
result "task ID not starting with task_: nothing on stdout" "" "$(cat "$tmp/out")"
has "task ID not starting with task_: receipt on stderr" "$(cat "$tmp/err")" "req_123"
# shellcheck disable=SC2086
result "empty task ID" 1 "$(ORCA_STUB_TASK_CREATE=empty create mailbox $good)"
result "empty task ID: nothing on stdout" "" "$(cat "$tmp/out")"
# shellcheck disable=SC2086
result "ok false receipt" 1 "$(ORCA_STUB_TASK_CREATE=notok create mailbox $good)"
result "ok false receipt: nothing on stdout" "" "$(cat "$tmp/out")"
has "ok false receipt: receipt on stderr" "$(cat "$tmp/err")" "Run not found."
# shellcheck disable=SC2086
result "non-zero orca exit (also exit 3)" 1 "$(ORCA_STUB_VERB_FAIL=task-create create mailbox $good)"
result "non-zero orca exit: nothing on stdout" "" "$(cat "$tmp/out")"
has "non-zero orca exit: receipt on stderr" "$(cat "$tmp/err")" "task-create failed"
# shellcheck disable=SC2086
result "two mailbox panes" 1 "$(create mailbox,mailbox $good)"
result "two mailbox panes: no task-create call" 0 "$(count 'orchestration task-create')"

# --- mailbox missing
# shellcheck disable=SC2086
result "mailbox missing" 3 "$(create shell,agent $good)"
has "mailbox missing: the mailbox message" "$(cat "$tmp/err")" "orca-mailbox.sh ensure"
result "mailbox missing: nothing on stdout" "" "$(cat "$tmp/out")"
result "mailbox missing: no task-create call" 0 "$(count 'orchestration task-create')"

# --- usage errors
result "no arguments" 64 "$(create mailbox)"
result "missing --run" 64 "$(create mailbox --title t --spec s)"
result "missing --title" 64 "$(create mailbox --run r --spec s)"
result "missing --spec" 64 "$(create mailbox --run r --title t)"
result "empty --spec" 64 "$(create mailbox --run r --title t --spec '')"
result "unknown option" 64 "$(create mailbox --run r --title t --spec s --bogus 1)"
result "missing option value" 64 "$(create mailbox --run r --title t --spec)"
result "usage errors call no orca" 0 "$(count .)"

exit "$fail"
