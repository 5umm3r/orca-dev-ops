#!/bin/sh
# Stub `orca` for the hook tests. It replays the fixture JSON captured from Orca 1.4.206
# (tests/fixtures/*.json) with the paths of the throwaway test repositories.
#   ORCA_STUB_FIXTURES  directory holding the fixture JSON files
#   ORCA_STUB           fail    -> no output, exit 1 (Orca unreachable)
#                       garbage -> non-JSON output, exit 0
#   ORCA_STUB_DELAY     seconds to sleep before answering any call (default: none)
#   ORCA_STUB_MAP       file of "<physical path><TAB><main|linked>" lines: the worktrees Orca knows.
#                       `worktree current` answers for the deepest entry containing the cwd.
#   ORCA_STUB_BASE_REF  worktreeBaseRef returned by `repo show` (default: null)
#   ORCA_STUB_REMOTE    gitRemoteIdentity.remoteName returned by `repo show` (default: origin; "null" for null)
#   ORCA_STUB_LOG       when set, every call's arguments are appended to this file, one call per line.
#   ORCA_STUB_ENV_LOG   when set, every call appends one line to this file: the names of the Orca
#                       attestation variables (ORCA_TERMINAL_HANDLE, ORCA_PANE_KEY, ORCA_AGENT_PANE,
#                       ORCA_AGENT_LAUNCH, ORCA_AGENT_LAUNCH_TOKEN, ORCA_TAB_ID) set in its
#                       environment, space-separated, or "-" when none is set.
#   ORCA_STUB_HEADER_AFTER  `terminal read` shows an agent header from this call on (1 = the first
#                       call; default 1; "never" for never). Counts need ORCA_STUB_LOG.
#   ORCA_STUB_START     space-separated outcomes of successive `orchestration worker-start` calls
#                       (default: ok): ok, race (not a recognized agent, JSON on stdout),
#                       race-stderr (the same as a plain message on stderr), other (another error),
#                       no-dispatch (ok receipt without a dispatchId), empty-dispatch (ok receipt
#                       with dispatchId ""). The ok receipt is Orca 1.4.244's: .result.dispatchId,
#                       .result.taskId, .result.state ready.
#   ORCA_STUB_TASKS     space-separated task IDs `orchestration task-list` reports (default: task_1).
#   ORCA_STUB_TASK_LIST `orchestration task-list`: ok (default) or fail (ok false, exit 1).
#   ORCA_STUB_TASK_CREATE  `orchestration task-create`: ok (default; .result.task.id task_stub),
#                       uuid (a UUID `id` at the top, no .result.task.id), badid (.result.task.id
#                       "req_123"), empty (.result.task.id ""), notok (ok false, exit 1).
#   ORCA_STUB_TERMINALS  space-separated terminal sets of successive `terminal list` calls (default:
#                       none; the last set repeats). A set is a comma-separated list of none (an
#                       empty list), shell (a plain shell: no agentIdentity, no header), agent
#                       (agentIdentity claude, header on `terminal read`), or header (no
#                       agentIdentity, header on `terminal read`), mailbox (a plain shell titled
#                       orca-mailbox), mailbox-agent (the same with agentIdentity claude),
#                       mailbox-closed (the same as mailbox with connected false), or
#                       mailbox-orphan (the same as mailbox with orphaned true), or mailbox-tab
#                       (a plain shell whose tab title is orca-mailbox but whose paneTitle is
#                       not). mailbox rows carry paneTitle orca-mailbox. The Nth item of a
#                       set has the handle term_N. `terminal read` answers by the latest list call.
#                       Needs ORCA_STUB_LOG.
#   ORCA_STUB_TERMINALS_RECREATED  the same kind of list, used from the second `terminal create`
#                       call on, indexed by the `terminal list` calls since that create.
#   ORCA_STUB_CREATE    space-separated outcomes of successive `terminal create` calls (default:
#                       ok; the last repeats): ok (handle term_1), timeout (the runtime_error
#                       JSON on stdout, exit 1), timeout-stderr (the same on stderr), other
#                       (another error).
#   ORCA_STUB_SPLIT     `terminal split`: ok (default; handle term_split) or fail (ok false, exit 1).
#   ORCA_STUB_PANE_TITLE  `terminal set-pane-title`: ok (default) or fail (ok false, exit 1).
#   ORCA_STUB_WORKTREE_LIST `worktree list`: ok (default; the git worktrees of the --repo main
#                       checkout, main first), truncated (the same with truncated: true).
#   ORCA_STUB_CHECK     space-separated results of successive `orchestration check` calls
#                       (default: timeout): timeout (empty, timedOut), empty (empty, not timed
#                       out), block (timeout after sleeping ORCA_STUB_BLOCK_SECONDS, default 3),
#                       error (ok false, exit 1), or a comma-separated list of message
#                       types for one Delivery with deliveryId dlv_<call number> (`untyped` is a
#                       message whose type is null). Each result follows a keepalive line on
#                       stdout and stderr.
#   ORCA_STUB_RUN       the Run id `orchestration run-current` reports as bound (default: none, a
#                       null run).
#   ORCA_STUB_RUN_CREATE  `orchestration run-create`: ok (default; Run run_created with the given
#                       --objective) or fenced (the consumer_fenced error, exit 1).
#   ORCA_STUB_VERB_FAIL  an orchestration verb without its own fixture (send, reply, task-create,
#                       ...) that fails: an ok false receipt on stdout, a line on stderr, exit 3.
#                       Every other such verb answers {"ok": true, "result": {"verb": <verb>}}.
fx=$ORCA_STUB_FIXTURES
[ -n "${ORCA_STUB_LOG:-}" ] && printf '%s\n' "$*" >> "$ORCA_STUB_LOG"
if [ -n "${ORCA_STUB_ENV_LOG:-}" ]; then
  set_vars=
  for v in ORCA_TERMINAL_HANDLE ORCA_PANE_KEY ORCA_AGENT_PANE ORCA_AGENT_LAUNCH ORCA_AGENT_LAUNCH_TOKEN ORCA_TAB_ID; do
    eval "[ -n \"\${$v+x}\" ]" && set_vars="$set_vars $v"
  done
  printf '%s\n' "${set_vars# }" | sed 's/^$/-/' >> "$ORCA_STUB_ENV_LOG"
fi
# calls <prefix>: how many logged calls, including this one, start with <prefix>.
calls() { [ -n "${ORCA_STUB_LOG:-}" ] && grep -c "^$1" "$ORCA_STUB_LOG" || echo 1; }
# nth <number> <word>...: the <number>th word, or the last one when there are fewer.
nth() { k=$1; shift; while [ "$k" -gt 1 ] && [ $# -gt 1 ]; do k=$((k - 1)); shift; done; echo "$1"; }
# list_state: the terminal set that the current `terminal list` call (or a `terminal read` after
# it) sees, see ORCA_STUB_TERMINALS and ORCA_STUB_TERMINALS_RECREATED.
list_state() {
  if [ -n "${ORCA_STUB_TERMINALS_RECREATED:-}" ] && [ "$(grep -c '^terminal create' "$ORCA_STUB_LOG")" -ge 2 ]; then
    nth "$(awk '/^terminal create/ { c = 0; next } /^terminal list/ { c++ } END { print c + 0 }' "$ORCA_STUB_LOG")" $ORCA_STUB_TERMINALS_RECREATED
  else
    lists=$(grep -c '^terminal list' "$ORCA_STUB_LOG" 2>/dev/null); lists=${lists:-0}
    [ "$lists" -ge 1 ] || lists=1
    nth "$lists" ${ORCA_STUB_TERMINALS:-none}
  fi
}
# The sleep's output is closed so a killed stub does not leave it holding the caller's pipe.
[ -n "${ORCA_STUB_DELAY:-}" ] && sleep "$ORCA_STUB_DELAY" >/dev/null 2>&1
case "${ORCA_STUB:-}" in
fail) exit 1 ;;
garbage) echo 'orca: something went wrong'; exit 0 ;;
esac
tab=$(printf '\t')

# lookup <path>: prints "<entry path><TAB><kind>" of the deepest map entry containing <path>.
lookup() {
  best= kind=
  [ -f "$ORCA_STUB_MAP" ] && while IFS=$tab read -r p k; do
    case "$1/" in "$p"/*) [ ${#p} -gt ${#best} ] && { best=$p; kind=$k; } ;; esac
  done < "$ORCA_STUB_MAP"
  [ -n "$best" ] && printf '%s\t%s\n' "$best" "$kind"
}

case "$1 $2" in
"worktree current")
  here=$(pwd -P)
  hit=$(lookup "$here")
  if [ -z "$hit" ]; then
    jq --arg m "No Orca-managed worktree contains the current directory: $here" '.error.message = $m' "$fx/worktree-current-not-found.json"
    exit 1
  fi
  p=${hit%"$tab"*}
  case "$hit" in
  *"${tab}main") jq --arg p "$p" '.result.worktree.path = $p | .result.worktree.git.path = $p' "$fx/worktree-current-main.json" ;;
  *) jq --arg p "$p" '.result.worktree.path = $p | .result.worktree.git.path = $p
      | .result.worktree.id = (.result.worktree.repoId + "::" + $p)' "$fx/worktree-current-child.json" ;;
  esac
  ;;
"repo show")
  sel=
  while [ $# -gt 0 ]; do [ "$1" = --repo ] && sel=$2; shift; done
  p=${sel#path:}
  case "$(lookup "$p")" in
  "$p${tab}main") ;;
  *) cat "$fx/repo-show-not-found.json"; exit 1 ;;
  esac
  jq --arg p "$p" --arg base "${ORCA_STUB_BASE_REF:-}" --arg remote "${ORCA_STUB_REMOTE:-origin}" '
    .result.repo.path = $p
    | .result.repo.worktreeBaseRef = (if $base == "" then null else $base end)
    | .result.repo.gitRemoteIdentity.remoteName = (if $remote == "null" then null else $remote end)' "$fx/repo-show.json"
  ;;
"worktree list")
  sel=
  while [ $# -gt 0 ]; do [ "$1" = --repo ] && sel=$2; shift; done
  p=${sel#path:}
  case "$(lookup "$p")" in
  "$p${tab}main") ;;
  *) cat "$fx/repo-show-not-found.json"; exit 1 ;;
  esac
  git -C "$p" worktree list --porcelain | sed -n 's/^worktree //p' \
    | jq -R . | jq -s --slurpfile f "$fx/worktree-list.json" --arg trunc "${ORCA_STUB_WORKTREE_LIST:-ok}" '
      . as $paths | $f[0] | .result.worktrees[0] as $row
      | .result.worktrees = [$paths | to_entries[] | .key as $i | .value as $p | $row
          | .path = $p | .git.path = $p | .id = (.repoId + "::" + $p)
          | .isMainWorktree = ($i == 0) | .git.isMainWorktree = ($i == 0)]
      | .result.totalCount = ($paths | length)
      | .result.truncated = ($trunc == "truncated")'
  ;;
"orchestration check")
  n=$(calls 'orchestration check')
  set -- ${ORCA_STUB_CHECK:-timeout}
  outcome=timeout
  while [ "$n" -gt 0 ] && [ $# -gt 0 ]; do outcome=$1; n=$((n - 1)); shift; done
  keepalive='{"_keepalive":true,"_heartbeat":true,"elapsedMs":15000,"deadlineMs":590000}'
  echo "$keepalive"; echo "$keepalive" >&2
  [ "$outcome" = block ] && { sleep "${ORCA_STUB_BLOCK_SECONDS:-3}"; outcome=timeout; }
  case "$outcome" in
  error) echo '{"ok":false,"error":{"code":"consumer_fenced","message":"Run run_stub is bound to another consumer."}}'; exit 1 ;;
  timeout | empty) jq --argjson t "$([ "$outcome" = timeout ] && echo true || echo false)" \
      '.result.deliveryId = null | .result.messages = [] | .result.count = 0 | .result.timedOut = $t' "$fx/check-delivery.json" ;;
  *) jq --arg types "$outcome" --arg d "dlv_$(calls 'orchestration check')" '
      .result.messages[0] as $m
      | .result.deliveryId = $d
      | .result.messages = [$types | split(",") | to_entries[]
          | $m + {id: "msg_\($d)_\(.key)", type: (if .value == "untyped" then null else .value end), subject: "\(.value) \(.key)"}]
      | .result.count = (.result.messages | length)' "$fx/check-delivery.json" ;;
  esac
  ;;
"terminal list")
  state=$(list_state)
  jq -n --arg s "$state" '[$s | split(",") | to_entries[] | select(.value != "none") | {
      handle: "term_\(.key + 1)", worktreeId: "repo_stub::/w", worktreePath: "/w",
      title: (if .value | startswith("mailbox") then "orca-mailbox" else "agent" end),
      paneTitle: (if .value == "mailbox-tab" then "other" elif .value | startswith("mailbox") then "orca-mailbox" else null end),
      preview: "", connected: (.value != "mailbox-closed"), orphaned: (.value == "mailbox-orphan"),
      agentIdentity: (if .value == "agent" or .value == "mailbox-agent" then "claude" else null end)}]
    | {ok: true, result: {terminals: ., totalCount: length, truncated: false}}'
  ;;
"terminal create")
  case "$(nth "$(calls 'terminal create')" ${ORCA_STUB_CREATE:-ok})" in
  ok) echo '{"ok":true,"result":{"terminal":{"handle":"term_1","title":"agent"}}}' ;;
  timeout) echo '{"code":"runtime_error","message":"Timed out waiting for terminal handle after creation"}'; exit 1 ;;
  timeout-stderr) echo '{"code":"runtime_error","message":"Timed out waiting for terminal handle after creation"}' >&2; exit 1 ;;
  other) echo '{"ok":false,"error":{"code":"not_found","message":"Worktree not found."}}'; exit 1 ;;
  esac
  ;;
"terminal split")
  case "${ORCA_STUB_SPLIT:-ok}" in
  ok) echo '{"ok":true,"result":{"split":{"handle":"term_split","tabId":"tab","paneRuntimeId":1,"leafId":"leaf"}}}' ;;
  fail) echo '{"ok":false,"error":{"code":"not_found","message":"Terminal not found."}}'; exit 1 ;;
  esac
  ;;
"terminal set-pane-title")
  case "${ORCA_STUB_PANE_TITLE:-ok}" in
  ok) echo '{"ok":true,"result":{"paneTitle":"set"}}' ;;
  fail) echo '{"ok":false,"error":{"code":"runtime_error","message":"set-pane-title failed"}}'; exit 1 ;;
  esac
  ;;
"terminal close")
  echo '{"ok":true,"result":{"closed":true}}'
  ;;
"terminal read")
  if [ -n "${ORCA_STUB_TERMINALS:-}" ]; then
    h=
    while [ $# -gt 0 ]; do [ "$1" = --terminal ] && h=$2; shift; done
    kind=
    case "$h" in term_[0-9]*) kind=$(list_state | cut -d, -f"${h#term_}") ;; esac
    line='$'
    case "$kind" in agent | header) line='[Opus 5.5] | cc-task' ;; esac
    jq -n --arg h "$h" --arg l "$line" '{ok: true, result: {terminal: {handle: $h, status: "running",
      tail: ["", $l, "❯"], source: "screen"}}}'
    exit 0
  fi
  after=${ORCA_STUB_HEADER_AFTER:-1}
  line='Claude Code'
  [ "$after" != never ] && [ "$(calls 'terminal read')" -ge "$after" ] && line='[Opus 5.5] | cc-task'
  jq -n --arg l "$line" '{ok: true, result: {terminal: {handle: "term_stub", status: "running",
    tail: ["", $l, "❯"], source: "screen"}}}'
  ;;
"orchestration worker-start")
  n=$(calls 'orchestration worker-start')
  set -- ${ORCA_STUB_START:-ok}
  outcome=ok
  while [ "$n" -gt 0 ] && [ $# -gt 0 ]; do outcome=$1; n=$((n - 1)); shift; done
  msg='Terminal term_stub is not running a recognized agent.'
  case "$outcome" in
  ok) echo '{"ok":true,"result":{"dispatchId":"ctx_stub","taskId":"task_stub","state":"ready"}}' ;;
  no-dispatch) echo '{"ok":true,"result":{"taskId":"task_stub","state":"ready"}}' ;;
  empty-dispatch) echo '{"ok":true,"result":{"dispatchId":"","taskId":"task_stub","state":"ready"}}' ;;
  race) jq -n --arg m "$msg" '{ok: false, error: {code: "invalid_argument", message: $m}}'; exit 1 ;;
  race-stderr) echo "Error: $msg" >&2; exit 1 ;;
  other) echo '{"ok":false,"error":{"code":"not_found","message":"Task task_stub not found."}}'; exit 1 ;;
  esac
  ;;
"orchestration run-current")
  jq -n --arg r "${ORCA_STUB_RUN:-}" '{ok: true, result: {run: (if $r == "" then null else {id: $r, objective: "stub"} end)}}'
  ;;
"orchestration run-create")
  obj=
  while [ $# -gt 0 ]; do [ "$1" = --objective ] && obj=$2; shift; done
  case "${ORCA_STUB_RUN_CREATE:-ok}" in
  ok) jq -n --arg o "$obj" '{ok: true, result: {run: {id: "run_created", objective: $o}}}' ;;
  fenced) echo '{"ok":false,"error":{"code":"consumer_fenced","message":"This terminal is attested as term_own and cannot act as term_1."}}'; exit 1 ;;
  esac
  ;;
"orchestration task-list")
  if [ "${ORCA_STUB_TASK_LIST:-ok}" = fail ]; then
    echo '{"ok":false,"error":{"code":"not_found","message":"Run not found."}}'
    exit 1
  fi
  jq -n --arg ids "${ORCA_STUB_TASKS-task_1}" '[$ids | split(" ")[] | select(. != "") | {id: ., status: "ready"}]
    | {ok: true, result: {tasks: ., count: length}}'
  ;;
"orchestration task-create")
  if [ "${ORCA_STUB_VERB_FAIL:-}" = task-create ]; then
    echo '{"ok":false,"error":{"code":"stub_failure","message":"task-create failed"}}'
    echo "orca stub: task-create failed" >&2
    exit 3
  fi
  case "${ORCA_STUB_TASK_CREATE:-ok}" in
  ok) echo '{"id":"7d1c9b52-1f0e-4c8a-9d2e-3a5b6c7d8e9f","ok":true,"result":{"task":{"id":"task_stub","status":"ready"}}}' ;;
  uuid) echo '{"id":"7d1c9b52-1f0e-4c8a-9d2e-3a5b6c7d8e9f","ok":true,"result":{"verb":"task-create"}}' ;;
  badid) echo '{"id":"7d1c9b52-1f0e-4c8a-9d2e-3a5b6c7d8e9f","ok":true,"result":{"task":{"id":"req_123","status":"ready"}}}' ;;
  empty) echo '{"ok":true,"result":{"task":{"id":"","status":"ready"}}}' ;;
  notok) echo '{"ok":false,"error":{"code":"not_found","message":"Run not found."}}'; exit 1 ;;
  esac
  ;;
"orchestration "*)
  if [ "$2" = "${ORCA_STUB_VERB_FAIL:-}" ]; then
    jq -n --arg v "$2" '{ok: false, error: {code: "stub_failure", message: "\($v) failed"}}'
    echo "orca stub: $2 failed" >&2
    exit 3
  fi
  jq -n --arg v "$2" '{ok: true, result: {verb: $v}}'
  ;;
*) echo "orca stub: unsupported command: $*" >&2; exit 2 ;;
esac
