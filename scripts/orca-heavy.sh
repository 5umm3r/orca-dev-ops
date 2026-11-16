#!/bin/sh
# Usage: orca-heavy.sh run [--] <command> [<arg>...]
#        orca-heavy.sh status
# Limits how many heavy commands (test suites, builds) the worktrees of one repository run at
# once on this machine, so parallel children do not slow the Mac down.
#   run     Waits for a free slot and for the machine to be calm enough, then runs <command> at
#           the configured priority, holds the slot while it runs, and exits with its exit code.
#   status  Prints the slots, the machine figures, the holders, and the waiters as JSON.
# Slots are directories <git common dir>/orca-heavy/slot-<n>, taken with mkdir (atomic); every
# worktree of the repository shares them. A slot whose holder process is gone is freed. A
# waiting command records itself in <git common dir>/orca-heavy/waiting/<pid>.json (worktree,
# command, reason), so status and the progress report can show it.
# Settings: built-in defaults, then the heavy section of the repository's .orca-dev-ops.json
# (read from the main checkout), then the per-machine file
# ${XDG_CONFIG_HOME:-~/.config}/orca-dev-ops/heavy.json (the same keys except commands):
#   concurrency      "auto" (default) or a number of slots. auto: max(1, min(cores / coresPerSlot,
#                    memory GB / memoryGBPerSlot)), rounded down.
#   coresPerSlot 6, memoryGBPerSlot 16
#   maxLoad 0.8      wait while the 1-minute load average exceeds cores * maxLoad
#   minFreeMemory 20 wait while the free memory is below this percentage
#   maxWaitSeconds 1800  after this long waiting in total, run anyway (with a warning): in a
#                    free slot when only the load or memory check held it back, else without one
#   priority "low"   normal, low (nice 10), or background (taskpolicy -b: efficiency cores only)
# While waiting it prints why on stderr, when the reason changes and once a minute.
# Without a git repository or a slot directory it can write to (a real mkdir is tried; a Codex
# child needs --add-dir for it), it warns and runs <command> directly.
# Exit codes: <command>'s own; 64 usage error. Requires git and jq.
# Test hooks: ORCA_HEAVY_NCPU, ORCA_HEAVY_MEM_GB (machine figures), ORCA_HEAVY_PROBE (a command
# printing "<load1> <free memory percent>"), ORCA_HEAVY_POLL (seconds between checks, default 10).
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/hooks/orca-lib.sh"
usage() { printf 'orca-heavy: %s\nusage: orca-heavy.sh run [--] <command> [<arg>...] | status\n' "$*" >&2; exit 64; }
say() { printf 'orca-heavy: %s\n' "$*" >&2; }

cmd=${1:-}
case "$cmd" in
run) shift; [ "${1:-}" = -- ] && shift; [ $# -ge 1 ] || usage "run needs a command" ;;
status) shift; [ $# -eq 0 ] || usage "status takes no arguments" ;;
*) usage "unknown or missing command: $cmd" ;;
esac

# --- settings
defaults='{"concurrency":"auto","coresPerSlot":6,"memoryGBPerSlot":16,"maxLoad":0.8,"minFreeMemory":20,"maxWaitSeconds":1800,"priority":"low"}'
settings=$defaults warning=
if git rev-parse --git-dir >/dev/null 2>&1; then
  orca_config_load "$PWD"
  [ "$ORCA_CONFIG_STATE" = invalid ] && warning=$ORCA_CONFIG_ERROR
  settings=$(printf '%s' "$ORCA_CONFIG" | jq -c --argjson d "$defaults" '$d * (.heavy // {} | del(.commands))')
fi
local_file=${XDG_CONFIG_HOME:-$HOME/.config}/orca-dev-ops/heavy.json
if [ -f "$local_file" ]; then
  why=$(jq -rs "$ORCA_CONFIG_DEFS"'
    if length != 1 or (.[0] | type) != "object" then "it must hold one JSON object"
    else .[0] | [((keys - ['"$ORCA_HEAVY_LOCAL_KEYS"'])[] | "unknown key \(.)"), '"$ORCA_HEAVY_CHECK"'] | join("; ") end' \
    "$local_file" 2>/dev/null) || why='it is not valid JSON'
  if [ -z "$why" ]; then
    settings=$(jq -c --argjson s "$settings" '$s * .' "$local_file")
  else
    warning="${warning:+$warning; }ignored $local_file ($why)"
  fi
fi
[ -z "$warning" ] || say "warning: $warning"
get() { printf '%s' "$settings" | jq -r ".$1"; }

# --- machine figures
ncpu=${ORCA_HEAVY_NCPU:-$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}
if [ -n "${ORCA_HEAVY_MEM_GB:-}" ]; then memgb=$ORCA_HEAVY_MEM_GB
else
  bytes=$(sysctl -n hw.memsize 2>/dev/null) \
    || bytes=$(awk '/^MemTotal:/ { print $2 * 1024 }' /proc/meminfo 2>/dev/null)
  memgb=$(awk -v b="${bytes:-0}" 'BEGIN { printf "%d", b / 1073741824 }')
fi
conc=$(get concurrency)
if [ "$conc" = auto ]; then
  slots=$(awk -v c="$ncpu" -v m="$memgb" -v cs="$(get coresPerSlot)" -v ms="$(get memoryGBPerSlot)" \
    'BEGIN { a = int(c / cs); b = int(m / ms); s = (a < b) ? a : b; if (s < 1) s = 1; print s }')
else
  conc=$(awk -v c="$conc" 'BEGIN { printf "%d", c }')
  slots=$conc
fi
load_limit=$(awk -v c="$ncpu" -v f="$(get maxLoad)" 'BEGIN { printf "%.2f", c * f }')
min_free=$(get minFreeMemory)

# probe: prints "<load1> <free percent>"; "-" for a figure it cannot read.
probe() {
  if [ -n "${ORCA_HEAVY_PROBE:-}" ]; then sh -c "$ORCA_HEAVY_PROBE"; return; fi
  l=$(sysctl -n vm.loadavg 2>/dev/null | awk '{ print $2 }')
  [ -n "$l" ] || l=$(awk '{ print $1 }' /proc/loadavg 2>/dev/null)
  f=$(memory_pressure -Q 2>/dev/null | sed -n 's/.*free percentage: *\([0-9][0-9]*\)%.*/\1/p')
  [ -n "$f" ] || f=$(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { if (t) printf "%d", a * 100 / t }' /proc/meminfo 2>/dev/null)
  echo "${l:--} ${f:--}"
}
# busy <load> <free>: why the machine is too busy, or nothing.
busy() {
  awk -v l="$1" -v f="$2" -v ll="$load_limit" -v mf="$min_free" 'BEGIN {
    if (l != "-" && l + 0 > ll + 0) { printf "load %s > %s", l, ll; exit }
    if (f != "-" && f + 0 < mf + 0) printf "free memory %s%% < %s%%", f, mf }'
}

# --- slot directory: usable only when a real mkdir in it succeeds (a sandbox may deny writes
# that [ -w ] does not see).
lockdir=
if common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  lockdir=$common/orca-heavy
  { mkdir -p "$lockdir/waiting" && mkdir "$lockdir/.probe.$$" && rmdir "$lockdir/.probe.$$"; } 2>/dev/null || lockdir=
fi
alive() { perl -e 'exit((kill(0, $ARGV[0]) || $!{EPERM}) ? 0 : 1)' "$1" 2>/dev/null; }
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || date +%s; }
# reap: frees the slots whose holder is gone; a slot without an owner pid is kept for a minute
# (its owner file is being written). A slot is renamed before it is deleted, so a reap never
# deletes a slot that was freed and taken again in between. Dead waiters are dropped too.
reap() {
  now=$(date +%s)
  for d in "$lockdir"/slot-*; do
    [ -d "$d" ] || continue
    pid=$(jq -r '.pid // empty' "$d/owner" 2>/dev/null)
    if [ -n "$pid" ]; then alive "$pid" && continue
    else [ $((now - $(mtime "$d"))) -lt 60 ] && continue
    fi
    g=$lockdir/.reap.$$.${d##*/}
    mv "$d" "$g" 2>/dev/null && rm -rf "$g"
  done
  for f in "$lockdir"/waiting/*.json; do
    [ -f "$f" ] || continue
    pid=${f##*/}; pid=${pid%.json}
    alive "$pid" || rm -f "$f"
  done
}
holders() {
  for d in "$lockdir"/slot-*; do
    [ -f "$d/owner" ] && jq -c --arg s "${d##*/slot-}" '{slot: ($s | tonumber)} + .' "$d/owner" 2>/dev/null
  done | jq -sc 'sort_by(.slot)'
}
waiters() { cat "$lockdir"/waiting/*.json 2>/dev/null | jq -sc 'sort_by(.since)'; }

if [ "$cmd" = status ]; then
  set -- $(probe)
  h='[]' wl='[]'; [ -n "$lockdir" ] && { reap; h=$(holders); wl=$(waiters); }
  jq -n --argjson slots "$slots" --arg conc "$conc" --argjson ncpu "$ncpu" --argjson mem "$memgb" \
    --arg load "$1" --arg ll "$load_limit" --arg free "$2" --argjson mf "$min_free" \
    --argjson held "$h" --argjson wl "$wl" --arg dir "$lockdir" --arg w "$warning" --argjson s "$settings" '
    {slots: $slots, concurrency: (if $conc == "auto" then "auto" else ($conc | tonumber) end),
     cores: $ncpu, memoryGB: $mem, load: (if $load == "-" then null else ($load | tonumber) + 0 end),
     loadLimit: (($ll | tonumber) + 0), freeMemory: (if $free == "-" then null else ($free | tonumber) + 0 end),
     minFreeMemory: $mf, priority: $s.priority, maxWaitSeconds: $s.maxWaitSeconds,
     held: $held, waiting: $wl, slotDir: (if $dir == "" then null else $dir end),
     warning: (if $w == "" then null else $w end)}'
  exit 0
fi

# --- run
runit() {
  case "$(get priority)" in
  low) nice -n 10 "$@" ;;
  background) if command -v taskpolicy >/dev/null 2>&1; then taskpolicy -b "$@"; else nice -n 19 "$@"; fi ;;
  *) "$@" ;;
  esac
}
nolock="no writable slot directory (not a git repository, or <git common dir>/orca-heavy is not writable from here; a Codex child needs --add-dir for it)"
if [ -z "$lockdir" ]; then
  say "warning: $nolock; running without a slot: $*"
  runit "$@"
  exit $?
fi

poll=${ORCA_HEAVY_POLL:-10}
max_wait=$(get maxWaitSeconds)
start=$(date +%s) last_reason= last_say=0 held=
top=$(git rev-parse --show-toplevel 2>/dev/null) || top=$PWD
me=$lockdir/waiting/$$.json
# acquire: takes a free slot into $held. 0 taken, 1 all held, 2 the directory refuses writes.
acquire() {
  reap
  i=1
  while [ "$i" -le "$slots" ]; do
    d=$lockdir/slot-$i
    if mkdir "$d" 2>/dev/null; then
      t=$lockdir/.owner.$$
      jq -nc --argjson pid "$$" --arg wt "${top##*/}" --arg c "$cmdline" --argjson t "$(date +%s)" \
        '{pid: $pid, worktree: $wt, command: $c, since: $t}' > "$t" && mv "$t" "$d/owner"
      held=$d
      return 0
    fi
    [ -d "$d" ] || return 2
    i=$((i + 1))
  done
  return 1
}
# release: frees the held slot, only while its owner is still this process.
release() {
  rm -f "$me"
  [ -n "$held" ] && [ "$(jq -r '.pid // empty' "$held/owner" 2>/dev/null)" = "$$" ] && rm -rf "$held"
  held=
}
trap 'release' EXIT
trap 'release; exit 130' INT
trap 'release; exit 143' TERM
cmdline=$*
while :; do
  now=$(date +%s)
  waited=$((now - start))
  reason=$(busy $(probe))
  if [ -z "$reason" ]; then
    acquire; got=$?
    [ "$got" -eq 0 ] && break
    [ "$got" -eq 2 ] && { say "warning: $nolock; running without a slot: $cmdline"; break; }
    reason="all $slots slot(s) held: $(holders | jq -r 'map("\(.worktree) (\(.command))") | join(", ")')"
  fi
  if [ "$waited" -ge "$max_wait" ]; then
    # Out of patience: the load check is skipped, but a free slot is still taken so later
    # arrivals see this command.
    case "$reason" in
    "all "*) say "warning: waited ${waited}s (maxWaitSeconds $max_wait), running anyway without a slot: $reason" ;;
    *) if acquire; then say "warning: waited ${waited}s (maxWaitSeconds $max_wait), starting despite $reason"
       else say "warning: waited ${waited}s (maxWaitSeconds $max_wait), running anyway without a slot: $reason"; fi ;;
    esac
    break
  fi
  if [ "$reason" != "$last_reason" ] || [ $((now - last_say)) -ge 60 ]; then
    say "waiting (${waited}s): $reason"
    jq -nc --argjson pid "$$" --arg wt "${top##*/}" --arg c "$cmdline" --argjson t "$start" --arg r "$reason" \
      '{pid: $pid, worktree: $wt, command: $c, since: $t, reason: $r}' > "$me.tmp" 2>/dev/null && mv "$me.tmp" "$me"
    last_reason=$reason last_say=$now
  fi
  sleep "$poll"
done
rm -f "$me"
[ -n "$held" ] && say "slot ${held##*/slot-}/$slots ($conc: $ncpu cores, $memgb GB), priority $(get priority): $cmdline"
runit "$@"
code=$?
release
exit "$code"
