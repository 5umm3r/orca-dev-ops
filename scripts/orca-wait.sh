#!/bin/sh
# Usage: orca-wait.sh --run <run_id> [--timeout-ms <n>] [--wake-on-status]
# Coordinator wait that wakes only on actionable mail. Wraps
#   orca orchestration check --run <run_id> --wait --types <types> --timeout-ms <remaining> --json
# where <types> is worker_done,escalation,question (plus status with --wake-on-status). Defaults
# come from the repository's .orca-dev-ops.json (monitor.timeoutMs, monitor.wakeOnStatus; see
# docs/config.md), read from the main checkout of the current directory's repository.
# A Delivery is the whole FIFO batch and is replayed until acknowledged; --types only decides
# when the waiter wakes, so a heartbeat alone can end a wait. This script:
#   - Delivery with any message other than heartbeat and (without --wake-on-status) status:
#     not acknowledged; prints {"delivery": <check result>, "deferred": [...]}, exit 0.
#   - Delivery of heartbeats and (without --wake-on-status) statuses only: its status messages
#     go to "deferred", it is acknowledged with --ack on the next blocking wait, and the wait
#     goes on with the remaining time.
#   - Deadline reached or empty result: prints {"delivery": null, "deferred": [...]}, exit 2.
#     A Delivery still to acknowledge at the deadline is acknowledged with one last check
#     without --wait; if that returns actionable mail, it is printed as above with exit 0.
#   - Orca error, or the same Delivery again after its acknowledgment: prints the object with
#     "delivery": null and an "error" (the Orca receipt or a message), exit 1.
# "deferred" holds the full status messages acknowledged by this call; the caller must read
# them, since they will not be delivered again. Every loop iteration blocks in `check --wait`
# (no busy loop). Usage errors exit 64. Requires orca and jq.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/hooks/orca-lib.sh"
usage() { printf 'orca-wait: %s\n' "$*" >&2; exit 64; }

run= timeout= wake=
while [ $# -gt 0 ]; do
  case "$1" in
  --run | --timeout-ms) [ $# -ge 2 ] || usage "missing value for $1" ;;
  esac
  case "$1" in
  --run) run=$2; shift ;;
  --timeout-ms) timeout=$2; [ -n "$2" ] || usage "--timeout-ms takes a whole number of milliseconds"; shift ;;
  --wake-on-status) wake=1 ;;
  *) usage "unknown option: $1" ;;
  esac
  shift
done
[ -n "$run" ] || usage "--run is required"
case "$timeout" in *[!0-9]*) usage "--timeout-ms takes a whole number of milliseconds" ;; esac
command -v orca >/dev/null 2>&1 || { echo 'orca-wait: orca is not on PATH' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'orca-wait: jq is not on PATH' >&2; exit 1; }

orca_config_load "$PWD"
[ -n "$ORCA_CONFIG_ERROR" ] && printf 'orca-wait: settings warning: %s\n' "$ORCA_CONFIG_ERROR" >&2
[ -n "$timeout" ] || timeout=$(orca_config .monitor.timeoutMs)
[ -n "$wake" ] || { [ "$(orca_config .monitor.wakeOnStatus)" = true ] && wake=1; }
[ "$timeout" -gt 0 ] 2>/dev/null || usage "--timeout-ms must be greater than 0"
types=worker_done,escalation,question
[ -n "$wake" ] && types=$types,status

deferred='[]' ack= remaining=$timeout
# date has whole seconds only: after the first wait, the current time counts as the end of the
# current second, so the deadline is never overshot and a short timeout cannot spin.
deadline=$(( $(date +%s) * 1000 + timeout ))
# finish <exit code> <delivery JSON or null> [<error JSON>]
finish() {
  jq -n --argjson d "$2" --argjson f "$deferred" --argjson e "${3:-null}" \
    '{delivery: $d, deferred: $f} + (if $e == null then {} else {error: $e} end)'
  exit "$1"
}
# check_once <option>...: one `orca orchestration check`; the final non-keepalive object in $res.
check_once() {
  res=$(orca orchestration check --run "$run" "$@" --json 2>/dev/null \
    | jq -cs 'map(select(type == "object" and (._keepalive | not))) | last' 2>/dev/null)
  printf '%s' "$res" | jq -e '.ok == true and (.result | type) == "object"' >/dev/null 2>&1 && return 0
  [ -n "$res" ] && [ "$res" != null ] || res='"orca orchestration check failed without a JSON receipt"'
  finish 1 null "$res"
}
# actionable: true when the Delivery in $res has a message that must wake the caller.
actionable() {
  printf '%s' "$res" | jq -e --arg wake "$wake" '
    any(.result.messages[]; (.type // "status") as $t | $t != "heartbeat" and ($t != "status" or $wake != ""))' >/dev/null
}

first=1
while :; do
  if [ -z "$first" ]; then
    remaining=$(( deadline - ($(date +%s) + 1) * 1000 ))
    [ "$remaining" -gt "$timeout" ] && remaining=$timeout
  fi
  first=
  if [ "$remaining" -le 0 ]; then
    [ -n "$ack" ] || finish 2 null
    # Acknowledge the last deferred Delivery; whatever this returns stays unacknowledged.
    check_once --ack "$ack"
    [ "$(printf '%s' "$res" | jq '.result.messages | length')" -gt 0 ] && actionable && finish 0 "$res"
    finish 2 null
  fi
  if [ -n "$ack" ]; then
    check_once --ack "$ack" --wait --types "$types" --timeout-ms "$remaining"
  else
    check_once --wait --types "$types" --timeout-ms "$remaining"
  fi
  [ "$(printf '%s' "$res" | jq '.result.messages | length')" -gt 0 ] || finish 2 null
  id=$(printf '%s' "$res" | jq -r '.result.deliveryId // empty')
  # Without a deliveryId the batch cannot be acknowledged here: hand it to the caller.
  if actionable || [ -z "$id" ]; then finish 0 "$res"; fi
  [ "$id" = "$ack" ] && finish 1 null "$(jq -n --arg id "$id" '"Delivery \($id) was returned again after its acknowledgment"')"
  deferred=$(printf '%s' "$res" | jq -c --argjson f "$deferred" '$f + [.result.messages[] | select((.type // "status") == "status")]')
  ack=$id
done
