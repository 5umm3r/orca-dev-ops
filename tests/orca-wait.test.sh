#!/bin/sh
# Tests for scripts/orca-wait.sh with a stub orca that scripts `orchestration check` Deliveries
# (never a live Run).
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"
script="$root/scripts/orca-wait.sh"
export ORCA_STUB_LOG="$tmp/calls"
repo="$tmp/dev/my repo"; mkdir -p "$repo"; new_repo "$repo"
cd "$repo" || exit 1

# wait_for <ORCA_STUB_CHECK> [<option>...]: runs the script in $repo; prints "<exit code> <check calls>"
# and keeps stdout in $tmp/out.
wait_for() {
  : > "$ORCA_STUB_LOG"
  ORCA_STUB_CHECK=$1; export ORCA_STUB_CHECK; shift
  sh "$script" --run run_1 "$@" > "$tmp/out" 2> "$tmp/err"
  printf '%s %s' "$?" "$(grep -c '^orchestration check' "$ORCA_STUB_LOG")"
}
# out <jq filter>: applied to the script's stdout.
out() { jq -c "$1" "$tmp/out" 2>/dev/null; }
# call <n>: the arguments of the n-th check call.
call() { grep '^orchestration check' "$ORCA_STUB_LOG" | sed -n "$1p"; }
has() { result "$1" yes "$(printf '%s' "$2" | grep -qF -- "$3" && echo yes || echo no)"; }
lacks() { result "$1" no "$(printf '%s' "$2" | grep -qF -- "$3" && echo yes || echo no)"; }

# --- wakes on actionable mail without acknowledging it
result "worker_done wakes" "0 1" "$(wait_for worker_done)"
result "worker_done: the Delivery is printed" '"dlv_1"' "$(out .delivery.result.deliveryId)"
result "worker_done: nothing deferred" '[]' "$(out .deferred)"
lacks "worker_done: not acknowledged" "$(call 1)" "--ack"
has "worker_done: blocking wait" "$(call 1)" "--wait"
has "worker_done: default types" "$(call 1)" "--types worker_done,escalation,question --timeout-ms"
has "worker_done: default timeout from the built-in settings" "$(call 1)" "--run run_1 --wait --types worker_done,escalation,question --timeout-ms 590000"
result "escalation wakes" "0 1" "$(wait_for escalation)"
result "question wakes" "0 1" "$(wait_for heartbeat,question)"
result "unknown type wakes" "0 1" "$(wait_for decision)"
result "status with worker_done wakes, status stays in the Delivery" '["status","worker_done"]' \
  "$(wait_for status,worker_done >/dev/null; out '[.delivery.result.messages[].type]')"

# --- heartbeat-only Delivery: acknowledged on the next blocking wait
result "heartbeat then worker_done" "0 2" "$(wait_for 'heartbeat worker_done')"
has "heartbeat: acknowledged with the next wait" "$(call 2)" "--ack dlv_1 --wait"
result "heartbeat: printed Delivery is the second" '"dlv_2"' "$(out .delivery.result.deliveryId)"
result "heartbeats twice then question" "0 3" "$(wait_for 'heartbeat heartbeat question')"
has "heartbeats twice: second ack" "$(call 3)" "--ack dlv_2 --wait"

# --- status: deferred and acknowledged, or waking with --wake-on-status
result "status deferred, then worker_done" "0 2" "$(wait_for 'status,heartbeat worker_done')"
result "status deferred: listed in deferred" '["status 0"]' "$(out '[.deferred[].subject]')"
result "status deferred: full message kept" '"msg_dlv_1_0"' "$(out .deferred[0].id)"
has "status deferred: acknowledged" "$(call 2)" "--ack dlv_1"
result "untyped message counts as status" "0 2" "$(wait_for 'untyped worker_done')"
result "untyped message: deferred" 1 "$(out '.deferred | length')"
result "--wake-on-status wakes on status" "0 1" "$(wait_for 'status worker_done' --wake-on-status)"
has "--wake-on-status: types include status" "$(call 1)" "--types worker_done,escalation,question,status"
result "--wake-on-status: status not deferred" '[]' "$(out .deferred)"
result "--wake-on-status: heartbeat still acknowledged" "0 2" "$(wait_for 'heartbeat status' --wake-on-status)"

# --- timeout and empty results: exit 2 with the deferred statuses
result "timeout" "2 1" "$(wait_for timeout)"
result "timeout: delivery null" null "$(out .delivery)"
result "empty result" "2 1" "$(wait_for empty)"
result "status then timeout" "2 2" "$(wait_for 'status timeout')"
result "status then timeout: deferred kept" 1 "$(out '.deferred | length')"
has "--timeout-ms is passed on" "$(wait_for timeout --timeout-ms 4000 >/dev/null; call 1)" "--timeout-ms 4000"
has "remaining time only shrinks" "$(wait_for 'heartbeat timeout' --timeout-ms 4000 >/dev/null; call 2)" "--timeout-ms "
result "remaining time never above the timeout" yes \
  "$(call 2 | awk '{ for (i = 1; i < NF; i++) if ($i == "--timeout-ms") v = $(i + 1) } END { print (v > 0 && v <= 4000) ? "yes" : "no" }')"

# --- deadline with a Delivery still to acknowledge: one last check without --wait, then exit 2
result "deadline after a heartbeat" "2 2" "$(wait_for 'heartbeat heartbeat' --timeout-ms 1)"
has "deadline: final acknowledgment" "$(call 2)" "--ack dlv_1"
lacks "deadline: final call does not block" "$(call 2)" "--wait"
result "deadline: actionable mail on the final call wakes" "0 2" "$(wait_for 'heartbeat worker_done' --timeout-ms 1)"

# --- no busy loop: every call but a final acknowledgment blocks with a positive timeout
wait_for 'heartbeat heartbeat status heartbeat timeout' --timeout-ms 30000 >/dev/null
result "every wait blocks" 0 "$(grep '^orchestration check' "$ORCA_STUB_LOG" | grep -vc -- '--wait --types .* --timeout-ms [1-9]')"
result "each Delivery acknowledged once" "dlv_1 dlv_2 dlv_3 dlv_4" \
  "$(grep -o -- '--ack dlv_[0-9]*' "$ORCA_STUB_LOG" | awk '{ printf "%s%s", (NR > 1 ? " " : ""), $2 }')"

# --- errors
result "Orca error" "1 1" "$(wait_for error)"
result "Orca error: receipt in error" '"consumer_fenced"' "$(out .error.error.code)"
result "Orca error after a status: deferred kept" "1 2" "$(wait_for 'status error')"
result "Orca error after a status: deferred" 1 "$(out '.deferred | length')"
export ORCA_STUB=fail
result "Orca down" "1 1" "$(wait_for worker_done)"
has "Orca down: error message" "$(out .error)" "without a JSON receipt"
unset ORCA_STUB
# A stub whose every Delivery has the same deliveryId.
mkdir -p "$tmp/same"
sed 's/"dlv_\$(calls .orchestration check.)"/"dlv_same"/' "$tmp/bin/orca" > "$tmp/same/orca" && chmod +x "$tmp/same/orca"
saved=$PATH; PATH="$tmp/same:$PATH"
result "same Delivery after its acknowledgment" "1 2" "$(wait_for 'heartbeat heartbeat')"
has "same Delivery: error message" "$(out .error)" "returned again after its acknowledgment"
PATH=$saved

# --- settings: monitor defaults from .orca-dev-ops.json in the main checkout
printf '%s\n' '{"monitor":{"wakeOnStatus":true,"timeoutMs":7000}}' > "$repo/.orca-dev-ops.json"
result "settings: wakeOnStatus" "0 1" "$(wait_for status)"
has "settings: timeoutMs and status type" "$(call 1)" "--types worker_done,escalation,question,status --timeout-ms 7000"
has "settings: --timeout-ms overrides" "$(wait_for timeout --timeout-ms 3000 >/dev/null; call 1)" "--timeout-ms 3000"
printf '%s\n' '{"monitor":{"timeoutMs":-1}}' > "$repo/.orca-dev-ops.json"
wait_for timeout >/dev/null
has "invalid settings: default timeout" "$(call 1)" "--timeout-ms 590000"
has "invalid settings: warning on stderr" "$(cat "$tmp/err")" "settings warning: Ignored"
rm -f "$repo/.orca-dev-ops.json"

# --- usage
usage() { sh "$script" "$@" >/dev/null 2>&1; echo "$?"; }
result "no arguments" 64 "$(usage)"
result "missing --run value" 64 "$(usage --run)"
result "unknown option" 64 "$(usage --run r --bogus)"
result "non-numeric --timeout-ms" 64 "$(usage --run r --timeout-ms soon)"
result "zero --timeout-ms" 64 "$(usage --run r --timeout-ms 0)"
result "empty --timeout-ms" 64 "$(usage --run r --timeout-ms '')"

exit "$fail"
