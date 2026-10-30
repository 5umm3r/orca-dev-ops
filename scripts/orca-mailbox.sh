#!/bin/sh
# Usage: orca-mailbox.sh ensure [--objective <text>]
#        orca-mailbox.sh exec <verb> [<arg>...]
# The coordinator's mailbox: a plain shell terminal titled orca-mailbox in the main checkout of
# the current directory's repository, owning the coordinator's Run. Orca types "You have N (new)
# orchestration message(s)..." into the terminal that owns a Run inbox whenever that terminal's
# agent status is idle and no untyped `check --wait` is live, and sends Enter 500 ms later; it
# does not check whether the user is typing (read from Orca 1.4.243's bundled code). A terminal
# that runs no agent has no agent status, so nothing is typed into it, and the coordinator's own
# agent terminal no longer owns the inbox.
# The mailbox terminal (M) is a live row of `orca terminal list --worktree path:<main checkout>`
# titled orca-mailbox without an agentIdentity. Its handle is read from that list on every call,
# never stored in a file. Calls that act as M run without the Orca attestation variables (see
# orca_unattested in hooks/orca-lib.sh); with them, Orca refuses with consumer_fenced.
#   ensure  Finds M, or creates it with `orca terminal create --worktree path:<main> --title
#           orca-mailbox` (no --command: a plain shell). Then runs `run-current --from M`, and
#           `run-create --from M --objective <text>` (default: orca-dev-ops coordinator) when no
#           Run is bound. Prints {"terminal": "<M>", "run": "<run id>"}, exit 0.
#   exec    Finds M (never creates it: exit 3 when there is none) and runs
#           `orca orchestration <verb> --terminal M <arg>...` for check and
#           `orca orchestration <verb> --from M <arg>...` for every other verb, leaving out that
#           option when <arg>... already holds it. Stdout, stderr, and the exit status are Orca's.
# Two or more mailbox terminals: uses none, lists their handles on stderr, exit 4 (close all but
# one with orca terminal close). Closing M fences its Run; the next `ensure` creates a new
# terminal and Run. Usage errors exit 64; other failures exit 1. Requires orca and jq.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/hooks/orca-lib.sh"
usage() { printf 'orca-mailbox: %s\n' "$*" >&2; exit 64; }
die() { code=$1; shift; printf 'orca-mailbox: %s\n' "$*" >&2; exit "$code"; }

title=orca-mailbox objective='orca-dev-ops coordinator'
[ $# -ge 1 ] || usage "a subcommand is required: ensure or exec"
sub=$1
shift
case "$sub" in
ensure)
  while [ $# -gt 0 ]; do
    case "$1" in
    --objective) [ $# -ge 2 ] && [ -n "$2" ] || usage "--objective takes a non-empty text"; objective=$2; shift ;;
    *) usage "unknown option: $1" ;;
    esac
    shift
  done
  ;;
exec)
  [ $# -ge 1 ] && [ -n "$1" ] || usage "exec needs an orchestration verb"
  case "$1" in -*) usage "exec needs an orchestration verb before any option, not $1" ;; esac
  ;;
*) usage "unknown subcommand: $sub (ensure or exec)" ;;
esac
command -v orca >/dev/null 2>&1 || die 1 "orca is not on PATH"
command -v jq >/dev/null 2>&1 || die 1 "jq is not on PATH"

main=$(orca_main_checkout "$PWD")
[ -n "$main" ] || die 1 "cannot find the main checkout of the repository at $PWD"
wt="path:$main"

# mailbox: the handle of the mailbox terminal in $handle (empty when there is none). Dies when
# the list cannot be read completely or holds several mailbox terminals.
mailbox() {
  found=$(orca terminal list --worktree "$wt" --json 2>/dev/null | jq -r --arg t "$title" '
    if .ok == true and (.result.terminals | type) == "array" and .result.truncated != true then
      .result.terminals[] | select(.title == $t and .connected != false and .orphaned != true
        and (.agentIdentity // "") == "") | .handle // empty
    else error("no complete terminal list") end' 2>/dev/null) \
    || die 1 "cannot list the terminals of $main (orca terminal list failed or was incomplete)"
  if [ "$(printf '%s\n' "$found" | grep -c .)" -ge 2 ]; then
    printf '%s\n' "$found" >&2
    die 4 "$main has several $title terminals (listed above); none was used. Close all but one with orca terminal close --terminal <handle>"
  fi
  handle=$found
}

mailbox
if [ "$sub" = exec ]; then
  [ -n "$handle" ] || die 3 "no $title terminal in $main; run scripts/orca-mailbox.sh ensure first"
  verb=$1
  shift
  opt=--from
  [ "$verb" = check ] && opt=--terminal
  for a in "$@"; do
    case "$a" in "$opt" | "$opt="*) orca_unattested orchestration "$verb" "$@"; exit ;; esac
  done
  orca_unattested orchestration "$verb" "$opt" "$handle" "$@"
  exit
fi

if [ -z "$handle" ]; then
  out=$(orca terminal create --worktree "$wt" --title "$title" --json) \
    && handle=$(printf '%s' "$out" | jq -r 'select(.ok != false) | .result.terminal.handle // .result.handle // empty' 2>/dev/null) \
    && [ -n "$handle" ] || { [ -z "$out" ] || printf '%s\n' "$out" >&2; die 1 "could not create the $title terminal in $main"; }
fi
# run_id <receipt>: the bound Run's id (empty when none is bound); fails on an error receipt.
run_id() { printf '%s' "$1" | jq -er 'if .ok == true then .result.run.id // "" else error end' 2>/dev/null; }
out=$(orca_unattested orchestration run-current --from "$handle" --json)
run=$(run_id "$out") || { [ -z "$out" ] || printf '%s\n' "$out" >&2; die 1 "run-current failed for $handle"; }
if [ -z "$run" ]; then
  out=$(orca_unattested orchestration run-create --from "$handle" --objective "$objective" --json)
  run=$(run_id "$out") && [ -n "$run" ] || { [ -z "$out" ] || printf '%s\n' "$out" >&2; die 1 "run-create failed for $handle"; }
fi
jq -nc --arg t "$handle" --arg r "$run" '{terminal: $t, run: $r}'
