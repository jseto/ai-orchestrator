#!/usr/bin/env bash
# Push a notice from a child into the main (orchestrator) session's input.
# Intended to be run from the child's own shell/bash tool.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_sub-common.sh
source "$SCRIPT_DIR/_sub-common.sh"

usage() { die "usage: ${0##*/} <task-name> <message...>" ; }

need tmux
[ "$#" -ge 2 ] || usage

TASK=$1
shift
valid_task "$TASK" || usage
MSG="[$TASK] $*"

# A missing target is a normal, safe outcome: the durable report file is the
# source of truth, and this helper must not push the child toward another
# notification mechanism. Return success so the child does not improvise.
if ! tmux has-session -t "=$MAIN_SESSION" 2>/dev/null; then
  warn "main session '$MAIN_SESSION' is not running; notice not sent"
  exit 0
fi

TARGET="=$MAIN_SESSION"
if [ -n "$MAIN_PANE" ]; then
  PANE_SESSION=$(tmux display-message -p -t "$MAIN_PANE" '#S' 2>/dev/null || true)
  if [ "$PANE_SESSION" = "$MAIN_SESSION" ]; then
    TARGET=$MAIN_PANE
  else
    warn "main pane '$MAIN_PANE' is unavailable; using session '$MAIN_SESSION'"
  fi
fi

if ! tmux send-keys -t "$TARGET" -l "$MSG" 2>/dev/null; then
  warn "main notice target disappeared; notice not sent"
  exit 0
fi
sleep 0.3
if ! tmux send-keys -t "$TARGET" Enter 2>/dev/null; then
  warn "could not submit notice to main notice target"
  exit 0
fi
info "notice sent to $TARGET"
