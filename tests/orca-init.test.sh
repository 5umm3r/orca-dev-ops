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

# --- repo path with spaces ---
r="$tmp/repo with spaces"; new_repo "$r"
run "$r"
result "space path: exit 0" 0 "$rc"
result "space path: CLAUDE.md matches template" match "$(matches_template "$r/.claude/CLAUDE.md")"
result "space path: AGENTS.md symlinked" .claude/CLAUDE.md "$(readlink "$r/AGENTS.md")"

exit "$fail"
