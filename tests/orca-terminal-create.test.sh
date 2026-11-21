#!/bin/sh
# Tests for scripts/orca-terminal-create.sh with a stub orca that scripts `terminal create`,
# `terminal list`, and `terminal read`.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"
script="$root/scripts/orca-terminal-create.sh"
export ORCA_STUB_LOG="$tmp/calls"

# create [<option>...]: runs the script with the required options plus <option>...; prints
# "<exit code> <create calls> <close calls>" and keeps stdout in $tmp/out, stderr in $tmp/err.
# It runs in the empty directory $tmp/cwd, which must stay empty (see the end).
mkdir -p "$tmp/cwd"
create() {
  : > "$ORCA_STUB_LOG"
  (cd "$tmp/cwd" && sh "$script" --worktree 'name:cc-x' --title agent --command 'claude --model m' \
    --interval 0 --timeout 1 "$@") > "$tmp/out" 2> "$tmp/err"
  printf '%s %s %s' "$?" "$(grep -c '^terminal create' "$ORCA_STUB_LOG")" "$(grep -c '^terminal close' "$ORCA_STUB_LOG")"
}
handles() { tr '\n' ' ' < "$tmp/out" | sed 's/ $//'; }
said() { grep -q -- "$1" "$tmp/err" && echo yes || echo no; }

result "immediate success" "0 1 0" "$(ORCA_STUB_TERMINALS='none agent' create)"
result "immediate success: handle on stdout" "term_1" "$(handles)"
result "create gets the given options" 1 "$(grep -c -- '^terminal create --worktree name:cc-x --title agent --command claude --model m --json' "$ORCA_STUB_LOG")"
result "timeout, then the agent appears" "0 1 0" "$(ORCA_STUB_CREATE=timeout ORCA_STUB_TERMINALS='none none agent' create)"
result "timeout, then the agent appears: handle" "term_1" "$(handles)"
result "timeout, then the agent appears: said so" yes "$(said 'create timed out')"
result "timeout on stderr, then the agent appears" "0 1 0" "$(ORCA_STUB_CREATE=timeout-stderr ORCA_STUB_TERMINALS='none agent' create)"
result "timeout, then a shell, then the agent" "0 1 0" "$(ORCA_STUB_CREATE=timeout ORCA_STUB_TERMINALS='none shell shell agent' create)"
result "timeout, then a shell, then the agent: handle" "term_1" "$(handles)"
result "agent by header only" "0 1 0" "$(ORCA_STUB_TERMINALS='none header' create)"
result "custom --expect" "5 1 0" "$(ORCA_STUB_TERMINALS='none header' create --expect 'OpenAI Codex')"
result "timeout, nothing, one recreate, then the agent" "0 2 0" "$(ORCA_STUB_CREATE=timeout ORCA_STUB_TERMINALS='none none none none agent' create --timeout 0)"
result "timeout, nothing, one recreate: handle" "term_1" "$(handles)"
result "timeout, nothing, one recreate: said so" yes "$(said 'creating once more')"
result "old shell turns into the agent: no recreate" "0 1 0" "$(ORCA_STUB_CREATE=timeout ORCA_STUB_TERMINALS='shell shell agent' create)"
result "old shell turns into the agent: its handle" "term_1" "$(handles)"
result "one agent after the recreate, waits the full time" "0 2 0" "$(ORCA_STUB_CREATE=timeout ORCA_STUB_TERMINALS='none' ORCA_STUB_TERMINALS_RECREATED='agent' create)"
result "late second agent after the recreate" "4 2 0" "$(ORCA_STUB_CREATE=timeout ORCA_STUB_TERMINALS='none' ORCA_STUB_TERMINALS_RECREATED='none agent agent,agent' create)"
result "late second agent after the recreate: both handles" "term_1 term_2" "$(handles)"
result "nothing after the recreate" "3 2 0" "$(ORCA_STUB_CREATE=timeout ORCA_STUB_TERMINALS='none' create --timeout 0)"
result "nothing after the recreate: no stdout" "" "$(handles)"
result "nothing after the recreate: reason" yes "$(said 'after two creates')"
result "agent already present" "4 0 0" "$(ORCA_STUB_TERMINALS='agent' create)"
result "agent already present: handle" "term_1" "$(handles)"
result "agent by header already present" "4 0 0" "$(ORCA_STUB_TERMINALS='shell,header' create)"
result "agent by header already present: only the agent" "term_2" "$(handles)"
result "shell already present: not an agent" "0 1 0" "$(ORCA_STUB_TERMINALS='shell shell,agent' create)"
result "shell already present: the new agent" "term_2" "$(handles)"
result "duplicates after the wait" "4 1 0" "$(ORCA_STUB_CREATE=timeout ORCA_STUB_TERMINALS='none none agent,agent' create)"
result "duplicates after the wait: every handle" "term_1 term_2" "$(handles)"
result "duplicates after the wait: reason" yes "$(said 'orca terminal close --terminal')"
result "shell never becomes an agent" "5 1 0" "$(ORCA_STUB_CREATE=timeout ORCA_STUB_TERMINALS='none shell' create)"
result "shell never becomes an agent: handle" "term_1" "$(handles)"
result "created handle never lists" "5 1 0" "$(ORCA_STUB_TERMINALS='none' create)"
result "created handle never lists: handle" "term_1" "$(handles)"
result "other create error" "1 1 0" "$(ORCA_STUB_CREATE=other ORCA_STUB_TERMINALS='none' create)"
result "other create error: receipt on stdout" '"not_found"' "$(jq '.error.code' "$tmp/out")"
result "list fails at the start" "1 0 0" "$(ORCA_STUB=fail create)"

# --- launch hooks: agent.launch.before of running development plugins, through `plugin dev hook`
# sent [<n>]: the --command of the <n>th (default first) `terminal create` call.
sent() {
  grep '^terminal create' "$ORCA_STUB_LOG" | sed -n "${1:-1}p" \
    | sed 's/^terminal create --worktree name:cc-x --title agent --command //; s/ --json$//'
}
hooks() { grep -c '^plugin dev hook' "$ORCA_STUB_LOG"; }
settings="$tmp/child settings.json"; printf '{ "agentPushNotifEnabled": false }\n' > "$settings"
claude="claude --dangerously-skip-permissions --settings '$settings' --model m --effort e"
codex="codex -a never -s workspace-write --add-dir '/w/.git/worktrees/cx x' -c sandbox_workspace_write.network_access=true -m m -c model_reasoning_effort=e"

result "no plugins: the command as given" "0 1 0" "$(ORCA_STUB_TERMINALS='none agent' create)"
result "no plugins: no hook run" 0 "$(hooks)"
result "plugin list fails: still creates" "0 1 0" "$(ORCA_STUB_PLUGINS=fail ORCA_STUB_TERMINALS='none agent' create)"
result "plugin list fails: the command as given" "claude --model m" "$(sent)"
result "plugin list fails: said so" yes "$(said 'launch hooks not applied')"

result "claude through the panel hook" "0 1 0" "$(ORCA_STUB_PLUGINS=panel ORCA_STUB_TERMINALS='none agent' create --command "$claude")"
result "claude: one hook run" 1 "$(hooks)"
result "claude: the hook gets the agent and the command" 1 \
  "$(grep -c "^plugin dev hook local.task-panel agent.launch.before --data .*\"agent\":\"claude\".*--model m --effort e" "$ORCA_STUB_LOG")"
result "claude: the transformed command with its env" \
  "env CLAUDE_CODE_ENABLE_TODO_TOOLS='1' claude --append-system-prompt 'X' $(echo "$claude" | sed 's/^claude //')" "$(sent)"
result "claude: said which plugin" yes "$(said 'launch hooks applied: local.task-panel')"

result "settings merged inline: accepted" "0 1 0" "$(ORCA_STUB_PLUGINS=panel ORCA_STUB_HOOK=merge ORCA_STUB_TERMINALS='none agent' create --command "$claude")"
result "settings merged inline: keeps the child settings" yes \
  "$(sent | grep -qF '"agentPushNotifEnabled":false,"statusLine"' && echo yes || echo no)"
result "settings merged inline: no file path left" no "$(sent | grep -qF "$settings" && echo yes || echo no)"
result "settings lost: falls back" "0 1 0" "$(ORCA_STUB_PLUGINS=panel ORCA_STUB_HOOK=lose ORCA_STUB_TERMINALS='none agent' create --command "$claude")"
result "settings lost: the command as given" "$claude" "$(sent)"
result "settings lost: names the key" yes "$(said 'agentPushNotifEnabled')"

result "codex through the panel hook" "0 1 0" "$(ORCA_STUB_PLUGINS=panel ORCA_STUB_TERMINALS='none agent' create --command "$codex")"
result "codex: the transformed command, no env" \
  "codex -c 'developer_instructions=\"X\"' $(echo "$codex" | sed 's/^codex //')" "$(sent)"

result "a hook drops flags: falls back" "0 1 0" "$(ORCA_STUB_PLUGINS=panel ORCA_STUB_HOOK=drop ORCA_STUB_TERMINALS='none agent' create --command "$claude")"
result "a hook drops flags: the command as given" "$claude" "$(sent)"
result "a hook drops flags: names a lost word" yes "$(said 'dropped --dangerously-skip-permissions')"
result "a hook drops a short flag its text contains: the command as given" "$codex" \
  "$(ORCA_STUB_PLUGINS=panel ORCA_STUB_HOOK=shadow ORCA_STUB_TERMINALS='none agent' create --command "$codex" >/dev/null; sent)"
result "a hook drops a short flag its text contains: names it" yes "$(said 'dropped -a')"
result "a hook denies: the command as given" "$claude" \
  "$(ORCA_STUB_PLUGINS=panel ORCA_STUB_HOOK=deny ORCA_STUB_TERMINALS='none agent' create --command "$claude" >/dev/null; sent)"
result "a hook fails: the command as given" "$claude" \
  "$(ORCA_STUB_PLUGINS=panel ORCA_STUB_HOOK=fail ORCA_STUB_TERMINALS='none agent' create --command "$claude" >/dev/null; sent)"
result "a hook fails: said so" yes "$(said 'local.task-panel')"

result "two plugins chain" "0 1 0" "$(ORCA_STUB_PLUGINS=two ORCA_STUB_TERMINALS='none agent' create --command "$claude")"
result "two plugins chain: both run" 2 "$(hooks)"
result "two plugins chain: the second sees the first's command" 1 \
  "$(grep '^plugin dev hook local.second' "$ORCA_STUB_LOG" | grep -c "append-system-prompt 'X'")"
result "two plugins chain: the second sees the first's env" 1 \
  "$(grep '^plugin dev hook local.second' "$ORCA_STUB_LOG" | grep -c '"CLAUDE_CODE_ENABLE_TODO_TOOLS":"1"')"
result "idle plugin: not run" 0 "$(ORCA_STUB_PLUGINS=idle ORCA_STUB_TERMINALS='none agent' create --command "$claude" >/dev/null; hooks)"
result "installed plugin: not run" 0 "$(ORCA_STUB_PLUGINS=installed ORCA_STUB_TERMINALS='none agent' create --command "$claude" >/dev/null; hooks)"
result "installed plugin: named as not applied" yes "$(said 'andoshin11.milestone')"
result "not claude or codex: no hook run" 0 \
  "$(ORCA_STUB_PLUGINS=panel ORCA_STUB_TERMINALS='none agent' create --command 'npm test' >/dev/null; hooks)"
result "recreate: hooks run once" "0 2 1" \
  "$(ORCA_STUB_PLUGINS=panel ORCA_STUB_CREATE=timeout ORCA_STUB_TERMINALS='none none none none agent' create --timeout 0 --command "$claude" | sed 's/ 0$//') $(hooks)"
result "recreate: both creates send the same command" yes "$([ "$(sent 1)" = "$(sent 2)" ] && echo yes || echo no)"
result "hooks, then a shell that never becomes an agent" "5 1 0" \
  "$(ORCA_STUB_PLUGINS=panel ORCA_STUB_CREATE=timeout ORCA_STUB_TERMINALS='none shell' create --command "$claude")"
result "hooks, then a shell that never becomes an agent: its handle" "term_1" "$(handles)"
result "hooks, then duplicates: every handle" "4 term_1 term_2" \
  "$(ORCA_STUB_PLUGINS=panel ORCA_STUB_CREATE=timeout ORCA_STUB_TERMINALS='none none agent,agent' create --command "$claude" | cut -d' ' -f1) $(handles)"
result "agent already present: no hook run" 0 "$(ORCA_STUB_PLUGINS=panel ORCA_STUB_TERMINALS='agent' create --command "$claude" >/dev/null; hooks)"

# usage [<arg>...]: exit code of the script run with exactly <arg>...
usage() { sh "$script" "$@" >/dev/null 2>&1; echo "$?"; }
result "no arguments" 64 "$(usage)"
result "missing --command" 64 "$(usage --worktree w --title t)"
result "unknown option" 64 "$(usage --worktree w --title t --command c --bogus 1)"
result "missing option value" 64 "$(usage --worktree w --title t --command)"
result "non-numeric --timeout" 64 "$(usage --worktree w --title t --command c --timeout soon)"
result "empty --interval" 64 "$(usage --worktree w --title t --command c --interval '')"
result "no file left in the working directory" "" "$(ls -A "$tmp/cwd")"

exit "$fail"
