#!/bin/sh
# Usage: orca-usage.sh [--json] [--since <ISO8601>] <worktree-path>
# Sums the token usage recorded in the local transcripts of the agent that worked in
# <worktree-path> (resolved to an absolute, symlink-free path when it exists; otherwise made
# absolute as written). The numbers come from transcripts, not from a billing record.
#   - Claude: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/<dir>, where <dir> is the path with
#     every character other than [A-Za-z0-9] replaced by "-". Main sessions are <dir>/*.jsonl,
#     subagents <dir>/<session-id>/subagents/agent-*.jsonl. Lines with .type == "assistant" are
#     deduplicated by .message.id (Claude writes one line per content block, each with the same
#     usage; the last line of a message wins) and their .message.usage is summed. Main and
#     subagents are reported separately and as a total.
#   - Codex: ${CODEX_HOME:-$HOME/.codex}/sessions/**/rollout-*.jsonl whose session_meta line has
#     .payload.cwd equal to the path. Per file, the last token_count event's
#     .payload.info.total_token_usage is taken and the files are summed. Codex input_tokens
#     includes cached_input_tokens, so input is reported as input_tokens - cached_input_tokens
#     and cache read as cached_input_tokens.
# Both agents are reported when both have transcripts for the path.
# --since <ISO8601> counts only lines whose top-level timestamp is >= the value, compared as
# strings: give UTC with a trailing Z (e.g. 2026-09-28T06:00:00Z); within the same second a
# fractional timestamp sorts before the whole-second one. For Codex, a file contributes its last
# token_count minus its last token_count before --since. Unparsable lines are skipped.
# Output: one line per agent with thousands separators, or with --json one object
#   {"worktree", "since", "claude": {"sessions", "main", "subagents": {"files", ...}, "total"},
#    "codex": {"sessions", ...}}
# whose usage objects have input, output, cache_read, cache_write (Codex also reasoning); an
# agent without transcripts is null. "sessions" and "files" count files with a counted line.
# Exit codes: 0 usage found; 3 no transcript for the path (a note on stderr; stdout is empty,
# or the object with nulls under --json); 64 usage error; 1 other error (e.g. jq missing).
# Known limitation: Claude truncates and hashes very long project directory names; such paths
# are not found (exit 3). Requires jq. Reads the transcripts only; never writes to them.
usage() { printf 'orca-usage: %s\n' "$*" >&2; exit 64; }
die() { printf 'orca-usage: %s\n' "$*" >&2; exit 1; }

json= since= path= have_path=
while [ $# -gt 0 ]; do
  case "$1" in
  --json) json=1 ;;
  --since)
    [ $# -ge 2 ] || usage "missing value for --since"
    since=$2
    case "$since" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*) ;;
    *) usage "--since takes an ISO8601 timestamp such as 2026-09-28T06:00:00Z" ;;
    esac
    shift ;;
  --) shift; [ $# -eq 1 ] || usage "expected one worktree path"; path=$1; have_path=1; shift; break ;;
  -*) usage "unknown option: $1" ;;
  *) [ -z "$have_path" ] || usage "expected one worktree path"; path=$1; have_path=1 ;;
  esac
  shift
done
[ -n "$path" ] || usage "a worktree path is required"
command -v jq >/dev/null 2>&1 || die 'jq is not on PATH'

if [ -d "$path" ]; then
  path=$(CDPATH= cd -P -- "$path" && pwd -P) || die "cannot resolve $path"
else
  case "$path" in /*) ;; *) path="$PWD/$path" ;; esac
fi
while :; do
  case "$path" in /) break ;; */) path=${path%/} ;; *) break ;; esac
done

# sum_claude <file>...: {files, input, output, cache_read, cache_write} over the assistant lines
# of the files, deduplicated by message.id.
sum_claude() {
  if [ $# -eq 0 ]; then
    echo '{"files":0,"input":0,"output":0,"cache_read":0,"cache_write":0}'
    return
  fi
  jq -ncR --arg since "$since" '
    reduce (inputs | fromjson? // empty
      | select(type == "object" and .type == "assistant" and (.message | type) == "object"
          and (.message.usage | type) == "object" and ((.timestamp // "") | tostring) >= $since)
      | [input_filename, .message.id, .message.usage]) as $r
      ({n: 0, m: {}, f: {}};
       .n += 1 | .m[($r[1] | strings) // "#\(.n)"] = $r[2] | .f[$r[0]] = true)
    | [.m[]] as $u
    | {files: (.f | length),
       input: ([$u[].input_tokens // 0] | add // 0),
       output: ([$u[].output_tokens // 0] | add // 0),
       cache_read: ([$u[].cache_read_input_tokens // 0] | add // 0),
       cache_write: ([$u[].cache_creation_input_tokens // 0] | add // 0)}' "$@"
}

# codex_file <file>: {counted, input, cached, output, reasoning, cache_write} when the file's
# session_meta cwd is the path; nothing otherwise.
codex_file() {
  jq -ncR --arg cwd "$path" --arg since "$since" '
    def usage: .payload.info.total_token_usage;
    def get($k): if . == null then 0 else (usage[$k] // 0) end;
    reduce (inputs | fromjson? // empty | select(type == "object" and (.payload | type) == "object")) as $l
      ({meta: null, last: null, before: null};
       if $l.type == "session_meta" and .meta == null then .meta = ($l.payload.cwd // "")
       elif $l.payload.type == "token_count" and ($l.payload.info | type) == "object"
         and ($l | usage | type) == "object" then
         .last = $l
         | if $since != "" and (($l.timestamp // "") | tostring) < $since then .before = $l else . end
       else . end)
    | select(.meta == $cwd)
    | .last as $a | .before as $b
    | {counted: ($a != null and ($since == "" or (($a.timestamp // "") | tostring) >= $since)),
       input: (($a | get("input_tokens")) - ($b | get("input_tokens"))),
       cached: (($a | get("cached_input_tokens")) - ($b | get("cached_input_tokens"))),
       output: (($a | get("output_tokens")) - ($b | get("output_tokens"))),
       reasoning: (($a | get("reasoning_output_tokens")) - ($b | get("reasoning_output_tokens"))),
       cache_write: (($a | get("cache_write_input_tokens")) - ($b | get("cache_write_input_tokens")))}' "$1"
}

claude=null
cdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$path" | sed 's/[^A-Za-z0-9]/-/g')"
if [ -d "$cdir" ]; then
  set --
  for f in "$cdir"/*.jsonl; do [ -f "$f" ] && set -- "$@" "$f"; done
  nmain=$#
  main=$(sum_claude "$@") || die "cannot read Claude transcripts in $cdir"
  set --
  for f in "$cdir"/*/subagents/agent-*.jsonl; do [ -f "$f" ] && set -- "$@" "$f"; done
  if [ "$nmain" -gt 0 ] || [ $# -gt 0 ]; then
    sub=$(sum_claude "$@") || die "cannot read Claude subagent transcripts in $cdir"
    claude=$(jq -nc --argjson m "$main" --argjson s "$sub" '
      def pick: {input, output, cache_read, cache_write};
      {sessions: $m.files, main: ($m | pick), subagents: $s,
       total: ($m | pick | with_entries(.value += $s[.key]))}') || die 'cannot sum Claude usage'
  fi
fi

codex=null
xroot="${CODEX_HOME:-$HOME/.codex}/sessions"
if [ -d "$xroot" ]; then
  # Cheap prefilter on the JSON-encoded path; codex_file checks session_meta.cwd exactly.
  needle=$(jq -nr --arg p "$path" '$p | tojson') || die 'cannot encode the path'
  files=$(find "$xroot" -type f -name 'rollout-*.jsonl' -exec grep -lF -- "$needle" {} +)
  if [ -n "$files" ]; then
    per=$(printf '%s\n' "$files" | while IFS= read -r f; do
      codex_file "$f" || exit 1
    done) || die "cannot read Codex transcripts in $xroot"
    if [ -n "$per" ]; then
      codex=$(printf '%s\n' "$per" | jq -sc '
        def total($k): [.[][$k]] | add // 0;
        {sessions: (map(select(.counted)) | length),
         input: (total("input") - total("cached")), output: total("output"),
         cache_read: total("cached"), cache_write: total("cache_write"),
         reasoning: total("reasoning")}') || die 'cannot sum Codex usage'
    fi
  fi
fi

result=$(jq -nc --arg w "$path" --arg s "$since" --argjson c "$claude" --argjson x "$codex" \
  '{worktree: $w, since: (if $s == "" then null else $s end), claude: $c, codex: $x}') \
  || die 'cannot build the result'
if [ "$claude" = null ] && [ "$codex" = null ]; then
  printf 'orca-usage: no Claude or Codex transcript for %s\n' "$path" >&2
  [ -n "$json" ] && printf '%s\n' "$result"
  exit 3
fi
if [ -n "$json" ]; then
  printf '%s\n' "$result"
  exit 0
fi
printf '%s\n' "$result" | jq -r '
  def c: tostring | if length <= 3 then . else (.[0:length - 3] | c) + "," + .[length - 3:] end;
  def plural($w): "\(. | c) \($w)\(if . == 1 then "" else "s" end)";
  (.claude | select(. != null)
    | "claude: in \(.main.input | c) / out \(.main.output | c) / cache read \(.main.cache_read | c) / cache write \(.main.cache_write | c) (\(.sessions | plural("session"))"
      + (if .subagents.files > 0 then "; subagents: out \(.subagents.output | c) in \(.subagents.files | plural("file"))" else "" end)
      + ")"),
  (.codex | select(. != null)
    | "codex: in \(.input | c) / out \(.output | c) (reasoning \(.reasoning | c)) / cache read \(.cache_read | c) / cache write \(.cache_write | c) (\(.sessions | plural("session")))")'
