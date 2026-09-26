#!/usr/bin/env bash
# Send a follow-up instruction to an existing child pi session.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_sub-common.sh
# shellcheck disable=SC1091  # followed with -x; plain runs must stay clean
source "$SCRIPT_DIR/_sub-common.sh"

usage() { die "usage: ${0##*/} <task-name> <message...>"; }

need tmux
[ "$#" -ge 2 ] || usage
TASK=$1
shift
valid_task "$TASK" || usage
SESS=$(session_of "$TASK")
tmux has-session -t "$SESS" 2>/dev/null \
  || die "child session '$SESS' is not running"

# Type the instruction, then make sure it is actually submitted: tmux_send_line
# re-types the text if it never landed and retries the Enter while the pane
# stays frozen, so a dropped keystroke cannot strand the instruction in the
# child's composer. An unconfirmed send is fatal — printing "instruction
# sent" for a line still sitting in the composer is the bug this guards.
tmux_send_line "$SESS" "$*" \
  || die "could not confirm that $SESS received the instruction — check the pane and retry"
info "instruction sent to $SESS"
