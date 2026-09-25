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

# Literal mode prevents tmux from interpreting punctuation in the prompt.
tmux send-keys -t "$SESS" -l "$*"
sleep 0.2
tmux send-keys -t "$SESS" Enter
info "instruction sent to $SESS"
