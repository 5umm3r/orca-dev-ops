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
# Every orca call is attested as the calling terminal: run this in the coordinator's own Orca
# terminal, the one that owns the Run (scripts/orca-run.sh ensure).
# Any other worker-start failure prints the receipt and exits 1 without a retry.
# Wrong-ID guard (a request ID once passed as --task left the task `ready` and unassigned): before
# anything else that touches Orca, --task must match ^task_[A-Za-z0-9]+$ and be listed by
# `task-list --run <run> --json` (.result.tasks[].id). After worker-start returns ok, the
# receipt's .result.dispatchId (also in the concise view of Orca 1.4.246) must be non-empty.
# Exit codes:
#   0   started; the receipt is on stdout
#   1   another failure, including a failing task-list call (its receipt is on stderr)
#   3   no agent header on screen; worker-start not called
#   4   worker-start failed twice on the start-up race
#   5   --task is not a task ID, or not listed in the Run; worker-start not called
#   6   worker-start returned ok without a dispatch ID (receipt on stderr); not a success
#   64  usage error
# Requires orca and jq. Do not pipe the output into tail or head: that hides the exit code.
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
if [ "${task#task_}" = "$task" ] || [ -z "${task#task_}" ] \
  || [ "$(printf '%s.' "${task#task_}" | LC_ALL=C tr -d 'A-Za-z0-9')" != . ]; then
  die 5 "--task '$task' is not a task ID (^task_[A-Za-z0-9]+\$); a request ID or run ID does not work. worker-start not called"
fi
command -v orca >/dev/null 2>&1 || die 1 "orca is not on PATH"
command -v jq >/dev/null 2>&1 || die 1 "jq is not on PATH"

# 0. The task must be listed in the Run.
list=$(orca orchestration task-list --run "$run" --json 2>&1) \
  && printf '%s' "$list" | jq -e '.ok != false and (.result.tasks | type) == "array"' >/dev/null 2>&1 \
  || { printf '%s\n' "$list" >&2; die 1 "task-list for run $run failed; worker-start not called"; }
printf '%s' "$list" | jq -e --arg t "$task" 'any(.result.tasks[]; .id == $t)' >/dev/null 2>&1 \
  || die 5 "task $task is not listed in run $run; worker-start not called"

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
# started: after an ok worker-start, requires a dispatch ID in the receipt.
started() {
  if [ -n "$(printf '%s' "$out" | jq -r '.result.dispatchId // empty | strings' 2>/dev/null)" ]; then receipt; exit 0; fi
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  cat "$err" >&2
  die 6 "worker-start for task $task on $term started without a dispatch ID; do not report it as started"
}
if start; then started; fi
{ printf '%s\n' "$out"; cat "$err"; } | grep -Eq 'not (running )?a recognized agent' || { receipt; exit 1; }
printf 'orca-worker-start: %s is not recognized as an agent yet; retrying in %ss\n' "$term" "$delay" >&2
sleep "$delay"
if start; then started; fi
receipt
die 4 "worker-start failed twice for task $task on $term; stop and report instead of re-running task-create"
