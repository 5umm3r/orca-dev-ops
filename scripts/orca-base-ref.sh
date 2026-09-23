#!/bin/sh
# Usage: orca-base-ref.sh [<path>]
# Prints the integration ref (for example origin/main) of the repository at <path> (default:
# the current directory). Exits non-zero with a message on stderr when it cannot be determined
# unambiguously. Never guesses master/main, never fetches, never creates branches.
#   1. Orca's worktreeBaseRef for the repository, when set.
#   2. Otherwise refs/remotes/<remote>/HEAD, where <remote> is the one Orca names
#      (gitRemoteIdentity.remoteName) or, when Orca names none, the only configured remote.
#   3. When Orca is unreachable or does not know the repository: git only, with the only
#      configured remote or `origin`.
die() { printf 'orca-base-ref: %s\n' "$*" >&2; exit 1; }
dir=${1:-.}
[ -d "$dir" ] || die "not a directory: $dir"
git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $dir"
# The main checkout is the first entry of the worktree list; Orca registers repositories by it.
main=$(git -C "$dir" worktree list --porcelain | sed -n '1s/^worktree //p')
[ -n "$main" ] || die "cannot find the main checkout of $dir"

# verify <ref>: prints the short name of <ref> when it exists as a commit.
verify() {
  git -C "$dir" rev-parse --verify --quiet "$1^{commit}" >/dev/null || return 1
  case "$1" in
  refs/remotes/*) printf '%s\n' "${1#refs/remotes/}" ;;
  refs/heads/*) printf '%s\n' "${1#refs/heads/}" ;;
  *) printf '%s\n' "$1" ;;
  esac
}

orca_json=
command -v orca >/dev/null 2>&1 && orca_json=$(orca repo show --repo "path:$main" --json 2>/dev/null)
if printf '%s' "$orca_json" | jq -e '.ok == true and (.result.repo | type) == "object"' >/dev/null 2>&1; then
  orca=yes
  base=$(printf '%s' "$orca_json" | jq -r '.result.repo.worktreeBaseRef // empty')
  if [ -n "$base" ]; then
    verify "$base" || die "Orca's worktreeBaseRef $base does not exist as a ref in $main"
    exit 0
  fi
  remote=$(printf '%s' "$orca_json" | jq -r '.result.repo.gitRemoteIdentity.remoteName // empty')
else
  orca=no remote=
fi

remotes=$(git -C "$dir" remote)
count=$(printf '%s' "$remotes" | grep -c .)
if [ -n "$remote" ]; then
  printf '%s\n' "$remotes" | grep -qFx -- "$remote" || die "Orca names remote $remote, which is not configured in $main"
elif [ "$count" -eq 1 ]; then
  remote=$remotes
elif [ "$count" -eq 0 ]; then
  die "no remote is configured in $main"
elif [ "$orca" = no ] && printf '%s\n' "$remotes" | grep -qFx origin; then
  remote=origin
elif [ "$orca" = yes ]; then
  die "several remotes are configured in $main and Orca names none; set one with: orca repo set-base-ref --repo path:$main --ref <remote>/<branch>"
else
  die "several remotes are configured in $main, none is origin, and Orca is unreachable"
fi

head=$(git -C "$dir" symbolic-ref --quiet "refs/remotes/$remote/HEAD") \
  || die "refs/remotes/$remote/HEAD is not set in $main; run: git -C \"$main\" remote set-head $remote --auto"
verify "$head" || die "$head does not exist in $main"
