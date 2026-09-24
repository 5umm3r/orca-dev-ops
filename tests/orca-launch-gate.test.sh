#!/bin/sh
# Tests for hooks/orca-launch-gate.sh with a stub orca, throwaway git repos, and synthetic
# Claude Code and Codex transcripts assembled from tests/fixtures/transcripts/*.jsonl.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"
gate="$root/hooks/orca-launch-gate.sh"
fx="$root/tests/fixtures/transcripts"

repo="$tmp/dev/my repo"; mkdir -p "$repo"; marker "$repo"; new_repo "$repo"
child="$tmp/work trees/task one"; mkdir -p "$tmp/work trees"
git -C "$repo" worktree add -q -b task-one "$child" || exit 1
plain="$tmp/plain"; mkdir -p "$plain"; new_repo "$plain"
orca_knows "$repo" main
orca_knows "$child" linked
orca_knows "$plain" main

create='orca terminal create --worktree name:cc-task --title agent --command "claude --model opus --effort high" --json'
# transcript <name> <fragment>...: a transcript file made of the fixture fragments, in order.
transcript() {
  _t="$tmp/scratch/$1.jsonl"; shift
  for _f in "$@"; do cat "$fx/$_f.jsonl"; done > "$_t"
  printf '%s\n' "$_t"
}
# input <command> <transcript path or ""> [cwd] [tool_use_id]
input() {
  jq -n --arg c "$1" --arg t "$2" --arg cwd "${3:-$repo}" --arg id "${4:-toolu_current}" \
    '{cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},tool_use_id:$id,
      transcript_path:(if $t == "" then null else $t end)}'
}
# check <name> <allow|deny> <json>
check() {
  out=$(printf '%s' "$3" | sh "$gate")
  if printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then got=deny
  elif [ -z "$out" ]; then got=allow
  else got="unexpected: $out"
  fi
  result "$1" "$2" "$got"
}
reason() { printf '%s' "$1" | sh "$gate" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'; }
has() { result "$1" yes "$(printf '%s' "$2" | grep -qF -- "$3" && echo yes || echo no)"; }

none=$(transcript none claude-prompt)
all=$(transcript all claude-prompt claude-ask-all)

# --- not a launch, or out of scope: allowed without a transcript
check "git status passes" allow "$(input 'git status' '')"
check "orca terminal list passes" allow "$(input 'orca terminal list --json' '')"
check "terminal create without an agent passes" allow "$(input 'orca terminal create --worktree name:x --command "npm test"' '')"
check "terminal create without --command passes" allow "$(input 'orca terminal create --worktree name:x' '')"
check "worker-start --terminal passes" allow "$(input 'orca orchestration worker-start --run r --task t --agent claude --terminal term_1' '')"
check "worker-start --terminal= passes" allow "$(input 'orca orchestration worker-start --agent=codex --terminal=term_1' '')"
check "orca-worker-start.sh passes" allow "$(input 'sh "$ROOT/scripts/orca-worker-start.sh" --run r --task t --terminal term_1 --worktree name:x' '')"
check "claude mentioned in echo passes" allow "$(input 'echo "orca terminal create --command claude"' '')"
check "role none passes" allow "$(input "$create" '' "$plain")"
check "non-Bash tool passes" allow "$(jq -n --arg cwd "$repo" '{cwd:$cwd,tool_name:"Write",tool_input:{file_path:"x",content:"orca terminal create --command claude"}}')"

# --- Claude transcripts
check "claude: no question denies" deny "$(input "$create" "$none")"
check "claude: all three answered allows" allow "$(input "$create" "$all")"
two=$(transcript two claude-prompt claude-ask-two)
check "claude: two topics denies" deny "$(input "$create" "$two")"
msg=$(reason "$(input "$create" "$two")")
has "claude: reason names the missing Effort" "$msg" "question about the child's Effort"
has "claude: reason names AskUserQuestion" "$msg" "AskUserQuestion"
has "claude: reason names the (Recommended) label" "$msg" '"(Recommended)"'
has "claude: reason forbids retrying" "$msg" "do not retry the launch"
msg=$(reason "$(input "$create" "$none")")
has "claude: reason names all missing topics" "$msg" "Agent, Model, Effort"
check "claude: declined question denies" deny "$(input "$create" "$(transcript declined claude-prompt claude-ask-declined)")"
check "claude: two answered then a separate Effort question allows" allow \
  "$(input "$create" "$(transcript split claude-prompt claude-ask-two claude-ask-all)")"
check "claude: answers before a successful launch deny" deny "$(input "$create" "$(transcript stale claude-prompt claude-ask-all claude-launch-ok)")"
check "claude: answers after a successful launch allow" allow "$(input "$create" "$(transcript fresh claude-prompt claude-launch-ok claude-ask-all)")"
check "claude: answers then a failed launch allow a retry" allow "$(input "$create" "$(transcript retry claude-prompt claude-ask-all claude-launch-failed)")"
check "claude: the current call in the transcript is excluded" allow \
  "$(input "$create" "$(transcript current claude-prompt claude-ask-all claude-launch-ok)" "$repo" toolu_launch_ok)"

# Launch spellings, each without answers (deny) and with them (allow).
for c in \
  'orca terminal create --worktree name:x --command=claude' \
  "orca terminal create --worktree name:x --command 'claude --model opus'" \
  'orca terminal create --command "env X=1 claude --effort high" --json' \
  'orca terminal create --command "FOO=1 /usr/local/bin/codex -m sol"' \
  'orca terminal create --command "cd sub && exec claude"' \
  'cd "$R" && orca terminal create --worktree name:x --command codex | jq .' \
  "$(printf 'orca terminal \\\n  create --worktree name:x \\\n  --command "claude"')" \
  'orca orchestration worker-start --run r --task t --agent claude' \
  'orca orchestration worker-start --agent=codex --worktree name:x'; do
  check "deny without answers: $c" deny "$(input "$c" "$none")"
  check "allow with answers: $c" allow "$(input "$c" "$all")"
done

# --- Codex transcripts
check "codex: no question denies" deny "$(input "$create" "$(transcript cx-none codex-prompt)")"
check "codex: sync answered allows" allow "$(input "$create" "$(transcript cx-sync codex-prompt codex-sync-answered)")"
check "codex: async with a later user message allows" allow \
  "$(input "$create" "$(transcript cx-async codex-prompt codex-async codex-user-reply)")"
check "codex: async without a later user message denies" deny \
  "$(input "$create" "$(transcript cx-async-open codex-prompt codex-async codex-injected)")"
check "codex: user message before the async question denies" deny \
  "$(input "$create" "$(transcript cx-async-early codex-prompt codex-user-reply codex-async)")"
check "codex: stale answers deny" deny "$(input "$create" "$(transcript cx-stale codex-prompt codex-sync-answered codex-launch-ok)")"
check "codex: answers then a failed launch allow a retry" allow \
  "$(input "$create" "$(transcript cx-retry codex-prompt codex-sync-answered codex-launch-failed)")"
check "codex: answers after a successful launch allow" allow \
  "$(input "$create" "$(transcript cx-fresh codex-prompt codex-launch-ok codex-async codex-user-reply)")"

# --- transcript problems fail closed
check "missing transcript_path denies" deny "$(input "$create" '')"
has "missing transcript: reason says so" "$(reason "$(input "$create" '')")" "missing or unreadable"
check "nonexistent transcript denies" deny "$(input "$create" "$tmp/scratch/nowhere.jsonl")"
unreadable=$(transcript unreadable claude-prompt claude-ask-all); chmod 000 "$unreadable"
[ -r "$unreadable" ] || check "unreadable transcript denies" deny "$(input "$create" "$unreadable")"
chmod 600 "$unreadable"
check "unknown format denies" deny "$(input "$create" "$(transcript unknown unknown)")"
has "unknown format: reason says so" "$(reason "$(input "$create" "$(transcript unknown unknown)")")" "format is not recognized"
check "empty transcript denies" deny "$(input "$create" "$(transcript empty)")"

# --- other roles are gated too
check "child: launch without answers denies" deny "$(input "$create" "$none" "$child")"
broken="$tmp/broken"; marker "$broken"; printf 'gitdir: %s\n' "$tmp/nowhere" > "$broken/.git"
check "unknown role: launch without answers denies" deny "$(input "$create" "$none" "$broken")"
check "unknown role: launch with answers allows" allow "$(input "$create" "$all" "$broken")"

# --- .orca-dev-ops.json launch mode auto: the launch must name the configured values
cfg="$repo/.orca-dev-ops.json"
printf '%s\n' '{"launch":{"mode":"auto","agent":"claude","model":"claude-opus-5-5","effort":"high"}}' > "$cfg"
ok='orca terminal create --worktree name:cc-x --title agent --command "claude --dangerously-skip-permissions --model claude-opus-5-5 --effort high" --json'
check "auto: matching launch allows without answers" allow "$(input "$ok" "$none")"
check "auto: matching launch allows without a transcript" allow "$(input "$ok" '')"
check "auto: --flag=value spelling allows" allow "$(input 'orca terminal create --command "claude --model=claude-opus-5-5 --effort=high"' '')"
check "auto: matching worker-start allows" allow "$(input 'orca orchestration worker-start --task t --agent claude --model claude-opus-5-5 --effort high' '')"
check "auto: worker-start with = allows" allow "$(input 'orca orchestration worker-start --agent=claude --model=claude-opus-5-5 --effort=high' '')"
check "auto: other model denies" deny "$(input 'orca terminal create --command "claude --model claude-sonnet-5 --effort high"' "$all")"
check "auto: other effort denies" deny "$(input 'orca terminal create --command "claude --model claude-opus-5-5 --effort max"' "$all")"
check "auto: missing effort denies" deny "$(input 'orca terminal create --command "claude --model claude-opus-5-5"' "$all")"
check "auto: other agent denies" deny "$(input 'orca terminal create --command "codex -m claude-opus-5-5 -c model_reasoning_effort=high"' "$all")"
check "auto: worker-start other effort denies" deny "$(input 'orca orchestration worker-start --agent claude --model claude-opus-5-5 --effort=max' "$all")"
check "auto: worker-start without model denies" deny "$(input 'orca orchestration worker-start --agent claude --effort high' "$all")"
check "auto: second launch mismatching denies" deny "$(input "$ok && orca terminal create --command 'claude --model x --effort high'" "$all")"
msg=$(reason "$(input 'orca terminal create --command "claude --model claude-sonnet-5"' '')")
has "auto: reason names the expected values" "$msg" "agent claude, model claude-opus-5-5, and effort high"
has "auto: reason names the launch's values" "$msg" "agent claude, model claude-sonnet-5, effort (unset)"
has "auto: reason forbids editing the file" "$msg" "do not edit .orca-dev-ops.json"
check "auto: not a launch still passes" allow "$(input 'git status' '')"

printf '%s\n' '{"launch":{"mode":"auto","agent":"codex","model":"gpt-sol","effort":"xhigh"}}' > "$cfg"
codex_cmd='codex -a never -s workspace-write --add-dir /x -c sandbox_workspace_write.network_access=true'
check "auto codex: -m and -c allow" allow "$(input "orca terminal create --command \"$codex_cmd -m gpt-sol -c model_reasoning_effort=xhigh\"" '')"
check "auto codex: --model and --config allow" allow "$(input "orca terminal create --command \"$codex_cmd --model gpt-sol --config model_reasoning_effort=xhigh\"" '')"
check "auto codex: quoted TOML effort allows" allow "$(input "orca terminal create --command '$codex_cmd -m gpt-sol -c model_reasoning_effort=\"xhigh\"'" '')"
check "auto codex: other model denies" deny "$(input "orca terminal create --command \"$codex_cmd -m gpt-other -c model_reasoning_effort=xhigh\"" "$all")"
check "auto codex: missing effort denies" deny "$(input "orca terminal create --command \"$codex_cmd -m gpt-sol\"" "$all")"
check "auto codex: claude denies" deny "$(input 'orca terminal create --command "claude --model gpt-sol --effort xhigh"' "$all")"

# Invalid settings: mode ask with the warning in the deny.
printf '%s\n' '{"launch":{"mode":"auto","agent":"claude","model":"claude-opus-5-5"}}' > "$cfg"
check "invalid config: matching launch without answers denies" deny "$(input "$ok" "$none")"
msg=$(reason "$(input "$ok" "$none")")
has "invalid config: deny carries the warning" "$msg" "Settings warning: Ignored $cfg"
check "invalid config: answers allow" allow "$(input "$ok" "$all")"

# Mode ask with recommended values: still asks, the deny names the recommendation.
printf '%s\n' '{"launch":{"agent":"codex","model":"gpt-sol","effort":"high"}}' > "$cfg"
check "ask with recommendations: no answers denies" deny "$(input "$ok" "$none")"
has "ask with recommendations: reason names them" "$(reason "$(input "$ok" "$none")")" "recommends agent codex model gpt-sol effort high"
check "ask with recommendations: answers allow" allow "$(input "$ok" "$all")"

# Read from the main checkout, never from the session's worktree.
rm -f "$cfg"
printf '%s\n' '{"launch":{"mode":"auto","agent":"claude","model":"claude-opus-5-5","effort":"high"}}' > "$child/.orca-dev-ops.json"
check "worktree copy: ignored from the worktree" deny "$(input "$ok" "$none" "$child")"
check "worktree copy: ignored from the main checkout" deny "$(input "$ok" "$none")"
cp "$child/.orca-dev-ops.json" "$cfg"
printf '%s\n' '{"launch":{"mode":"ask"}}' > "$child/.orca-dev-ops.json"
check "main checkout's auto applies in the worktree" allow "$(input "$ok" "$none" "$child")"
rm -f "$cfg" "$child/.orca-dev-ops.json"

exit "$fail"
