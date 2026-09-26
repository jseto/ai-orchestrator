#!/usr/bin/env bash
# Push a notice from a child into the main (orchestrator) session's input.
# Intended to be run from the child's own shell/bash tool.
#
# Delivery is verified through the shared tmux_send_line helper: this script
# exits 0 only when the notice is confirmed submitted. When delivery is
# impossible it fails loudly (ERROR: on stderr, non-zero exit) and points the
# caller back at the durable report file, which remains the source of truth —
# never at another notification mechanism.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_sub-common.sh
# shellcheck disable=SC1091  # followed with -x; plain runs must stay clean
source "$SCRIPT_DIR/_sub-common.sh"

usage() { die "usage: ${0##*/} <task-name> <message...>" ; }

[ "$#" -ge 2 ] || usage
TASK=$1
shift
valid_task "$TASK" || usage
MSG="[$TASK] $*"

# Every impossible delivery funnels through here: fail loudly and redirect
# the caller to the durable report file (the source of truth). The helper
# must not push the child toward another notification mechanism.
undeliverable() { # $1=reason
  die "notice not delivered: $1 — the durable report file remains the source of truth: $SCRATCH_DIR/reports/$TASK.md"
}

command -v tmux >/dev/null 2>&1 \
  || undeliverable "missing command: tmux"
tmux has-session -t "=$MAIN_SESSION" 2>/dev/null \
  || undeliverable "main session '$MAIN_SESSION' is not running"

# send-keys targets panes, so make the exact session target explicit by
# appending `:` (the `=session` form is valid for has-session but not for
# pane-targeting commands).
TARGET="=${MAIN_SESSION}:"
if [ -n "$MAIN_PANE" ]; then
  PANE_SESSION=$(tmux display-message -p -t "$MAIN_PANE" '#S' 2>/dev/null || true)
  if [ "$PANE_SESSION" = "$MAIN_SESSION" ]; then
    TARGET=$MAIN_PANE
  else
    warn "main pane '$MAIN_PANE' is unavailable; using session '$MAIN_SESSION'"
  fi
fi

# Verified send: tmux_send_line re-types the text when it never appeared and
# retries Enter while the pane stays frozen. A non-zero status means the
# notice could not be confirmed submitted — fail loudly instead of claiming
# a delivery that is still sitting in the composer.
if ! tmux_send_line "$TARGET" "$MSG"; then
  undeliverable "could not confirm that $TARGET received the notice"
fi
info "notice delivered to $TARGET"
