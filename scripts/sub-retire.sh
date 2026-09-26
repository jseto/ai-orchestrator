#!/usr/bin/env bash
# Retire a subsession: kill its tmux session, return the worktree, and clean
# up the task's branches (best effort; see --no-branch-cleanup).
# Refuses (without --force) when unlanded work would be destroyed.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_sub-common.sh
# shellcheck disable=SC1091  # followed with -x; plain runs must stay clean
source "$SCRIPT_DIR/_sub-common.sh"

usage() { die "usage: ${0##*/} <task-name> [repo-dir] [--force] [--keep-files] [--no-branch-cleanup]" ; }

need git tmux treehouse jq
if [ "$#" -lt 1 ] || [ "$#" -gt 4 ]; then usage; fi

TASK=$1
REPO=$PWD
FORCE=0
KEEP_FILES=0
CLEANUP=1
for a in "$@"; do
  case "$a" in
    --force)             FORCE=1 ;;
    --keep-files)        KEEP_FILES=1 ;;
    --no-branch-cleanup) CLEANUP=0 ;;
  esac
done
if [ "$#" -ge 2 ] && [[ "$2" != --* ]]; then REPO=$2; fi

valid_task "$TASK" || usage
ROOT=$(repo_root "$REPO")
SESS=$(session_of "$TASK")

cd "$ROOT"
WT=$(wt_for_task "$TASK" "$ROOT")
[ -n "$WT" ] || die "no worktree leased for '$TASK' (in $ROOT)"
# Capture the task branch before 'treehouse return' detaches the worktree HEAD.
BRANCH=$(git -C "$WT" branch --show-current 2>/dev/null || true)

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

# State of a branch's pull request: merged | open | none | unknown.
# A missing/failing gh degrades to 'unknown' — never an error.
pr_state() { # $1=branch
  local branch=$1 out
  command -v gh >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  if ! out=$(gh pr list --state merged --head "$branch" --json number 2>/dev/null); then
    printf 'unknown'; return 0
  fi
  if [ -n "$out" ] && [ "$out" != "[]" ]; then printf 'merged'; return 0; fi
  if ! out=$(gh pr list --state open --head "$branch" --json number 2>/dev/null); then
    printf 'unknown'; return 0
  fi
  if [ -n "$out" ] && [ "$out" != "[]" ]; then printf 'open'; return 0; fi
  printf 'none'
}

# True when origin/<branch> is fully merged into origin/<dev-base>.
remote_merged() { # $1=branch
  git -C "$ROOT" rev-parse --verify --quiet "refs/remotes/origin/$DEV_BRANCH" >/dev/null \
    && git -C "$ROOT" merge-base --is-ancestor "refs/remotes/origin/$1" "refs/remotes/origin/$DEV_BRANCH" 2>/dev/null
}

# Best-effort cleanup of the task's branches, run only after the retirement
# itself succeeded. Every deletion is gated and guarded: failures are warnings,
# never errors — retiring must not break because a branch was already gone.
cleanup_branches() { # $1=branch
  local branch=$1 pr
  [ -n "$branch" ] || return 0
  case "$branch" in task/*) ;; *) return 0 ;; esac

  # Local: only ever 'branch -d' (fully merged into the dev base), never -D.
  if git -C "$ROOT" merge-base --is-ancestor "refs/heads/$branch" "refs/heads/$DEV_BRANCH" 2>/dev/null; then
    if git -C "$ROOT" branch -d "$branch" >/dev/null 2>&1; then
      info "deleted local branch $branch (merged into $DEV_BRANCH)"
    else
      warn "could not delete local branch $branch"
    fi
  else
    warn "local branch $branch is not merged into $DEV_BRANCH; keeping it"
  fi

  # Remote: delete only for a merged PR, or — with no open PR — when the tip
  # is merged into origin/<dev-base>. An open PR always keeps the branch.
  git -C "$ROOT" show-ref --verify --quiet "refs/remotes/origin/$branch" || return 0
  pr=$(pr_state "$branch")
  if [ "$pr" = "open" ]; then
    info "remote branch origin/$branch has an open PR; keeping it"
    return 0
  fi
  if [ "$pr" != "merged" ] && ! remote_merged "$branch"; then
    info "remote branch origin/$branch is not merged; keeping it"
    return 0
  fi
  if git -C "$ROOT" push --delete origin "$branch" >/dev/null 2>&1; then
    info "deleted remote branch origin/$branch"
  else
    warn "could not delete remote branch origin/$branch"
  fi
  return 0
}

# Safety: 'treehouse return --force' clean-resets the worktree.
if [ "$FORCE" != 1 ]; then
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

# Best-effort branch cleanup after a successful retirement (REQ-1..REQ-6).
if [ "$CLEANUP" = 1 ]; then
  cleanup_branches "$BRANCH" || true
else
  info "branch cleanup skipped (--no-branch-cleanup)"
fi

info "retired task '$TASK'"
