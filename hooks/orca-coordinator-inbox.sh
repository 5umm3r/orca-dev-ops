#!/bin/sh
# UserPromptSubmit (Claude Code, coordinator only): on every user prompt, peek at the Run bound
# to this terminal and, when it holds unread orchestration messages, remind the session to
# handle them in this turn. A wake that Orca held (a composer draft) or that was lost is then
# caught the next time the user types.
#
#   stdin: the hook JSON (.cwd, .prompt)
#
# Behavior:
#   - Acts only when orca_role (orca-lib.sh) says `master`; any other role prints nothing.
#   - Prints nothing when ORCA_TERMINAL_HANDLE is empty, when the prompt (leading whitespace
#     trimmed) is Orca's own wake text ("You have N orchestration message(s). Run ..."), or
#     when orca or jq is missing; these checks come before any Orca call.
#   - Calls, as the calling terminal (never --from; the Orca attestation variables are left
#     as they are): `orca orchestration run-current --json` (.result.runId, or .result.run.id
#     from an older Orca), then `orca orchestration check --run <id> --peek --json`. --peek
#     marks nothing read, so the coordinator's own `check` still sees every message.
#   - Prints nothing when no Run is bound, the mailbox is empty, or any call fails, times out
#     (ORCA_CLI_TIMEOUT, default 3 seconds per call here), prints non-JSON, or answers without
#     ok true.
#   - Otherwise prints one additionalContext line: the message count, the count per type, and
#     the deduplicated Dispatch IDs of worker_done, question, and escalation messages.
# Never blocks or rewrites the prompt; always exits 0.
here="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$here/orca-lib.sh"
command -v jq >/dev/null 2>&1 || exit 0
command -v orca >/dev/null 2>&1 || exit 0
[ -n "${ORCA_TERMINAL_HANDLE:-}" ] || exit 0
input=$(cat)
prompt=$(printf '%s' "$input" | jq -r '.prompt // empty | sub("^\\s+"; "")' 2>/dev/null)
case "$prompt" in
"You have "*"orchestration message"*) exit 0 ;;
esac
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ "$(orca_role "$cwd")" = master ] || exit 0

ORCA_CLI_TIMEOUT=${ORCA_CLI_TIMEOUT:-3}
cd "$cwd" 2>/dev/null || exit 0
run=$(orca_cli orchestration run-current --json 2>/dev/null) || exit 0
run=$(printf '%s' "$run" | jq -r 'select(.ok == true) | .result | (.runId // .run.id // empty) | strings' 2>/dev/null)
# A Run ID goes into the context and onto a command line: accept the plain ID form only.
case "$run" in '' | *[!A-Za-z0-9_-]*) exit 0 ;; esac
mail=$(orca_cli orchestration check --run "$run" --peek --json 2>/dev/null) || exit 0
summary=$(printf '%s' "$mail" | jq -r '
  def uniq_ordered: reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end);
  select(.ok == true) | .result.messages | arrays | select(length > 0)
  | . as $m
  | ([$m[] | .type | strings | select(test("^[A-Za-z0-9_-]+$"))] | uniq_ordered) as $types
  | [$types[] as $t | "\($t) \([$m[] | select(.type == $t)] | length)"] as $counts
  | ([$m[] | select(.type == "worker_done" or .type == "question" or .type == "escalation")
      | .payload | (if type == "string" then (try fromjson catch null) else . end)
      | objects | .dispatchId | strings | select(test("^[A-Za-z0-9_-]+$"))] | uniq_ordered) as $ids
  | "\($m | length)\t\($counts | join(", "))\t\($ids | join(", "))"' 2>/dev/null)
[ -n "$summary" ] || exit 0
tab=$(printf '\t')
n=${summary%%"$tab"*}
rest=${summary#*"$tab"}
types=${rest%%"$tab"*}
ids=${rest#*"$tab"}
noun=messages
[ "$n" = 1 ] && noun=message
detail=$types
[ -n "$ids" ] && detail="$detail; dispatches $ids"
ctx="[orca-workflow] $n unread orchestration $noun on Run $run ($detail). Run \`orca orchestration check --run $run\` and handle them in this turn along with the user's request."
jq -n --arg ctx "$ctx" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$ctx}}'
exit 0
