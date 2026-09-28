#!/bin/sh
# Tests for scripts/orca-usage.sh with synthetic Claude and Codex transcripts (tests/fixtures/usage)
# copied under $tmp, reached through CLAUDE_CONFIG_DIR and CODEX_HOME.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"
script="$root/scripts/orca-usage.sh"
fx="$root/tests/fixtures/usage"
export CLAUDE_CONFIG_DIR="$tmp/claude" CODEX_HOME="$tmp/codex"

# A worktree path with a space and dots; Claude's project directory replaces both with "-".
wt="$tmp/work tree/cc-x.y"
mkdir -p "$wt" "$tmp/claude-only" "$tmp/empty"
proj="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$tmp" | sed 's/[^A-Za-z0-9]/-/g')-work-tree-cc-x-y"
mkdir -p "$proj" && cp -R "$fx/claude/." "$proj/" || exit 1
only="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$tmp" | sed 's/[^A-Za-z0-9]/-/g')-claude-only"
mkdir -p "$only" && cp "$fx/claude/sess-b.jsonl" "$only/" || exit 1
(cd "$fx/codex" && find . -type f) | while IFS= read -r f; do
  mkdir -p "$CODEX_HOME/sessions/$(dirname -- "$f")" \
    && sed "s|__WT__|$wt|g" "$fx/codex/$f" > "$CODEX_HOME/sessions/$f" || exit 1
done || exit 1

# run <arg>...: stdout, then "rc=<exit code>".
run() {
  out=$(sh "$script" "$@" 2>"$tmp/err")
  printf '%s\nrc=%s' "$out" "$?"
}
# field <jq filter> <arg>...: the filter applied to the --json output, compact.
field() {
  f=$1; shift
  sh "$script" --json "$@" 2>/dev/null | jq -c "$f"
}

result "resolved worktree path" "\"$wt\"" "$(field .worktree "$wt")"
result "Claude main deduplicated by message.id" \
  '{"input":16,"output":157,"cache_read":1000530,"cache_write":204}' "$(field .claude.main "$wt")"
result "Claude sessions" 2 "$(field .claude.sessions "$wt")"
result "Claude subagents summed separately" \
  '{"files":2,"input":5,"output":50,"cache_read":500,"cache_write":50}' "$(field .claude.subagents "$wt")"
result "Claude total includes subagents" \
  '{"input":21,"output":207,"cache_read":1001030,"cache_write":254}' "$(field .claude.total "$wt")"
result "Codex matches session_meta.cwd, last token_count, input without cached" \
  '{"sessions":2,"input":1800,"output":320,"cache_read":3600,"cache_write":5,"reasoning":70}' "$(field .codex "$wt")"
result "--json since is null by default" null "$(field .since "$wt")"

result "human output" "claude: in 16 / out 157 / cache read 1,000,530 / cache write 204 (2 sessions; subagents: out 50 in 2 files)
codex: in 1,800 / out 320 (reasoning 70) / cache read 3,600 / cache write 5 (2 sessions)
rc=0" "$(run "$wt")"
result "human output, one agent, no subagents" \
  "claude: in 1 / out 7 / cache read 30 / cache write 4 (1 session)
rc=0" "$(run "$tmp/claude-only")"
result "relative path with trailing slash" "\"$wt\"" "$(cd "$tmp" && field .worktree "work tree/cc-x.y/")"
result "relative path counts the same" 157 "$(cd "$tmp/work tree" && field .claude.main.output "./cc-x.y")"

result "--since Claude main" '{"input":6,"output":57,"cache_read":530,"cache_write":4}' \
  "$(field .claude.main --since 2026-09-28T02:00:00Z "$wt")"
result "--since Claude subagents" '{"files":1,"input":3,"output":30,"cache_read":300,"cache_write":30}' \
  "$(field .claude.subagents --since 2026-09-28T02:00:00Z "$wt")"
result "--since Claude sessions with counted lines" 1 "$(field .claude.sessions --since 2026-09-28T04:00:00Z "$wt")"
result "--since Codex subtracts the last token_count before it" \
  '{"sessions":2,"input":1600,"output":270,"cache_read":2800,"cache_write":5,"reasoning":60}' \
  "$(field .codex --since 2026-09-28T02:00:00Z "$wt")"
result "--since Codex after a file's last token_count" \
  '{"sessions":1,"input":300,"output":20,"cache_read":100,"cache_write":0,"reasoning":0}' \
  "$(field .codex --since 2026-09-28T03:30:00Z "$wt")"
result "--since echoed in --json" '"2026-09-28T02:00:00Z"' "$(field .since --since 2026-09-28T02:00:00Z "$wt")"
result "--since after everything: found, zero" '{"input":0,"output":0,"cache_read":0,"cache_write":0}' \
  "$(field .claude.total --since 2027-01-01T00:00:00Z "$wt")"

result "no transcript: exit 3, stdout empty" "
rc=3" "$(run "$tmp/empty")"
result "no transcript: note on stderr" 1 "$(grep -c 'no Claude or Codex transcript' "$tmp/err")"
result "no transcript: --json prints nulls" \
  "{\"worktree\":\"$tmp/empty\",\"since\":null,\"claude\":null,\"codex\":null}
rc=3" "$(run --json "$tmp/empty")"
result "missing directory: exit 3" "
rc=3" "$(run "$tmp/does-not-exist")"
result "missing path" "
rc=64" "$(run)"
result "missing path after --json" "
rc=64" "$(run --json)"
result "unknown option" "
rc=64" "$(run --bogus "$wt")"
result "two paths" "
rc=64" "$(run "$wt" "$tmp/empty")"
result "--since without a value" "
rc=64" "$(run --since)"
result "--since not ISO8601" "
rc=64" "$(run --since yesterday "$wt")"

exit "$fail"
