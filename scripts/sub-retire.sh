#!/usr/bin/env bash
# Retire a subsession: kill its tmux session and return the worktree.
# Refuses (without --force) when unlanded work would be destroyed.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_sub-common.sh
source "$SCRIPT_DIR/_sub-common.sh"

usage() { die "usage: ${0##*/} <task-name> [repo-dir] [--force] [--keep-files]" ; }

need git tmux treehouse jq
[ "$#" -ge 1 ] && [ "$#" -le 4 ] || usage

TASK=$1
REPO=$PWD
FORCE=0
KEEP_FILES=0
for a in "$@"; do
  case "$a" in
    --force)      FORCE=1 ;;
    --keep-files) KEEP_FILES=1 ;;
  esac
done
if [ "$#" -ge 2 ] && [[ "$2" != --* ]]; then REPO=$2; fi

valid_task "$TASK" || usage
ROOT=$(repo_root "$REPO")
SESS=$(session_of "$TASK")

cd "$ROOT"
WT=$(wt_for_task "$TASK" "$ROOT")
[ -n "$WT" ] || die "no worktree leased for '$TASK' (in $ROOT)"

# A branch is "published" (safe to retire) when its tip is already reachable
# from a remote branch, i.e. the task branch was pushed for a PR or the work
# was merged into the remote development branch. The remote copy is durable,
# so returning the worktree cannot lose it.
is_published() {
  local branch=$1 tip
  tip=$(git -C "$WT" rev-parse HEAD)
  if git -C "$ROOT" rev-parse --verify --quiet "origin/$DEV_BRANCH" >/dev/null \
     && git -C "$ROOT" merge-base --is-ancestor "$tip" "origin/$DEV_BRANCH" 2>/dev/null; then
    return 0
  fi
  if git -C "$ROOT" show-ref --verify --quiet "refs/remotes/origin/$branch" \
     && git -C "$ROOT" merge-base --is-ancestor "$tip" "origin/$branch" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Safety: 'treehouse return --force' clean-resets the worktree.
if [ "$FORCE" != 1 ]; then
  BRANCH=$(git -C "$WT" branch --show-current || true)
  DIRTY=$(git -C "$WT" status --porcelain | wc -l)
  if [ -n "$BRANCH" ] && [ "$BRANCH" != "$DEV_BRANCH" ]; then
    UNLANDED=$(git -C "$WT" log --oneline "$DEV_BRANCH"..HEAD | wc -l)
  else
    UNLANDED=0
  fi
  if [ "$DIRTY" -gt 0 ]; then
    warn "refusing to destroy uncommitted work: $DIRTY uncommitted file(s) in $WT"
    info "commit & push first:  ${0%/*}/sub-land.sh $TASK"
    info "then retry:  ${0##*/} $TASK --force   (only after publishing, or to discard)"
    exit 1
  fi
  if [ "$UNLANDED" -gt 0 ] && ! is_published "$BRANCH"; then
    warn "refusing to destroy unpublished work: $UNLANDED commit(s) on '$BRANCH' not on $DEV_BRANCH or any origin branch"
    info "publish first:  push the branch and open a PR (see ${0%/*}/sub-land.sh $TASK)"
    info "then retry:    ${0##*/} $TASK --force   (only after publishing, or to discard)"
    exit 1
  fi
fi

if tmux has-session -t "$SESS" 2>/dev/null; then
  tmux kill-session -t "$SESS"
  info "killed tmux session $SESS"
else
  info "tmux session $SESS not running"
fi

treehouse return --force "$WT"
info "returned worktree $WT"

# Drop the scratch brief/report/patch now that the worktree is gone; the pushed
# branch/PR is the durable copy. Use --keep-files to retain them.
if [ "$KEEP_FILES" != 1 ]; then
  removed=0
  agent_dir="$(scratch_root "$ROOT")/agent-dirs/$TASK"
  if [ -d "$agent_dir" ]; then
    rm -rf "$agent_dir"
    removed=$((removed + 1))
  fi
  for f in "$(task_file "$ROOT" "$TASK")" "$(report_file "$ROOT" "$TASK")" "$(patch_file "$ROOT" "$TASK")"; do
    if [ -e "$f" ]; then
      rm -f "$f"
      removed=$((removed + 1))
    fi
  done
  # remove scratch subdirectories when no other task still uses them
  rmdir "$(scratch_root "$ROOT")/tasks" "$(scratch_root "$ROOT")/reports" "$(scratch_root "$ROOT")/agent-dirs" 2>/dev/null || true
  rmdir "$(scratch_root "$ROOT")" 2>/dev/null || true
  if [ "$removed" -gt 0 ]; then
    info "removed $removed scratch file(s) for '$TASK'"
  fi
fi

info "retired task '$TASK'"
