#!/bin/sh
# Install the generic "Orca worktree rules" block into a repository.
#
#   orca-init.sh [--apply] [repo-path]
#
# Target file: <repo>/.claude/CLAUDE.md, plus a <repo>/AGENTS.md symlink for Codex.
# Behaviour:
#   file missing              -> create it (no confirmation needed)
#   marker block present      -> replace the block in place (idempotent update)
#   file exists, no marker    -> print the block and exit 2 unless --apply is given
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMPLATE="$ROOT/templates/worktree-rules.md"
START='<!-- orca-worktree-rules:start'
END='<!-- orca-worktree-rules:end -->'

APPLY=0
REPO=""
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    -*) echo "unknown option: $a" >&2; exit 64 ;;
    *) REPO="$a" ;;
  esac
done
[ -n "$REPO" ] || REPO=$(pwd)
REPO=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || {
  echo "not a git repository" >&2; exit 65; }
[ -f "$TEMPLATE" ] || { echo "template not found: $TEMPLATE" >&2; exit 66; }

TARGET="$REPO/.claude/CLAUDE.md"

link_agents() {
  if [ -L "$REPO/AGENTS.md" ] || [ -e "$REPO/AGENTS.md" ]; then
    [ -L "$REPO/AGENTS.md" ] || echo "note: AGENTS.md exists as a regular file; left untouched. Codex children need the same rules there."
  else
    ln -s .claude/CLAUDE.md "$REPO/AGENTS.md"
    echo "linked: AGENTS.md -> .claude/CLAUDE.md"
  fi
}

if [ ! -f "$TARGET" ]; then
  mkdir -p "$REPO/.claude"
  cat "$TEMPLATE" > "$TARGET"
  echo "created: ${TARGET#"$REPO"/}"
  link_agents
  exit 0
fi

if grep -q "$START" "$TARGET" 2>/dev/null; then
  tmp=$(mktemp)
  awk -v tpl="$TEMPLATE" -v s="$START" -v e="$END" '
    index($0, s) == 1 { while ((getline line < tpl) > 0) print line; close(tpl); skip = 1; next }
    skip && index($0, e) == 1 { skip = 0; next }
    !skip { print }
  ' "$TARGET" > "$tmp"
  if cmp -s "$tmp" "$TARGET"; then
    rm -f "$tmp"; echo "up to date: ${TARGET#"$REPO"/}"
  else
    cat "$tmp" > "$TARGET"; rm -f "$tmp"
    echo "updated: ${TARGET#"$REPO"/} (marker block replaced)"
  fi
  link_agents
  exit 0
fi

if [ "$APPLY" = 1 ]; then
  printf '\n' >> "$TARGET"
  cat "$TEMPLATE" >> "$TARGET"
  echo "appended: ${TARGET#"$REPO"/}"
  link_agents
  exit 0
fi

echo "NEEDS CONFIRMATION: ${TARGET#"$REPO"/} exists without an orca-worktree-rules marker."
echo "Review any hand-written worktree rules already in that file, then rerun with --apply."
echo "--- block that would be appended ---"
cat "$TEMPLATE"
exit 2
