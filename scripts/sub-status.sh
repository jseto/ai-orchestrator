#!/usr/bin/env bash
# Report everything known about a subsession: lease, pane tail, report tail.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_sub-common.sh
source "$SCRIPT_DIR/_sub-common.sh"

usage() { die "usage: ${0##*/} <task-name> [repo-dir] [lines]"; }

need git tmux treehouse jq
[ "$#" -ge 1 ] && [ "$#" -le 3 ] || usage

TASK=$1
REPO=${2:-$PWD}
LINES=${3:-30}

valid_task "$TASK" || usage
ROOT=$(repo_root "$REPO")
SESS=$(session_of "$TASK")
RF=$(report_file "$ROOT" "$TASK")

info "== task:    $TASK"
info "== session: $SESS"

WT=$(wt_for_task "$TASK" "$ROOT")
if [ -n "$WT" ]; then
  info "== worktree: $WT"
  info "--- git ---"
  git -C "$WT" status -sb | head -n 10
else
  info "== worktree: none leased for '$TASK'"
fi

info "--- pane tail (last $LINES lines) ---"
pane_tail "$TASK" "$LINES"

if [ -f "$RF" ]; then
  info "--- report tail ($RF) ---"
  tail -n "$LINES" "$RF"
else
  info "--- report: $RF (not written yet) ---"
fi
