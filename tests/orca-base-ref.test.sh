#!/bin/sh
# Tests for scripts/orca-base-ref.sh with a stub orca and throwaway remotes and clones.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"
script="$root/scripts/orca-base-ref.sh"

# bare <name> <default branch>: a bare remote with that default branch and a `release` branch.
bare() {
  b="$tmp/remotes/$1.git" s="$tmp/seed-$1"
  git init -q --bare -b "$2" "$b" && mkdir -p "$s" && git -C "$s" init -q -b "$2" \
    && git -C "$s" commit -q --allow-empty -m init && git -C "$s" push -q "$b" "$2" "$2:release" || exit 1
}
bare on-main main
bare on-master master
r="$tmp/repos with space"
mkdir -p "$r"
clone() { git clone -q "$@" || exit 1; }
clone "$tmp/remotes/on-main.git" "$r/main"
clone "$tmp/remotes/on-master.git" "$r/master"
clone -o upstream "$tmp/remotes/on-main.git" "$r/upstream"
clone "$tmp/remotes/on-main.git" "$r/multi"
git -C "$r/multi" remote add fork "$tmp/remotes/on-master.git" && git -C "$r/multi" fetch -q fork \
  && git -C "$r/multi" remote set-head fork master >/dev/null || exit 1
clone -o a "$tmp/remotes/on-main.git" "$r/ab"
git -C "$r/ab" remote add b "$tmp/remotes/on-master.git" || exit 1
clone "$tmp/remotes/on-main.git" "$r/nohead"
git -C "$r/nohead" remote set-head origin -d || exit 1
clone "$tmp/remotes/on-main.git" "$r/unregistered"
git -C "$r/main" worktree add -q -b task "$tmp/task wt" || exit 1
for d in main master upstream multi ab nohead; do orca_knows "$r/$d" main; done
orca_knows "$tmp/task wt" linked

# base [<path>]: the printed ref, or "error" when it exits non-zero with a message on stderr only.
base() {
  if out=$(sh "$script" "$@" 2>"$tmp/err"); then printf '%s' "$out"
  elif [ -z "$out" ] && [ -s "$tmp/err" ]; then echo error
  else echo "bad failure: [$out] [$(cat "$tmp/err")]"
  fi
}

result "origin/main" origin/main "$(base "$r/main")"
result "origin/master" origin/master "$(base "$r/master")"
result "default path is cwd" origin/main "$(cd "$r/main" && base)"
result "subdirectory" origin/main "$(mkdir -p "$r/main/sub" && base "$r/main/sub")"
result "non-origin remote named by Orca" upstream/main "$(ORCA_STUB_REMOTE=upstream base "$r/upstream")"
result "non-origin single remote, no Orca hint" upstream/main "$(ORCA_STUB_REMOTE=null base "$r/upstream")"
result "several remotes, Orca names origin" origin/main "$(base "$r/multi")"
result "several remotes, Orca names fork" fork/master "$(ORCA_STUB_REMOTE=fork base "$r/multi")"
result "several remotes, no Orca hint" error "$(ORCA_STUB_REMOTE=null base "$r/multi")"
result "Orca remote not configured, single remote" error "$(ORCA_STUB_REMOTE=gone base "$r/upstream")"
result "Orca worktreeBaseRef short" origin/release "$(ORCA_STUB_BASE_REF=origin/release base "$r/main")"
result "Orca worktreeBaseRef full" origin/release "$(ORCA_STUB_BASE_REF=refs/remotes/origin/release base "$r/main")"
result "Orca worktreeBaseRef missing ref" error "$(ORCA_STUB_BASE_REF=origin/nope base "$r/main")"
result "linked worktree asks Orca about the main checkout" origin/release "$(ORCA_STUB_BASE_REF=origin/release base "$tmp/task wt")"
result "linked worktree, no Orca base ref" origin/main "$(base "$tmp/task wt")"
result "remote HEAD not set" error "$(base "$r/nohead")"
result "Orca does not know the repo: git only" origin/main "$(base "$r/unregistered")"
export ORCA_STUB=fail
result "Orca unreachable: origin/main" origin/main "$(base "$r/main")"
result "Orca unreachable: origin/master" origin/master "$(base "$r/master")"
result "Orca unreachable: single non-origin remote" upstream/main "$(base "$r/upstream")"
result "Orca unreachable: several remotes with origin" origin/main "$(base "$r/multi")"
result "Orca unreachable: several remotes without origin" error "$(base "$r/ab")"
result "Orca unreachable: linked worktree" origin/main "$(base "$tmp/task wt")"
export ORCA_STUB=garbage
result "Orca garbage: git only" origin/master "$(base "$r/master")"
unset ORCA_STUB
result "not a repository" error "$(base "$tmp/scratch")"
result "missing path" error "$(base "$tmp/does-not-exist")"

exit "$fail"
