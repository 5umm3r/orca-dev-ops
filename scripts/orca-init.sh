#!/bin/sh
# Install the generic "Orca worktree rules" block into a repository.
#
#   orca-init.sh [--apply] [--no-settings | --settings=add | --settings=reset] [repo-path]
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
# Then prints whether Claude and Codex reach the same marker block.
#
# Codex launch gate (Codex plugin hooks only apply to manually installed desktop
# plugins, so the gate is installed into the repository instead):
#   .codex/hooks/orca-launch-gate.sh and .codex/hooks/orca-lib.sh
#                               -> copies of the plugin's hooks, always refreshed
#                                   (plugin-owned; do not edit them)
#   .codex/hooks.json missing   -> created with a PreToolUse "Bash" entry that runs
#                                   the copied gate from the checkout's top level
#   entry present               -> updated in place, other hooks kept
#   file exists, no entry       -> print the entry and exit 3 unless --apply is
#                                   given; with --apply it is merged in, other
#                                   hooks kept
#   malformed JSON              -> reported, exit 68, file unchanged
# At the end, reminds that Codex asks the user to trust new or changed hooks
# once at its next start.
#
# Repository settings: .orca-dev-ops.json (in the main checkout, handled first):
#   missing                     -> created with every key that has a built-in
#                                   default (the values at creation time; later
#                                   plugin default changes do not update it),
#                                   without needing --apply; --no-settings skips
#                                   this
#   present, valid              -> reported as valid, then, without --settings=:
#                                   "missing key" lines for every default the file
#                                   lacks and every applicable suggested opt-in key
#                                   (launch.escalate with mode semi-auto or auto
#                                   and agent claude), "available key" lines for the other
#                                   opt-in keys it lacks, "reset would change" lines
#                                   for every value a reset changes or removes, and
#                                   a rerun hint when a key is missing; unchanged
#     --settings=add            -> the missing keys are added, existing values kept
#                                   ("updated" or "up to date")
#   present, invalid            -> reported on stderr (the hooks ignore it and use
#                                   the built-in defaults); unchanged, also with
#                                   --settings=add
#   present, --settings=reset   -> copied to .orca-dev-ops.json.bak (never
#                                   overwritten: an existing backup means no reset),
#                                   then rewritten with the defaults as at creation
#   main checkout unknown       -> nothing is done
# --settings=add and --settings=reset write through a temp file and only a result
# that passes the hooks' own check. Neither an invalid file nor a failed write
# changes the exit code.
#
# Exit codes: 0 ok; 2 .claude/CLAUDE.md needs confirmation (no marker, no
# --apply); 3 .codex/hooks.json needs confirmation (no gate entry, no
# --apply); 64 unknown or conflicting option (usage: [--apply] [--no-settings |
# --settings=add | --settings=reset] [repo-path]);
# 65 not a git repository; 66 template or plugin hook not found; 67 broken
# marker block in .claude/CLAUDE.md; 68 malformed .codex/hooks.json.
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMPLATE="$ROOT/templates/worktree-rules.md"
START='<!-- orca-worktree-rules:start'
END='<!-- orca-worktree-rules:end -->'

APPLY=0
SETTINGS=1
SETTINGS_MODE=
REPO=""
usage() { echo "usage: orca-init.sh [--apply] [--no-settings | --settings=add | --settings=reset] [repo-path]" >&2; exit 64; }
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --no-settings) SETTINGS=0 ;;
    --settings=add | --settings=reset)
      if [ -n "$SETTINGS_MODE" ] && [ "$SETTINGS_MODE" != "${a#--settings=}" ]; then
        echo "conflicting options: --settings=$SETTINGS_MODE and $a" >&2; usage
      fi
      SETTINGS_MODE=${a#--settings=} ;;
    -*) echo "unknown option: $a" >&2; usage ;;
    *) REPO="$a" ;;
  esac
done
if [ "$SETTINGS" = 0 ] && [ -n "$SETTINGS_MODE" ]; then
  echo "conflicting options: --no-settings and --settings=$SETTINGS_MODE" >&2; usage
fi
[ -n "$REPO" ] || REPO=$(pwd)
REPO=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || {
  echo "not a git repository" >&2; exit 65; }
[ -f "$TEMPLATE" ] || { echo "template not found: $TEMPLATE" >&2; exit 66; }
for _h in orca-launch-gate.sh orca-lib.sh; do
  [ -f "$ROOT/hooks/$_h" ] || { echo "plugin hook not found: $ROOT/hooks/$_h" >&2; exit 66; }
done

# Repository settings (.orca-dev-ops.json in the main checkout): created with every default
# when missing (unless --no-settings); when present, validated and reported, and changed only
# by --settings=add or --settings=reset. A problem does not change the exit code.
. "$ROOT/hooks/orca-lib.sh"

# settings_format: the settings JSON on stdin in the layout orca-init writes, one line per
# section. Creation, --settings=add, and --settings=reset all write through it.
settings_format() {
  jq -r '
    def flat: if type == "object" and length > 0
      then "{ " + (to_entries | map("\(.key | tojson): \(.value | flat)") | join(", ")) + " }"
      else tojson end;
    (keys_unsorted | map(length) | max) as $w
    | "{", (to_entries | map("  \(.key | tojson):" + " " * ($w - (.key | length) + 1) + (.value | flat))
      | join(",\n")), "}"'
}

# settings_write <json>: writes <json> to the settings file through a temp file, but only when
# the formatted result passes the loader's check; otherwise sets SETTINGS_WHY and returns 1.
settings_write() {
  SETTINGS_WHY= _t=$(mktemp) || { SETTINGS_WHY="could not create a temp file"; return 1; }
  if ! printf '%s' "$1" | settings_format > "$_t" 2>/dev/null; then
    SETTINGS_WHY="could not format the result"
  elif _e=$(jq -rs "$ORCA_CONFIG_CHECK" "$_t" 2>/dev/null) || _e='it is not valid JSON'; [ -n "$_e" ]; then
    SETTINGS_WHY="the result would be invalid ($_e)"
  elif ! cat "$_t" > "$ORCA_CONFIG_PATH" 2>/dev/null; then
    SETTINGS_WHY="could not write $ORCA_CONFIG_PATH"
  fi
  rm -f "$_t"
  [ -z "$SETTINGS_WHY" ]
}

# What a valid file lacks or a reset would change, as jq definitions over the file:
#   missing    {path, kind, value}: every default the file lacks (kind "default", at leaf
#              level) and every applicable suggested opt-in key it lacks (kind "suggested")
#   available  {path}: the opt-in keys the file lacks that have no applicable suggestion
#   changes    {path, old, new}: every value in the file that a reset changes (new null: removed)
SETTINGS_JQ='def opt_in: '"$ORCA_CONFIG_OPT_IN"';
  def dotted: map(tostring) | join(".");
  def absent($p): getpath($p) == null;
  def missing: . as $f
    | ($d | paths(type != "object") as $p | select($f | absent($p)) | {path: $p, kind: "default", value: getpath($p)}),
      ($d * $f | opt_in | select(has("value") and (.path as $p | $f | absent($p))) | .kind = "suggested");
  def available: . as $f | $d * $f | opt_in | select((has("value") | not) and (.path as $p | $f | absent($p)));
  def changes: paths(type != "object") as $p | {path: $p, old: getpath($p), new: ($d | getpath($p))}
    | select(.old != .new);
  .[0] | '
settings_jq() { jq -rs --argjson d "$ORCA_CONFIG_DEFAULTS" "$SETTINGS_JQ$1" "$ORCA_CONFIG_PATH"; }

# settings_report: the lines a run without --settings= prints for a valid file.
settings_report() {
  settings_jq '(missing | "settings: missing key \(.path | dotted) (\(.kind) \(.value | tojson))"),
    (available | "settings: available key \(.path | dotted) (no default; set by hand, see docs/config.md)"),
    (changes | "settings: reset would change \(.path | dotted) (\(.old | tojson) -> \(if .new == null then "removed" else .new | tojson end))"),
    (if first(missing) then "settings: rerun with --settings=add to add the missing keys, or --settings=reset to restore the defaults" else empty end)' || :
}

# settings_add: --settings=add on a valid file; adds every missing key, keeps every value.
settings_add() {
  _added=$(settings_jq '[missing | .path | dotted] | join(", ")') || _added=
  _json=$(settings_jq 'reduce missing as $m ($d * .; setpath($m.path; $m.value))') || _json=
  if [ -z "$_json" ]; then
    echo "SETTINGS NOT UPDATED: could not read $ORCA_CONFIG_PATH; it was left unchanged." >&2
  elif [ -z "$_added" ]; then
    echo "up to date: $ORCA_CONFIG_PATH"
  elif settings_write "$_json"; then
    echo "updated: $ORCA_CONFIG_PATH (added: $_added)"
  else
    echo "SETTINGS NOT UPDATED: $SETTINGS_WHY; $ORCA_CONFIG_PATH was left unchanged." >&2
  fi
}

# settings_reset: --settings=reset; backs the file up to <file>.bak (never overwritten), then
# writes the defaults as at creation. Returns 1 when the file was not reset.
settings_reset() {
  _bak=$ORCA_CONFIG_PATH.bak
  if [ -e "$_bak" ] || [ -L "$_bak" ]; then
    echo "SETTINGS NOT RESET: $_bak already exists; move it away first" >&2; return 1
  fi
  if ! ( set -C; : > "$_bak" ) 2>/dev/null; then
    echo "SETTINGS NOT RESET: could not create $_bak; $ORCA_CONFIG_PATH was left unchanged." >&2; return 1
  fi
  if ! cat "$ORCA_CONFIG_PATH" > "$_bak" 2>/dev/null; then
    rm -f "$_bak"
    echo "SETTINGS NOT RESET: could not copy $ORCA_CONFIG_PATH to $_bak; it was left unchanged." >&2; return 1
  fi
  if ! settings_write "$ORCA_CONFIG_DEFAULTS"; then
    echo "SETTINGS NOT RESET: $SETTINGS_WHY; $ORCA_CONFIG_PATH was left unchanged (backup: $_bak)." >&2; return 1
  fi
  echo "reset: $ORCA_CONFIG_PATH (backup: $_bak)"
}

orca_config_load "$REPO" || :
case "$ORCA_CONFIG_STATE" in
  missing)
    if [ "$SETTINGS" = 1 ] && [ -n "$ORCA_CONFIG_PATH" ]; then
      _settings=$(printf '%s' "$ORCA_CONFIG_DEFAULTS" | settings_format) || _settings=
      # noclobber: a file that appears meanwhile is never overwritten.
      if [ -n "$_settings" ] && ( set -C; printf '%s\n' "$_settings" > "$ORCA_CONFIG_PATH" ) 2>/dev/null; then
        echo "created: $ORCA_CONFIG_PATH"
      else
        echo "SETTINGS NOT CREATED: could not write $ORCA_CONFIG_PATH; the built-in defaults apply." >&2
      fi
    fi
    ;;
  *)
    if [ "$SETTINGS_MODE" = reset ] && settings_reset; then
      :
    elif [ "$ORCA_CONFIG_STATE" = invalid ]; then
      echo "INVALID SETTINGS: $ORCA_CONFIG_ERROR Fix it by hand (see docs/config.md in the plugin); it was left unchanged." >&2
      if [ "$SETTINGS_MODE" = add ]; then
        echo "SETTINGS NOT UPDATED: --settings=add only adds to a valid file; only --settings=reset can replace an invalid one (it keeps a .bak backup)." >&2
      fi
    elif [ "$SETTINGS_MODE" = add ]; then
      settings_add
    else
      echo "settings: $ORCA_CONFIG_PATH is valid"
      settings_report
    fi
    ;;
esac

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

# Codex launch gate. Codex runs hook commands in the session's cwd, which can be a
# subdirectory, so the command resolves the gate from the checkout's top level.
HOOKS_JSON="$REPO/.codex/hooks.json"
GATE_CMD='sh "$(git rev-parse --show-toplevel)/.codex/hooks/orca-launch-gate.sh"'
# ours: a hook that runs our gate, whatever its exact command spelling.
HOOKS_JQ='def ours: (.command? // "") | tostring | contains(".codex/hooks/orca-launch-gate.sh");
  def entry: {matcher: "Bash", hooks: [{type: "command", command: $cmd, timeout: 10}]};'
hooks_jq() { _p=$1; shift; jq --indent 2 --arg cmd "$GATE_CMD" "$HOOKS_JQ$_p" "$@"; }

# State of .codex/hooks.json first, so a malformed file or a missing confirmation
# changes nothing under .codex.
if [ ! -e "$HOOKS_JSON" ]; then
  hooks_state=missing
elif ! jq -e 'type == "object" and ((.hooks // {}) | type) == "object"
    and ((.hooks.PreToolUse // []) | type) == "array"
    and all((.hooks.PreToolUse // [])[]; type == "object" and ((.hooks // []) | type) == "array")' "$HOOKS_JSON" >/dev/null 2>&1; then
  echo "BROKEN JSON: .codex/hooks.json is not valid JSON or not a hooks file ({\"hooks\": {\"PreToolUse\": [...]}}); left unchanged. Fix it by hand and run again." >&2
  exit 68
elif hooks_jq 'any(.hooks.PreToolUse[]?.hooks[]?; ours)' -e "$HOOKS_JSON" >/dev/null; then
  hooks_state=present
elif [ "$APPLY" = 1 ]; then
  hooks_state=merge
else
  echo "NEEDS CONFIRMATION: .codex/hooks.json exists without the orca launch gate entry."
  echo "Review the hooks already in that file, then rerun with --apply to merge the entry (other hooks are kept)."
  echo "--- PreToolUse entry that would be added ---"
  hooks_jq 'entry' -n
  exit 3
fi

CODEX_CHANGED=0
mkdir -p "$REPO/.codex/hooks"
for _h in orca-launch-gate.sh orca-lib.sh; do
  _dst="$REPO/.codex/hooks/$_h"
  if [ -f "$_dst" ] && cmp -s "$ROOT/hooks/$_h" "$_dst"; then
    echo "up to date: .codex/hooks/$_h"
  else
    [ -f "$_dst" ] && _verb=updated || _verb=installed
    cat "$ROOT/hooks/$_h" > "$_dst"
    echo "$_verb: .codex/hooks/$_h"
    CODEX_CHANGED=1
  fi
done

_tmp=$(mktemp)
case "$hooks_state" in
  missing)
    hooks_jq '{hooks: {PreToolUse: [entry]}}' -n > "$HOOKS_JSON"
    echo "created: .codex/hooks.json"
    CODEX_CHANGED=1
    ;;
  present)
    # Update our entry in place: its group matches Bash and its hook runs the current command.
    hooks_jq '.hooks.PreToolUse |= map(if any(.hooks[]?; ours)
        then .matcher = "Bash" | .hooks |= map(if ours then entry.hooks[0] else . end) else . end)' \
      "$HOOKS_JSON" > "$_tmp"
    if jq -e --slurpfile a "$_tmp" '. == $a[0]' "$HOOKS_JSON" >/dev/null; then
      echo "up to date: .codex/hooks.json"
    else
      cat "$_tmp" > "$HOOKS_JSON"
      echo "updated: .codex/hooks.json (launch gate entry)"
      CODEX_CHANGED=1
    fi
    ;;
  merge)
    hooks_jq '.hooks.PreToolUse = ((.hooks.PreToolUse // []) + [entry])' "$HOOKS_JSON" > "$_tmp"
    cat "$_tmp" > "$HOOKS_JSON"
    echo "merged: .codex/hooks.json (launch gate entry added; other hooks kept)"
    CODEX_CHANGED=1
    ;;
esac
rm -f "$_tmp"
if [ "$CODEX_CHANGED" = 1 ]; then
  echo "note: Codex asks the user to trust new or changed hooks once at its next start; the launch gate runs only after the project's .codex hooks are trusted."
fi
