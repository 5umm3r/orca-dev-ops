#!/bin/sh
# Usage: orca-terminal-create.sh --worktree <selector> --title <text> --command <agent command>
#                                [--timeout <sec>] [--interval <sec>] [--expect <ERE>]
# Creates the agent terminal of a child worktree without opening a second agent session when
# `orca terminal create` times out. On Orca 1.4.225 a worktree created moments earlier can make
# it fail with "Timed out waiting for terminal handle after creation" although the agent starts
# minutes later; recreating by hand then leaves several agent sessions in one task.
# An agent terminal is a row of `orca terminal list --worktree <selector> --json` with a
# non-empty agentIdentity, or one whose `orca terminal read` screen lines (.result.terminal.tail)
# match the ERE --expect (default: a Claude or Codex header).
#   1. Lists the worktree's terminals. If an agent terminal exists already, creates nothing:
#      prints every agent handle (one per line), a reason on stderr, exit 4.
#   2. Runs `orca terminal create --worktree <selector> --title <text> --command <command> --json`.
#      Success, or a failure that says "Timed out waiting for terminal handle", goes on; any
#      other failure prints the receipt and exits 1.
#   3. Every --interval (default 3) seconds, up to --timeout (default 180) seconds, lists the
#      terminals and looks for handles that were not there in step 1 (plus the handle create
#      returned). A new plain shell is neither closed nor a failure: it is polled until it
#      becomes an agent or the time is up.
#   4. If no new terminal appeared at all and the worktree still has no agent terminal (an
#      old shell may have turned into one), creates once more with the identical command and
#      repeats step 3. Never a third create. After this second create the wait does not stop at
#      the first agent: it polls until the deadline, stopping early only at two or more agent
#      terminals, so a late start of the first create's agent is counted.
#   5. Counts the agent terminals in the worktree. One: prints its handle, exit 0. Two or more:
#      prints every agent handle, a reason on stderr, exit 4 (the caller closes the extras). A
#      new terminal but no agent by the last deadline: prints the new handles, exit 5, no
#      recreate. No new terminal after the second create: exit 3.
# Progress lines go to stderr. The script never closes a terminal. Usage errors exit 64.
# Requires orca and jq.
usage() { printf 'orca-terminal-create: %s\n' "$*" >&2; exit 64; }
die() { code=$1; shift; printf 'orca-terminal-create: %s\n' "$*" >&2; exit "$code"; }

wt= title= cmd= limit=180 interval=3
expect='(Opus|Sonnet|Haiku|Fable) [0-9]|with [a-z]+ effort|OpenAI Codex|model:'
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage "missing value for $1"
  case "$1" in
  --worktree) wt=$2 ;;
  --title) title=$2 ;;
  --command) cmd=$2 ;;
  --timeout) limit=$2 ;;
  --interval) interval=$2 ;;
  --expect) expect=$2 ;;
  *) usage "unknown option: $1" ;;
  esac
  shift 2
done
[ -n "$wt" ] && [ -n "$title" ] && [ -n "$cmd" ] || usage "--worktree, --title, and --command are required"
case "$limit,$interval" in ,* | *, | *[!0-9,]*) usage "--timeout and --interval take whole seconds" ;; esac
command -v orca >/dev/null 2>&1 || die 1 "orca is not on PATH"
command -v jq >/dev/null 2>&1 || die 1 "jq is not on PATH"

work=$(mktemp -d) || die 1 "cannot create a temporary directory"
trap 'rm -rf "$work"' EXIT
rows=$work/rows all=$work/all agents=$work/agents before=$work/before made=$work/made new=$work/new
err=$work/err
: > "$made"
tab=$(printf '\t')

# has_header <handle>: the terminal's screen lines match --expect.
has_header() {
  orca terminal read --terminal "$1" --json 2>/dev/null \
    | jq -r '.result.terminal.tail // [] | join("\n")' 2>/dev/null | grep -Eq -- "$expect"
}
# scan: lists the worktree's terminals into $all (every handle, plus the handles create
# returned) and $agents (the agent ones). Fails when the list cannot be read.
scan() {
  list=$(orca terminal list --worktree "$wt" --json 2>/dev/null) \
    && printf '%s\n' "$list" | jq -r '.result.terminals[]?
      | [(.handle // ""), (.agentIdentity | if type == "string" then . else "" end)] | join("\t")' > "$rows" 2>/dev/null \
    || return 1
  while read -r h; do
    cut -f1 "$rows" | grep -qxF -- "$h" || printf '%s\t\n' "$h" >> "$rows"
  done < "$made"
  : > "$all"; : > "$agents"
  while IFS=$tab read -r h ident; do
    [ -n "$h" ] || continue
    printf '%s\n' "$h" >> "$all"
    if [ -n "$ident" ] || has_header "$h"; then printf '%s\n' "$h" >> "$agents"; fi
  done < "$rows"
}
# fresh: the handles in $all that were not there before step 2, into $new.
fresh() { grep -vxFf "$before" "$all" > "$new"; }
# new_agent: some fresh handle is an agent terminal.
new_agent() { fresh; [ -s "$new" ] && grep -qxFf "$new" "$agents"; }
# create: runs terminal create once; $out holds its stdout. Continues on success or on the
# handle timeout, exits 1 with the receipt on any other failure.
create() {
  out=$(orca terminal create --worktree "$wt" --title "$title" --command "$cmd" --json 2>"$err") && code=0 || code=$?
  if [ "$code" -eq 0 ] && ! printf '%s' "$out" | jq -e '.ok == false' >/dev/null 2>&1; then
    h=$(printf '%s' "$out" | jq -r '.result.terminal.handle // .result.handle // empty' 2>/dev/null)
    [ -z "$h" ] || printf '%s\n' "$h" >> "$made"
    return
  fi
  if { printf '%s\n' "$out"; cat "$err"; } | grep -q 'Timed out waiting for terminal handle'; then
    printf 'orca-terminal-create: create timed out; waiting up to %ss for the terminal to appear\n' "$limit" >&2
    return
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
  cat "$err" >&2
  die 1 "terminal create failed"
}
# wait_new <agents>: polls every --interval seconds until --timeout seconds have passed, or
# until a fresh agent terminal appears (<agents> 1) or the worktree holds two agent terminals
# (<agents> 2).
wait_new() {
  deadline=$(($(date +%s) + limit))
  while :; do
    if scan; then
      if [ "$1" -ge 2 ]; then [ "$(wc -l < "$agents" | tr -d ' ')" -ge 2 ] && return
      else new_agent && return
      fi
    fi
    [ "$(date +%s)" -ge "$deadline" ] && return
    sleep "$interval"
  done
}
# agents_die <reason>: prints every agent handle and dies with 4.
agents_die() { cat "$agents"; die 4 "$1"; }

# 1. Existing agents.
scan || die 1 "cannot list the terminals of $wt"
if [ -s "$agents" ]; then
  agents_die "$wt already has an agent terminal; nothing created. Use it, or close the extras with orca terminal close --terminal <handle>"
fi
cp "$all" "$before"

# 2. to 4. Create, wait, and at most one more create when nothing appeared.
create
wait_new 1
scan || die 1 "cannot list the terminals of $wt"
fresh
if [ ! -s "$new" ] && [ ! -s "$agents" ]; then
  printf 'orca-terminal-create: no new terminal appeared; creating once more\n' >&2
  create
  wait_new 2
fi

# 5. Final check.
scan || die 1 "cannot list the terminals of $wt"
fresh
if [ ! -s "$agents" ]; then
  if [ -s "$new" ]; then
    cat "$new"
    die 5 "terminal(s) exist in $wt but none shows an agent after ${limit}s; not recreating. Inspect them with orca terminal read"
  fi
  die 3 "no terminal appeared in $wt after two creates; stop and report"
fi
if [ "$(wc -l < "$agents" | tr -d ' ')" -ge 2 ]; then
  agents_die "$wt has several agent terminals; close all but one with orca terminal close --terminal <handle> before worker-start"
fi
cat "$agents"
