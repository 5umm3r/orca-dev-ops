#!/bin/sh
# Tests for scripts/orca-progress.sh (read-only progress snapshot for the coordinator) with a stub
# orca that scripts `orchestration run-current`, `task-list`, `check --peek`, `terminal list`,
# and `terminal read`.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"
script="$root/scripts/orca-progress.sh"
export ORCA_STUB_LOG="$tmp/calls"

repo="$tmp/dev/my repo"; mkdir -p "$repo"; lines 10 > "$repo/app.txt"; new_repo "$repo"
wa="$tmp/work trees/cc-alpha"; wb="$tmp/work trees/cx-beta"; wd="$tmp/work trees/cc-done"
mkdir -p "$tmp/work trees"
git -C "$repo" worktree add -q -b cc-alpha "$wa" || exit 1
git -C "$repo" worktree add -q -b cx-beta "$wb" || exit 1
git -C "$repo" worktree add -q -b cc-done "$wd" || exit 1
orca_knows "$repo" main
# alpha: 2 tracked files changed (+3 -1 in app.txt, +2 in a new staged file), 1 untracked file
# besides TASKS.md (not counted: it is never committed), TASKS.md 2 of 5 checked
{ lines 9; echo "changed"; echo "added 1"; echo "added 2"; } > "$wa/app.txt"
echo "staged one" > "$wa/new.txt"; echo "staged two" >> "$wa/new.txt"; git -C "$wa" add new.txt
echo scratch > "$wa/notes.tmp"
printf '%s\n' '# Tasks' '- [x] read the code' '  - [X] write the failing test' '- [ ] implement' '* [ ] run the suite' '- [ ] report' > "$wa/TASKS.md"

cat > "$tmp/tasks.json" <<'EOF'
{"ok":true,"result":{"tasks":[
 {"id":"task_d","status":"completed","title":"done one"},
 {"id":"task_a","status":"dispatched","title":"alpha","dispatchId":"ctx_a","assignee":"term_a"},
 {"id":"task_b","status":"dispatched","title":"beta","dispatchId":"ctx_b","assignee":"term_b"},
 {"id":"task_c","status":"ready","title":"gamma"}],"runId":"run_x"}}
EOF
jq -n --arg a "$wa" --arg b "$wb" '{ok: true, result: {terminals: [
  {handle: "term_own", worktreePath: "/elsewhere", branch: "refs/heads/main", agentIdentity: "claude"},
  {handle: "term_a", worktreePath: $a, branch: "refs/heads/cc-alpha", agentIdentity: "claude", lastOutputAt: 1794792673228},
  {handle: "term_b", worktreePath: $b, branch: "refs/heads/cx-beta", agentIdentity: "codex", lastOutputAt: 1794792600000}],
  totalCount: 3, truncated: false}}' > "$tmp/terminals.json"
mkdir -p "$tmp/screens"
{ echo ""; lines 50; echo "   "; echo "✻ Running tests (2m 10s)"; echo ""; } > "$tmp/screens/term_a"
# term_b has no screen file: its terminal read fails.

export ORCA_TERMINAL_HANDLE=term_own ORCA_STUB_RUN=run_x ORCA_STUB_PEEK=mixed \
  ORCA_STUB_TASK_LIST_FILE="$tmp/tasks.json" ORCA_STUB_TERMINAL_LIST_FILE="$tmp/terminals.json" \
  ORCA_STUB_SCREEN_DIR="$tmp/screens"
cd "$repo" || exit 1

# run <arg>...: runs the script; prints its exit code and keeps stdout and stderr in $tmp/out and
# $tmp/err.
run() {
  : > "$ORCA_STUB_LOG"
  sh "$script" "$@" > "$tmp/out" 2> "$tmp/err"
  echo "$?"
}
q() { jq -c "$1" "$tmp/out"; }
count() { grep -c -- "$1" "$ORCA_STUB_LOG"; }
has() { result "$1" yes "$(printf '%s' "$2" | grep -qF -- "$3" && echo yes || echo no)"; }

# --- the full snapshot
result "snapshot" 0 "$(run)"
result "snapshot: run" '"run_x"' "$(q .run)"
result "snapshot: only unfinished tasks, in task-list order" '["task_a","task_b","task_c"]' "$(q '[.tasks[].id]')"
result "snapshot: completed tasks listed apart" '[{"id":"task_d","title":"done one"}]' "$(q .completed)"
result "alpha: task fields" '{"title":"alpha","status":"dispatched","dispatchId":"ctx_a","assignee":"term_a","agent":"claude","lastOutputAt":1794792673228}' \
  "$(q '.tasks[0] | {title, status, dispatchId, assignee, agent, lastOutputAt}')"
result "alpha: worktree and branch" "$(jq -nc --arg p "$wa" '{worktree: $p, branch: "cc-alpha"}')" "$(q '.tasks[0] | {worktree, branch}')"
result "alpha: diff against HEAD plus untracked" '{"files":2,"insertions":5,"deletions":1,"untracked":1}' "$(q .tasks[0].diff)"
result "alpha: TASKS.md checklist" '{"done":2,"total":5}' "$(q .tasks[0].checklist)"
result "alpha: screen is the last 40 non-blank lines" 40 "$(q '.tasks[0].screen | length')"
result "alpha: screen ends with the spinner" '"✻ Running tests (2m 10s)"' "$(q '.tasks[0].screen[-1]')"
result "alpha: screen starts at line 12" '"line 12"' "$(q '.tasks[0].screen[0]')"
result "alpha: unread worker_done and status" '[{"type":"worker_done","subject":"Done"},{"type":"status","subject":"Tests"}]' "$(q .tasks[0].unread)"
result "beta: failed terminal read gives a null screen" null "$(q .tasks[1].screen)"
result "beta: clean worktree" '{"files":0,"insertions":0,"deletions":0,"untracked":0}' "$(q .tasks[1].diff)"
result "beta: no TASKS.md" null "$(q .tasks[1].checklist)"
result "beta: agent codex" '"codex"' "$(q .tasks[1].agent)"
result "beta: unread question and escalation" '["question","escalation"]' "$(q '[.tasks[1].unread[].type]')"
result "gamma: no assignee, no worktree, no screen" '{"assignee":null,"worktree":null,"diff":null,"checklist":null,"screen":null}' \
  "$(q '.tasks[2] | {assignee, worktree, diff, checklist, screen}')"
result "gamma: unread status" '["status"]' "$(q '[.tasks[2].unread[].type]')"
result "idle worktrees: linked worktrees without an unfinished task" "$(jq -nc --arg p "$wd" '[{path: $p, branch: "cc-done"}]')" "$(q .idleWorktrees)"
result "peek ok" false "$(q .peekFailed)"
result "no unread outside the unfinished tasks" '[]' "$(q .unreadOther)"
result "terminal list not truncated" false "$(q .terminalsTruncated)"
result "screen read with --screen" 1 "$(count 'terminal read --terminal term_a --screen --json')"
result "nothing on stderr" "" "$(cat "$tmp/err")"
result "peek is a --peek call" 1 "$(count 'orchestration check --run run_x --peek --json')"
result "no consuming check" 1 "$(count 'orchestration check')"
result "read-only: no send, no create, no status" 0 "$(grep -Ec 'terminal (send|create)|run-create|orchestration (send|status|reply)' "$ORCA_STUB_LOG")"
result "the repository is untouched" "" "$(git -C "$repo" status --porcelain)"

# --- options
result "--lines 3" 0 "$(run --lines 3)"
result "--lines 3: three lines" '["line 49","line 50","✻ Running tests (2m 10s)"]' "$(q .tasks[0].screen)"
result "--run skips run-current" 0 "$(run --run run_given)"
result "--run: used" '"run_given"' "$(q .run)"
result "--run: no run-current" 0 "$(count 'run-current')"
has "--run: task-list for it" "$(cat "$ORCA_STUB_LOG")" "orchestration task-list --run run_given --json"

# --- no Run bound: an empty snapshot, nothing created
result "unbound" 0 "$(ORCA_STUB_RUN= run)"
result "unbound: empty snapshot" '{"run":null,"tasks":[],"completed":[]}' "$(q '{run, tasks, completed}')"
result "unbound: no run-create" 0 "$(count 'run-create')"
result "unbound: idle worktrees still listed" 3 "$(q '.idleWorktrees | length')"
result "unbound: no unread, not truncated" '{"unreadOther":[],"terminalsTruncated":false}' "$(q '{unreadOther, terminalsTruncated}')"

# --- an unread worker_done of a task Orca already marks completed is not dropped
jq '.result.tasks |= map(if .id == "task_a" then {id, status: "completed", title} else . end)' "$tmp/tasks.json" > "$tmp/tasks-done.json"
result "completed with unread" 0 "$(ORCA_STUB_TASK_LIST_FILE="$tmp/tasks-done.json" run)"
result "completed with unread: not in tasks" '["task_b","task_c"]' "$(q '[.tasks[].id]')"
result "completed with unread: unreadOther" '[{"taskId":"task_a","title":"alpha","type":"worker_done","subject":"Done"},{"taskId":"task_a","title":"alpha","type":"status","subject":"Tests"}]' "$(q .unreadOther)"
jq '.result.truncated = true' "$tmp/terminals.json" > "$tmp/terminals-trunc.json"
result "terminal list truncated" 0 "$(ORCA_STUB_TERMINAL_LIST_FILE="$tmp/terminals-trunc.json" run)"
result "terminal list truncated: flagged" true "$(q .terminalsTruncated)"

# --- partial failures keep the snapshot
result "peek fails" 0 "$(ORCA_STUB_PEEK=fail run)"
result "peek fails: flagged" true "$(q .peekFailed)"
result "peek fails: unread null" '[null,null,null]' "$(q '[.tasks[].unread]')"
result "peek fails: unreadOther null" null "$(q .unreadOther)"
result "terminal list fails" 0 "$(ORCA_STUB_TERMINAL_LIST_FILE="$tmp/missing" run)"
result "terminal list fails: no worktree" '[null,null,null]' "$(q '[.tasks[].worktree]')"
result "terminal list fails: screen still read" 40 "$(q '.tasks[0].screen | length')"

# --- hard failures
result "task-list fails" 1 "$(ORCA_STUB_TASK_LIST_FILE= ORCA_STUB_TASK_LIST=fail run)"
has "task-list fails: receipt on stderr" "$(cat "$tmp/err")" "Run not found."
result "task-list fails: nothing on stdout" "" "$(cat "$tmp/out")"
result "run-current fails" 1 "$(ORCA_STUB_RUN_CURRENT=fail run)"
result "Orca unreachable" 1 "$(ORCA_STUB=fail run)"
result "no ORCA_TERMINAL_HANDLE without --run" 3 "$(unset ORCA_TERMINAL_HANDLE; run)"
result "no ORCA_TERMINAL_HANDLE: no orca call" 0 "$(count .)"
result "no ORCA_TERMINAL_HANDLE with --run" 0 "$(unset ORCA_TERMINAL_HANDLE; run --run run_x)"

# --- usage errors
result "unknown option" 64 "$(run --bogus)"
result "--run without a value" 64 "$(run --run)"
result "--lines not a number" 64 "$(run --lines abc)"
result "--lines 0" 64 "$(run --lines 0)"
result "usage errors call no orca" 0 "$(count .)"

exit "$fail"
