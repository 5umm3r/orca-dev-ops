#!/bin/sh
# PreToolUse(Bash) launch gate: a session starts a child agent only after the user answered a
# structured question about the child's agent, model, and effort in this session.
#
# Runs for Claude Code (plugin hook) and Codex (repository hook installed by orca-init.sh, which
# copies this file and orca-lib.sh into <repo>/.codex/hooks/). A launch is a simple command
#   orca terminal create ... --command <value>   whose <value> runs `claude` or `codex`, or
#   orca orchestration worker-start ... --agent ...   without --terminal.
# The launch is allowed when the session transcript, after the last previous successful launch,
# holds answered questions for all three topics: header `Agent`, `Model`, `Effort` (trimmed,
# any case), or, without a header, a title/question starting with `[Agent]`, `[Model]`,
# `[Effort]`. A failed launch does not reset that window. Missing or unreadable transcripts and
# unknown transcript formats are denied. Allow is silent; deny is the hookSpecificOutput JSON,
# which Claude and Codex both honor (never `allow` or `ask`: Codex fails open on those).
# Misoperation prevention by string matching, not a sandbox.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/orca-lib.sh"
input=$(cat)
[ "$(printf '%s' "$input" | jq -r '.tool_name // empty')" = Bash ] || exit 0

deny() {
  jq -n --arg r "[orca-launch-gate] $1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}
how='Ask the user now with a structured question tool: AskUserQuestion in Claude Code, request_user_input or request_user_input_async in Codex. Ask one question each with header `Agent` (claude or codex), `Model`, and `Effort`; request_user_input_async has no header, so start each title with `[Agent]`, `[Model]`, `[Effort]` instead. Put the recommended option first with a label ending in "(Recommended)"; values the user already named in the request are that recommended option. Never infer or pick the values yourself, and do not retry the launch until the user has answered.'

# Joins backslash-newline line continuations outside single quotes, as the shell does
# (the same as orca-role-guard.sh).
join_lines() {
  awk 'BEGIN { q = "" }
    { out = ""; cont = 0
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (q == "\047") { if (c == q) q = ""; out = out c; continue }
        if (c == "\\") { if (i == length($0)) { cont = 1; break }; out = out c substr($0, i + 1, 1); i++; continue }
        if (q == "\"") { if (c == q) q = ""; out = out c; continue }
        if (c == "\047" || c == "\"") q = c
        out = out c
      }
      printf "%s%s", out, (cont ? "" : "\n")
    }'
}
# The simple commands on stdin, one per line, words separated by \037, with quotes and
# backslashes resolved (no expansion). Splits on ; & | ( ) ` and unquoted newlines
# (the same as orca-role-guard.sh, reading stdin).
commands() {
  awk 'BEGIN { US = sprintf("%c", 31); q = "" }
    function word() { if (inw) { out = out (n++ ? US : "") w; w = ""; inw = 0 } }
    function flush() { word(); if (n) print out; out = ""; n = 0 }
    { for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (q != "") {
          if (c == q) q = ""
          else if (c == "\\" && q == "\"" && i < length($0)) { i++; w = w substr($0, i, 1) }
          else w = w c
          continue
        }
        if (c == "\047" || c == "\"") { q = c; inw = 1; continue }
        if (c == "\\") { if (i < length($0)) { i++; w = w substr($0, i, 1) }; inw = 1; continue }
        if (c == " " || c == "\t") { word(); continue }
        if (index(";&|()`", c)) { flush(); continue }
        w = w c; inw = 1
      }
      if (q == "") flush(); else w = w "\n"
    }
    END { flush() }'
}
# Word index of the command name after assignments and wrappers such as sudo or env.
skip_prefix='i = 1; while (i <= NF && ($i ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || $i ~ /^(sudo|command|env|nohup|time|exec|\{|!)$/)) i++; w = $i; sub(/.*\//, "", w)'

# is_launch <command>: true when a simple command in <command> starts a child agent.
is_launch() {
  printf '%s\n' "$1" | join_lines | commands | awk "BEGIN { FS = sprintf(\"%c\", 31) } { $skip_prefix"'
    if (w != "orca") next
    if ($(i + 1) == "terminal" && $(i + 2) == "create") {
      for (j = i + 3; j <= NF; j++) {
        v = ""
        if ($j == "--command" && j < NF) { v = $(j + 1); j++ }
        else if ($j ~ /^--command=/) v = substr($j, 11)
        else continue
        gsub(/\n/, " ", v); print "command\t" v
      }
    } else if ($(i + 1) == "orchestration" && $(i + 2) == "worker-start") {
      agent = 0; term = 0
      for (j = i + 3; j <= NF; j++) {
        if ($j == "--agent" || $j ~ /^--agent=/) agent = 1
        if ($j == "--terminal" || $j ~ /^--terminal=/) term = 1
      }
      if (agent && !term) print "launch"
    }
  }' | while IFS="$(printf '\t')" read -r kind value; do
    [ "$kind" = launch ] && { echo yes; break; }
    # The --command value is itself a shell command: any simple command in it that runs claude or codex.
    printf '%s\n' "$value" | commands | awk "BEGIN { FS = sprintf(\"%c\", 31) } { $skip_prefix"'
      if (w == "claude" || w == "codex") { print "yes"; exit } }' | grep -q yes && { echo yes; break; }
  done | grep -q yes
}

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
is_launch "$cmd" || exit 0
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
# Out of scope: this repository did not opt into the Orca worktree rules. A child is gated as
# well: it never launches agents.
[ "$(orca_role "$cwd")" = none ] && exit 0

transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
current=$(printf '%s' "$input" | jq -r '.tool_use_id // empty')
[ -n "$transcript" ] && [ -f "$transcript" ] && [ -r "$transcript" ] \
  || deny "Blocked a child agent launch: the session transcript (transcript_path) is missing or unreadable, so the answers about the child's agent, model, and effort cannot be verified. $how"

# Transcript events in order, one per line:
#   A<TAB><topic>        an answered question about agent, model, or effort
#   C<TAB><id><TAB><json command>  a shell call that may be a launch (cheap prefilter)
#   F<TAB><id>           that call failed (error result or non-zero exit)
topic='def trim: gsub("^\\s+|\\s+$"; "");
  def topic: ((.header // "") | if type == "string" then trim else "" end) as $h
    | if $h != "" then ($h | ascii_downcase | select(. == "agent" or . == "model" or . == "effort"))
      else [(.title // .question // "") | tostring | trim | ascii_downcase
        | capture("^\\[(?<t>agent|model|effort)\\]")?][0].t // empty end;
  def nonempty: if type == "string" or type == "array" or type == "object" then length > 0 else . != null and . != false end;
  def candidate: type == "string" and (test("worker-start") or (test("terminal") and test("create")));
  def parse: if type == "string" then (try fromjson catch null) else . end;'
format=$(jq -nrR 'first(inputs | fromjson? | select(type == "object")
  | if (.type == "user" or .type == "assistant") and (.message | type) == "object" then "claude"
    elif .type == "session_meta" or .type == "response_item" or .type == "event_msg" or .type == "turn_context" then "codex"
    else empty end) // "unknown"' < "$transcript" 2>/dev/null)
case "$format" in
claude)
  events=$(jq -nrR "$topic"'
    inputs | fromjson? | select(type == "object") | try (
    if .type == "assistant" and (.message.content | type) == "array" then
      .message.content[] | select(.type == "tool_use" and .name == "Bash" and (.input.command | candidate))
      | "C\t\(.id)\t\(.input.command | @json)"
    elif .type == "user" and (.message.content | type) == "array" then
      ([.message.content[] | select(.type == "tool_result" and .is_error == true) | .tool_use_id]) as $err
      | ($err[] | "F\t\(.)"),
        (select($err == []) | .toolUseResult | select(type == "object" and (.answers | type) == "object")
          | .answers as $a | .questions[]? | select($a[.question // ""] | nonempty) | topic | "A\t\(.)")
    else empty end) catch empty' < "$transcript")
  ;;
codex)
  # Records wrap items in `payload` (response_item, event_msg); older rollouts hold them bare.
  events=$(jq -nrR "$topic"'
    def shellcmd: if type == "array" then (if length >= 3 and (.[-2] | tostring | test("^-[A-Za-z]*c$")) then .[-1] else join(" ") end) else . end;
    def exitcode: [tostring | capture("(?:[Pp]rocess exited with code|[Ee]xit code:?) (?<c>-?[0-9]+)")?][0].c // null;
    def synthetic: [.content[]? | .text? // empty][0] // "" | test("^\\s*(<|# AGENTS\\.md instructions)");
    foreach (inputs | fromjson? | select(type == "object")) as $l
      ({sync: {}, shell: {}, pending: [], out: []};
       . as $s | try (.out = [] | ($l.payload // $l) as $p | ($p.call_id // "" | tostring) as $id |
       if $p.type == "function_call" then
         ($p.arguments | parse // {}) as $a |
         if $p.name == "request_user_input" then
           .sync[$id] = [$a.questions[]? | {id: (.id // ""), t: topic}]
         elif $p.name == "request_user_input_async" then
           .pending += [$a.questions[]? | topic]
         elif ($p.name | tostring | test("^(exec_command|shell|shell_command|container\\.exec)$")) then
           (($a.cmd // $a.command) | shellcmd) as $c
           | if ($c | candidate) and $id != $current then .shell[$id] = $c else . end
         else . end
       elif $p.type == "function_call_output" and .sync[$id] then
         ($p.output | parse | if type == "object" and (.answers | type) == "object" then .answers else {} end) as $ans
         | .out = [.sync[$id][] | select($ans[.id] | if type == "object" then .answers else null end | nonempty) | "A\t\(.t)"]
         | del(.sync[$id])
       elif $p.type == "function_call_output" and .shell[$id] then
         ($p.output | if type == "string" then . else tojson end | exitcode) as $x
         | .out = ["C\t\($id)\t\(.shell[$id] | @json)"] + (if $x != null and $x != "0" then ["F\t\($id)"] else [] end)
         | del(.shell[$id])
       elif $p.type == "item_completed" and $p.item.type == "CommandExecution" then
         ($p.item.command | shellcmd) as $c | $p.item as $i
         | if ($c | candidate) then
             .out = ["C\t\($i.id)\t\($c | @json)"]
               + (if ($i.exit_code // $i.exitCode) == 0 and ($i.status | tostring | test("fail|declin|error") | not) then [] else ["F\t\($i.id)"] end)
           else . end
       elif ($p.type == "user_message") or ($p.type == "item_completed" and $p.item.type == "UserMessage")
         or ($p.type == "message" and $p.role == "user" and ($p | synthetic | not)) then
         .out = [.pending[] | "A\t\(.)"] | .pending = []
       else . end) catch ($s | .out = []);
       .out[])' --arg current "$current" < "$transcript")
  ;;
*)
  deny "Blocked a child agent launch: the session transcript format is not recognized (neither a Claude Code nor a Codex transcript), so the answers about the child's agent, model, and effort cannot be verified. $how"
  ;;
esac

# Walk the events: a successful launch other than this call clears the answered topics.
failed=$(printf '%s\n' "$events" | awk -F '\t' '$1 == "F" { print $2 }')
agent= model= effort=
tab=$(printf '\t')
while IFS=$tab read -r kind a b; do
  case "$kind" in
  A)
    case "$a" in agent) agent=1 ;; model) model=1 ;; effort) effort=1 ;; esac ;;
  C)
    [ -n "$current" ] && [ "$a" = "$current" ] && continue
    printf '%s\n' "$failed" | grep -Fxq -- "$a" && continue
    is_launch "$(printf '%s' "$b" | jq -r .)" && agent= model= effort=
    ;;
  esac
done <<EOF
$events
EOF

missing=
[ -n "$agent" ] || missing="$missing, Agent"
[ -n "$model" ] || missing="$missing, Model"
[ -n "$effort" ] || missing="$missing, Effort"
[ -z "$missing" ] && exit 0
deny "Blocked a child agent launch: this session has no answered question about the child's ${missing#, } since the last successful launch (the user must answer Agent, Model, and Effort before every launch; a failed launch can be retried without asking again). $how"
