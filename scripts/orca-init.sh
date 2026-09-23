#!/bin/sh
# Install the generic "Orca worktree rules" block into a repository.
#
#   orca-init.sh [--apply] [repo-path]
#
# Target files: <repo>/.claude/CLAUDE.md (Claude) and <repo>/AGENTS.md (Codex).
#
# Behaviour, per file:
#   file missing              -> create it (no confirmation needed)
#   marker block present      -> replace the block in place (idempotent update)
#   file exists, no marker    -> print the block and exit 2 unless --apply is given
#   marker block broken (an unterminated start, a stray end, or more than one
#     block)                  -> report what is wrong, exit 67, change nothing
#
# AGENTS.md additionally:
#   missing                     -> create the symlink AGENTS.md -> .claude/CLAUDE.md
#   symlink to .claude/CLAUDE.md -> left as is
#   symlink elsewhere           -> never replaced; reports the target and whether
#                                   it already has the marker block
#   regular file, with marker   -> updated the same way as .claude/CLAUDE.md
#   regular file, no marker     -> never replaced; reports that Codex children will
#                                   not see the rules; the block is only added
#                                   with --apply
#   marker block broken         -> reported, left untouched (does not change the
#                                   script's exit code; .claude/CLAUDE.md already
#                                   reports its own broken block with exit 67)
#
# At the end, prints whether Claude and Codex reach the same marker block.
#
# Exit codes: 0 ok; 2 .claude/CLAUDE.md needs confirmation (no marker, no
# --apply); 64 unknown option; 65 not a git repository; 66 template not
# found; 67 broken marker block in .claude/CLAUDE.md.
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

# A marker line is a line that STARTS with the marker text (index($0,m)==1),
# never a mid-line mention. marker_state and replace_block share this exact
# definition via these two helpers so they can never disagree about what
# counts as a marker.

# marker_line_count <file> <marker>: number of lines in <file> starting with <marker>.
marker_line_count() {
  awk -v m="$2" 'index($0, m) == 1 { c++ } END { print c + 0 }' "$1" 2>/dev/null
}

# marker_line_no <file> <marker>: line number of the first line starting with
# <marker>, or empty if there is none.
marker_line_no() {
  awk -v m="$2" 'index($0, m) == 1 { print NR; exit }' "$1" 2>/dev/null
}

# marker_state <file>: none (missing file or no marker line), ok (one
# well-formed block), or broken (unterminated start, stray end, or more than
# one block).
marker_state() {
  _f=$1
  [ -f "$_f" ] || { echo none; return; }
  _s=$(marker_line_count "$_f" "$START")
  _e=$(marker_line_count "$_f" "$END")
  if [ "$_s" -eq 0 ] && [ "$_e" -eq 0 ]; then echo none; return; fi
  if [ "$_s" -eq 1 ] && [ "$_e" -eq 1 ]; then
    _sl=$(marker_line_no "$_f" "$START")
    _el=$(marker_line_no "$_f" "$END")
    if [ "$_sl" -lt "$_el" ]; then echo ok; return; fi
  fi
  echo broken
}

# replace_block <file>: rewrites <file>'s marker block (the lines from the
# first line starting with the start marker up to the first following line
# starting with the end marker) with the template. Returns 0 if it changed
# the file, 1 if it was already up to date, 2 if a block it opened never
# closes (the file is left unchanged either way, independently of what
# marker_state already found, as a second line of defense).
replace_block() {
  _f=$1
  _tmp=$(mktemp)
  if awk -v tpl="$TEMPLATE" -v s="$START" -v e="$END" '
    index($0, s) == 1 { while ((getline line < tpl) > 0) print line; close(tpl); skip = 1; next }
    skip && index($0, e) == 1 { skip = 0; next }
    !skip { print }
    END { if (skip) exit 3 }
  ' "$_f" > "$_tmp" 2>/dev/null; then
    if cmp -s "$_tmp" "$_f"; then
      rm -f "$_tmp"; return 1
    fi
    cat "$_tmp" > "$_f"; rm -f "$_tmp"; return 0
  fi
  rm -f "$_tmp"; return 2
}

CLAUDE_TARGET="$REPO/.claude/CLAUDE.md"
CLAUDE_REL=${CLAUDE_TARGET#"$REPO"/}
claude_state=$(marker_state "$CLAUDE_TARGET")
case "$claude_state" in
  none)
    if [ ! -f "$CLAUDE_TARGET" ]; then
      mkdir -p "$REPO/.claude"
      cat "$TEMPLATE" > "$CLAUDE_TARGET"
      echo "created: $CLAUDE_REL"
    elif [ "$APPLY" = 1 ]; then
      printf '\n' >> "$CLAUDE_TARGET"
      cat "$TEMPLATE" >> "$CLAUDE_TARGET"
      echo "appended: $CLAUDE_REL"
    else
      echo "NEEDS CONFIRMATION: $CLAUDE_REL exists without an orca-worktree-rules marker."
      echo "Review any hand-written worktree rules already in that file, then rerun with --apply."
      echo "--- block that would be appended ---"
      cat "$TEMPLATE"
      exit 2
    fi
    ;;
  ok)
    _rc=0
    replace_block "$CLAUDE_TARGET" || _rc=$?
    case "$_rc" in
      0) echo "updated: $CLAUDE_REL (marker block replaced)" ;;
      1) echo "up to date: $CLAUDE_REL" ;;
      *)
        echo "BROKEN MARKER: $CLAUDE_REL has a start marker whose block never closes; left unchanged." >&2
        exit 67
        ;;
    esac
    ;;
  broken)
    echo "BROKEN MARKER: $CLAUDE_REL has an unterminated start marker, a stray end marker, or more than one orca-worktree-rules block; left unchanged." >&2
    exit 67
    ;;
esac

AGENTS_PATH="$REPO/AGENTS.md"
AGENTS_SYNCED=0

if [ -L "$AGENTS_PATH" ]; then
  agents_link=$(readlink "$AGENTS_PATH")
  if [ "$agents_link" = ".claude/CLAUDE.md" ]; then
    AGENTS_SYNCED=1
  else
    agents_state=$(marker_state "$AGENTS_PATH")
    if [ "$agents_state" = ok ]; then
      echo "note: AGENTS.md is a symlink to $agents_link, not .claude/CLAUDE.md; left untouched. That target already has the marker block."
    else
      echo "note: AGENTS.md is a symlink to $agents_link, not .claude/CLAUDE.md; left untouched. That target has no marker block, so Codex children will not see the rules."
    fi
  fi
elif [ -e "$AGENTS_PATH" ]; then
  agents_state=$(marker_state "$AGENTS_PATH")
  case "$agents_state" in
    ok)
      _rc=0
      replace_block "$AGENTS_PATH" || _rc=$?
      case "$_rc" in
        0) echo "updated: AGENTS.md (marker block replaced)"; AGENTS_SYNCED=1 ;;
        1) echo "up to date: AGENTS.md"; AGENTS_SYNCED=1 ;;
        *) echo "note: AGENTS.md has a start marker whose block never closes; left untouched. Codex children will not see the rules." >&2 ;;
      esac
      ;;
    none)
      if [ "$APPLY" = 1 ]; then
        printf '\n' >> "$AGENTS_PATH"
        cat "$TEMPLATE" >> "$AGENTS_PATH"
        echo "appended: AGENTS.md"
        AGENTS_SYNCED=1
      else
        echo "note: AGENTS.md exists as a regular file without an orca-worktree-rules marker; left untouched. Codex children will not see the rules until it has the block; rerun with --apply to add it."
      fi
      ;;
    broken)
      echo "note: AGENTS.md has an unterminated start marker, a stray end marker, or more than one orca-worktree-rules block; left untouched. Codex children will not see the rules." >&2
      ;;
  esac
else
  ln -s .claude/CLAUDE.md "$AGENTS_PATH"
  echo "linked: AGENTS.md -> .claude/CLAUDE.md"
  AGENTS_SYNCED=1
fi

if [ "$AGENTS_SYNCED" = 1 ]; then
  echo "in sync: Claude (.claude/CLAUDE.md) and Codex (AGENTS.md) reach the same marker block."
else
  echo "out of sync: Codex (AGENTS.md) does not reach the marker block that .claude/CLAUDE.md has."
fi
