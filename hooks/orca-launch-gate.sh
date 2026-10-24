#!/bin/sh
# PreToolUse(Bash) launch gate: in launch mode `ask` (the default), a session starts a child
# agent only after the user answered a structured question about the child's agent, model, and
# effort in this session.
#
# Runs for Claude Code (plugin hook) and Codex (repository hook installed by orca-init.sh, which
# copies this file and orca-lib.sh into <repo>/.codex/hooks/). A launch is a simple command
#   orca terminal create ... --command <value>   whose <value> runs `claude` or `codex` (also
#     inside a `sh -c` string in <value>), or the
#     same --command <value> after any word of the command whose basename is
#     orca-terminal-create.sh (run directly, by a shell with options, by `.`/`source`, or by
#     another wrapper such as perl or gtimeout), or
#   orca orchestration worker-start ... --agent ...   without --terminal.
# Wrappers such as sudo or env are skipped together with their options, and the command string
# of `sh`/`bash`/`dash`/`zsh -c` is checked the same way, recursively.
# The launch is allowed when the session transcript, after the last previous successful launch,
# holds answered questions for all three topics: header `Agent`, `Model`, `Effort` (trimmed,
# any case), or, without a header, a title/question starting with `[Agent]`, `[Model]`,
# `[Effort]`. A failed launch does not reset that window. Missing or unreadable transcripts and
# unknown transcript formats are denied. Allow is silent; deny is the hookSpecificOutput JSON,
# which Claude and Codex both honor (never `allow` or `ask`: Codex fails open on those).
# The repository's .orca-dev-ops.json (read from the main checkout, see orca-lib.sh) sets the
# launch mode; an invalid settings file means mode `ask`, the behavior above.
# With launch mode `semi-auto` or `auto`, no transcript is read for the default tier: every
# launch in the command is allowed only when its agent, model, and effort equal launch.agent,
# launch.model, and launch.effort; a mismatch or a value the command does not set is denied.
# With launch.escalate {model, effort} also set, a launch of launch.agent with exactly those
# values is allowed as well:
#   semi-auto  only when the transcript holds an answered `Model` question after the last
#              successful launch (the same transcript logic as ask mode, `Model` only);
#   auto       without reading the transcript (the coordinator chooses the tier itself).
# Without launch.escalate, semi-auto and auto behave the same.
# Misoperation prevention by string matching, not a sandbox.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/orca-lib.sh"
input=$(cat)
[ "$(printf '%s' "$input" | jq -r '.tool_name // empty')" = Bash ] || exit 0

# Settings warning appended to every deny (set once the settings are loaded).
warn=
deny() {
  jq -n --arg r "[orca-launch-gate] $1$warn" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
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
# (the same as orca-role-guard.sh, reading stdin); a quoted newline is kept as \036, so a word
# never spans two output lines.
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
      if (q == "") flush(); else w = w "\036"
    }
    END { flush() }'
}
# Word index i of the command name after assignments, `{`, `!`, and wrappers such as sudo or
# env with their options (and the separate argument of an option that takes one; `--` ends a
# wrapper's options); w is its basename.
skip_prefix='i = 1
  while (i <= NF) {
    if ($i ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || $i ~ /^(\{|!)$/) { i++; continue }
    if ($i !~ /^(sudo|command|env|nohup|time|exec)$/) break
    p = $i; i++
    while (i <= NF && $i ~ /^-/) {
      if ($i == "--") { i++; break }
      if ((p == "sudo" && $i ~ /^-[ugpCDhrtTUR]$/) || (p == "env" && $i ~ /^-[uCSP]$/) || (p == "exec" && $i == "-a") || (p == "time" && $i ~ /^-[of]$/)) i++
      i++
    }
  }
  w = $i; sub(/.*\//, "", w)'
# After skip_prefix: nested, the command string of `sh -c` and the like (its newlines are \036,
# see commands()), or empty.
shell_string='nested = ""
  if (w ~ /^(sh|bash|dash|zsh)$/) {
    cmode = 0
    for (j = i + 1; j <= NF; j++) {
      o = $j
      if (o == "--" || o == "-") { j++; break }
      if (o !~ /^[-+]./) break
      if (o == "--rcfile" || o == "--init-file") { j++; continue }
      if (o ~ /^--/) continue
      if (o ~ /^-[A-Za-z]*c/) cmode = 1
      if (o ~ /^[-+][A-Za-z]*[oO]$/) j++
    }
    if (cmode && j <= NF) nested = $j
  }'
# After skip_prefix: nested (see shell_string); or s, the index of the first word that may hold
# --command, for `orca terminal create` or any word whose basename is orca-terminal-create.sh.
launch_start="$shell_string"'; s = 0
  if (w == "orca" && $(i + 1) == "terminal" && $(i + 2) == "create") s = i + 3
  if (!s && nested == "") for (j = 1; j <= NF; j++) { b = $j; sub(/.*\//, "", b); if (b == "orca-terminal-create.sh") { s = j + 1; break } }'

us=$(printf '\037')
# value_agents <command>: "<agent>\037<model>\037<effort>" for every simple command in <command>
# (a --command value, itself a shell command) that runs claude or codex, also inside the command
# string of `sh -c` and the like, recursively; a value the command does not set is empty.
# Claude: --model, --effort; Codex: -m/--model and -c/--config model_reasoning_effort=<v>.
value_agents() {
  printf '%s\n' "$1" | commands | awk "BEGIN { FS = sprintf(\"%c\", 31); OFS = FS } { $skip_prefix; $shell_string"'
    if (nested != "") { print "N", nested; next }
    if (w != "claude" && w != "codex") next
    model = effort = ""
    for (j = i + 1; j <= NF; j++) {
      t = $j; c = ""
      if (t == "--model" || (w == "codex" && t == "-m")) { if (j < NF) model = $(++j) }
      else if (t ~ /^--model=/) model = substr(t, 9)
      else if (w == "claude" && t == "--effort") { if (j < NF) effort = $(++j) }
      else if (w == "claude" && t ~ /^--effort=/) effort = substr(t, 10)
      else if (w == "codex" && (t == "-c" || t == "--config")) { if (j < NF) c = $(++j) }
      else if (w == "codex" && t ~ /^--config=/) c = substr(t, 10)
      if (c ~ /^model_reasoning_effort=/) {
        effort = substr(c, 24)
        if (effort ~ /^".*"$/ || effort ~ /^\047.*\047$/) effort = substr(effort, 2, length(effort) - 2)
      }
    }
    print "L", w, model, effort }' | while IFS= read -r _l; do
    case "$_l" in
    "N$us"*) value_agents "$(printf '%s' "${_l#N"$us"}" | tr '\036' '\n')" ;;
    *) printf '%s\n' "${_l#L"$us"}" ;;
    esac
  done
}

# is_launch <command>: true when a simple command in <command> starts a child agent.
is_launch() {
  printf '%s\n' "$1" | join_lines | commands | awk "BEGIN { FS = sprintf(\"%c\", 31) } { $skip_prefix; $launch_start"'
    if (nested != "") print "nested\t" nested
    else if (s) {
      for (j = s; j <= NF; j++) {
        v = ""
        if ($j == "--command" && j < NF) { v = $(j + 1); j++ }
        else if ($j ~ /^--command=/) v = substr($j, 11)
        else continue
        gsub(/\036/, " ", v); print "command\t" v
      }
    } else if (w == "orca" && $(i + 1) == "orchestration" && $(i + 2) == "worker-start") {
      agent = 0; term = 0
      for (j = i + 3; j <= NF; j++) {
        if ($j == "--agent" || $j ~ /^--agent=/) agent = 1
        if ($j == "--terminal" || $j ~ /^--terminal=/) term = 1
      }
      if (agent && !term) print "launch"
    }
  }' | while IFS="$(printf '\t')" read -r kind value; do
    [ "$kind" = launch ] && { echo yes; break; }
    if [ "$kind" = nested ]; then
      is_launch "$(printf '%s' "$value" | tr '\036' '\n')" && { echo yes; break; }
      continue
    fi
    # The --command value is itself a shell command: any simple command in it that runs claude or codex.
    [ -n "$(value_agents "$value")" ] && { echo yes; break; }
  done | grep -q yes
}

# launch_params <command>: "<agent>\037<model>\037<effort>" for every launch that is_launch
# detects in <command>; a value the launch does not set is empty. A --command value: see
# value_agents; worker-start: --agent, --model, --effort. Both `--flag value` and `--flag=value`;
# the last occurrence wins.
launch_params() {
  printf '%s\n' "$1" | join_lines | commands | awk "BEGIN { FS = sprintf(\"%c\", 31); OFS = FS } { $skip_prefix; $launch_start"'
    if (nested != "") print "N", nested
    else if (s) {
      for (j = s; j <= NF; j++) {
        v = ""
        if ($j == "--command" && j < NF) { v = $(j + 1); j++ }
        else if ($j ~ /^--command=/) v = substr($j, 11)
        else continue
        gsub(/\036/, " ", v); print "C", v
      }
    } else if (w == "orca" && $(i + 1) == "orchestration" && $(i + 2) == "worker-start") {
      agent = model = effort = ""; has = 0; term = 0
      for (j = i + 3; j <= NF; j++) {
        if ($j == "--agent" || $j ~ /^--agent=/) has = 1
        if ($j == "--terminal" || $j ~ /^--terminal=/) term = 1
        if ($j ~ /^--(agent|model|effort)$/ && j < NF) { k = substr($j, 3); v = $(j + 1); j++ }
        else if ($j ~ /^--(agent|model|effort)=/) { k = substr($j, 3, index($j, "=") - 3); v = substr($j, index($j, "=") + 1) }
        else continue
        if (k == "agent") agent = v; else if (k == "model") model = v; else effort = v
      }
      if (has && !term) print "L", agent, model, effort
    }
  }' | while IFS= read -r _l; do
    case "$_l" in
    "L$us"*) printf '%s\n' "${_l#L"$us"}" ;;
    "N$us"*) launch_params "$(printf '%s' "${_l#N"$us"}" | tr '\036' '\n')" ;;
    # The --command value is itself a shell command: every simple command in it that runs claude or codex.
    *) value_agents "${_l#C"$us"}" ;;
    esac
  done
}

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
is_launch "$cmd" || exit 0
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
# Out of scope: this repository did not opt into the Orca worktree rules. A child is gated as
# well: it never launches agents.
[ "$(orca_role "$cwd")" = none ] && exit 0

orca_config_load "$cwd"
[ -n "$ORCA_CONFIG_ERROR" ] && warn=" Settings warning: $ORCA_CONFIG_ERROR"
want_agent=$(orca_config .launch.agent) want_model=$(orca_config .launch.model) want_effort=$(orca_config .launch.effort)
# Set in semi-auto mode when every launch is in the default or the escalate tier and one is in
# the escalate tier: only the answered Model question is then required, and no Agent or Effort
# question.
escalating=
what='agent, model, and effort'
mode=$(orca_config .launch.mode)
if [ "$mode" = semi-auto ] || [ "$mode" = auto ]; then
  esc_model=$(orca_config .launch.escalate.model) esc_effort=$(orca_config .launch.escalate.effort)
  tier=$(launch_params "$cmd" | awk -F "$us" -v a="$want_agent" -v m="$want_model" -v e="$want_effort" -v xm="$esc_model" -v xe="$esc_effort" '
    { n++
      if ($1 == a && $2 == m && $3 == e) next
      if (xm != "" && $1 == a && $2 == xm && $3 == xe) { esc = 1; next }
      printf "B" "agent %s, model %s, effort %s", ($1 == "" ? "(unset)" : $1), ($2 == "" ? "(unset)" : $2), ($3 == "" ? "(unset)" : $3); bad = 1; exit }
    END { if (bad) exit
      if (!n) printf "Bno agent, model, or effort that could be read"
      else if (esc) printf "E" }')
  case "$tier" in
  "") exit 0 ;;
  E)
    [ "$mode" = auto ] && exit 0
    escalating=1 what=model ;;
  *)
    tiers="agent $want_agent, model $want_model, and effort $want_effort"
    flags="Claude: --model $want_model --effort $want_effort; Codex: -m $want_model -c model_reasoning_effort=$want_effort; worker-start: --agent $want_agent --model $want_model --effort $want_effort"
    if [ -n "$esc_model" ]; then
      if [ "$mode" = auto ]; then
        tiers="$tiers, or agent $want_agent, model $esc_model, and effort $esc_effort"
      else
        tiers="$tiers, or, only after the user answered a question with header \`Model\` in this session since the last successful launch, agent $want_agent, model $esc_model, and effort $esc_effort"
      fi
      flags="$flags. Second tier: Claude: --model $esc_model --effort $esc_effort; Codex: -m $esc_model -c model_reasoning_effort=$esc_effort; worker-start: --agent $want_agent --model $esc_model --effort $esc_effort"
    fi
    deny "Blocked a child agent launch: this repository's $ORCA_CONFIG_FILE ($ORCA_CONFIG_PATH) sets launch mode $mode, which allows only $tiers, and this launch has ${tier#B}. Launch with exactly those values ($flags). To use other values, ask the user; do not edit $ORCA_CONFIG_FILE to get around this." ;;
  esac
  how='Ask the user now with a structured question tool: AskUserQuestion in Claude Code, request_user_input or request_user_input_async in Codex. Ask one question with header `Model` (request_user_input_async has no header, so start the title with `[Model]` instead). Put the recommended option first with a label ending in "(Recommended)". Never infer or pick the answer yourself, and do not retry the launch until the user has answered.'
fi
if [ -z "$escalating" ] && [ -n "$want_agent$want_model$want_effort" ]; then
  how="$how This repository's $ORCA_CONFIG_FILE recommends${want_agent:+ agent $want_agent}${want_model:+ model $want_model}${want_effort:+ effort $want_effort}: make those the (Recommended) options."
fi

transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
current=$(printf '%s' "$input" | jq -r '.tool_use_id // empty')
[ -n "$transcript" ] && [ -f "$transcript" ] && [ -r "$transcript" ] \
  || deny "Blocked a child agent launch: the session transcript (transcript_path) is missing or unreadable, so the answers about the child's $what cannot be verified. $how"

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
  deny "Blocked a child agent launch: the session transcript format is not recognized (neither a Claude Code nor a Codex transcript), so the answers about the child's $what cannot be verified. $how"
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
[ -n "$escalating" ] || [ -n "$agent" ] || missing="$missing, Agent"
[ -n "$model" ] || missing="$missing, Model"
[ -n "$escalating" ] || [ -n "$effort" ] || missing="$missing, Effort"
[ -z "$missing" ] && exit 0
if [ -n "$escalating" ]; then
  deny "Blocked a child agent launch: this launch uses the escalate tier of $ORCA_CONFIG_FILE, and this session has no answered question about the child's Model since the last successful launch (the user must answer Model before every escalate launch; a failed launch can be retried without asking again). $how"
fi
deny "Blocked a child agent launch: this session has no answered question about the child's ${missing#, } since the last successful launch (the user must answer Agent, Model, and Effort before every launch; a failed launch can be retried without asking again). $how"
