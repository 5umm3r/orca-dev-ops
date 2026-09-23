#!/bin/sh
# Shared setup for the hook tests, sourced by tests/*.test.sh: a throwaway temp dir and HOME,
# a stub `orca` on PATH (tests/fixtures/orca-stub.sh), and helpers to build git repositories.
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp=$(mktemp -d) || exit 1
tmp=$(CDPATH= cd -P -- "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
mkdir -p "$HOME" "$tmp/bin" "$tmp/scratch"
cp "$root/tests/fixtures/orca-stub.sh" "$tmp/bin/orca" && chmod +x "$tmp/bin/orca" || exit 1
export PATH="$tmp/bin:$PATH" ORCA_STUB_FIXTURES="$root/tests/fixtures" ORCA_STUB_MAP="$tmp/orca-map"
unset ORCA_STUB ORCA_STUB_BASE_REF ORCA_STUB_REMOTE CLAUDE_PLUGIN_ROOT
: > "$ORCA_STUB_MAP"

# orca_knows <path> <main|linked>: the stub Orca reports <path> as a worktree of that kind.
orca_knows() { printf '%s\t%s\n' "$1" "$2" >> "$ORCA_STUB_MAP"; }
# marker <dir>: opt <dir> into the Orca worktree rules.
marker() { mkdir -p "$1/.claude" && printf '<!-- orca-worktree-rules:start (test) -->\nrules\n<!-- orca-worktree-rules:end -->\n' > "$1/.claude/CLAUDE.md"; }
# new_repo <dir>: a git repository on branch main with one commit of whatever <dir> already holds.
new_repo() {
  mkdir -p "$1" && git -C "$1" init -q -b main && git -C "$1" add -A && git -C "$1" commit -q --allow-empty -m init || exit 1
}
lines() { awk -v n="$1" 'BEGIN { for (i = 1; i <= n; i++) print "line " i }'; }

fail=0
# result <name> <expected> <got>
result() {
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (expected $2, got $3)"; fail=1; fi
}
