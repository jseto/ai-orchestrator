#!/usr/bin/env bash
# Launch a local pi session in a durable, repo-scoped tmux session.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SESSION_NAME=${PI_TMUX_SESSION:-local-pi-ai-orchestrator}

if [[ "$SESSION_NAME" == "pi-main" || "$SESSION_NAME" == pi-* ]]; then
  printf 'pi.sh: refusing reserved session name: %s\n' "$SESSION_NAME" >&2
  exit 2
fi

if [[ -n "${PI_BIN:-}" ]]; then
  PI_COMMAND=$PI_BIN
else
  PI_COMMAND=$(command -v pi || true)
fi
if [[ -z "$PI_COMMAND" || ! -x "$PI_COMMAND" ]]; then
  printf 'pi.sh: pi executable not found (set PI_BIN to its path)\n' >&2
  exit 127
fi

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  : # The existing session already owns its pi process; do not start a second one.
else
  tmux new-session -d -s "$SESSION_NAME" -c "$ROOT_DIR" -- "$PI_COMMAND" "$@"
fi

if [[ -n "${TMUX:-}" ]]; then
  exec tmux switch-client -t "$SESSION_NAME"
else
  exec tmux attach-session -t "$SESSION_NAME"
fi
