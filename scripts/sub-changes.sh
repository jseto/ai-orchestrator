#!/usr/bin/env bash
# Show what a subsession has changed in its worktree (read-only).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_sub-common.sh
source "$SCRIPT_DIR/_sub-common.sh"

usage() { die "usage: ${0##*/} <task-name> [repo-dir]"; }

need git treehouse jq
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage

TASK=$1
REPO=${2:-$PWD}

valid_task "$TASK" || usage
ROOT=$(repo_root "$REPO")

WT=$(wt_for_task "$TASK" "$ROOT")
[ -n "$WT" ] || die "no worktree leased for '$TASK' (in $ROOT)"

BRANCH=$(git -C "$WT" branch --show-current || true)
info "== worktree: $WT"
info "== branch:   ${BRANCH:-detached}"
info "--- status ---"
git -C "$WT" status -sb
info "--- commits not on $DEV_BRANCH ---"
if [ "$BRANCH" = "$DEV_BRANCH" ]; then
  info "(worktree is on $DEV_BRANCH itself; showing last 10 commits)"
  git -C "$WT" log --oneline -10
else
  git -C "$WT" log --oneline "$DEV_BRANCH"..HEAD
fi
info "--- diff stat vs $DEV_BRANCH ---"
git -C "$WT" diff --stat "$DEV_BRANCH"...HEAD 2>/dev/null || true
info "--- staged and unstaged ---"
git -C "$WT" diff --stat HEAD 2>/dev/null || true
