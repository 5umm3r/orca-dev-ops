#!/bin/sh
# Usage: orca-worker-start.sh --run <run_id> --task <task_id> --terminal <handle> --worktree <selector>
#                             [--expect <ERE>] [--retry-delay <sec>] [--header-timeout <sec>]
# Starts a dispatched worker on a child terminal that was just created, working around a
# start-up race: `orca terminal wait --for tui-idle` can return before Orca recognizes the agent,
# and `worker-start` then fails with "is not running a recognized agent".
#   1. Polls `orca terminal read` every second, up to --header-timeout (default 30) seconds, until
#      the joined screen lines (.result.terminal.tail) match the ERE --expect (default: a Claude
#      or Codex header). No match: exit 3 without calling worker-start.
#   2. Runs `orca orchestration worker-start --json`. Success: prints its JSON, exit 0.
#   3. On "not a recognized agent", waits --retry-delay (default 5) seconds and runs the identical
#      worker-start once more with the same task ID. Never calls task-create. Success: exit 0;
#      failure: prints the second receipt, a reason on stderr, exit 4.
# Any other worker-start failure prints the receipt and exits 1 without a retry. Usage errors
# exit 64. Requires orca and jq.
usage() { printf 'orca-worker-start: %s\n' "$*" >&2; exit 64; }
die() { code=$1; shift; printf 'orca-worker-start: %s\n' "$*" >&2; exit "$code"; }

run= task= term= wt= delay=5 limit=30
expect='(Opus|Sonnet|Haiku|Fable) [0-9]|with [a-z]+ effort|OpenAI Codex|model:'
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage "missing value for $1"
  case "$1" in
  --run) run=$2 ;;
  --task) task=$2 ;;
  --terminal) term=$2 ;;
  --worktree) wt=$2 ;;
  --expect) expect=$2 ;;
  --retry-delay) delay=$2 ;;
  --header-timeout) limit=$2 ;;
  *) usage "unknown option: $1" ;;
  esac
  shift 2
done
[ -n "$run" ] && [ -n "$task" ] && [ -n "$term" ] && [ -n "$wt" ] \
  || usage "--run, --task, --terminal, and --worktree are required"
case "$delay,$limit" in ,* | *, | *[!0-9,]*) usage "--retry-delay and --header-timeout take whole seconds" ;; esac
command -v orca >/dev/null 2>&1 || die 1 "orca is not on PATH"
command -v jq >/dev/null 2>&1 || die 1 "jq is not on PATH"

# 1. Wait for the agent header on screen.
waited=0
until orca terminal read --terminal "$term" --json 2>/dev/null \
  | jq -r '.result.terminal.tail // [] | join("\n")' 2>/dev/null | grep -Eq -- "$expect"; do
  [ "$waited" -ge "$limit" ] && die 3 "no agent header matching /$expect/ on $term after ${limit}s; worker-start not called"
  sleep 1
  waited=$((waited + 1))
done

# 2. and 3. Start the worker, retrying once on the start-up race.
err=$(mktemp) || die 1 "cannot create a temporary file"
trap 'rm -f "$err"' EXIT
# start: runs worker-start with its stdout in $out and its stderr in $err. Fails on a non-zero
# exit or on a JSON receipt with ok false.
start() {
  out=$(orca orchestration worker-start --run "$run" --task "$task" --terminal "$term" --worktree "$wt" --json 2>"$err") \
    && ! printf '%s' "$out" | jq -e '.ok == false' >/dev/null 2>&1
}
receipt() { [ -z "$out" ] || printf '%s\n' "$out"; cat "$err" >&2; }
if start; then receipt; exit 0; fi
{ printf '%s\n' "$out"; cat "$err"; } | grep -Eq 'not (running )?a recognized agent' || { receipt; exit 1; }
printf 'orca-worker-start: %s is not recognized as an agent yet; retrying in %ss\n' "$term" "$delay" >&2
sleep "$delay"
if start; then receipt; exit 0; fi
receipt
die 4 "worker-start failed twice for task $task on $term; stop and report instead of re-running task-create"
