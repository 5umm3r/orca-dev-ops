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
check "cat of the create script passes" allow "$(input 'cat scripts/orca-terminal-create.sh' '')"
check "bash -n of the create script passes" allow "$(input 'bash -n scripts/orca-terminal-create.sh' '')"
check "bash -c without an agent passes" allow "$(input "bash -c 'echo hi'" '')"
check "env -i orca terminal list passes" allow "$(input 'env -i orca terminal list --json' '')"
check "role none passes" allow "$(input "$create" '' "$plain")"
check "non-Bash tool passes" allow "$(jq -n --arg cwd "$repo" '{cwd:$cwd,tool_name:"Write",tool_input:{file_path:"x",content:"orca terminal create --command claude"}}')"

# --- Claude transcripts
check "claude: no question denies" deny "$(input "$create" "$none")"
check "claude: all three answered allows" allow "$(input "$create" "$all")"
script_create='sh "$ROOT/scripts/orca-terminal-create.sh" --worktree name:cc-task --title agent --command "claude --model opus --effort high"'
check "claude: script without answers denies" deny "$(input "$script_create" "$none")"
check "claude: script with all three answered allows" allow "$(input "$script_create" "$all")"
check "claude: script without a transcript denies" deny "$(input "$script_create" '')"
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
  'orca orchestration worker-start --agent=codex --worktree name:x' \
  "sh -x scripts/orca-terminal-create.sh --command 'claude --model opus'" \
  "bash -- scripts/orca-terminal-create.sh --command 'codex -m sol'" \
  "bash -o errexit scripts/orca-terminal-create.sh --command 'claude --model opus'" \
  ". scripts/orca-terminal-create.sh --command 'claude --model opus'" \
  "source scripts/orca-terminal-create.sh --command 'claude --model opus'" \
  "env -i orca terminal create --command 'claude --model opus'" \
  "sudo -u someone orca terminal create --command 'claude --model opus'" \
  "orca terminal create --command 'env -i claude --model opus'" \
  "bash -c \"orca terminal create --command 'claude --model opus'\"" \
  "$(printf '%s\n%s' "bash -c 'echo hi" "orca terminal create --command \"claude --model opus\"'")" \
  "perl -e 'alarm shift; exec @ARGV' 30 sh scripts/orca-terminal-create.sh --command claude" \
  'sudo -u someone -- env -i FOO=1 orca orchestration worker-start --agent claude'; do
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
sett="--settings '/opt/plugin/templates/child-settings.json'"
check "auto: --settings launch with the configured values allows" allow "$(input "orca terminal create --worktree name:cc-x --title agent --command \"claude --dangerously-skip-permissions $sett --model claude-opus-5-5 --effort high\"" "$none")"
check "auto: --settings launch with other model denies" deny "$(input "orca terminal create --worktree name:cc-x --title agent --command \"claude --dangerously-skip-permissions $sett --model claude-sonnet-5 --effort high\"" "$all")"

# scripts/orca-terminal-create.sh takes the same --command and is gated like the orca command.
tcs='"$ROOT/scripts/orca-terminal-create.sh" --worktree name:cc-x --title agent'
okc='--command "claude --dangerously-skip-permissions --model claude-opus-5-5 --effort high"'
badc='--command "claude --model claude-sonnet-5 --effort high"'
check "auto script: sh with the configured values allows" allow "$(input "sh $tcs $okc" "$none")"
check "auto script: --command= spelling allows" allow "$(input "sh $tcs --command='claude --model claude-opus-5-5 --effort high'" '')"
setc="--command \"claude --dangerously-skip-permissions $sett --model claude-opus-5-5 --effort high\""
check "auto script: --settings launch with the configured values allows" allow "$(input "sh $tcs $setc" "$none")"
check "auto script: --settings launch with other model denies" deny "$(input "sh $tcs --command \"claude --dangerously-skip-permissions $sett --model claude-sonnet-5 --effort high\"" "$none")"
check "auto script: sh with other values denies" deny "$(input "sh $tcs $badc" "$none")"
check "auto script: bash with other values denies" deny "$(input "bash $tcs $badc" "$none")"
check "auto script: zsh with other values denies" deny "$(input "zsh $tcs $badc" "$none")"
check "auto script: direct path with other values denies" deny "$(input "/opt/plugin/scripts/orca-terminal-create.sh --worktree name:x --title agent $badc" "$none")"
check "auto script: direct path with the configured values allows" allow "$(input "/opt/plugin/scripts/orca-terminal-create.sh --worktree name:x --title agent $okc" "$none")"
check "auto script: command without effort denies" deny "$(input "sh $tcs --command 'claude --model claude-opus-5-5'" "$none")"
check "auto script: without an agent command passes" allow "$(input "sh $tcs --command 'npm test'" "$none")"
check "auto script: another script passes" allow "$(input "sh \"\$ROOT/scripts/other.sh\" $badc" "$none")"
has "auto script: reason names the launch's values" "$(reason "$(input "sh $tcs $badc" '')")" "agent claude, model claude-sonnet-5, effort high"
check "auto script: bash -x with the configured values allows" allow "$(input 'bash -x scripts/orca-terminal-create.sh --command "claude --model claude-opus-5-5 --effort high"' "$none")"
check "auto: bash -c launch with other model denies" deny "$(input "bash -c \"orca terminal create --command 'claude --model claude-sonnet-5 --effort high'\"" "$none")"
check "auto: bash -c launch with the configured values allows" allow "$(input "bash -c \"orca terminal create --command 'claude --model claude-opus-5-5 --effort high'\"" "$none")"

printf '%s\n' '{"launch":{"mode":"auto","agent":"codex","model":"gpt-sol","effort":"xhigh"}}' > "$cfg"
codex_cmd='codex -a never -s workspace-write --add-dir /x -c sandbox_workspace_write.network_access=true'
check "auto codex: -m and -c allow" allow "$(input "orca terminal create --command \"$codex_cmd -m gpt-sol -c model_reasoning_effort=xhigh\"" '')"
check "auto codex: --model and --config allow" allow "$(input "orca terminal create --command \"$codex_cmd --model gpt-sol --config model_reasoning_effort=xhigh\"" '')"
check "auto codex: quoted TOML effort allows" allow "$(input "orca terminal create --command '$codex_cmd -m gpt-sol -c model_reasoning_effort=\"xhigh\"'" '')"
check "auto codex: other model denies" deny "$(input "orca terminal create --command \"$codex_cmd -m gpt-other -c model_reasoning_effort=xhigh\"" "$all")"
check "auto codex: missing effort denies" deny "$(input "orca terminal create --command \"$codex_cmd -m gpt-sol\"" "$all")"
check "auto codex: claude denies" deny "$(input 'orca terminal create --command "claude --model gpt-sol --effort xhigh"' "$all")"

# Mode semi-auto with launch.escalate: the default tier as above; the escalate tier only after an
# answered Model question.
printf '%s\n' '{"launch":{"mode":"semi-auto","agent":"claude","model":"claude-sonnet-5-5","effort":"medium","escalate":{"model":"claude-opus-5-5","effort":"high"}}}' > "$cfg"
dflt='orca terminal create --worktree name:cc-x --command "claude --model claude-sonnet-5-5 --effort medium"'
esc='orca terminal create --worktree name:cc-x --command "claude --model claude-opus-5-5 --effort high"'
mans=$(transcript mans claude-prompt claude-ask-two)
check "semi-auto escalate: default values allow without a transcript" allow "$(input "$dflt" '')"
check "semi-auto escalate: default values allow without answers" allow "$(input "$dflt" "$none")"
check "semi-auto escalate: escalate values deny without a Model answer" deny "$(input "$esc" "$none")"
check "semi-auto escalate: escalate values allow after an answered Model question" allow "$(input "$esc" "$mans")"
check "semi-auto escalate: --flag=value spelling allows after a Model answer" allow \
  "$(input 'orca terminal create --command "claude --model=claude-opus-5-5 --effort=high"' "$mans")"
check "semi-auto escalate: Model answer before the last launch denies" deny \
  "$(input "$esc" "$(transcript esc-stale claude-prompt claude-ask-two claude-launch-ok)")"
check "semi-auto escalate: Model answer after a launch allows" allow \
  "$(input "$esc" "$(transcript esc-fresh claude-prompt claude-launch-ok claude-ask-two)")"
check "semi-auto escalate: declined question denies" deny "$(input "$esc" "$(transcript esc-declined claude-prompt claude-ask-declined)")"
check "semi-auto escalate: missing transcript denies" deny "$(input "$esc" '')"
check "semi-auto escalate: nonexistent transcript denies" deny "$(input "$esc" "$tmp/scratch/nowhere.jsonl")"
check "semi-auto escalate: unknown transcript format denies" deny "$(input "$esc" "$(transcript esc-unknown unknown)")"
check "semi-auto escalate: other model denies" deny "$(input 'orca terminal create --command "claude --model claude-haiku-5-5 --effort high"' "$mans")"
check "semi-auto escalate: escalate model with default effort denies" deny "$(input 'orca terminal create --command "claude --model claude-opus-5-5 --effort medium"' "$mans")"
check "semi-auto escalate: default model with escalate effort denies" deny "$(input 'orca terminal create --command "claude --model claude-sonnet-5-5 --effort high"' "$mans")"
check "semi-auto escalate: other agent denies" deny "$(input 'orca terminal create --command "codex -m claude-opus-5-5 -c model_reasoning_effort=high"' "$mans")"
check "semi-auto escalate: second launch mismatching denies" deny "$(input "$esc && orca terminal create --command 'claude --model x --effort high'" "$mans")"
check "semi-auto escalate: default and escalate launch together need the answer" deny "$(input "$dflt && $esc" "$none")"
check "semi-auto escalate: default and escalate launch together allow with it" allow "$(input "$dflt && $esc" "$mans")"
check "semi-auto escalate: worker-start escalate values allow after a Model answer" allow \
  "$(input 'orca orchestration worker-start --task t --agent claude --model claude-opus-5-5 --effort high' "$mans")"
check "semi-auto escalate: worker-start with = allows after a Model answer" allow \
  "$(input 'orca orchestration worker-start --agent=claude --model=claude-opus-5-5 --effort=high' "$mans")"
check "semi-auto escalate: worker-start escalate values deny without it" deny \
  "$(input 'orca orchestration worker-start --agent claude --model claude-opus-5-5 --effort high' "$none")"
check "semi-auto escalate: worker-start default values allow without a transcript" allow \
  "$(input 'orca orchestration worker-start --agent claude --model claude-sonnet-5-5 --effort medium' '')"
check "semi-auto escalate: worker-start other agent denies" deny \
  "$(input 'orca orchestration worker-start --agent codex --model claude-opus-5-5 --effort high' "$mans")"
msg=$(reason "$(input "$esc" "$none")")
has "semi-auto escalate: reason names the Model question" "$msg" "no answered question about the child's Model"
result "semi-auto escalate: reason does not ask for Agent or Effort" no "$(printf '%s' "$msg" | grep -qF 'Agent, Model' && echo yes || echo no)"
msg=$(reason "$(input 'orca terminal create --command "claude --model claude-haiku-5-5 --effort low"' "$mans")")
has "semi-auto escalate: reason names the default tier" "$msg" "agent claude, model claude-sonnet-5-5, and effort medium"
has "semi-auto escalate: reason names the escalate tier" "$msg" "agent claude, model claude-opus-5-5, and effort high"
has "semi-auto escalate: reason requires the Model question" "$msg" "answered a question with header \`Model\`"
has "semi-auto escalate: reason names the mode" "$msg" "sets launch mode semi-auto,"
codex_all=$(transcript cx-esc codex-prompt codex-sync-answered)
check "semi-auto escalate: codex flags with escalate values deny when launch.agent is claude" deny \
  "$(input 'orca terminal create --command "codex -m claude-opus-5-5 -c model_reasoning_effort=high"' "$codex_all")"
printf '%s\n' '{"launch":{"mode":"semi-auto","agent":"codex","model":"gpt-sol","effort":"xhigh","escalate":{"model":"gpt-sol-pro","effort":"max"}}}' > "$cfg"
cxesc="orca terminal create --command \"$codex_cmd -m gpt-sol-pro -c model_reasoning_effort=max\""
check "semi-auto escalate codex agent: default values allow without answers" allow \
  "$(input "orca terminal create --command \"$codex_cmd -m gpt-sol -c model_reasoning_effort=xhigh\"" '')"
check "semi-auto escalate codex agent: escalate values deny without answers" deny "$(input "$cxesc" "$none")"
check "semi-auto escalate codex agent: escalate values allow after a Model answer" allow "$(input "$cxesc" "$codex_all")"
check "semi-auto escalate codex agent: --model and --config allow after a Model answer" allow \
  "$(input "orca terminal create --command \"$codex_cmd --model gpt-sol-pro --config model_reasoning_effort=max\"" "$codex_all")"
check "semi-auto escalate codex agent: stale Model answer denies" deny \
  "$(input "$cxesc" "$(transcript cx-esc-stale codex-prompt codex-sync-answered codex-launch-ok)")"
check "semi-auto escalate codex agent: worker-start escalate values allow after a Model answer" allow \
  "$(input 'orca orchestration worker-start --agent codex --model gpt-sol-pro --effort max' "$codex_all")"
check "semi-auto escalate codex agent: claude with escalate values denies" deny \
  "$(input 'orca terminal create --command "claude --model gpt-sol-pro --effort max"' "$mans")"

# Mode semi-auto without launch.escalate: the same as auto without it.
printf '%s\n' '{"launch":{"mode":"semi-auto","agent":"claude","model":"claude-opus-5-5","effort":"high"}}' > "$cfg"
check "semi-auto: matching launch allows without a transcript" allow "$(input "$ok" '')"
check "semi-auto: other model denies" deny "$(input 'orca terminal create --command "claude --model claude-sonnet-5 --effort high"' "$all")"
has "semi-auto: reason names the mode" "$(reason "$(input 'orca terminal create --command "claude --model x --effort high"' '')")" \
  "sets launch mode semi-auto, which allows only agent claude, model claude-opus-5-5, and effort high,"

# Mode auto with launch.escalate: either tier without a question; the transcript is never read.
printf '%s\n' '{"launch":{"mode":"auto","agent":"claude","model":"claude-sonnet-5-5","effort":"medium","escalate":{"model":"claude-opus-5-5","effort":"high"}}}' > "$cfg"
check "auto escalate: escalate values allow without a transcript" allow "$(input "$esc" '')"
check "auto escalate: escalate values allow with a nonexistent transcript" allow "$(input "$esc" "$tmp/scratch/nowhere.jsonl")"
check "auto escalate: escalate values allow without a Model answer" allow "$(input "$esc" "$none")"
check "auto escalate: escalate values allow with an unknown transcript format" allow "$(input "$esc" "$(transcript auto-esc-unknown unknown)")"
check "auto escalate: --flag=value spelling allows" allow \
  "$(input 'orca terminal create --command "claude --model=claude-opus-5-5 --effort=high"' '')"
check "auto escalate: default values allow without a transcript" allow "$(input "$dflt" '')"
check "auto escalate: default and escalate launch together allow" allow "$(input "$dflt && $esc" "$none")"
check "auto escalate: worker-start escalate values allow" allow \
  "$(input 'orca orchestration worker-start --task t --agent claude --model claude-opus-5-5 --effort high' '')"
check "auto escalate: worker-start default values allow" allow \
  "$(input 'orca orchestration worker-start --agent claude --model claude-sonnet-5-5 --effort medium' '')"
check "auto escalate: other model denies" deny "$(input 'orca terminal create --command "claude --model claude-haiku-5-5 --effort high"' "$mans")"
check "auto escalate: escalate model with default effort denies" deny "$(input 'orca terminal create --command "claude --model claude-opus-5-5 --effort medium"' "$mans")"
check "auto escalate: default model with escalate effort denies" deny "$(input 'orca terminal create --command "claude --model claude-sonnet-5-5 --effort high"' "$mans")"
check "auto escalate: missing effort denies" deny "$(input 'orca terminal create --command "claude --model claude-opus-5-5"' "$mans")"
check "auto escalate: other agent denies" deny "$(input 'orca terminal create --command "codex -m claude-opus-5-5 -c model_reasoning_effort=high"' "$mans")"
check "auto escalate: worker-start other agent denies" deny \
  "$(input 'orca orchestration worker-start --agent codex --model claude-opus-5-5 --effort high' "$mans")"
check "auto escalate: second launch mismatching denies" deny "$(input "$esc && orca terminal create --command 'claude --model x --effort high'" "$mans")"
msg=$(reason "$(input 'orca terminal create --command "claude --model claude-haiku-5-5 --effort low"' "$mans")")
has "auto escalate: reason lists both tiers" "$msg" \
  "sets launch mode auto, which allows only agent claude, model claude-sonnet-5-5, and effort medium, or agent claude, model claude-opus-5-5, and effort high, and this launch has"
result "auto escalate: reason has no Model clause" no "$(printf '%s' "$msg" | grep -qF 'header `Model`' && echo yes || echo no)"
has "auto escalate: reason names the flags" "$msg" "Second tier: Claude: --model claude-opus-5-5 --effort high"
has "auto escalate: reason forbids editing the file" "$msg" "To use other values, ask the user; do not edit .orca-dev-ops.json to get around this."
printf '%s\n' '{"launch":{"mode":"auto","agent":"codex","model":"gpt-sol","effort":"xhigh","escalate":{"model":"gpt-sol-pro","effort":"max"}}}' > "$cfg"
check "auto escalate codex agent: escalate values allow without a transcript" allow "$(input "$cxesc" '')"
check "auto escalate codex agent: escalate values allow without answers" allow "$(input "$cxesc" "$none")"
check "auto escalate codex agent: default values allow" allow \
  "$(input "orca terminal create --command \"$codex_cmd -m gpt-sol -c model_reasoning_effort=xhigh\"" '')"
check "auto escalate codex agent: worker-start escalate values allow" allow \
  "$(input 'orca orchestration worker-start --agent codex --model gpt-sol-pro --effort max' '')"
check "auto escalate codex agent: claude with escalate values denies" deny \
  "$(input 'orca terminal create --command "claude --model gpt-sol-pro --effort max"' '')"
check "auto escalate codex agent: other effort denies" deny \
  "$(input "orca terminal create --command \"$codex_cmd -m gpt-sol-pro -c model_reasoning_effort=xhigh\"" '')"

# launch.escalate with mode ask makes the file invalid: ask mode applies, the escalate tier is not recognized.
printf '%s\n' '{"launch":{"mode":"ask","agent":"claude","model":"claude-sonnet-5-5","effort":"medium","escalate":{"model":"claude-opus-5-5","effort":"high"}}}' > "$cfg"
check "escalate with mode ask: matching launch without answers denies" deny "$(input "$dflt" "$none")"
check "escalate with mode ask: escalate launch needs all three answers" deny "$(input "$esc" "$mans")"
check "escalate with mode ask: all three answers allow" allow "$(input "$esc" "$all")"
has "escalate with mode ask: deny carries the warning" "$(reason "$(input "$esc" "$none")")" "Settings warning: Ignored $cfg"

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
