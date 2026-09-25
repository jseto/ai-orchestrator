#!/usr/bin/env bash
# Inspect a subsession's work and print how to publish it. Read-only by design:
# publishing (push + pull request) happens in YOUR checkout, so this script
# never merges or pushes for you. Never merge into development.
# Use --patch to also export the work as a patch file.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_sub-common.sh
source "$SCRIPT_DIR/_sub-common.sh"

usage() { die "usage: ${0##*/} <task-name> [repo-dir] [--patch]" ; }

need git treehouse jq
[ "$#" -ge 1 ] && [ "$#" -le 3 ] || usage

TASK=$1
REPO=$PWD
PATCH=0
for a in "$@"; do
  if [ "$a" = "--patch" ]; then PATCH=1; fi
done
# first non-flag arg after task = repo
if [ "$#" -ge 2 ] && [ "$2" != "--patch" ]; then REPO=$2; fi

valid_task "$TASK" || usage
ROOT=$(repo_root "$REPO")

WT=$(wt_for_task "$TASK" "$ROOT")
[ -n "$WT" ] || die "no worktree leased for '$TASK' (in $ROOT)"

BRANCH=$(git -C "$WT" branch --show-current || true)
info "== worktree: $WT"
info "== branch:   ${BRANCH:-detached}"

info "--- status ---"
git -C "$WT" status -sb

info "--- what would be lost if returned without publishing ---"
if [ "$BRANCH" = "$DEV_BRANCH" ] || [ -z "$BRANCH" ]; then
  UNLANDED=0
else
  UNLANDED=$(git -C "$WT" log --oneline "$DEV_BRANCH"..HEAD | wc -l)
fi
DIRTY=$(git -C "$WT" status --porcelain | wc -l)
info "uncommitted files: $DIRTY | commits not on $DEV_BRANCH: $UNLANDED"

if [ "$BRANCH" != "$DEV_BRANCH" ] && [ -n "$BRANCH" ]; then
  info "--- commits to publish ---"
  git -C "$WT" log --stat --oneline "$DEV_BRANCH"..HEAD
  info ""
  info "Publish as a pull request from your checkout ($ROOT) — never merge into $DEV_BRANCH:"
  info "  git push -u origin $BRANCH"
  info "  gh pr create --base $DEV_BRANCH --head $BRANCH"
  info "  # patch-only rescue:  ${0##*/} $TASK --patch"
fi

if [ "$PATCH" = 1 ]; then
  OUT=$(patch_file "$ROOT" "$TASK")
  git -C "$WT" diff "$DEV_BRANCH"...HEAD > "$OUT" 2>/dev/null || true
  # HEAD includes both staged and unstaged changes; plain `git diff` misses
  # staged files and could produce an incomplete rescue patch.
  git -C "$WT" diff HEAD >> "$OUT" 2>/dev/null || true
  info "patch written: $OUT"
fi

if [ "$UNLANDED" -eq 0 ] && [ "$DIRTY" -eq 0 ]; then
  info "Nothing to publish — worktree is clean."
fi
