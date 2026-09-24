#!/bin/sh
# Stub `orca` for the hook tests. It replays the fixture JSON captured from Orca 1.4.206
# (tests/fixtures/*.json) with the paths of the throwaway test repositories.
#   ORCA_STUB_FIXTURES  directory holding the fixture JSON files
#   ORCA_STUB           fail    -> no output, exit 1 (Orca unreachable)
#                       garbage -> non-JSON output, exit 0
#   ORCA_STUB_MAP       file of "<physical path><TAB><main|linked>" lines: the worktrees Orca knows.
#                       `worktree current` answers for the deepest entry containing the cwd.
#   ORCA_STUB_BASE_REF  worktreeBaseRef returned by `repo show` (default: null)
#   ORCA_STUB_REMOTE    gitRemoteIdentity.remoteName returned by `repo show` (default: origin; "null" for null)
#   ORCA_STUB_LOG       when set, every call's arguments are appended to this file, one call per line.
#   ORCA_STUB_HEADER_AFTER  `terminal read` shows an agent header from this call on (1 = the first
#                       call; default 1; "never" for never). Counts need ORCA_STUB_LOG.
#   ORCA_STUB_START     space-separated outcomes of successive `orchestration worker-start` calls
#                       (default: ok): ok, race (not a recognized agent, JSON on stdout),
#                       race-stderr (the same as a plain message on stderr), other (another error).
fx=$ORCA_STUB_FIXTURES
[ -n "${ORCA_STUB_LOG:-}" ] && printf '%s\n' "$*" >> "$ORCA_STUB_LOG"
# calls <prefix>: how many logged calls, including this one, start with <prefix>.
calls() { [ -n "${ORCA_STUB_LOG:-}" ] && grep -c "^$1" "$ORCA_STUB_LOG" || echo 1; }
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
"terminal read")
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
  ok) echo '{"ok":true,"result":{"worker":{"terminal":"term_stub","status":"started"}}}' ;;
  race) jq -n --arg m "$msg" '{ok: false, error: {code: "invalid_argument", message: $m}}'; exit 1 ;;
  race-stderr) echo "Error: $msg" >&2; exit 1 ;;
  other) echo '{"ok":false,"error":{"code":"not_found","message":"Task task_stub not found."}}'; exit 1 ;;
  esac
  ;;
*) echo "orca stub: unsupported command: $*" >&2; exit 2 ;;
esac
