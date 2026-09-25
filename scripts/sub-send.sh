#!/usr/bin/env bash
# Send a follow-up instruction to an existing child pi session.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_sub-common.sh
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
# child's composer.
tmux_send_line "$SESS" "$*"
info "instruction sent to $SESS"
