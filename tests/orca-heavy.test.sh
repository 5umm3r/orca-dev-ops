#!/bin/sh
# Tests for scripts/orca-heavy.sh (heavy-command slots shared by the worktrees of a repository).
# The machine figures and the load probe are injected (ORCA_HEAVY_NCPU, ORCA_HEAVY_MEM_GB,
# ORCA_HEAVY_PROBE); slots, waiting, and priorities are real.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"
script="$root/scripts/orca-heavy.sh"
repo="$tmp/dev/my repo"; mkdir -p "$repo"; new_repo "$repo"
child="$tmp/work trees/cc-one"; mkdir -p "$tmp/work trees"
git -C "$repo" worktree add -q -b cc-one "$child" || exit 1
plain="$tmp/plain"; mkdir -p "$plain"
slotdir="$repo/.git/orca-heavy"
echo "1.00 80" > "$tmp/probe"
export ORCA_HEAVY_NCPU=12 ORCA_HEAVY_MEM_GB=32 ORCA_HEAVY_PROBE="cat '$tmp/probe'" ORCA_HEAVY_POLL=0.2
cd "$repo" || exit 1

# st [<jq>]: one field of `status` in the current directory.
st() { sh "$script" status 2>"$tmp/st-err" | jq -c "${1:-.}"; }
has() { result "$1" yes "$(printf '%s' "$2" | grep -qF -- "$3" && echo yes || echo no)"; }
# wait_for <file>: waits up to 10 s for <file>; prints yes or no.
wait_for() {
  k=0; while [ ! -e "$1" ] && [ "$k" -lt 100 ]; do sleep 0.1; k=$((k + 1)); done
  [ -e "$1" ] && echo yes || echo no
}
# wait_text <file> <text>: waits up to 10 s for <text> in <file>; prints yes or no.
wait_text() {
  k=0; while ! grep -qF -- "$2" "$1" 2>/dev/null && [ "$k" -lt 100 ]; do sleep 0.1; k=$((k + 1)); done
  grep -qF -- "$2" "$1" 2>/dev/null && echo yes || echo no
}
slots_held() { ls -d "$slotdir"/slot-* 2>/dev/null | wc -l | tr -d ' '; }

# --- slot count from the machine (auto)
result "auto: 12 cores, 32 GB -> 2" 2 "$(st .slots)"
result "auto: 8 cores, 16 GB -> 1" 1 "$(ORCA_HEAVY_NCPU=8 ORCA_HEAVY_MEM_GB=16 st .slots)"
result "auto: 32 cores, 16 GB -> 1 (memory bound)" 1 "$(ORCA_HEAVY_NCPU=32 ORCA_HEAVY_MEM_GB=16 st .slots)"
result "auto: 24 cores, 128 GB -> 4 (core bound)" 4 "$(ORCA_HEAVY_NCPU=24 ORCA_HEAVY_MEM_GB=128 st .slots)"
result "auto: 4 cores, 8 GB -> at least 1" 1 "$(ORCA_HEAVY_NCPU=4 ORCA_HEAVY_MEM_GB=8 st .slots)"
result "status: machine figures" '{"cores":12,"memoryGB":32,"load":1,"loadLimit":9.6,"freeMemory":80,"minFreeMemory":20,"priority":"low"}' \
  "$(st '{cores, memoryGB, load, loadLimit, freeMemory, minFreeMemory, priority}')"
result "status: slot dir in the common git dir" "\"$slotdir\"" "$(st .slotDir)"
result "status: from a linked worktree, the same slot dir" "\"$slotdir\"" "$(cd "$child" && st .slotDir)"
result "status: nothing held" '[]' "$(st .held)"
result "status: real machine figures without the test hooks" yes \
  "$(env -u ORCA_HEAVY_NCPU -u ORCA_HEAVY_MEM_GB -u ORCA_HEAVY_PROBE sh "$script" status | jq -e '.cores >= 1 and .memoryGB >= 1 and .slots >= 1' >/dev/null && echo yes || echo no)"

# --- repository settings, then the per-machine file
printf '%s\n' '{"heavy":{"coresPerSlot":3,"maxLoad":0.5,"commands":["sh tests/all.sh"]}}' > "$repo/.orca-dev-ops.json"
result "repo: coresPerSlot 3 -> 12/3=4, 32/16=2 -> 2" 2 "$(st .slots)"
result "repo: maxLoad 0.5 -> limit 6" 6 "$(st .loadLimit)"
printf '%s\n' '{"heavy":{"concurrency":2.0}}' > "$repo/.orca-dev-ops.json"
result "repo: integral float concurrency" '{"slots":2,"concurrency":2}' "$(st '{slots, concurrency}')"
printf '%s\n' '{"heavy":{"concurrency":3}}' > "$repo/.orca-dev-ops.json"
result "repo: fixed concurrency" '{"slots":3,"concurrency":3}' "$(st '{slots, concurrency}')"
result "repo: read from the main checkout in a linked worktree" 3 "$(cd "$child" && st .slots)"
printf '%s\n' '{"heavy":{"concurrency":3}}' > "$child/.orca-dev-ops.json"
printf '%s\n' '{"heavy":{"concurrency":9}}' > "$child/.orca-dev-ops.json"
result "repo: a worktree copy is ignored" 3 "$(cd "$child" && st .slots)"
rm -f "$child/.orca-dev-ops.json"
mkdir -p "$HOME/.config/orca-dev-ops"
printf '%s\n' '{"concurrency":"auto","memoryGBPerSlot":8,"priority":"background"}' > "$HOME/.config/orca-dev-ops/heavy.json"
result "machine file overrides the repo" '{"slots":2,"concurrency":"auto","priority":"background"}' "$(st '{slots, concurrency, priority}')"
result "machine file: no warning" null "$(st .warning)"
printf '%s\n' '{"concurrency":0,"commands":["x"]}' > "$HOME/.config/orca-dev-ops/heavy.json"
result "machine file invalid: ignored" 3 "$(st .slots)"
has "machine file invalid: warning names the problems" "$(st .warning)" "unknown key commands; concurrency must be"
has "machine file invalid: warning on stderr" "$(cat "$tmp/st-err")" "orca-heavy: warning: ignored"
echo 'not json' > "$HOME/.config/orca-dev-ops/heavy.json"
has "machine file not JSON" "$(st .warning)" "it is not valid JSON"
rm -f "$HOME/.config/orca-dev-ops/heavy.json"
printf '%s\n' '{"heavy":{"concurrency":"many"}}' > "$repo/.orca-dev-ops.json"
result "repo file invalid: defaults" 2 "$(st .slots)"
has "repo file invalid: warning" "$(st .warning)" "heavy.concurrency must be"
rm -f "$repo/.orca-dev-ops.json"

# --- run: exit code, slot released, priority
result "run: exit code passes through" 7 "$(sh "$script" run -- sh -c 'exit 7' 2>/dev/null; echo $?)"
result "run: slot released" 0 "$(slots_held)"
result "run: without --" ok "$(sh "$script" run echo ok 2>/dev/null)"
result "run: arguments kept" "a b|c" "$(sh "$script" run -- sh -c 'printf "%s|%s" "$1" "$2"' x 'a b' c 2>/dev/null)"
has "run: names the slot" "$(sh "$script" run -- true 2>&1)" "orca-heavy: slot 1/2 (auto: 12 cores, 32 GB), priority low: true"
base=$(ps -o nice= -p $$ | tr -d ' ')
result "run: priority low is nice +10" "$((base + 10))" "$(sh "$script" run -- sh -c 'ps -o nice= -p $$' 2>/dev/null | tr -d ' ')"
mkdir -p "$HOME/.config/orca-dev-ops"
echo '{"priority":"normal"}' > "$HOME/.config/orca-dev-ops/heavy.json"
result "run: priority normal" "$base" "$(sh "$script" run -- sh -c 'ps -o nice= -p $$' 2>/dev/null | tr -d ' ')"
echo '{"priority":"background"}' > "$HOME/.config/orca-dev-ops/heavy.json"
if command -v taskpolicy >/dev/null 2>&1; then
  result "run: priority background runs" ok "$(sh "$script" run -- echo ok 2>/dev/null)"
else
  result "run: priority background without taskpolicy is nice +19" "$((base + 19))" "$(sh "$script" run -- sh -c 'ps -o nice= -p $$' 2>/dev/null | tr -d ' ')"
fi
rm -f "$HOME/.config/orca-dev-ops/heavy.json"

# --- one slot: the second command waits for the first, also from another worktree
echo '{"concurrency":1}' > "$HOME/.config/orca-dev-ops/heavy.json"
rm -f "$tmp/a-started" "$tmp/a-go" "$tmp/b-done"
sh "$script" run -- sh -c "touch '$tmp/a-started'; while [ ! -f '$tmp/a-go' ]; do sleep 0.1; done; touch '$tmp/a-ended'" 2>"$tmp/a-err" &
a=$!
result "one slot: first starts" yes "$(wait_for "$tmp/a-started")"
result "one slot: status shows the holder" '[{"slot":1,"worktree":"my repo","command":"sh -c touch '"'$tmp/a-started'"'; while [ ! -f '"'$tmp/a-go'"' ]; do sleep 0.1; done; touch '"'$tmp/a-ended'"'"}]' \
  "$(st '[.held[] | {slot, worktree, command}]')"
(cd "$child" && sh "$script" run -- sh -c "[ -f '$tmp/a-ended' ] && touch '$tmp/b-done'") 2>"$tmp/b-err" &
b=$!
result "one slot: second says why it waits" yes "$(wait_text "$tmp/b-err" "all 1 slot(s) held: my repo (sh -c touch")"
result "one slot: second has not run" no "$([ -e "$tmp/b-done" ] && echo yes || echo no)"
result "one slot: status lists the waiter" '[{"worktree":"cc-one","reason":"all 1 slot(s) held"}]' \
  "$(st '[.waiting[] | {worktree, reason: (.reason | sub(": .*"; ""))}]')"
touch "$tmp/a-go"
wait "$a"; wait "$b"
result "one slot: no waiter left" '[]' "$(st .waiting)"
result "one slot: second ran after the first ended" yes "$([ -e "$tmp/b-done" ] && echo yes || echo no)"
result "one slot: all released" 0 "$(slots_held)"

# --- two slots: two run at once, the third waits
echo '{"concurrency":2}' > "$HOME/.config/orca-dev-ops/heavy.json"
rm -f "$tmp"/p-*
for n in 1 2; do
  sh "$script" run -- sh -c "touch '$tmp/p-$n'; while [ ! -f '$tmp/p-go' ]; do sleep 0.1; done" 2>/dev/null &
done
result "two slots: both start" "yes yes" "$(wait_for "$tmp/p-1") $(wait_for "$tmp/p-2")"
sh "$script" run -- touch "$tmp/p-3" 2>"$tmp/p-err" &
c=$!
result "two slots: the third says it waits" yes "$(wait_text "$tmp/p-err" "all 2 slot(s) held")"
result "two slots: the third waits" no "$([ -e "$tmp/p-3" ] && echo yes || echo no)"
touch "$tmp/p-go"
wait
result "two slots: the third ran" yes "$([ -e "$tmp/p-3" ] && echo yes || echo no)"
result "two slots: all released" 0 "$(slots_held)"

# --- a slot whose holder is gone is freed
echo '{"concurrency":1}' > "$HOME/.config/orca-dev-ops/heavy.json"
sh -c 'exit 0' & dead=$!; wait "$dead"
mkdir -p "$slotdir/slot-1"
jq -nc --argjson p "$dead" '{pid: $p, worktree: "gone", command: "x", since: 0}' > "$slotdir/slot-1/owner"
result "stale slot: freed, runs at once" ok "$(sh "$script" run -- echo ok 2>/dev/null)"
mkdir -p "$slotdir/slot-1"
result "fresh slot without an owner file: kept (being written)" 1 "$(st '.held | length' >/dev/null; slots_held)"
: > "$slotdir/slot-1/owner"
result "fresh slot with an empty owner file: kept" 1 "$(st '.held | length' >/dev/null; slots_held)"
touch -t 202001010000 "$slotdir/slot-1"
result "old slot without an owner pid: freed" 0 "$(st '.held | length' >/dev/null; slots_held)"
rm -rf "$slotdir/slot-1"
# A live holder that is not ours (PID 1) is kept.
mkdir -p "$slotdir/slot-1"; echo '{"pid":1,"worktree":"init","command":"x","since":0}' > "$slotdir/slot-1/owner"
result "live foreign holder: kept" '[1]' "$(st '[.held[].pid]')"
rm -rf "$slotdir/slot-1"

# --- the machine is busy: wait for the load, then for free memory
echo '{"concurrency":2}' > "$HOME/.config/orca-dev-ops/heavy.json"
echo "20.5 80" > "$tmp/probe"; rm -f "$tmp/l-done"
sh "$script" run -- touch "$tmp/l-done" 2>"$tmp/l-err" &
l=$!
result "load: says why" yes "$(wait_text "$tmp/l-err" "load 20.5 > 9.60")"
result "load: waits" no "$([ -e "$tmp/l-done" ] && echo yes || echo no)"
echo "1.0 5" > "$tmp/probe"
result "free memory: says why" yes "$(wait_text "$tmp/l-err" "free memory 5% < 20%")"
result "free memory: still waits" no "$([ -e "$tmp/l-done" ] && echo yes || echo no)"
echo "1.0 80" > "$tmp/probe"
wait "$l"
result "calm again: runs" yes "$([ -e "$tmp/l-done" ] && echo yes || echo no)"
echo "- -" > "$tmp/probe"
result "figures unavailable: runs" ok "$(sh "$script" run -- echo ok 2>/dev/null)"

# --- maxWaitSeconds: run anyway
echo '{"maxWaitSeconds":0}' > "$HOME/.config/orca-dev-ops/heavy.json"
echo "50 80" > "$tmp/probe"
result "maxWaitSeconds 0: runs at once" ok "$(sh "$script" run -- echo ok 2>"$tmp/w-err")"
has "maxWaitSeconds 0: warns" "$(cat "$tmp/w-err")" "starting despite load 50 > 9.60"
has "maxWaitSeconds 0: still takes a free slot" "$(cat "$tmp/w-err")" "orca-heavy: slot 1/2"
echo '{"maxWaitSeconds":0,"concurrency":1}' > "$HOME/.config/orca-dev-ops/heavy.json"
mkdir -p "$slotdir/slot-1"; echo '{"pid":1,"worktree":"init","command":"x","since":0}' > "$slotdir/slot-1/owner"
result "maxWaitSeconds 0, all held, busy: runs" ok "$(sh "$script" run -- echo ok 2>"$tmp/w-err")"
has "maxWaitSeconds 0, all held, busy: without a slot" "$(cat "$tmp/w-err")" "running anyway without a slot: load 50 > 9.60"
echo "1.0 80" > "$tmp/probe"
result "maxWaitSeconds 0, all held: runs" ok "$(sh "$script" run -- echo ok 2>"$tmp/w-err")"
has "maxWaitSeconds 0, all held: without a slot" "$(cat "$tmp/w-err")" "running anyway without a slot: all 1 slot(s) held: init (x)"
rm -rf "$slotdir/slot-1"
echo '{"maxWaitSeconds":0}' > "$HOME/.config/orca-dev-ops/heavy.json"
echo '{"maxWaitSeconds":1}' > "$HOME/.config/orca-dev-ops/heavy.json"
result "maxWaitSeconds 1: runs after waiting" ok "$(sh "$script" run -- echo ok 2>/dev/null)"
echo "1.0 80" > "$tmp/probe"
rm -f "$HOME/.config/orca-dev-ops/heavy.json"

# --- no slot directory: run directly
chmod 555 "$slotdir"
result "slot dir not writable: runs" ok "$(sh "$script" run -- echo ok 2>"$tmp/n-err")"
has "slot dir not writable: warns" "$(cat "$tmp/n-err")" "running without a slot: echo ok"
chmod 755 "$slotdir"
result "not a git repository: runs" ok "$(cd "$plain" && sh "$script" run -- echo ok 2>"$tmp/n-err")"
has "not a git repository: warns" "$(cat "$tmp/n-err")" "running without a slot: echo ok"

# --- usage
result "no command" 64 "$(sh "$script" 2>/dev/null; echo $?)"
result "unknown command" 64 "$(sh "$script" go 2>/dev/null; echo $?)"
result "run without a command" 64 "$(sh "$script" run 2>/dev/null; echo $?)"
result "run -- without a command" 64 "$(sh "$script" run -- 2>/dev/null; echo $?)"
result "status with arguments" 64 "$(sh "$script" status x 2>/dev/null; echo $?)"

result "the repository is untouched" "" "$(git -C "$repo" status --porcelain)"
exit "$fail"
