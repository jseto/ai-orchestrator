#!/usr/bin/env bash
# Remove scratch briefs/reports/patches for tasks that no longer have a
# worktree lease or a running tmux session. Dry-run by default; --yes deletes.
# Ordinary retirement already cleans its own files (sub-retire.sh); use this to
# sweep leftovers from crashed/interrupted sessions.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_sub-common.sh
source "$SCRIPT_DIR/_sub-common.sh"

usage() { die "usage: ${0##*/} [repo-dir] [--yes]" ; }

need tmux treehouse jq
REPO=$PWD
YES=0
for a in "$@"; do
  case "$a" in
    --yes|-y) YES=1 ;;
    --*)      usage ;;
  esac
done
if [ "$#" -ge 1 ] && [[ "$1" != --* ]]; then REPO=$1; fi

ROOT=$(repo_root "$REPO")
SCRATCH=$(scratch_root "$ROOT")

if [ ! -d "$SCRATCH" ]; then
  info "nothing to clean: no scratch dir at $SCRATCH"
  exit 0
fi

declare -A tasks=()
for f in "$SCRATCH"/tasks/*.md "$SCRATCH"/reports/*.md "$SCRATCH"/reports/*.patch; do
  [ -e "$f" ] || continue
  b=$(basename "$f")
  b=${b%.md}
  b=${b%.patch}
  tasks["$b"]=1
done

if [ "${#tasks[@]}" -eq 0 ]; then
  info "nothing to clean in $SCRATCH"
  exit 0
fi

actions=0
for t in "${!tasks[@]}"; do
  if [ -n "$(wt_for_task "$t" "$ROOT")" ] \
     || tmux has-session -t "$(session_of "$t")" 2>/dev/null; then
    info "keep   $t (lease or tmux session still active)"
    continue
  fi
  if [ "$YES" = 1 ]; then
    for f in "$SCRATCH/tasks/$t.md" "$SCRATCH/reports/$t.md" "$SCRATCH/reports/$t.patch"; do
      if [ -e "$f" ]; then
        rm -f "$f"
      fi
    done
    info "remove $t"
  else
    info "would remove $t"
  fi
  actions=$((actions + 1))
done

if [ "$YES" = 1 ]; then
  rmdir "$SCRATCH/tasks" "$SCRATCH/reports" 2>/dev/null || true
  rmdir "$SCRATCH" 2>/dev/null || true
  info "cleaned $actions orphaned task(s)"
else
  info "$actions orphaned task(s); re-run with --yes to delete"
fi
