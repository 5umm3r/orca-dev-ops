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
fx=$ORCA_STUB_FIXTURES
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
*) echo "orca stub: unsupported command: $*" >&2; exit 2 ;;
esac
