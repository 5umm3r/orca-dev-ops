#!/bin/sh
# Usage: orca-mailbox.sh ensure [--objective <text>] [--direction horizontal|vertical]
#        orca-mailbox.sh exec <verb> [<arg>...]
# The coordinator's mailbox: a plain shell split pane of the coordinator's own tab, with pane title
# orca-mailbox, owning the coordinator's Run. Orca types "You have N (new)
# orchestration message(s)..." into the terminal that owns a Run inbox whenever that terminal's
# agent status is idle and no untyped `check --wait` is live, and sends Enter 500 ms later; it
# does not check whether the user is typing (read from Orca 1.4.243's bundled code). A terminal
# that runs no agent has no agent status, so nothing is typed into it, and the coordinator's own
# agent terminal no longer owns the inbox.
# The mailbox pane (M) is a live row of `orca terminal list --worktree path:<main checkout>` whose
# paneTitle is orca-mailbox, without an agentIdentity (the row's title is the tab's, shared by all
# its panes, so it is not matched). Its handle is read from that list on every call, never stored
# in a file. Calls that act as M run without the Orca attestation variables (see orca_unattested in
# hooks/orca-lib.sh); with them, Orca refuses with consumer_fenced.
#   ensure  Finds M, or splits the caller's own pane (`orca terminal split --terminal
#           $ORCA_TERMINAL_HANDLE --direction <direction>`, a plain shell; it must run inside the
#           coordinator's Orca terminal) and names the new pane with `orca terminal set-pane-title
#           --title orca-mailbox`; when naming fails the new pane is closed again. --direction
#           defaults to horizontal (stacked above and below). Then runs `run-current --from M`, and
#           `run-create --from M --objective <text>` (default: orca-dev-ops coordinator) when no
#           Run is bound. Prints {"terminal": "<M>", "run": "<run id>"}, exit 0.
#   exec    Finds M (never creates it: exit 3 when there is none) and runs
#           `orca orchestration <verb> --terminal M <arg>...` for check and
#           `orca orchestration <verb> --from M <arg>...` for every other verb, leaving out that
#           option when <arg>... already holds it. Stdout, stderr, and the exit status are Orca's.
# Two or more mailbox panes: uses none, lists their handles on stderr, exit 4 (close all but
# one with orca terminal close). M closes with the coordinator's tab. Closing M fences its Run;
# the next `ensure` splits a new pane and creates a new Run. Usage errors exit 64; other failures
# exit 1. Requires orca and jq.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/hooks/orca-lib.sh"
usage() { printf 'orca-mailbox: %s\n' "$*" >&2; exit 64; }
die() { code=$1; shift; printf 'orca-mailbox: %s\n' "$*" >&2; exit "$code"; }

# The subcommand and the exec verb come first, with no option before them: the launch gate
# (hooks/orca-launch-gate.sh) finds a launch only as the adjacent words `exec worker-start`.
# Keep this order, or extend the gate first (tests/orca-mailbox.test.sh pins it).
title=orca-mailbox objective='orca-dev-ops coordinator' direction=horizontal
[ $# -ge 1 ] || usage "a subcommand is required: ensure or exec"
sub=$1
shift
case "$sub" in
ensure)
  while [ $# -gt 0 ]; do
    case "$1" in
    --objective) [ $# -ge 2 ] && [ -n "$2" ] || usage "--objective takes a non-empty text"; objective=$2; shift ;;
    --direction)
      [ $# -ge 2 ] && { [ "$2" = horizontal ] || [ "$2" = vertical ]; } || usage "--direction takes horizontal or vertical"
      direction=$2; shift ;;
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

# mailbox: the handle of the mailbox pane in $handle (empty when there is none). Dies when
# the list cannot be read completely or holds several mailbox panes.
mailbox() {
  found=$(orca terminal list --worktree "$wt" --json 2>/dev/null | jq -r --arg t "$title" '
    if .ok == true and (.result.terminals | type) == "array" and .result.truncated != true then
      .result.terminals[] | select(.paneTitle == $t and .connected != false and .orphaned != true
        and (.agentIdentity // "") == "") | .handle // empty
    else error("no complete terminal list") end' 2>/dev/null) \
    || die 1 "cannot list the terminals of $main (orca terminal list failed or was incomplete)"
  if [ "$(printf '%s\n' "$found" | grep -c .)" -ge 2 ]; then
    printf '%s\n' "$found" >&2
    die 4 "$main has several $title panes (listed above); none was used. Close all but one with orca terminal close --terminal <handle>"
  fi
  handle=$found
}

mailbox
if [ "$sub" = exec ]; then
  [ -n "$handle" ] || die 3 "no $title pane in $main; run scripts/orca-mailbox.sh ensure first"
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
  [ -n "${ORCA_TERMINAL_HANDLE:-}" ] || die 1 "ensure must run inside the coordinator's Orca terminal (ORCA_TERMINAL_HANDLE is empty)"
  out=$(orca terminal split --terminal "$ORCA_TERMINAL_HANDLE" --direction "$direction" --json) \
    && handle=$(printf '%s' "$out" | jq -r 'select(.ok != false) | .result.split.handle // empty' 2>/dev/null) \
    && [ -n "$handle" ] || { [ -z "$out" ] || printf '%s\n' "$out" >&2; die 1 "could not split the $title pane off $ORCA_TERMINAL_HANDLE"; }
  out=$(orca terminal set-pane-title --terminal "$handle" --title "$title" --json) \
    && printf '%s' "$out" | jq -e '.ok != false' >/dev/null 2>&1 \
    || { [ -z "$out" ] || printf '%s\n' "$out" >&2
         orca terminal close --terminal "$handle" >/dev/null 2>&1
         die 1 "could not name the new pane $handle $title; it was closed"; }
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
