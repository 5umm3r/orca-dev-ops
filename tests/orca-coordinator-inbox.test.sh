#!/bin/sh
# Tests for hooks/orca-coordinator-inbox.sh (UserPromptSubmit unread-mail reminder) with a stub
# orca that scripts `orchestration run-current` and `orchestration check --peek`.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"
hook="$root/hooks/orca-coordinator-inbox.sh"
export ORCA_STUB_LOG="$tmp/calls" ORCA_STUB_ENV_LOG="$tmp/env"

repo="$tmp/dev/my repo"; mkdir -p "$repo"; marker "$repo"; new_repo "$repo"
child="$tmp/work trees/task one"; mkdir -p "$tmp/work trees"
git -C "$repo" worktree add -q -b task-one "$child" || exit 1
plain="$tmp/plain"; mkdir -p "$plain"; new_repo "$plain"
orca_knows "$repo" main
orca_knows "$child" linked
orca_knows "$plain" main
attested="ORCA_TERMINAL_HANDLE ORCA_PANE_KEY ORCA_AGENT_PANE ORCA_AGENT_LAUNCH ORCA_AGENT_LAUNCH_TOKEN ORCA_TAB_ID"
export ORCA_TERMINAL_HANDLE=term_own ORCA_PANE_KEY=pane ORCA_AGENT_PANE=1 ORCA_AGENT_LAUNCH=1 \
  ORCA_AGENT_LAUNCH_TOKEN=tok ORCA_TAB_ID=tab ORCA_STUB_RUN=run_x

# run <cwd> [<prompt>]: runs the hook; prints its exit code and keeps stdout in $tmp/out.
run() {
  : > "$ORCA_STUB_LOG"; : > "$ORCA_STUB_ENV_LOG"
  jq -n --arg cwd "$1" --arg p "${2-fix the login page}" '{cwd:$cwd,hook_event_name:"UserPromptSubmit",prompt:$p}' \
    | sh "$hook" > "$tmp/out" 2> "$tmp/err"
  echo "$?"
}
ctx() { jq -r '.hookSpecificOutput.additionalContext // empty' "$tmp/out"; }
count() { grep -c -- "$1" "$ORCA_STUB_LOG"; }
call() { grep -- "^$1" "$ORCA_STUB_LOG" | sed -n 1p; }
has() { result "$1" yes "$(printf '%s' "$2" | grep -qF -- "$3" && echo yes || echo no)"; }
lacks() { result "$1" no "$(printf '%s' "$2" | grep -qF -- "$3" && echo yes || echo no)"; }
silent() { result "$1: exit 0" 0 "$2"; result "$1: no output" "" "$(cat "$tmp/out")"; result "$1: nothing on stderr" "" "$(cat "$tmp/err")"; }

# --- master, one unread worker_done
result "worker_done: exit 0" 0 "$(ORCA_STUB_PEEK=worker_done run "$repo")"
result "worker_done: event name" UserPromptSubmit "$(jq -r '.hookSpecificOutput.hookEventName' "$tmp/out")"
c=$(ctx)
has "worker_done: count" "$c" "1 unread orchestration message on Run run_x"
has "worker_done: type count" "$c" "(worker_done 1; dispatches ctx_a)"
has "worker_done: check command" "$c" "\`orca orchestration check --run run_x\`"
has "worker_done: this turn" "$c" "in this turn"
result "worker_done: one line" 1 "$(printf '%s\n' "$c" | wc -l | tr -d ' ')"
result "worker_done: run-current as the caller" "orchestration run-current --json" "$(call 'orchestration run-current')"
result "worker_done: check peeks" "orchestration check --run run_x --peek --json" "$(call 'orchestration check')"
result "worker_done: every check has --peek" 0 "$(grep '^orchestration check' "$ORCA_STUB_LOG" | grep -vc -- '--peek')"
result "worker_done: no --from" 0 "$(count '--from')"
result "worker_done: every call attested" "$attested
$attested
$attested" "$(cat "$ORCA_STUB_ENV_LOG")"

# --- master, mixed mailbox: types counted in order, dispatches of worker_done/question/escalation only
result "mixed: exit 0" 0 "$(ORCA_STUB_PEEK=mixed run "$repo")"
c=$(ctx)
has "mixed: count" "$c" "5 unread orchestration messages on Run run_x"
has "mixed: types and dispatches" "$c" "(status 2, worker_done 1, question 1, escalation 1; dispatches ctx_a, ctx_b)"
lacks "mixed: status-only dispatch not listed" "$c" "ctx_c"

# --- older Orca: .result.run.id
result "legacy run shape: exit 0" 0 "$(ORCA_STUB_RUN_SHAPE=legacy ORCA_STUB_PEEK=worker_done run "$repo")"
has "legacy run shape: Run" "$(ctx)" "on Run run_x"

# --- silent cases
silent "empty mailbox" "$(run "$repo")"
result "empty mailbox: peeked" 1 "$(count 'orchestration check --run run_x --peek')"
silent "no bound Run" "$(ORCA_STUB_RUN= ORCA_STUB_PEEK=worker_done run "$repo")"
result "no bound Run: no check" 0 "$(count 'orchestration check')"
silent "legacy, no bound Run" "$(ORCA_STUB_RUN= ORCA_STUB_RUN_SHAPE=legacy ORCA_STUB_PEEK=worker_done run "$repo")"
silent "child role" "$(ORCA_STUB_PEEK=worker_done run "$child")"
result "child role: no orchestration call" 0 "$(count '^orchestration')"
silent "out-of-scope repository" "$(ORCA_STUB_PEEK=worker_done run "$plain")"
result "out-of-scope repository: no orchestration call" 0 "$(count '^orchestration')"
silent "no cwd" "$(ORCA_STUB_PEEK=worker_done run "")"
silent "wake text" "$(ORCA_STUB_PEEK=worker_done run "$repo" 'You have 2 orchestration message(s). Run orca orchestration check --run run_x.')"
result "wake text: no Orca call" "" "$(cat "$ORCA_STUB_LOG")"
silent "wake text, leading whitespace" "$(ORCA_STUB_PEEK=worker_done run "$repo" '
   You have 1 orchestration message(s). Run orca orchestration check --run run_x.')"
result "wake text, leading whitespace: no Orca call" "" "$(cat "$ORCA_STUB_LOG")"
result "user prompt quoting the wake: reminded" 0 "$(ORCA_STUB_PEEK=worker_done run "$repo" 'Why did You have 1 orchestration message appear?')"
has "user prompt quoting the wake: context" "$(ctx)" "1 unread orchestration message"
silent "no terminal handle" "$(ORCA_TERMINAL_HANDLE= ORCA_STUB_PEEK=worker_done run "$repo")"
result "no terminal handle: no Orca call" "" "$(cat "$ORCA_STUB_LOG")"
silent "peek fails" "$(ORCA_STUB_PEEK=fail run "$repo")"
silent "peek garbage" "$(ORCA_STUB_PEEK=garbage run "$repo")"
silent "run-current fails" "$(ORCA_STUB_RUN_CURRENT=fail ORCA_STUB_PEEK=worker_done run "$repo")"
silent "Orca unreachable" "$(ORCA_STUB=fail run "$repo")"
silent "Orca garbage" "$(ORCA_STUB=garbage run "$repo")"
silent "unsafe Run ID" "$(ORCA_STUB_RUN='run_x; rm -rf /' ORCA_STUB_PEEK=worker_done run "$repo")"
result "unsafe Run ID: no check" 0 "$(count 'orchestration check')"
silent "slow Orca" "$(ORCA_CLI_TIMEOUT=1 ORCA_STUB_DELAY=3 ORCA_STUB_PEEK=worker_done run "$repo")"

# --- no orca or jq on PATH (a PATH with only the basic tools)
mkdir -p "$tmp/nobin"
for t in sh cat dirname pwd; do ln -s "$(command -v "$t")" "$tmp/nobin/$t"; done
r=$(printf '{"cwd":"%s","prompt":"hi"}' "$repo" | PATH="$tmp/nobin" "$tmp/nobin/sh" "$hook" > "$tmp/out" 2> "$tmp/err"; echo $?)
silent "no orca or jq" "$r"
ln -s "$(command -v jq)" "$tmp/nobin/jq"
: > "$ORCA_STUB_LOG"
r=$(printf '{"cwd":"%s","prompt":"hi"}' "$repo" | PATH="$tmp/nobin" "$tmp/nobin/sh" "$hook" > "$tmp/out" 2> "$tmp/err"; echo $?)
silent "no orca" "$r"
result "no orca: stub not called" "" "$(cat "$ORCA_STUB_LOG")"

exit "$fail"
