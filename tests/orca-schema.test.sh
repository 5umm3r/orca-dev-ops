#!/bin/sh
# Tests for schemas/orca-dev-ops.schema.json.
# - Shape (jq only, always runs): valid JSON, $id is the URL orca-init.sh writes, the top-level
#   keys, additionalProperties false on every object, a description on every key, and the
#   defaults of the file orca-init.sh creates.
# - Parity: every sample file gets the same verdict from the settings loader
#   (scripts/orca-config.sh show: exit 0 valid, 3 invalid) and from a JSON Schema validator:
#   check-jsonschema on PATH, else Python jsonschema (Draft 2020-12); SKIP when neither exists.
#   Regex-dialect edges (a trailing newline, Unicode spaces) are left out on purpose: they depend
#   on the validator's regex engine, not on the schema.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"
schema="$root/schemas/orca-dev-ops.schema.json"
config="$root/scripts/orca-config.sh"

# --- shape (jq only)
result "schema: valid JSON" yes "$(jq -e 'type == "object"' "$schema" >/dev/null 2>&1 && echo yes || echo no)"
result "schema: draft 2020-12" 'https://json-schema.org/draft/2020-12/schema' "$(jq -r '.["$schema"]' "$schema" 2>/dev/null)"
# The file orca-init.sh creates in a new repository: its $schema is the URL editors fetch.
init="$tmp/init"; new_repo "$init"
sh "$root/scripts/orca-init.sh" "$init" > "$tmp/init-out" 2>&1
created="$init/.orca-dev-ops.json"
url=$(jq -r '.["$schema"] // empty' "$created" 2>/dev/null)
result "schema: orca-init writes a \$schema" yes "$([ -n "$url" ] && echo yes || echo no)"
result "schema: \$id is the URL orca-init writes" "$url" "$(jq -r '.["$id"]' "$schema" 2>/dev/null)"
result "schema: the URL names this file on the main branch" yes \
  "$(case "$url" in (https://raw.githubusercontent.com/*/main/schemas/orca-dev-ops.schema.json) echo yes ;; (*) echo no ;; esac)"
result "schema: top-level properties" '$schema,launch,limits,monitor,workflow' "$(jq -r '.properties | keys | join(",")' "$schema" 2>/dev/null)"
# tree: the schema objects that describe a JSON object of the file (root, sections, tiers),
# reached through properties and $defs; not the conditional subschemas.
tree='def tree: ., (.properties // {} | .[] | tree); [., (.["$defs"] // {} | .[])] | map(tree) | map(select(.type == "object"))'
result "schema: object schemas found" 6 "$(jq "$tree | length" "$schema" 2>/dev/null)"
result "schema: additionalProperties false on every object" true "$(jq "$tree | all(.additionalProperties == false)" "$schema" 2>/dev/null)"
result "schema: a description on every key" true "$(jq "$tree | map(.properties[]) | all(has(\"description\") and (.description | length) > 0)" "$schema" 2>/dev/null)"
result "schema: monitor deprecated" true "$(jq '.properties.monitor.deprecated' "$schema" 2>/dev/null)"
result "schema: monitor keys deprecated" true "$(jq '.properties.monitor.properties | all(.deprecated == true)' "$schema" 2>/dev/null)"
result "schema: monitor says it is ignored since 1.12.0" yes "$(jq -r '.properties.monitor.description' "$schema" 2>/dev/null | grep -q 'ignored since 1\.12\.0' && echo yes || echo no)"
# Every value of the created file (except $schema) is the default the schema states for it.
result "schema: defaults equal the created file" '5|true' "$(jq -r --slurpfile s "$schema" 'del(.["$schema"])
  | [paths(type != "object") as $p | {p: $p, v: getpath($p)}]
  | "\(length)|\(all(.p as $p | .v == ($s[0] | getpath(["properties", $p[0], "properties", $p[1], "default"]))))"' "$created" 2>/dev/null)"

# --- parity samples: <name> <valid|invalid> <file content>
mkdir -p "$tmp/samples"; : > "$tmp/samples/list"; n=0
sample() { n=$((n + 1)); printf '%s\n' "$3" > "$tmp/samples/$n.json"; printf '%s\t%s\t%s\n' "$n" "$2" "$1" >> "$tmp/samples/list"; }
ea='"mode":"auto","agent":"claude","model":"claude-sonnet-5-5","effort":"medium"'
ex='"escalate":{"model":"claude-opus-5-5","effort":"high"}'
tp='"top":{"model":"claude-fable-5-2","effort":"high"}'
sample "empty object" valid '{}'
sample "created file" valid "$(cat "$created")"
sample "any \$schema string" valid '{"$schema":"./local.schema.json"}'
sample "workflow direct" valid '{"workflow":{"mode":"direct"}}'
sample "workflow worktree" valid '{"workflow":{"mode":"worktree"}}'
sample "empty workflow" valid '{"workflow":{}}'
sample "launch ask" valid '{"launch":{"mode":"ask"}}'
sample "agent, model, effort without mode" valid '{"launch":{"agent":"claude","model":"m","effort":"e"}}'
sample "auto with all three" valid '{"launch":{"mode":"auto","agent":"codex","model":"gpt-sol","effort":"xhigh"}}'
sample "semi-auto with escalate" valid '{"launch":{"mode":"semi-auto","agent":"claude","model":"m","effort":"e",'"$ex"'}}'
sample "auto with escalate and top" valid '{"launch":{'"$ea,$ex,$tp"'}}'
sample "limits at their minimums" valid '{"limits":{"maxWorktrees":1,"smallChangeFiles":0,"smallChangeLines":0}}'
sample "integral float" valid '{"limits":{"maxWorktrees":2.0}}'
sample "full example" valid '{"$schema":"https://example.com/s.json","workflow":{"mode":"direct"},"launch":{'"$ea,$ex,$tp"'},"limits":{"maxWorktrees":3,"smallChangeFiles":2,"smallChangeLines":20}}'
sample "deprecated monitor" valid '{"monitor":{"wakeOnStatus":true,"timeoutMs":60000}}'
sample "empty monitor" valid '{"monitor":{}}'
sample "top level array" invalid '[]'
sample "unknown top-level key" invalid '{"sandbox":{}}'
sample "bad workflow mode" invalid '{"workflow":{"mode":"foo"}}'
sample "numeric workflow mode" invalid '{"workflow":{"mode":1}}'
sample "unknown key under workflow" invalid '{"workflow":{"mode":"direct","x":1}}'
sample "workflow not an object" invalid '{"workflow":"direct"}'
sample "empty \$schema" invalid '{"$schema":""}'
sample "numeric \$schema" invalid '{"$schema":1}'
sample "null \$schema" invalid '{"$schema":null}'
sample "bad launch mode" invalid '{"launch":{"mode":"yolo"}}'
sample "bad agent" invalid '{"launch":{"agent":"gemini"}}'
sample "empty model" invalid '{"launch":{"model":""}}'
sample "model with a space" invalid '{"launch":{"model":"a b"}}'
sample "numeric effort" invalid '{"launch":{"effort":3}}'
sample "unknown launch key" invalid '{"launch":{"dangerouslySkipPermissions":true}}'
sample "auto alone" invalid '{"launch":{"mode":"auto"}}'
sample "semi-auto without effort" invalid '{"launch":{"mode":"semi-auto","agent":"claude","model":"m"}}'
sample "escalate with mode ask" invalid '{"launch":{"mode":"ask",'"$ex"'}}'
sample "escalate without mode" invalid '{"launch":{"agent":"claude","model":"m","effort":"e",'"$ex"'}}'
sample "escalate without effort" invalid '{"launch":{'"$ea"',"escalate":{"model":"m"}}}'
sample "escalate with an unknown key" invalid '{"launch":{'"$ea"',"escalate":{"model":"m","effort":"e","agent":"codex"}}}'
sample "escalate model with a space" invalid '{"launch":{'"$ea"',"escalate":{"model":"a b","effort":"e"}}}'
sample "escalate not an object" invalid '{"launch":{'"$ea"',"escalate":"opus"}}'
sample "escalate null" invalid '{"launch":{'"$ea"',"escalate":null}}'
sample "top without escalate" invalid '{"launch":{'"$ea,$tp"'}}'
sample "top with mode ask" invalid '{"launch":{"mode":"ask",'"$tp"'}}'
sample "top with an empty model" invalid '{"launch":{'"$ea,$ex"',"top":{"model":"","effort":"e"}}}'
sample "escalate outside launch" invalid '{"escalate":{"model":"m","effort":"e"}}'
sample "maxWorktrees 0" invalid '{"limits":{"maxWorktrees":0}}'
sample "maxWorktrees fraction" invalid '{"limits":{"maxWorktrees":2.5}}'
sample "maxWorktrees boolean" invalid '{"limits":{"maxWorktrees":true}}'
sample "negative smallChangeFiles" invalid '{"limits":{"smallChangeFiles":-1}}'
sample "string smallChangeLines" invalid '{"limits":{"smallChangeLines":"20"}}'
sample "unknown key under limits" invalid '{"limits":{"maxWorktrees":3,"x":1}}'
sample "monitor wakeOnStatus string" invalid '{"monitor":{"wakeOnStatus":"true"}}'
sample "monitor timeoutMs 0" invalid '{"monitor":{"timeoutMs":0}}'
sample "monitor not an object" invalid '{"monitor":true}'

# loader <file>: the loader's verdict through orca-config.sh show in a repository holding <file>.
lrepo="$tmp/loader"; new_repo "$lrepo"
loader() {
  cp "$1" "$lrepo/.orca-dev-ops.json"
  sh "$config" show "$lrepo" >/dev/null 2>&1 </dev/null; _rc=$?
  case $_rc in 0) echo valid ;; 3) echo invalid ;; *) echo "error $_rc" ;; esac
}
while IFS="$(printf '\t')" read -r i want name; do
  result "loader: $name" "$want" "$(loader "$tmp/samples/$i.json")"
done < "$tmp/samples/list"

# The validator: check-jsonschema (exit 0 valid, 1 invalid), else Python jsonschema.
pyval='import json, sys
from jsonschema import Draft202012Validator as V
s = json.load(open(sys.argv[1]))
if sys.argv[2] == "--check-schema":
    V.check_schema(s); sys.exit(0)
sys.exit(0 if V(s).is_valid(json.load(open(sys.argv[2]))) else 1)'
if command -v check-jsonschema >/dev/null 2>&1; then
  validator=check-jsonschema
  validate() { check-jsonschema --schemafile "$schema" "$1" >/dev/null 2>&1; }
  metaschema() { check-jsonschema --check-metaschema "$schema" >/dev/null 2>&1; }
elif python3 -c 'from jsonschema import Draft202012Validator' >/dev/null 2>&1; then
  validator="python jsonschema"
  validate() { python3 -c "$pyval" "$schema" "$1" >/dev/null 2>&1; }
  metaschema() { python3 -c "$pyval" "$schema" --check-schema >/dev/null 2>&1; }
else
  validator=
fi
if [ -z "$validator" ]; then
  echo "SKIP schema parity (no validator)"
else
  echo "validator: $validator"
  result "schema: valid against its metaschema ($validator)" yes "$(metaschema && echo yes || echo no)"
  while IFS="$(printf '\t')" read -r i want name; do
    validate "$tmp/samples/$i.json" </dev/null; _rc=$?
    case $_rc in 0) got=valid ;; 1) got=invalid ;; *) got="error $_rc" ;; esac
    result "parity: $name" "$(loader "$tmp/samples/$i.json")" "$got"
  done < "$tmp/samples/list"
fi

exit "$fail"
