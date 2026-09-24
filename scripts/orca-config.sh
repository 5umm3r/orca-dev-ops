#!/bin/sh
# Usage: orca-config.sh show [<path>]
# Prints the effective per-repository settings (.orca-dev-ops.json merged over the built-in
# defaults, see docs/config.md) of the repository at <path> (default: the current directory) as
# JSON on stdout. The file is always read from the main checkout, also when <path> is a linked
# worktree. stderr names the source file and, for an invalid file, why it is ignored.
# Exit codes: 0 valid or missing (defaults); 3 invalid (ignored, defaults printed); 64 usage
# error; 65 not a git repository. Requires git and jq.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/hooks/orca-lib.sh"
usage() { printf 'orca-config: %s\nusage: orca-config.sh show [<path>]\n' "$*" >&2; exit 64; }

[ "${1:-}" = show ] || usage "unknown or missing command: ${1:-}"
[ $# -le 2 ] || usage "too many arguments"
dir=${2:-.}
git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || { printf 'orca-config: not a git repository: %s\n' "$dir" >&2; exit 65; }

orca_config_load "$dir"
printf '%s\n' "$ORCA_CONFIG" | jq .
case "$ORCA_CONFIG_STATE" in
missing)
  printf 'orca-config: source: built-in defaults (%s does not exist)\n' "${ORCA_CONFIG_PATH:-$ORCA_CONFIG_FILE}" >&2 ;;
valid)
  printf 'orca-config: source: %s\n' "$ORCA_CONFIG_PATH" >&2 ;;
*)
  printf 'orca-config: source: built-in defaults (%s is invalid)\n' "$ORCA_CONFIG_PATH" >&2
  printf 'orca-config: error: %s\n' "$ORCA_CONFIG_ERROR" >&2
  exit 3 ;;
esac
