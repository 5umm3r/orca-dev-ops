#!/bin/sh
# Shared role detection for the Orca master/child workflow hooks.
# child  = a session whose cwd is inside an Orca task worktree (~/orca/workspaces/...)
# master = a session whose cwd is inside an Orca-registered repository checkout
ORCA_WS="$HOME/orca/workspaces"
ORCA_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/orca-dev-ops/repos"

orca_repos() {
  mkdir -p "$(dirname "$ORCA_CACHE")" 2>/dev/null
  if [ ! -s "$ORCA_CACHE" ] || [ -n "$(find "$ORCA_CACHE" -mmin +1440 2>/dev/null)" ]; then
    out=$(orca repo list 2>/dev/null | awk 'NF>=3{ $1=""; $2=""; sub(/^[[:space:]]+/, ""); print }')
    [ -n "$out" ] && printf '%s\n' "$out" > "$ORCA_CACHE"
  fi
  cat "$ORCA_CACHE" 2>/dev/null
}

orca_under() { case "$1/" in "$2"/*) return 0 ;; esac; return 1; }

orca_repo_of() {
  orca_repos | while IFS= read -r r; do
    if [ -n "$r" ] && orca_under "$1" "$r"; then printf '%s\n' "$r"; break; fi
  done
}

orca_role() {
  [ -z "$1" ] && { echo none; return; }
  orca_under "$1" "$ORCA_WS" && { echo child; return; }
  [ -n "$(orca_repo_of "$1")" ] && { echo master; return; }
  echo none
}
