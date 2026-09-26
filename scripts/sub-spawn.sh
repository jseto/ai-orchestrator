#!/usr/bin/env bash
# Spawn a subsession: lease a worktree, base it on $DEV_BRANCH, boot pi in a
# tmux session, write/kick off the task brief, and print the handles.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_sub-common.sh
# shellcheck disable=SC1091  # followed with -x; plain runs must stay clean
source "$SCRIPT_DIR/_sub-common.sh"

# Capture the invoking pane before opening the child viewer pane. The pane ID
# remains stable even after the new pane becomes the window's active pane.
INVOKING_PANE=$(invoking_tmux_pane)
INVOKING_SESSION=""
INVOKING_COMMAND=""
if [ -n "$INVOKING_PANE" ]; then
  INVOKING_SESSION=$(tmux display-message -p -t "$INVOKING_PANE" '#S' 2>/dev/null || true)
  INVOKING_COMMAND=$(tmux display-message -p -t "$INVOKING_PANE" '#{pane_current_command}' 2>/dev/null || true)
fi

# Prefer the live Pi session that invoked this script when the default
# pi-main name is stale or the current orchestrator was auto-named by tmux.
# An explicitly configured MAIN_SESSION always wins.
if [ -z "${_SUB_MAIN_SESSION_WAS_SET:-}" ] \
   && [ -n "$INVOKING_SESSION" ] \
   && tmux has-session -t "=$INVOKING_SESSION" 2>/dev/null \
   && { ! tmux has-session -t "=$MAIN_SESSION" 2>/dev/null || [ "$INVOKING_COMMAND" = pi ]; }; then
  MAIN_SESSION=$INVOKING_SESSION
fi
# Keep the original pane as the notice target when it belongs to the selected
# session. An explicitly configured MAIN_PANE always wins.
if [ -z "${MAIN_PANE:-}" ] \
   && [ -n "$INVOKING_PANE" ] \
   && [ "$INVOKING_SESSION" = "$MAIN_SESSION" ]; then
  MAIN_PANE=$INVOKING_PANE
fi
# Make the selected targets available both to this process and to the child
# tmux session created below.
export MAIN_SESSION MAIN_PANE

usage() { die "usage: ${0##*/} <task-name> <repo-dir> [brief-file]"; }

need git tmux treehouse jq realpath
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then usage; fi

TASK=$1
REPO=$2
BRIEF_SRC=${3:-}

if [ -n "$BRIEF_SRC" ]; then
  [ -f "$BRIEF_SRC" ] || die "no such brief file: $BRIEF_SRC"
  BRIEF_SRC=$(realpath "$BRIEF_SRC")
fi

valid_task "$TASK" || usage
ROOT=$(repo_root "$REPO")
SESS=$(session_of "$TASK")
TF=$(task_file "$ROOT" "$TASK")
RF=$(report_file "$ROOT" "$TASK")

cd "$ROOT"

WT=""
CHILD_AGENT_DIR=""
SESS_STARTED=0
cleanup_on_error() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    if [ "$SESS_STARTED" = 1 ]; then
      tmux kill-session -t "$SESS" 2>/dev/null || true
    fi
    [ -n "$CHILD_AGENT_DIR" ] && rm -rf "$CHILD_AGENT_DIR"
    if [ -n "$WT" ]; then
      treehouse return --force "$WT" >/dev/null 2>&1 || true
    fi
    warn "spawn failed; released the leased worktree"
  fi
  exit "$status"
}
trap cleanup_on_error EXIT

# Refuse obvious double-bookings before touching anything.
if [ -n "$(wt_for_task "$TASK" "$ROOT")" ]; then
  die "task '$TASK' already holds a worktree lease — check ${0%/*}/sub-status.sh $TASK"
fi
if tmux has-session -t "$SESS" 2>/dev/null; then
  die "tmux session $SESS already exists — retire it first (${0%/*}/sub-retire.sh $TASK)"
fi

# 1. Lease a worktree (path on stdout, banners on stderr).
info "Leasing worktree for '$TASK' in $ROOT ..."
WT=$(treehouse get --lease --lease-holder "$TASK")
[ -n "$WT" ] || die "treehouse returned no worktree path"
WT=$(cd "$WT" && pwd -P)

# 2. Work on a unique task branch cut from the requested development base.
#    The main checkout commonly owns development, so switching to it here
#    would fail (or, worse, allow commits directly on the shared branch).
BRANCH=$(task_branch "$ROOT" "$TASK")
git -C "$WT" fetch --quiet origin "$DEV_BRANCH" 2>/dev/null || true
if git -C "$WT" rev-parse --verify --quiet "origin/$DEV_BRANCH" >/dev/null; then
  BASE_REF="origin/$DEV_BRANCH"
else
  BASE_REF="$DEV_BRANCH"
fi
git -C "$WT" switch -c "$BRANCH" "$BASE_REF" \
  || die "cannot create $BRANCH from $BASE_REF"

# 3. Task brief in the MAIN checkout (gitignored scratch, outside the worktree).
mkdir -p "$(scratch_root "$ROOT")/tasks" "$(scratch_root "$ROOT")/reports"
if [ -n "$BRIEF_SRC" ]; then
  if [ "$BRIEF_SRC" != "$(realpath "$TF" 2>/dev/null || echo "$TF")" ]; then
    cp "$BRIEF_SRC" "$TF"
  fi
elif [ ! -f "$TF" ]; then
  cat > "$TF" <<EOF
# Task: $TASK

Requirements: (the orchestrator created this stub — fill it in before the
child gets far; the child was told this file is the source of truth.)
EOF
  warn "no brief given; created stub at $TF — fill it in now"
fi

# 4. Build the kickoff prompt. It is handed to pi as its initial message
#    argument (absolute paths, since the child's cwd is the worktree but the
#    brief lives in the main checkout) instead of being typed into the
#    composer: a send-keys kickoff races pi's startup, and a dropped Enter
#    leaves the prompt stranded in the input box — a child that never starts.
KICKOFF="Read the task brief at $TF and complete the full flow (atomic specs, TDD tests passing, code audit). Commit your work on the current branch ($BRANCH). Push your branch to origin and create a pull request against development using gh pr create. Write your report to $RF (what you changed, test results, PR link, notes). Do not use notify, ntfy, or any other external notification mechanism. When done or blocked, use only $SCRIPT_DIR/sub-report.sh $TASK \"DONE: <one-line summary> (PR #...)\" (or BLOCKED: <reason>)"

# 5. Boot pi in a named tmux session, rooted in the worktree. The isolated
#    agent directory deliberately provides no extensions or packages.
CHILD_AGENT_DIR=$(prepare_child_agent_dir "$(scratch_root "$ROOT")/agent-dirs/$TASK")
# The -e assignments are intentional: tmux servers may predate this shell's
# environment, so inheriting the notice targets is not sufficient.
tmux new-session -d -s "$SESS" -c "$WT" \
  -e "MAIN_SESSION=$MAIN_SESSION" \
  -e "MAIN_PANE=$MAIN_PANE" \
  -e "PI_CODING_AGENT_DIR=$CHILD_AGENT_DIR" \
  || die "could not create tmux session $SESS"
SESS_STARTED=1
sleep 0.5
printf -v PI_LAUNCH '%q -n %q --no-extensions %q' "$PI_BIN" "$TASK" "$KICKOFF"
# tmux_send_line retries the Enter (and re-types the line) until the pane shows
# it was picked up, so a dropped keystroke cannot leave the child idle. An
# unconfirmed launch fails the spawn: reporting handles for a child that never
# started is worse than a loud failure (the trap above releases everything).
tmux_send_line "$SESS" "$PI_LAUNCH" \
  || die "could not confirm the kickoff was submitted to $SESS — not reporting an idle child"
info "Waiting ${PI_BOOT_DELAY}s for pi to boot ..."
sleep "$PI_BOOT_DELAY"

# 6. Live viewer pane in the invoking tmux window (falling back to a
#    detached viewer window when there is no invoking pane). A viewer problem
#    must never fail the spawn: the EXIT trap would release the worktree.
#    Skippable with SUB_SPAWN_NO_VIEWER=1.
VIEWER=$(open_viewer_window "$TASK" "$SESS" "$INVOKING_PANE" || true)

info ""
info "Subsession spawned:"
info "  task:     $TASK"
info "  worktree: $WT"
info "  branch:   $BRANCH"
info "  session:  $SESS"
if [ -n "$VIEWER" ]; then
  info "  viewer:   pane/window in session $VIEWER"
fi
info "  brief:    $TF"
info "  report:   $RF"
info "  scripts:  $SCRIPT_DIR"
info ""
info "--- pane tail ---"
pane_tail "$TASK" 15
