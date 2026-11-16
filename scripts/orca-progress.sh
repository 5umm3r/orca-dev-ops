#!/bin/sh
# Usage: orca-progress.sh [--run <run_id>] [--lines <n>]
# Read-only progress snapshot of the coordinator's child tasks, for the progress-report skill.
# It never creates a Run, never sends to a terminal, and never consumes a message.
#   1. The Run: --run, or the Run bound to this terminal (`orca orchestration run-current`).
#      No Run bound: an empty snapshot (run null).
#   2. `orca orchestration task-list --run <run> --json`: every task whose status is not
#      completed, in task-list order; completed tasks go to .completed.
#   3. `orca terminal list --json`: the assignee's worktree path, branch, agent, lastOutputAt.
#   4. Per assignee, `orca terminal read --terminal <handle> --screen --json`: the last <n> (default 40)
#      non-blank screen lines.
#   5. Per worktree, git: `diff HEAD --numstat` (files, insertions, deletions) and the untracked
#      files besides TASKS.md; TASKS.md checkboxes ("- [x]" / "- [ ]", also "*").
#   6. `orca orchestration check --run <run> --peek --json`: unread messages per task (peek
#      marks nothing read). A message of no unfinished task (its task may already be
#      completed while its worker_done is unread) goes to .unreadOther.
#   7. git worktree list of this repository: linked worktrees without an unfinished task.
# Prints one JSON object:
#   {run, tasks: [{id, title, status, dispatchId, assignee, agent, lastOutputAt, worktree,
#    branch, diff: {files, insertions, deletions, untracked} | null, checklist: {done, total} |
#    null, screen: [line] | null, unread: [{type, subject}] | null}], completed: [{id, title}],
#    unreadOther: [{taskId, title, type, subject}] | null, idleWorktrees: [{path, branch}],
#    terminalsTruncated, peekFailed}
# A failing terminal list, terminal read, or peek leaves its fields null (peekFailed true).
# Exit codes:
#   0   the snapshot is on stdout
#   1   run-current or task-list failed (the receipt is on stderr)
#   3   no --run and not inside an Orca terminal (ORCA_TERMINAL_HANDLE is empty); nothing called
#   64  usage error
# Requires orca, git, and jq.
usage() { printf 'orca-progress: %s\n' "$*" >&2; exit 64; }
die() { code=$1; shift; printf 'orca-progress: %s\n' "$*" >&2; exit "$code"; }

run= lines=40
while [ $# -gt 0 ]; do
  case "$1" in
  --run) [ $# -ge 2 ] && [ -n "$2" ] || usage "--run takes a Run ID"; run=$2; shift ;;
  --lines)
    [ $# -ge 2 ] || usage "--lines takes a positive number"
    case "$2" in '' | *[!0-9]* | 0*) usage "--lines takes a positive number" ;; esac
    lines=$2; shift ;;
  *) usage "unknown option: $1" ;;
  esac
  shift
done
[ -n "$run" ] || [ -n "${ORCA_TERMINAL_HANDLE:-}" ] \
  || die 3 "without --run this must run inside the coordinator's own Orca terminal (ORCA_TERMINAL_HANDLE is empty)"
command -v orca >/dev/null 2>&1 || die 1 "orca is not on PATH"
command -v jq >/dev/null 2>&1 || die 1 "jq is not on PATH"

tmpd=$(mktemp -d) || exit 1
trap 'rm -rf "$tmpd"' EXIT

# phys <path>: the physical path when it is a directory, else <path>.
phys() { (CDPATH= cd -P -- "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }

# Linked worktrees of this repository (git, no Orca): "<path><TAB><branch>" lines.
: > "$tmpd/worktrees"
if git rev-parse --git-dir >/dev/null 2>&1; then
  git worktree list --porcelain 2>/dev/null | awk '
    /^worktree / { if (p != "") print p "\t" b; p = substr($0, 10); b = ""; n++; if (n == 1) { p = ""; skip = 1 } else skip = 0; next }
    /^branch / { b = substr($0, 8); sub(/^refs\/heads\//, "", b) }
    END { if (p != "") print p "\t" b }' > "$tmpd/worktrees"
fi
idle_json() {
  # idle_json <file of active worktree paths>
  while IFS=$(printf '\t') read -r p b; do
    pp=$(phys "$p")
    grep -Fxq -- "$pp" "$1" 2>/dev/null || jq -nc --arg p "$pp" --arg b "$b" '{path: $p, branch: $b}'
  done < "$tmpd/worktrees" | jq -sc .
}

if [ -z "$run" ]; then
  out=$(orca orchestration run-current --json 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ] || ! run=$(printf '%s' "$out" | jq -er 'if .ok == true then (.result.runId // .result.run.id // "" | strings) else error end' 2>/dev/null); then
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    die 1 "run-current failed (exit $rc)"
  fi
  if [ -z "$run" ]; then
    : > "$tmpd/active"
    jq -n --argjson idle "$(idle_json "$tmpd/active")" \
      '{run: null, tasks: [], completed: [], unreadOther: [], idleWorktrees: $idle,
        terminalsTruncated: false, peekFailed: false}'
    exit 0
  fi
fi

list=$(orca orchestration task-list --run "$run" --json 2>&1)
rc=$?
if [ "$rc" -ne 0 ] || ! printf '%s' "$list" | jq -e '.ok == true and (.result.tasks | type == "array")' >/dev/null 2>&1; then
  [ -z "$list" ] || printf '%s\n' "$list" >&2
  die 1 "task-list for run $run failed (exit $rc)"
fi

terms=$(orca terminal list --json 2>/dev/null) \
  && printf '%s' "$terms" | jq -e '.ok == true' >/dev/null 2>&1 || terms='{"result":{"terminals":[]}}'
peek_failed=false
mail=$(orca orchestration check --run "$run" --peek --json 2>/dev/null) \
  && printf '%s' "$mail" | jq -e '.ok == true and (.result.messages | type == "array")' >/dev/null 2>&1 \
  || { mail=null; peek_failed=true; }

: > "$tmpd/active"
: > "$tmpd/tasks"
printf '%s' "$list" | jq -c '.result.tasks[] | select(.status != "completed")' | while IFS= read -r task; do
  h=$(printf '%s' "$task" | jq -r '.assignee // empty')
  row=null wt= diff=null checklist=null screen=null
  if [ -n "$h" ]; then
    row=$(printf '%s' "$terms" | jq -c --arg h "$h" '[.result.terminals[]? | select(.handle == $h)][0]')
    wt=$(printf '%s' "$row" | jq -r '.worktreePath // empty')
    [ -z "$wt" ] || wt=$(phys "$wt")
    screen=$(orca terminal read --terminal "$h" --screen --json 2>/dev/null \
      | jq -c --argjson n "$lines" 'if .ok == true then [.result.terminal.tail[]? | strings | select(test("\\S"))] | .[-$n:] else error end' 2>/dev/null) \
      || screen=null
    [ -n "$screen" ] || screen=null
  fi
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    printf '%s\n' "$wt" >> "$tmpd/active"
    if numstat=$(git -C "$wt" diff HEAD --numstat 2>/dev/null); then
      untracked=$(git -C "$wt" ls-files --others --exclude-standard 2>/dev/null | grep -cvx 'TASKS.md')
      diff=$(printf '%s\n' "$numstat" | awk -v u="$untracked" '
        NF >= 3 { f++; if ($1 != "-") i += $1; if ($2 != "-") d += $2 }
        END { printf "{\"files\":%d,\"insertions\":%d,\"deletions\":%d,\"untracked\":%d}", f, i, d, u }')
    fi
    if [ -f "$wt/TASKS.md" ]; then
      checklist=$(awk '
        /^[[:space:]]*[-*][[:space:]]+\[[xX]\]/ { d++; t++; next }
        /^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\]/ { t++ }
        END { printf "{\"done\":%d,\"total\":%d}", d, t }' "$wt/TASKS.md")
    fi
  fi
  jq -nc --argjson t "$task" --argjson row "$row" --arg wt "$wt" --argjson diff "$diff" \
    --argjson checklist "$checklist" --argjson screen "$screen" --argjson mail "$mail" '
    {id: $t.id, title: $t.title, status: $t.status, dispatchId: ($t.dispatchId // null),
     assignee: ($t.assignee // null), agent: ($row.agentIdentity // null),
     lastOutputAt: ($row.lastOutputAt // null),
     worktree: (if $wt == "" then null else $wt end),
     branch: ($row.branch // null | if . == null then null else sub("^refs/heads/"; "") end),
     diff: $diff, checklist: $checklist, screen: $screen,
     unread: (if $mail == null then null else
       [$mail.result.messages[] | select(.payload.taskId == $t.id) | {type, subject}] end)}' >> "$tmpd/tasks"
done

jq -n --arg run "$run" --slurpfile tasks "$tmpd/tasks" --argjson list "$list" \
  --argjson idle "$(idle_json "$tmpd/active")" --argjson pf "$peek_failed" \
  --argjson mail "$mail" --argjson terms "$terms" '
  ([$tasks[].id]) as $open
  | ([$list.result.tasks[] | {key: .id, value: .title}] | from_entries) as $titles
  | {run: $run, tasks: $tasks,
     completed: [$list.result.tasks[] | select(.status == "completed") | {id, title}],
     unreadOther: (if $mail == null then null else
       [$mail.result.messages[] | (.payload.taskId // null) as $id
        | select($id == null or ($open | index($id) | not))
        | {taskId: $id, title: (if $id == null then null else $titles[$id] end), type, subject}] end),
     idleWorktrees: $idle, terminalsTruncated: ($terms.result.truncated == true), peekFailed: $pf}'
