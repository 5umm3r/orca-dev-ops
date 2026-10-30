#!/bin/sh
# Tests for scripts/orca-mailbox.sh with a stub orca that scripts `terminal list`, `terminal
# split`, `terminal set-pane-title`, and the orchestration verbs (never a live terminal or Run).
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"
script="$root/scripts/orca-mailbox.sh"
export ORCA_STUB_LOG="$tmp/calls" ORCA_STUB_ENV_LOG="$tmp/env"
repo="$tmp/dev/my repo"; mkdir -p "$repo"; new_repo "$repo"
child="$tmp/wt/task"; mkdir -p "$tmp/wt"
git -C "$repo" worktree add -q -b task "$child" || exit 1
cd "$child" || exit 1
# The calling terminal's attestation, which the calls that act as the mailbox must drop.
export ORCA_TERMINAL_HANDLE=term_own ORCA_PANE_KEY=pane ORCA_AGENT_PANE=1 ORCA_AGENT_LAUNCH=1 \
  ORCA_AGENT_LAUNCH_TOKEN=tok ORCA_TAB_ID=tab

# mailbox <ORCA_STUB_TERMINALS> <arg>...: runs the script; prints its exit code and keeps stdout
# and stderr in $tmp/out and $tmp/err.
mailbox() {
  : > "$ORCA_STUB_LOG"; : > "$ORCA_STUB_ENV_LOG"
  ORCA_STUB_TERMINALS=$1; export ORCA_STUB_TERMINALS; shift
  sh "$script" "$@" > "$tmp/out" 2> "$tmp/err"
  echo "$?"
}
count() { grep -c -- "$1" "$ORCA_STUB_LOG"; }
# call <prefix>: the arguments of the first logged call starting with <prefix>.
call() { grep -- "^$1" "$ORCA_STUB_LOG" | sed -n 1p; }
# env_of <prefix>: the attestation variables the first call starting with <prefix> saw.
env_of() { n=$(grep -n -- "^$1" "$ORCA_STUB_LOG" | sed -n '1s/:.*//p'); sed -n "${n}p" "$ORCA_STUB_ENV_LOG"; }
has() { result "$1" yes "$(printf '%s' "$2" | grep -qF -- "$3" && echo yes || echo no)"; }
lacks() { result "$1" no "$(printf '%s' "$2" | grep -qF -- "$3" && echo yes || echo no)"; }

# --- ensure: splits the caller's pane and creates the Run
unset ORCA_STUB_RUN
result "ensure without a mailbox" 0 "$(mailbox none ensure)"
result "ensure without a mailbox: JSON" '{"terminal":"term_split","run":"run_created"}' "$(jq -c . "$tmp/out")"
has "ensure lists the main checkout's terminals" "$(call 'terminal list')" "--worktree path:$repo --json"
result "ensure splits the caller's own pane" "terminal split --terminal term_own --direction horizontal --json" "$(call 'terminal split')"
result "ensure: the split stays attested" "ORCA_TERMINAL_HANDLE ORCA_PANE_KEY ORCA_AGENT_PANE ORCA_AGENT_LAUNCH ORCA_AGENT_LAUNCH_TOKEN ORCA_TAB_ID" "$(env_of 'terminal split')"
result "ensure names the new pane" "terminal set-pane-title --terminal term_split --title orca-mailbox --json" "$(call 'terminal set-pane-title')"
result "ensure: no terminal create" 0 "$(count 'terminal create')"
result "ensure: no close" 0 "$(count 'terminal close')"
result "ensure: the list stays attested" "ORCA_TERMINAL_HANDLE ORCA_PANE_KEY ORCA_AGENT_PANE ORCA_AGENT_LAUNCH ORCA_AGENT_LAUNCH_TOKEN ORCA_TAB_ID" "$(env_of 'terminal list')"
has "ensure asks run-current as the mailbox" "$(call 'orchestration run-current')" "--from term_split --json"
result "ensure: run-current unattested" - "$(env_of 'orchestration run-current')"
has "ensure creates the Run as the mailbox" "$(call 'orchestration run-create')" "--from term_split --objective orca-dev-ops coordinator --json"
result "ensure: run-create unattested" - "$(env_of 'orchestration run-create')"
result "ensure --objective" 0 "$(mailbox none ensure --objective 'ship it')"
has "ensure --objective is passed on" "$(call 'orchestration run-create')" "--objective ship it --json"
result "ensure --direction horizontal" 0 "$(mailbox none ensure --direction horizontal)"
has "ensure --direction is passed on" "$(call 'terminal split')" "--direction horizontal --json"
result "ensure --direction vertical" 0 "$(mailbox none ensure --direction vertical)"
has "ensure --direction vertical is passed on" "$(call 'terminal split')" "--direction vertical --json"
result "ensure: run-create fenced" 1 "$(ORCA_STUB_RUN_CREATE=fenced mailbox none ensure)"
has "ensure: run-create fenced: receipt on stderr" "$(cat "$tmp/err")" "consumer_fenced"
result "ensure: run-create fenced: nothing on stdout" "" "$(cat "$tmp/out")"
result "ensure: split fails" 1 "$(ORCA_STUB_SPLIT=fail mailbox none ensure)"
has "ensure: split fails: receipt on stderr" "$(cat "$tmp/err")" "not_found"
result "ensure: split fails: no pane title" 0 "$(count 'terminal set-pane-title')"
result "ensure: split fails: no close" 0 "$(count 'terminal close')"
result "ensure: split fails: no run calls" 0 "$(count 'orchestration')"
result "ensure: set-pane-title fails" 1 "$(ORCA_STUB_PANE_TITLE=fail mailbox none ensure)"
has "ensure: set-pane-title fails: receipt on stderr" "$(cat "$tmp/err")" "set-pane-title failed"
result "ensure: set-pane-title fails: the new pane is closed" "terminal close --terminal term_split" "$(call 'terminal close')"
result "ensure: set-pane-title fails: no run calls" 0 "$(count 'orchestration')"
result "ensure: set-pane-title fails: nothing on stdout" "" "$(cat "$tmp/out")"
result "ensure without ORCA_TERMINAL_HANDLE" 1 "$(unset ORCA_TERMINAL_HANDLE; mailbox none ensure)"
has "ensure without ORCA_TERMINAL_HANDLE: says where to run" "$(cat "$tmp/err")" "inside the coordinator's Orca terminal"
result "ensure without ORCA_TERMINAL_HANDLE: no split" 0 "$(count 'terminal split')"
result "ensure without ORCA_TERMINAL_HANDLE: no state change" 0 "$(count 'terminal set-pane-title\|^terminal close\|orchestration')"
result "ensure with an empty ORCA_TERMINAL_HANDLE" 1 "$(ORCA_TERMINAL_HANDLE= mailbox none ensure)"
result "ensure with an empty ORCA_TERMINAL_HANDLE: no split" 0 "$(count 'terminal split')"

# --- ensure: reuses the pane and the Run
result "ensure with a mailbox and a Run" 0 "$(ORCA_STUB_RUN=run_live mailbox shell,agent,mailbox ensure)"
result "ensure with a mailbox and a Run: JSON" '{"terminal":"term_3","run":"run_live"}' "$(jq -c . "$tmp/out")"
result "ensure reuses the pane" 0 "$(count 'terminal split')"
result "ensure reuses the pane: no title call" 0 "$(count 'terminal set-pane-title')"
result "ensure reuses the Run" 0 "$(count 'orchestration run-create')"
result "ensure reuses the pane without ORCA_TERMINAL_HANDLE" 0 "$(unset ORCA_TERMINAL_HANDLE; ORCA_STUB_RUN=run_live mailbox mailbox ensure)"
result "ensure with a mailbox, no Run" 0 "$(mailbox mailbox ensure)"
result "ensure with a mailbox, no Run: JSON" '{"terminal":"term_1","run":"run_created"}' "$(jq -c . "$tmp/out")"
result "ensure with a mailbox, no Run: no split" 0 "$(count 'terminal split')"
result "a tab titled orca-mailbox with another paneTitle is not the mailbox" 0 "$(mailbox mailbox-tab ensure)"
result "a tab titled orca-mailbox: a new split" 1 "$(count 'terminal split')"
result "an agent pane titled orca-mailbox is not the mailbox" 0 "$(mailbox mailbox-agent ensure)"
result "an agent pane titled orca-mailbox: a new split" 1 "$(count 'terminal split')"
result "a closed mailbox is not the mailbox" 1 "$(mailbox mailbox-closed ensure >/dev/null; count 'terminal split')"
result "an orphaned mailbox is not the mailbox" 1 "$(mailbox mailbox-orphan ensure >/dev/null; count 'terminal split')"

# --- duplicates: exit 4 and nothing used
result "ensure with two mailboxes" 4 "$(mailbox mailbox,shell,mailbox ensure)"
result "two mailboxes: handles on stderr" "term_1 term_3" "$(grep '^term_' "$tmp/err" | tr '\n' ' ' | sed 's/ $//')"
result "two mailboxes: nothing split" 0 "$(count 'terminal split')"
result "two mailboxes: no orchestration call" 0 "$(count 'orchestration')"
result "a mailbox and a tab titled orca-mailbox: one match" 0 "$(mailbox mailbox,mailbox-tab ensure)"
result "exec with two mailboxes" 4 "$(mailbox mailbox,mailbox exec send --to x)"
result "exec with two mailboxes: no orchestration call" 0 "$(count 'orchestration')"

# --- exec: adds --from or --terminal as the mailbox, unattested
result "exec send" 0 "$(mailbox shell,mailbox exec send --to term_x --subject hi)"
has "exec send: --from the mailbox" "$(call 'orchestration send')" "orchestration send --from term_2 --to term_x --subject hi"
result "exec send: unattested" - "$(env_of 'orchestration send')"
result "exec send: stdout passed through" '"send"' "$(jq .result.verb "$tmp/out")"
result "exec check" 0 "$(mailbox mailbox exec check --run run_1 --json)"
has "exec check: --terminal the mailbox" "$(call 'orchestration check')" "orchestration check --terminal term_1 --run run_1 --json"
lacks "exec check: no --from" "$(call 'orchestration check')" "--from"
result "exec check: unattested" - "$(env_of 'orchestration check')"
result "exec task-create" 0 "$(mailbox mailbox exec task-create --spec x)"
has "exec task-create: --from" "$(call 'orchestration task-create')" "task-create --from term_1 --spec x"
result "exec with an explicit --from" 0 "$(mailbox mailbox exec reply --from term_other --id m)"
result "exec with an explicit --from: left alone" "orchestration reply --from term_other --id m" "$(call 'orchestration reply')"
result "exec with an explicit --from=" 0 "$(mailbox mailbox exec send --from=term_other)"
result "exec with an explicit --from=: left alone" "orchestration send --from=term_other" "$(call 'orchestration send')"
result "exec check with an explicit --terminal" 0 "$(mailbox mailbox exec check --terminal term_other)"
result "exec check with an explicit --terminal: left alone" "orchestration check --terminal term_other" "$(call 'orchestration check')"
result "exec: exit status passed through" 3 "$(ORCA_STUB_VERB_FAIL=send mailbox mailbox exec send --to x)"
result "exec: failure receipt on stdout" '"stub_failure"' "$(jq .error.code "$tmp/out")"
result "exec: Orca's stderr passed through" "orca stub: send failed" "$(cat "$tmp/err")"

# --- exec without a mailbox: exit 3, never creates one
result "exec without a mailbox" 3 "$(mailbox shell,agent exec send --to x)"
has "exec without a mailbox: tells to run ensure" "$(cat "$tmp/err")" "orca-mailbox.sh ensure"
result "exec without a mailbox: nothing created" 0 "$(count 'terminal split')"
result "exec without a mailbox: no orchestration call" 0 "$(count 'orchestration')"

# --- other failures
result "terminal list fails" 1 "$(ORCA_STUB=fail mailbox mailbox ensure)"
result "outside a git repository" 1 "$(cd "$tmp/scratch" && mailbox none ensure)"

# --- usage errors
result "no arguments" 64 "$(mailbox none)"
result "unknown subcommand" 64 "$(mailbox none status)"
result "ensure: unknown option" 64 "$(mailbox none ensure --bogus)"
result "ensure: --objective without a value" 64 "$(mailbox none ensure --objective)"
result "ensure: empty --objective" 64 "$(mailbox none ensure --objective '')"
result "exec without a verb" 64 "$(mailbox none exec)"
result "exec with an option instead of a verb" 64 "$(mailbox none exec --from x send)"
result "usage errors call no orca" 0 "$(count .)"
# The launch gate detects only the adjacent words `orca-mailbox.sh exec worker-start`; every other
# order must stop here before any orca call, or a launch could pass the gate.
for a in "--x exec worker-start" "exec --from x worker-start" "exec -- worker-start" "exec --json worker-start"; do
  # shellcheck disable=SC2086 # split on purpose
  result "launch-gate order: $a" 64 "$(mailbox none $a --agent claude)"
  result "launch-gate order: $a calls no orca" 0 "$(count .)"
done

exit "$fail"
