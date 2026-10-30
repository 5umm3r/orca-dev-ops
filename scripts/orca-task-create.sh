#!/bin/sh
# Usage: orca-task-create.sh --run <run_id> --title <text> --spec <text> [--deps <json_array>]
#                            [--parent <task_id>] [--display-name <text>]
# Creates an orchestration task as the coordinator's mailbox terminal (`orca-mailbox.sh exec
# task-create ... --json`, see scripts/orca-mailbox.sh) and prints the new task ID, and nothing
# else, on stdout. The ID is read from `.result.task.id` of the receipt only (Orca 1.4.244 prints
# `Created ${r.task.id}`; the receipt's top-level `id` is the request ID, not the task), and must
# match ^task_[A-Za-z0-9]+$. Keep the stdout for `orca-worker-start.sh --task`. Do not pipe this
# script into tail or head: that hides the exit code and the error.
# Exit codes:
#   0   task created; its ID is on stdout
#   1   task-create failed (non-zero exit of orca, a receipt with ok false), or the receipt holds
#       no valid task ID; the receipt is on stderr and nothing is on stdout
#   3   no orca-mailbox pane exists (the mailbox message is on stderr; run orca-mailbox.sh ensure)
#   64  usage error
# Requires orca and jq.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
usage() { printf 'orca-task-create: %s\n' "$*" >&2; exit 64; }
die() { code=$1; shift; printf 'orca-task-create: %s\n' "$*" >&2; exit "$code"; }

run= title= spec= deps= parent= dname=
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage "missing value for $1"
  case "$1" in
  --run) run=$2 ;;
  --title) title=$2 ;;
  --spec) spec=$2 ;;
  --deps) deps=$2 ;;
  --parent) parent=$2 ;;
  --display-name) dname=$2 ;;
  *) usage "unknown option: $1" ;;
  esac
  shift 2
done
[ -n "$run" ] && [ -n "$title" ] && [ -n "$spec" ] || usage "--run, --title, and --spec are required"
command -v orca >/dev/null 2>&1 || die 1 "orca is not on PATH"
command -v jq >/dev/null 2>&1 || die 1 "jq is not on PATH"

err=$(mktemp) || die 1 "cannot create a temporary file"
trap 'rm -f "$err"' EXIT
set -- --run "$run" --task-title "$title" --spec "$spec"
[ -z "$deps" ] || set -- "$@" --deps "$deps"
[ -z "$parent" ] || set -- "$@" --parent "$parent"
[ -z "$dname" ] || set -- "$@" --display-name "$dname"
out=$(sh "$ROOT/scripts/orca-mailbox.sh" exec task-create "$@" --json 2>"$err")
rc=$?
receipt() { [ -z "$out" ] || printf '%s\n' "$out" >&2; cat "$err" >&2; }
# The mailbox script's own "no pane" message (exit 3) is told apart from a task-create failure
# that happens to exit 3.
if [ "$rc" -eq 3 ] && grep -q '^orca-mailbox: no .* pane in ' "$err"; then cat "$err" >&2; exit 3; fi
if [ "$rc" -ne 0 ]; then receipt; die 1 "task-create failed (exit $rc); no task was assumed"; fi
id=$(printf '%s' "$out" | jq -r 'if .ok == false then "" else (.result.task.id // "" | strings) end' 2>/dev/null)
if [ -z "$id" ] || [ "${id#task_}" = "$id" ] || [ -z "${id#task_}" ] \
  || [ "$(printf '%s.' "${id#task_}" | LC_ALL=C tr -d 'A-Za-z0-9')" != . ]; then
  receipt
  die 1 "the receipt holds no task ID at .result.task.id matching ^task_[A-Za-z0-9]+\$"
fi
printf '%s\n' "$id"
