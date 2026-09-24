#!/bin/sh
# Tests for scripts/orca-init.sh: the orca-worktree-rules marker block installer.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"
script="$root/scripts/orca-init.sh"
template="$root/templates/worktree-rules.md"
START='<!-- orca-worktree-rules:start'
END='<!-- orca-worktree-rules:end -->'

# run <repo> [args...]: runs the script against <repo>, output in $out, exit code in $rc.
run() {
  _r=$1; shift
  out=$(sh "$script" "$@" "$_r" 2>&1); rc=$?
}
count() { printf '%s\n' "$out" | grep -c "$1"; }
matches_template() { cmp -s "$1" "$template" && echo match || echo diff; }

# --- new file: CLAUDE.md created, AGENTS.md symlinked, in sync ---
r="$tmp/new"; new_repo "$r"
run "$r"
result "new: exit 0" 0 "$rc"
result "new: created message" 1 "$(count '^created: \.claude/CLAUDE\.md$')"
result "new: CLAUDE.md matches template" match "$(matches_template "$r/.claude/CLAUDE.md")"
result "new: AGENTS.md symlinked" .claude/CLAUDE.md "$(readlink "$r/AGENTS.md")"
result "new: AGENTS.md content matches template" match "$(matches_template "$r/AGENTS.md")"
result "new: in sync" 1 "$(count '^in sync:')"

# --- re-run unchanged: no rewrite, reports up to date ---
touch -t 202001010000 "$r/.claude/CLAUDE.md"
: > "$tmp/marker-new"
run "$r"
result "unchanged: exit 0" 0 "$rc"
result "unchanged: reports up to date" 1 "$(count '^up to date: \.claude/CLAUDE\.md$')"
result "unchanged: file not rewritten" no "$([ "$r/.claude/CLAUDE.md" -nt "$tmp/marker-new" ] && echo yes || echo no)"

# --- update: marker block replaced, surrounding text preserved ---
r="$tmp/update"; new_repo "$r"
mkdir -p "$r/.claude"
{
  echo "# custom top"
  echo "$START (old) -->"
  echo "old rules line"
  echo "$END"
  echo "# custom bottom"
} > "$r/.claude/CLAUDE.md"
run "$r"
result "update: exit 0" 0 "$rc"
result "update: reports updated" 1 "$(count '^updated: \.claude/CLAUDE\.md')"
result "update: top text preserved" "# custom top" "$(sed -n '1p' "$r/.claude/CLAUDE.md")"
result "update: bottom text preserved" "# custom bottom" "$(tail -1 "$r/.claude/CLAUDE.md")"
sed -n "/${START}/,/${END}/p" "$r/.claude/CLAUDE.md" > "$tmp/blk-got"
sed -n "/${START}/,/${END}/p" "$template" > "$tmp/blk-want"
result "update: block equals template" match "$(cmp -s "$tmp/blk-got" "$tmp/blk-want" && echo match || echo diff)"

# --- CLAUDE.md exists without a marker: needs confirmation, then --apply ---
r="$tmp/needs-confirm"; new_repo "$r"
mkdir -p "$r/.claude"
echo "hand-written rules, no marker" > "$r/.claude/CLAUDE.md"
run "$r"
result "no marker: exit 2" 2 "$rc"
result "no marker: file unchanged" "hand-written rules, no marker" "$(cat "$r/.claude/CLAUDE.md")"
run "$r" --apply
result "no marker --apply: exit 0" 0 "$rc"
result "no marker --apply: block appended" 1 "$(grep -cF "$START" "$r/.claude/CLAUDE.md")"
result "no marker --apply: original text kept" "hand-written rules, no marker" "$(sed -n '1p' "$r/.claude/CLAUDE.md")"

# --- broken markers: reported, non-zero exit, file unchanged ---
r="$tmp/unterminated"; new_repo "$r"
mkdir -p "$r/.claude"
printf '%s (only) -->\nsome rules\n' "$START" > "$r/.claude/CLAUDE.md"
before=$(cat "$r/.claude/CLAUDE.md")
run "$r"
result "unterminated start: exit 67" 67 "$rc"
result "unterminated start: file unchanged" "$before" "$(cat "$r/.claude/CLAUDE.md")"

r="$tmp/stray-end"; new_repo "$r"
mkdir -p "$r/.claude"
printf 'top\n%s\nbottom\n' "$END" > "$r/.claude/CLAUDE.md"
before=$(cat "$r/.claude/CLAUDE.md")
run "$r"
result "stray end: exit 67" 67 "$rc"
result "stray end: file unchanged" "$before" "$(cat "$r/.claude/CLAUDE.md")"

r="$tmp/two-blocks"; new_repo "$r"
mkdir -p "$r/.claude"
{
  echo "$START -->"; echo "a"; echo "$END"
  echo "$START -->"; echo "b"; echo "$END"
} > "$r/.claude/CLAUDE.md"
before=$(cat "$r/.claude/CLAUDE.md")
run "$r"
result "two blocks: exit 67" 67 "$rc"
result "two blocks: file unchanged" "$before" "$(cat "$r/.claude/CLAUDE.md")"

# --- AGENTS.md: correct link kept ---
r="$tmp/agents-correct-link"; new_repo "$r"
mkdir -p "$r/.claude"
cat "$template" > "$r/.claude/CLAUDE.md"
ln -s .claude/CLAUDE.md "$r/AGENTS.md"
run "$r"
result "agents correct link: exit 0" 0 "$rc"
result "agents correct link: still linked" .claude/CLAUDE.md "$(readlink "$r/AGENTS.md")"
result "agents correct link: in sync" 1 "$(count '^in sync:')"

# --- AGENTS.md: symlink elsewhere, never replaced ---
r="$tmp/agents-elsewhere"; new_repo "$r"
mkdir -p "$r/other"
echo "custom" > "$r/other/rules.md"
ln -s other/rules.md "$r/AGENTS.md"
run "$r"
result "agents elsewhere: exit 0" 0 "$rc"
result "agents elsewhere: link untouched" other/rules.md "$(readlink "$r/AGENTS.md")"
result "agents elsewhere: reports target" 1 "$(count 'symlink to other/rules\.md')"
result "agents elsewhere: out of sync" 1 "$(count '^out of sync:')"

# --- AGENTS.md: regular file with marker, updated like CLAUDE.md ---
r="$tmp/agents-regular-marker"; new_repo "$r"
{
  echo "top"
  echo "$START (old) -->"
  echo "old"
  echo "$END"
  echo "bottom"
} > "$r/AGENTS.md"
run "$r"
result "agents regular marker: exit 0" 0 "$rc"
result "agents regular marker: reports updated" 1 "$(count '^updated: AGENTS\.md')"
result "agents regular marker: top preserved" top "$(sed -n '1p' "$r/AGENTS.md")"
result "agents regular marker: bottom preserved" bottom "$(tail -1 "$r/AGENTS.md")"
result "agents regular marker: in sync" 1 "$(count '^in sync:')"

# --- AGENTS.md: regular file, no marker, without --apply ---
r="$tmp/agents-regular-nomarker"; new_repo "$r"
echo "custom codex notes" > "$r/AGENTS.md"
run "$r"
result "agents no marker: exit 0" 0 "$rc"
result "agents no marker: file untouched" "custom codex notes" "$(cat "$r/AGENTS.md")"
result "agents no marker: reports missing rules" 1 "$(count 'Codex children will not see the rules')"
result "agents no marker: out of sync" 1 "$(count '^out of sync:')"

# --- AGENTS.md: regular file, no marker, with --apply ---
r="$tmp/agents-regular-nomarker-apply"; new_repo "$r"
echo "custom codex notes" > "$r/AGENTS.md"
run "$r" --apply
result "agents no marker --apply: exit 0" 0 "$rc"
result "agents no marker --apply: block appended" 1 "$(grep -cF "$START" "$r/AGENTS.md")"
result "agents no marker --apply: original text kept" "custom codex notes" "$(sed -n '1p' "$r/AGENTS.md")"
result "agents no marker --apply: in sync" 1 "$(count '^in sync:')"

# --- regression: an inline mention of the end marker (not at line start)
# must not count as a real end marker. A start marker with no real (line-
# start) end marker is a broken, unterminated block: non-zero exit, message,
# file unchanged. This is the exact bug marker_state/replace_block disagreed
# on before the fix (grep -cF counts inline mentions; the awk that writes the
# file only ever recognized a marker at the start of a line). ---
r="$tmp/inline-end-mention"; new_repo "$r"
mkdir -p "$r/.claude"
{
  echo "$START (generated) -->"
  echo "some rules text"
  printf 'Keep `%s` last.\n' "$END"
  echo "more user text"
} > "$r/.claude/CLAUDE.md"
before=$(cat "$r/.claude/CLAUDE.md")
run "$r"
result "inline end mention: exit 67" 67 "$rc"
result "inline end mention: file unchanged" "$before" "$(cat "$r/.claude/CLAUDE.md")"
result "inline end mention: clear message" 1 "$(count 'BROKEN MARKER')"

# --- regression: an inline mention of the start marker (not at line start),
# with no real block anywhere, must not be treated as a block at all: it is
# plain "no marker" (needs confirmation / create), not "broken". ---
r="$tmp/inline-start-mention"; new_repo "$r"
mkdir -p "$r/.claude"
{
  echo "top"
  printf 'Docs mention `%s` inline, not as a real block.\n' "$START"
  echo "bottom"
} > "$r/.claude/CLAUDE.md"
before=$(cat "$r/.claude/CLAUDE.md")
run "$r"
result "inline start mention: exit 2 (no marker)" 2 "$rc"
result "inline start mention: file unchanged" "$before" "$(cat "$r/.claude/CLAUDE.md")"
run "$r" --apply
result "inline start mention --apply: exit 0" 0 "$rc"
result "inline start mention --apply: original text kept" top "$(sed -n '1p' "$r/.claude/CLAUDE.md")"
result "inline start mention --apply: block appended" 1 "$(awk -v m="$START" 'index($0,m)==1{c++} END{print c+0}' "$r/.claude/CLAUDE.md")"

# --- Codex launch gate: missing .codex, installed with a fresh hooks.json ---
r="$tmp/codex-new"; new_repo "$r"
run "$r"
gate_cmd='sh "$(git rev-parse --show-toplevel)/.codex/hooks/orca-launch-gate.sh"'
same() { cmp -s "$1" "$2" && echo match || echo diff; }
result "codex new: exit 0" 0 "$rc"
result "codex new: gate copied" match "$(same "$root/hooks/orca-launch-gate.sh" "$r/.codex/hooks/orca-launch-gate.sh")"
result "codex new: lib copied" match "$(same "$root/hooks/orca-lib.sh" "$r/.codex/hooks/orca-lib.sh")"
result "codex new: created message" 1 "$(count '^created: \.codex/hooks\.json$')"
result "codex new: one Bash entry" "Bash|$gate_cmd|10" \
  "$(jq -r '.hooks.PreToolUse | length as $n | .[0] | "\(.matcher)|\(.hooks[0].command)|\(.hooks[0].timeout)" + (if $n == 1 then "" else " (\($n) entries)" end)' "$r/.codex/hooks.json")"
result "codex new: trust note" 1 "$(count 'Codex asks the user to trust new or changed hooks')"
# The installed command finds the gate from a subdirectory and denies a launch without a transcript.
mkdir -p "$r/sub/dir"
gate_out=$(cd "$r/sub/dir" && jq -n --arg cwd "$r/sub/dir" '{cwd:$cwd,tool_name:"Bash",tool_input:{command:"orca terminal create --command codex"},transcript_path:null}' \
  | sh -c "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$r/.codex/hooks.json")" | jq -r '.hookSpecificOutput.permissionDecision // empty')
result "codex new: installed gate denies from a subdirectory" deny "$gate_out"

run "$r"
result "codex rerun: exit 0" 0 "$rc"
result "codex rerun: hooks.json up to date" 1 "$(count '^up to date: \.codex/hooks\.json$')"
result "codex rerun: gate up to date" 1 "$(count '^up to date: \.codex/hooks/orca-launch-gate\.sh$')"
result "codex rerun: no trust note" 0 "$(count 'Codex asks the user to trust')"

echo "# stale" >> "$r/.codex/hooks/orca-lib.sh"
run "$r"
result "codex stale copy: refreshed" match "$(same "$root/hooks/orca-lib.sh" "$r/.codex/hooks/orca-lib.sh")"
result "codex stale copy: reported" 1 "$(count '^updated: \.codex/hooks/orca-lib\.sh$')"
result "codex stale copy: trust note" 1 "$(count 'Codex asks the user to trust')"

# --- Codex: existing hooks.json with an outdated gate entry, updated in place ---
r="$tmp/codex-entry"; new_repo "$r"; mkdir -p "$r/.codex"
cat > "$r/.codex/hooks.json" <<'EOF'
{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "echo start"}]}],
  "PreToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "echo other"}]},
    {"matcher": "shell", "hooks": [{"type": "command", "command": "sh .codex/hooks/orca-launch-gate.sh", "timeout": 3}]}]}}
EOF
run "$r"
result "codex entry: exit 0" 0 "$rc"
result "codex entry: reports updated" 1 "$(count '^updated: \.codex/hooks\.json')"
result "codex entry: gate entry updated in place" "Bash|$gate_cmd|10" \
  "$(jq -r '.hooks.PreToolUse[1] | "\(.matcher)|\(.hooks[0].command)|\(.hooks[0].timeout)"' "$r/.codex/hooks.json")"
result "codex entry: other hooks kept" "echo start|Edit|echo other|2" \
  "$(jq -r '"\(.hooks.SessionStart[0].hooks[0].command)|\(.hooks.PreToolUse[0].matcher)|\(.hooks.PreToolUse[0].hooks[0].command)|\(.hooks.PreToolUse | length)"' "$r/.codex/hooks.json")"
run "$r"
result "codex entry rerun: up to date" 1 "$(count '^up to date: \.codex/hooks\.json$')"

# --- Codex: existing hooks.json without the entry: confirmation, then --apply merges ---
r="$tmp/codex-noentry"; new_repo "$r"; mkdir -p "$r/.codex"
printf '%s\n' '{"hooks": {"PreToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "echo other"}]}]}}' > "$r/.codex/hooks.json"
before=$(cat "$r/.codex/hooks.json")
run "$r"
result "codex no entry: exit 3" 3 "$rc"
result "codex no entry: file unchanged" "$before" "$(cat "$r/.codex/hooks.json")"
result "codex no entry: gate not copied" no "$([ -e "$r/.codex/hooks" ] && echo yes || echo no)"
result "codex no entry: shows the entry" 1 "$(count 'orca-launch-gate\.sh')"
run "$r" --apply
result "codex no entry --apply: exit 0" 0 "$rc"
result "codex no entry --apply: reports merged" 1 "$(count '^merged: \.codex/hooks\.json')"
result "codex no entry --apply: both entries" "Edit|echo other;Bash|$gate_cmd" \
  "$(jq -r '[.hooks.PreToolUse[] | "\(.matcher)|\(.hooks[0].command)"] | join(";")' "$r/.codex/hooks.json")"
result "codex no entry --apply: gate copied" match "$(same "$root/hooks/orca-launch-gate.sh" "$r/.codex/hooks/orca-launch-gate.sh")"
run "$r"
result "codex no entry rerun: exit 0" 0 "$rc"
result "codex no entry rerun: up to date" 1 "$(count '^up to date: \.codex/hooks\.json$')"

# --- Codex: malformed hooks.json: reported, nothing under .codex changes ---
for bad in '{"hooks": ' '[]' '{"hooks": {"PreToolUse": {}}}'; do
  r="$tmp/codex-bad"; rm -rf "$r"; new_repo "$r"; mkdir -p "$r/.codex"
  printf '%s\n' "$bad" > "$r/.codex/hooks.json"
  run "$r" --apply
  result "codex malformed ($bad): exit 68" 68 "$rc"
  result "codex malformed ($bad): file unchanged" "$bad" "$(cat "$r/.codex/hooks.json")"
  result "codex malformed ($bad): gate not copied" no "$([ -e "$r/.codex/hooks" ] && echo yes || echo no)"
  result "codex malformed ($bad): message" 1 "$(count '^BROKEN JSON: \.codex/hooks\.json')"
done

# --- repository settings (.orca-dev-ops.json): created with every default when absent,
# never modified when present, validated ---
# config_state <dir>: ORCA_CONFIG_STATE after orca_config_load, in a subshell.
config_state() { ( . "$root/hooks/orca-lib.sh"; orca_config_load "$1"; echo "$ORCA_CONFIG_STATE" ); }
r="$tmp/settings"; new_repo "$r"
run "$r"
result "settings absent: exit 0" 0 "$rc"
result "settings absent: created message" 1 "$(count "^created: $r/\\.orca-dev-ops\\.json$")"
cat > "$tmp/settings-want" <<'JSON'
{
  "launch":  { "mode": "ask" },
  "limits":  { "maxWorktrees": 3, "smallChangeFiles": 2, "smallChangeLines": 20 },
  "monitor": { "wakeOnStatus": false, "timeoutMs": 590000 }
}
JSON
result "settings absent: created with every default" match "$(cmp -s "$r/.orca-dev-ops.json" "$tmp/settings-want" && echo match || echo diff)"
result "settings absent: equals the built-in defaults" true "$(. "$root/hooks/orca-lib.sh"; jq --argjson d "$ORCA_CONFIG_DEFAULTS" '. == $d' "$r/.orca-dev-ops.json")"
result "settings absent: created file is valid" valid "$(config_state "$r")"
cp "$r/.orca-dev-ops.json" "$tmp/settings-before"
run "$r"
result "settings created, rerun: reported valid" 1 "$(count '^settings: .*\.orca-dev-ops\.json is valid$')"
result "settings created, rerun: not created again" 0 "$(count '^created: .*\.orca-dev-ops\.json')"
result "settings created, rerun: file untouched" match "$(cmp -s "$r/.orca-dev-ops.json" "$tmp/settings-before" && echo match || echo diff)"
printf '%s\n' '{"limits":{"maxWorktrees":2}}' > "$r/.orca-dev-ops.json"
cp "$r/.orca-dev-ops.json" "$tmp/settings-before"
run "$r"
result "settings valid: exit 0" 0 "$rc"
result "settings valid: reported" 1 "$(count '^settings: .*\.orca-dev-ops\.json is valid$')"
result "settings valid: file untouched" match "$(cmp -s "$r/.orca-dev-ops.json" "$tmp/settings-before" && echo match || echo diff)"
bad='{"launch":{"mode":"auto"},"extra":1}'
printf '%s\n' "$bad" > "$r/.orca-dev-ops.json"
run "$r"
result "settings invalid: exit code unchanged" 0 "$rc"
result "settings invalid: reported" 1 "$(count '^INVALID SETTINGS: Ignored .*unknown key extra; launch.mode "auto" needs agent, model, and effort')"
result "settings invalid: file unchanged" "$bad" "$(cat "$r/.orca-dev-ops.json")"
result "settings invalid: not created" 0 "$(count '^created: .*\.orca-dev-ops\.json')"
git -C "$r" worktree add -q -b t "$tmp/settings-task" || exit 1
printf '{bad\n' > "$tmp/settings-task/.orca-dev-ops.json"
run "$tmp/settings-task"
result "settings from a worktree: the main checkout's file is checked" 1 "$(count "^INVALID SETTINGS: Ignored $r/\.orca-dev-ops\.json")"
result "settings from a worktree: its own copy is not" 0 "$(count 'not valid JSON')"

r="$tmp/settings-none"; new_repo "$r"
run "$r" --no-settings
result "settings --no-settings: exit 0" 0 "$rc"
result "settings --no-settings: not created" no "$([ -e "$r/.orca-dev-ops.json" ] && echo yes || echo no)"
result "settings --no-settings: nothing reported" 0 "$(count 'settings')"
printf '{bad\n' > "$r/.orca-dev-ops.json"
run "$r" --no-settings
result "settings --no-settings: an existing file is still checked" 1 "$(count '^INVALID SETTINGS: Ignored .*not valid JSON')"

r="$tmp/settings-readonly"; new_repo "$r"
run "$r" --no-settings
chmod a-w "$r"
run "$r"
chmod u+w "$r"
result "settings write failure: exit code unchanged" 0 "$rc"
result "settings write failure: reported" 1 "$(count '^SETTINGS NOT CREATED: could not write .*\.orca-dev-ops\.json')"
result "settings write failure: not created" no "$([ -e "$r/.orca-dev-ops.json" ] && echo yes || echo no)"

r="$tmp/settings-main"; new_repo "$r"
git -C "$r" worktree add -q -b t "$tmp/settings-main-task" || exit 1
run "$tmp/settings-main-task"
result "settings created from a worktree: exit 0" 0 "$rc"
result "settings created from a worktree: in the main checkout" match "$(cmp -s "$r/.orca-dev-ops.json" "$tmp/settings-want" && echo match || echo diff)"
result "settings created from a worktree: not in the worktree" no "$([ -e "$tmp/settings-main-task/.orca-dev-ops.json" ] && echo yes || echo no)"
result "settings created from a worktree: message names the main checkout" 1 "$(count "^created: $r/\\.orca-dev-ops\\.json$")"

# --- repo path with spaces ---
r="$tmp/repo with spaces"; new_repo "$r"
run "$r"
result "space path: exit 0" 0 "$rc"
result "space path: CLAUDE.md matches template" match "$(matches_template "$r/.claude/CLAUDE.md")"
result "space path: AGENTS.md symlinked" .claude/CLAUDE.md "$(readlink "$r/AGENTS.md")"

exit "$fail"
