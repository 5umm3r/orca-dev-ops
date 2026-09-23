#!/bin/sh
# Shared applicability and role detection for the Orca master/child workflow hooks.
#
# These hooks prevent misoperation by string and path matching; they are not a sandbox.
# They apply to Claude sessions only: Codex is limited by its own sandbox flags and the
# AGENTS.md rules.
#
# Applicability: a path is in scope when its git checkout has the orca-worktree-rules marker
# in .claude/CLAUDE.md or AGENTS.md at the top level. Out of scope, the role is `none` and the
# hooks do nothing, whatever Orca says.
# Role in scope: Orca (`orca worktree current --json`) and git (git dir vs common dir) each
# say main checkout (`master`) or linked worktree (`child`). One answer is enough; if they
# disagree, or neither answers, the role is `unknown` and writes are blocked.
ORCA_MARKER='orca-worktree-rules:start'

orca_under() { case "$1/" in "$2"/*) return 0 ;; esac; return 1; }

# orca_cli <args>: the orca CLI, bounded by timeout(1) when one is installed.
orca_cli() {
  command -v orca >/dev/null 2>&1 || return 127
  if command -v timeout >/dev/null 2>&1; then timeout 5 orca "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout 5 orca "$@"
  else orca "$@"
  fi
}

# orca_phys <absolute path>: the path with symlinks resolved in its nearest existing directory
# (the path itself may not exist yet).
orca_phys() {
  _d=$1 _rest=
  while [ ! -d "$_d" ]; do
    case "$_d" in /*/*) ;; *) _rest=$_d$_rest; _d=/; break ;; esac
    _rest=/${_d##*/}$_rest
    _d=${_d%/*}
  done
  _d=$(CDPATH= cd -P -- "$_d" 2>/dev/null && pwd -P) || _d=
  _d=${_d%/}$_rest
  printf '%s\n' "${_d:-/}"
}

# orca_abspath <path> [<base dir>]: absolute, normalized, physical form of <path>.
# ~, $HOME and ${HOME} are expanded; relative paths are resolved against <base dir>.
orca_abspath() {
  _p=$1
  case "$_p" in
  '~' | '~/'*) _p=$HOME${_p#?} ;;
  '$HOME' | '$HOME/'*) _p=$HOME${_p#?????} ;;
  '${HOME}' | '${HOME}/'*) _p=$HOME${_p#???????} ;;
  esac
  case "$_p" in /*) ;; *) _p=$(orca_phys "${2:-$PWD}")/$_p ;; esac
  _p=$(printf '%s\n' "$_p" | awk -F / '{ n = 0
    for (i = 1; i <= NF; i++) { if ($i == "" || $i == ".") continue; if ($i == "..") { if (n) n--; continue } s[++n] = $i }
    o = ""; for (i = 1; i <= n; i++) o = o "/" s[i]; print (o == "" ? "/" : o) }')
  orca_phys "$_p"
}

# orca_top <absolute physical path>: top level of the checkout containing the path, or empty.
# Uses git; when git cannot read the checkout (for example a worktree whose .git points
# nowhere), falls back to the nearest ancestor that has a .git entry.
orca_top() {
  _d=$1
  while [ ! -d "$_d" ]; do _d=${_d%/*}; [ -z "$_d" ] && _d=/; done
  _t=$(git -C "$_d" rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$_t" ]; then orca_phys "$_t"; return; fi
  while :; do
    [ -e "$_d/.git" ] && { printf '%s\n' "$_d"; return; }
    [ "$_d" = / ] && return
    _d=${_d%/*}; [ -z "$_d" ] && _d=/
  done
}

# orca_scoped <top>: true when the checkout opted into the Orca worktree rules.
orca_scoped() {
  for _f in "$1/.claude/CLAUDE.md" "$1/AGENTS.md"; do
    [ -f "$_f" ] && grep -qF "$ORCA_MARKER" "$_f" 2>/dev/null && return 0
  done
  return 1
}

# orca_git_kind <top>: master (main checkout) or child (linked worktree) from git; empty on failure.
orca_git_kind() {
  _g=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 0
  _c=$(cd "$1" 2>/dev/null && _c=$(git rev-parse --git-common-dir 2>/dev/null) && CDPATH= cd -P -- "$_c" 2>/dev/null && pwd -P) || return 0
  [ -n "$_g" ] && [ -n "$_c" ] || return 0
  if [ "$(orca_phys "$_g")" = "$_c" ]; then echo master; else echo child; fi
}

# orca_orca_kind <top>: master or child from Orca; empty when Orca fails, times out, answers
# ok:false, or answers for a different checkout.
orca_orca_kind() {
  _o=$(cd "$1" 2>/dev/null && orca_cli worktree current --json 2>/dev/null)
  _o=$(printf '%s' "$_o" | jq -r 'select(.ok == true) | .result.worktree
    | select(type == "object" and (.isMainWorktree | type) == "boolean" and (.path | type) == "string")
    | (if .isMainWorktree then "master" else "child" end) + " " + .path' 2>/dev/null)
  [ -n "$_o" ] || return 0
  [ "$(orca_phys "${_o#* }")" = "$1" ] && printf '%s\n' "${_o%% *}"
  return 0
}

# orca_role <dir>: none (out of scope), master, child, or unknown.
orca_role() {
  [ -z "$1" ] && { echo none; return; }
  _top=$(orca_top "$(orca_abspath "$1" /)")
  [ -n "$_top" ] && orca_scoped "$_top" || { echo none; return; }
  _ok=$(orca_orca_kind "$_top")
  _gk=$(orca_git_kind "$_top")
  if [ -n "$_ok" ] && [ -n "$_gk" ]; then
    if [ "$_ok" = "$_gk" ]; then echo "$_ok"; else echo unknown; fi
  elif [ -n "$_ok$_gk" ]; then echo "$_ok$_gk"
  else echo unknown
  fi
}

# orca_worktrees <dir>: physical paths of every worktree of the repository at <dir>, main first.
orca_worktrees() {
  git -C "$1" worktree list --porcelain 2>/dev/null | while IFS= read -r _l; do
    case "$_l" in "worktree "*) orca_phys "${_l#worktree }" ;; esac
  done
}
