#!/bin/sh
# Usage: orca-run.sh ensure [--objective <text>]
# Makes sure the coordinator's own Orca terminal has an orchestration Run, once per session.
# Orca (1.4.246, Orchestrator V3) wakes the terminal that owns a Run: when a worker reports, it
# types "You have N orchestration message(s). Run orca orchestration check --run <id>." into
# that terminal and submits it. So the coordinator itself owns the Run, and every call runs as
# the calling terminal, with the Orca attestation variables unchanged (no --from).
#   ensure  Runs `orca orchestration run-current --json`; when a Run is bound, prints
#           {"run": "<run id>"}. Otherwise runs `orca orchestration run-create --objective <text>
#           --json` (default objective: "<repository basename> coordinator") and prints
#           {"run": "<run id>"} of the new Run. The run ID is read from .result.runId (the
#           concise view of Orca 1.4.246) or .result.run.id (an older Orca, or --full).
# Exit codes:
#   0   a Run is bound; {"run": "<run id>"} is on stdout
#   1   an Orca call failed or its receipt holds no Run ID (the receipt is on stderr)
#   3   not inside an Orca terminal (ORCA_TERMINAL_HANDLE is empty); nothing was called
#   64  usage error
# Requires orca, git, and jq.
usage() { printf 'orca-run: %s\n' "$*" >&2; exit 64; }
die() { code=$1; shift; printf 'orca-run: %s\n' "$*" >&2; exit "$code"; }

objective=
[ $# -ge 1 ] || usage "a subcommand is required: ensure"
[ "$1" = ensure ] || usage "unknown subcommand: $1 (ensure)"
shift
while [ $# -gt 0 ]; do
  case "$1" in
  --objective) [ $# -ge 2 ] && [ -n "$2" ] || usage "--objective takes a non-empty text"; objective=$2; shift ;;
  *) usage "unknown option: $1" ;;
  esac
  shift
done
[ -n "${ORCA_TERMINAL_HANDLE:-}" ] \
  || die 3 "ensure must run inside the coordinator's own Orca terminal (ORCA_TERMINAL_HANDLE is empty); the Run belongs to the terminal that calls it"
command -v orca >/dev/null 2>&1 || die 1 "orca is not on PATH"
command -v jq >/dev/null 2>&1 || die 1 "jq is not on PATH"
if [ -z "$objective" ]; then
  top=$(git rev-parse --show-toplevel 2>/dev/null) || top=$PWD
  objective="${top##*/} coordinator"
fi

# run_id <receipt>: the Run ID (empty when none is bound); fails on an error receipt.
run_id() {
  printf '%s' "$1" | jq -er 'if .ok == true then (.result.runId // .result.run.id // "" | strings) else error end' 2>/dev/null
}
out=$(orca orchestration run-current --json 2>&1)
rc=$?
if [ "$rc" -ne 0 ] || ! run=$(run_id "$out"); then
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  die 1 "run-current failed (exit $rc)"
fi
if [ -z "$run" ]; then
  out=$(orca orchestration run-create --objective "$objective" --json 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ] || ! run=$(run_id "$out") || [ -z "$run" ]; then
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    die 1 "run-create failed (exit $rc) or its receipt holds no Run ID"
  fi
fi
jq -nc --arg r "$run" '{run: $r}'
