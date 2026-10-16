#!/bin/sh
# Tests for scripts/orca-terminal-create.sh with a stub orca that scripts `terminal create`,
# `terminal list`, and `terminal read`.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"
script="$root/scripts/orca-terminal-create.sh"
export ORCA_STUB_LOG="$tmp/calls"

# create [<option>...]: runs the script with the required options plus <option>...; prints
# "<exit code> <create calls> <close calls>" and keeps stdout in $tmp/out, stderr in $tmp/err.
create() {
  : > "$ORCA_STUB_LOG"
  sh "$script" --worktree 'name:cc-x' --title agent --command 'claude --model m' \
    --interval 0 --timeout 1 "$@" > "$tmp/out" 2> "$tmp/err"
  printf '%s %s %s' "$?" "$(grep -c '^terminal create' "$ORCA_STUB_LOG")" "$(grep -c '^terminal close' "$ORCA_STUB_LOG")"
}
handles() { tr '\n' ' ' < "$tmp/out" | sed 's/ $//'; }
said() { grep -q -- "$1" "$tmp/err" && echo yes || echo no; }

result "immediate success" "0 1 0" "$(ORCA_STUB_TERMINALS='none agent' create)"
result "immediate success: handle on stdout" "term_1" "$(handles)"
result "create gets the given options" 1 "$(grep -c -- '^terminal create --worktree name:cc-x --title agent --command claude --model m --json' "$ORCA_STUB_LOG")"
result "timeout, then the agent appears" "0 1 0" "$(ORCA_STUB_CREATE=timeout ORCA_STUB_TERMINALS='none none agent' create)"
result "timeout, then the agent appears: handle" "term_1" "$(handles)"
result "timeout, then the agent appears: said so" yes "$(said 'create timed out')"
result "timeout on stderr, then the agent appears" "0 1 0" "$(ORCA_STUB_CREATE=timeout-stderr ORCA_STUB_TERMINALS='none agent' create)"
result "timeout, then a shell, then the agent" "0 1 0" "$(ORCA_STUB_CREATE=timeout ORCA_STUB_TERMINALS='none shell shell agent' create)"
result "timeout, then a shell, then the agent: handle" "term_1" "$(handles)"
result "agent by header only" "0 1 0" "$(ORCA_STUB_TERMINALS='none header' create)"
result "custom --expect" "5 1 0" "$(ORCA_STUB_TERMINALS='none header' create --expect 'OpenAI Codex')"
result "timeout, nothing, one recreate, then the agent" "0 2 0" "$(ORCA_STUB_CREATE=timeout ORCA_STUB_TERMINALS='none none none none agent' create --timeout 0)"
result "timeout, nothing, one recreate: handle" "term_1" "$(handles)"
result "timeout, nothing, one recreate: said so" yes "$(said 'creating once more')"
result "old shell turns into the agent: no recreate" "0 1 0" "$(ORCA_STUB_CREATE=timeout ORCA_STUB_TERMINALS='shell shell agent' create)"
result "old shell turns into the agent: its handle" "term_1" "$(handles)"
result "one agent after the recreate, waits the full time" "0 2 0" "$(ORCA_STUB_CREATE=timeout ORCA_STUB_TERMINALS='none' ORCA_STUB_TERMINALS_RECREATED='agent' create)"
result "late second agent after the recreate" "4 2 0" "$(ORCA_STUB_CREATE=timeout ORCA_STUB_TERMINALS='none' ORCA_STUB_TERMINALS_RECREATED='none agent agent,agent' create)"
result "late second agent after the recreate: both handles" "term_1 term_2" "$(handles)"
result "nothing after the recreate" "3 2 0" "$(ORCA_STUB_CREATE=timeout ORCA_STUB_TERMINALS='none' create --timeout 0)"
result "nothing after the recreate: no stdout" "" "$(handles)"
result "nothing after the recreate: reason" yes "$(said 'after two creates')"
result "agent already present" "4 0 0" "$(ORCA_STUB_TERMINALS='agent' create)"
result "agent already present: handle" "term_1" "$(handles)"
result "agent by header already present" "4 0 0" "$(ORCA_STUB_TERMINALS='shell,header' create)"
result "agent by header already present: only the agent" "term_2" "$(handles)"
result "shell already present: not an agent" "0 1 0" "$(ORCA_STUB_TERMINALS='shell shell,agent' create)"
result "shell already present: the new agent" "term_2" "$(handles)"
result "duplicates after the wait" "4 1 0" "$(ORCA_STUB_CREATE=timeout ORCA_STUB_TERMINALS='none none agent,agent' create)"
result "duplicates after the wait: every handle" "term_1 term_2" "$(handles)"
result "duplicates after the wait: reason" yes "$(said 'orca terminal close --terminal')"
result "shell never becomes an agent" "5 1 0" "$(ORCA_STUB_CREATE=timeout ORCA_STUB_TERMINALS='none shell' create)"
result "shell never becomes an agent: handle" "term_1" "$(handles)"
result "created handle never lists" "5 1 0" "$(ORCA_STUB_TERMINALS='none' create)"
result "created handle never lists: handle" "term_1" "$(handles)"
result "other create error" "1 1 0" "$(ORCA_STUB_CREATE=other ORCA_STUB_TERMINALS='none' create)"
result "other create error: receipt on stdout" '"not_found"' "$(jq '.error.code' "$tmp/out")"
result "list fails at the start" "1 0 0" "$(ORCA_STUB=fail create)"

# usage [<arg>...]: exit code of the script run with exactly <arg>...
usage() { sh "$script" "$@" >/dev/null 2>&1; echo "$?"; }
result "no arguments" 64 "$(usage)"
result "missing --command" 64 "$(usage --worktree w --title t)"
result "unknown option" 64 "$(usage --worktree w --title t --command c --bogus 1)"
result "missing option value" 64 "$(usage --worktree w --title t --command)"
result "non-numeric --timeout" 64 "$(usage --worktree w --title t --command c --timeout soon)"
result "empty --interval" 64 "$(usage --worktree w --title t --command c --interval '')"

exit "$fail"
