#!/usr/bin/env bash
# Shared helpers for the subsession scripts (see AGENTS.md, "pi sessions").
# Source this file; don't execute it.
# shellcheck shell=bash

: "${DEV_BRANCH:=development}"   # base branch for worktrees
# Keep this distinction so callers can fall back to the invoking tmux session
# only when MAIN_SESSION was not explicitly configured.
_SUB_MAIN_SESSION_WAS_SET=${MAIN_SESSION+x}
: "${MAIN_SESSION:=pi-main}"     # orchestrator tmux session
: "${MAIN_PANE:=}"               # stable orchestrator pane ID, when known
: "${PI_BIN:=pi}"                # pi executable
: "${PI_BOOT_DELAY:=3}"          # seconds to wait for the pi TUI to boot
: "${SCRATCH_DIR:=tmp/pi-sub}"      # gitignored scratch dir in the main checkout

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing command: $c"
  done
}

valid_task() { [[ "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; }

# Echo the git toplevel of a directory (default: cwd), or die.
repo_root() {
  local r="${1:-$PWD}"
  [ -e "$r" ] || die "no such path: $r"
  git -C "$r" rev-parse --show-toplevel 2>/dev/null || die "not a git repository: $r"
}

# tmux session name for a task
session_of() { printf 'pi-%s' "$1"; }

# Echo the tmux session containing the invoking pane, when this script was
# launched from tmux. An empty result means there is no usable invoking pane.
invoking_tmux_session() {
  [ -n "${TMUX:-}" ] || return 0
  if [ -n "${TMUX_PANE:-}" ]; then
    tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null || true
  else
    tmux display-message -p '#S' 2>/dev/null || true
  fi
}

# Echo the stable pane ID containing the invoking shell, when launched from
# tmux. Pane IDs remain tied to the original pane even if another window is
# selected later (for example, by open_viewer_window).
invoking_tmux_pane() {
  [ -n "${TMUX:-}" ] || return 0
  if [ -n "${TMUX_PANE:-}" ]; then
    tmux display-message -p -t "$TMUX_PANE" '#{pane_id}' 2>/dev/null || true
  else
    tmux display-message -p '#{pane_id}' 2>/dev/null || true
  fi
}

# Echo the leased worktree path for a task (lease holder == task name),
# or print nothing when the task holds no lease.
wt_for_task() { # $1=task $2=repo-root
  ( cd "$2" && treehouse status --json 2>/dev/null \
      | jq -r --arg h "$1" '[.[] | select(.lease_holder == $h) | .path][0] // empty' \
    ) || true
}

branch_exists() { git -C "$1" show-ref --verify --quiet "refs/heads/$2"; }

# Pick an unused local task branch. A linked worktree cannot check out a branch
# already checked out by another worktree, so never assume task/<name> is free.
task_branch() { # $1=repo-root $2=task
  local root=$1 task=$2 candidate suffix=2
  candidate="task/$task"
  while branch_exists "$root" "$candidate"; do
    candidate="task/$task-$suffix"
    suffix=$((suffix + 1))
  done
  printf '%s' "$candidate"
}

# Shared file locations for the brief/report exchange with a child. They live
# in a gitignored scratch dir inside the MAIN checkout (outside any worktree,
# so they survive 'treehouse return --force') and are deleted when the task is
# retired (see sub-retire.sh). The default `tmp/pi-sub/` is covered by the
# global excludes file (~/.config/git/ignore); set SCRATCH_DIR to relocate it,
# but keep it gitignored. Do NOT use `.pi/` — that is pi's own config dir.
scratch_root() { printf '%s/%s' "$1" "$SCRATCH_DIR"; }
task_file()    { printf '%s/%s/tasks/%s.md'    "$1" "$SCRATCH_DIR" "$2"; }
report_file()  { printf '%s/%s/reports/%s.md'  "$1" "$SCRATCH_DIR" "$2"; }
patch_file()   { printf '%s/%s/reports/%s.patch' "$1" "$SCRATCH_DIR" "$2"; }

# Prepare an isolated Pi agent directory for a child. It preserves the user's
# other settings, skills, prompts, themes, packages, and extensions, while
# excluding the notify extension, Telegram-specific extensions, and the
# pi-telegram package. The directory lives in the gitignored scratch dir of
# the main checkout (outside the worktree) and is removed on retirement.
prepare_child_agent_dir() { # $1=destination dir; echoes dir
  local agent_dir=$1 source name
  rm -rf "$agent_dir"
  mkdir -p "$agent_dir/extensions"

  if [ -f "$HOME/.pi/agent/settings.json" ]; then
    jq 'if (.packages | type) == "array" then .packages |= map(select(if type == "string" then (test("pi-telegram"; "i") | not) else true end)) else . end' \
      "$HOME/.pi/agent/settings.json" > "$agent_dir/settings.json"
  else
    printf '{}\n' > "$agent_dir/settings.json"
  fi

  for name in auth.json keybindings.json models.json models-store.json trust.json AGENTS.md AGENTS.override.md SYSTEM.md APPEND_SYSTEM.md; do
    source="$HOME/.pi/agent/$name"
    if [ -e "$source" ] || [ -L "$source" ]; then
      ln -s "$source" "$agent_dir/$name"
    fi
  done
  for name in npm node_modules skills prompts themes; do
    source="$HOME/.pi/agent/$name"
    if [ -e "$source" ] || [ -L "$source" ]; then
      ln -s "$source" "$agent_dir/$name"
    fi
  done
  for source in "$HOME/.pi/agent/extensions"/*; do
    [ -e "$source" ] || [ -L "$source" ] || continue
    name=$(basename "$source")
    case "$name" in
      notify*|telegram*) continue ;;
    esac
    ln -s "$source" "$agent_dir/extensions/$name"
  done

  printf '%s\n' "$agent_dir"
}

# Open a live viewer for a child session. When launched from tmux, prefer a
# pane in the invoking window; otherwise retain the old viewer-window
# fallback, but create it detached so a non-tmux invocation does not change
# the selected window. Best effort — every failure is silent and non-fatal;
# echoes the target session name on success, nothing on skip/failure. Panes
# inherit $TMUX, so the nested attach needs it cleared — and when the child
# session dies, the attach client exits and tmux closes the pane/window.
open_viewer_window() { # $1=task $2=child-session $3=invoking-pane (optional)
  local task=$1 child=$2 invoking_pane=${3:-} anchor target=$MAIN_SESSION wins
  [ "${SUB_SPAWN_NO_VIEWER:-0}" = 1 ] && return 0
  # An explicitly configured MAIN_PANE is the stable viewer anchor. Otherwise,
  # prefer the pane that invoked the spawn, and report that pane's session.
  anchor=${MAIN_PANE:-$invoking_pane}
  if [ -n "$anchor" ] \
     && tmux display-message -p -t "$anchor" '#{pane_id}' >/dev/null 2>&1; then
    target=$(tmux display-message -p -t "$anchor" '#S' 2>/dev/null) || return 0
    tmux split-window -h -t "$anchor" \
      "env -u TMUX tmux attach -t $child" >/dev/null 2>&1 || return 0
    tmux set-window-option -t "$target" main-pane-width 50% >/dev/null 2>&1 || true
    tmux select-layout -t "$target" main-vertical >/dev/null 2>&1 || true
    tmux resize-pane -t "$anchor" -x 50% >/dev/null 2>&1 || true
    printf '%s\n' "$target"
    return 0
  fi
  tmux has-session -t "=$target" 2>/dev/null || return 0
  wins=$(tmux list-windows -t "=$target:" -F '#W' 2>/dev/null) || return 0
  if grep -Fxq -- "$task" <<<"$wins"; then return 0; fi
  tmux new-window -d -t "=$target:" -n "$task" \
    "env -u TMUX tmux attach -t $child" >/dev/null 2>&1 || return 0
  printf '%s\n' "$target"
}

# Tail of the task's tmux pane (trailing blank lines dropped), or a note
# when it isn't running.
pane_tail() { # $1=task $2=lines
  local sess
  sess=$(session_of "$1")
  if tmux has-session -t "$sess" 2>/dev/null; then
    tmux capture-pane -t "$sess" -p | awk -v n="$2" '
      { if ($0 ~ /[^[:space:]]/) last=NR; line[NR]=$0 }
      END { start=last-n+1; if (start<1) start=1
            for (i=start; i<=last; i++) print line[i] }'
  else
    info "(tmux session $sess is not running)"
  fi
}
