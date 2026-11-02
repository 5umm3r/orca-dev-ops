#!/bin/sh
# Tests for scripts/orca-run.sh with a stub orca that scripts `orchestration run-current` and
# `orchestration run-create` (never a live Run).
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"
script="$root/scripts/orca-run.sh"
export ORCA_STUB_LOG="$tmp/calls" ORCA_STUB_ENV_LOG="$tmp/env"
repo="$tmp/dev/my repo"; mkdir -p "$repo"; new_repo "$repo"
cd "$repo" || exit 1
attested="ORCA_TERMINAL_HANDLE ORCA_PANE_KEY ORCA_AGENT_PANE ORCA_AGENT_LAUNCH ORCA_AGENT_LAUNCH_TOKEN ORCA_TAB_ID"
export ORCA_TERMINAL_HANDLE=term_own ORCA_PANE_KEY=pane ORCA_AGENT_PANE=1 ORCA_AGENT_LAUNCH=1 \
  ORCA_AGENT_LAUNCH_TOKEN=tok ORCA_TAB_ID=tab

# run <arg>...: runs the script; prints its exit code and keeps stdout and stderr in $tmp/out and
# $tmp/err.
run() {
  : > "$ORCA_STUB_LOG"; : > "$ORCA_STUB_ENV_LOG"
  sh "$script" "$@" > "$tmp/out" 2> "$tmp/err"
  echo "$?"
}
count() { grep -c -- "$1" "$ORCA_STUB_LOG"; }
call() { grep -- "^$1" "$ORCA_STUB_LOG" | sed -n 1p; }
has() { result "$1" yes "$(printf '%s' "$2" | grep -qF -- "$3" && echo yes || echo no)"; }

# --- a Run is bound (concise view)
result "bound" 0 "$(ORCA_STUB_RUN=run_live run ensure)"
result "bound: JSON" '{"run":"run_live"}' "$(cat "$tmp/out")"
result "bound: nothing on stderr" "" "$(cat "$tmp/err")"
result "bound: run-current as the caller, --json" "orchestration run-current --json" "$(call 'orchestration run-current')"
result "bound: no run-create" 0 "$(count 'orchestration run-create')"
result "bound: no --from" 0 "$(count '--from')"
result "bound: attested" "$attested" "$(cat "$ORCA_STUB_ENV_LOG")"

# --- a Run is bound (older Orca or --full: .result.run.id)
result "bound, legacy shape" 0 "$(ORCA_STUB_RUN=run_old ORCA_STUB_RUN_SHAPE=legacy run ensure)"
result "bound, legacy shape: JSON" '{"run":"run_old"}' "$(cat "$tmp/out")"
result "bound, legacy shape: no run-create" 0 "$(count 'orchestration run-create')"

# --- no Run bound: one is created
result "unbound" 0 "$(run ensure)"
result "unbound: JSON" '{"run":"run_created"}' "$(cat "$tmp/out")"
result "unbound: default objective" "orchestration run-create --objective my repo coordinator --json" "$(call 'orchestration run-create')"
result "unbound: two calls, both attested" "$attested
$attested" "$(cat "$ORCA_STUB_ENV_LOG")"
result "unbound: no --from" 0 "$(count '--from')"
result "unbound, legacy shapes" 0 "$(ORCA_STUB_RUN_SHAPE=legacy ORCA_STUB_RUN_CREATE=legacy run ensure)"
result "unbound, legacy shapes: JSON" '{"run":"run_created"}' "$(cat "$tmp/out")"
result "--objective" 0 "$(run ensure --objective 'ship it')"
has "--objective is passed on" "$(call 'orchestration run-create')" "--objective ship it --json"

# --- Orca errors: exit 1, receipt on stderr
result "run-current fails" 1 "$(ORCA_STUB_RUN_CURRENT=fail run ensure)"
has "run-current fails: receipt on stderr" "$(cat "$tmp/err")" "run-current failed"
result "run-current fails: nothing on stdout" "" "$(cat "$tmp/out")"
result "run-current fails: no run-create" 0 "$(count 'orchestration run-create')"
result "run-create fails" 1 "$(ORCA_STUB_RUN_CREATE=fail run ensure)"
has "run-create fails: receipt on stderr" "$(cat "$tmp/err")" '"run-create failed"'
result "run-create fails: nothing on stdout" "" "$(cat "$tmp/out")"
result "Orca unreachable" 1 "$(ORCA_STUB=fail run ensure)"
result "garbage receipt" 1 "$(ORCA_STUB=garbage run ensure)"
has "garbage receipt: on stderr" "$(cat "$tmp/err")" "orca: something went wrong"

# --- outside an Orca terminal: exit 3, nothing called
result "no ORCA_TERMINAL_HANDLE" 3 "$(unset ORCA_TERMINAL_HANDLE; run ensure)"
has "no ORCA_TERMINAL_HANDLE: message" "$(cat "$tmp/err")" "coordinator's own Orca terminal"
result "no ORCA_TERMINAL_HANDLE: no orca call" 0 "$(count .)"
result "empty ORCA_TERMINAL_HANDLE" 3 "$(ORCA_TERMINAL_HANDLE= run ensure)"

# --- usage errors
result "no arguments" 64 "$(run)"
result "unknown subcommand" 64 "$(run exec check)"
result "unknown option" 64 "$(run ensure --bogus)"
result "--objective without a value" 64 "$(run ensure --objective)"
result "empty --objective" 64 "$(run ensure --objective '')"
result "usage errors call no orca" 0 "$(count .)"

exit "$fail"
