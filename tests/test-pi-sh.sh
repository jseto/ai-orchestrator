#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/pi" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "${TMUX_LOG:?}"
printf '\n' >> "$TMUX_LOG"
if [[ ${1:-} == has-session ]]; then
  if [[ -e ${TMUX_EXISTS:?} ]]; then
    exit 0
  else
    exit 1
  fi
fi
EOF
chmod +x "$TMP/bin/pi" "$TMP/bin/tmux"

run_wrapper() {
  PATH="$TMP/bin:$PATH" TMUX= TMUX_LOG="$TMP/log" TMUX_EXISTS="$TMP/exists" "$ROOT/pi.sh" "$@"
}

# [REQ-1] A new session gets the script directory and exact argument boundaries.
run_wrapper --model 'name with spaces'
grep -F -- '-c '"$ROOT"' -- ' "$TMP/log" >/dev/null
grep -F -- '--model name\ with\ spaces' "$TMP/log" >/dev/null
# The final operation is an attach outside tmux.
grep -F -- 'attach-session -t local-pi-ai-orchestrator' "$TMP/log" >/dev/null

# [REQ-2] Existing sessions are reused without new-session.
: > "$TMP/log"
touch "$TMP/exists"
run_wrapper
! grep -F -- 'new-session' "$TMP/log"
grep -F -- 'attach-session -t local-pi-ai-orchestrator' "$TMP/log" >/dev/null

# [REQ-3] An in-tmux caller switches instead of attaching.
: > "$TMP/log"
PATH="$TMP/bin:$PATH" TMUX_LOG="$TMP/log" TMUX_EXISTS="$TMP/exists" TMUX=client "$ROOT/pi.sh"
grep -F -- 'switch-client -t local-pi-ai-orchestrator' "$TMP/log" >/dev/null

# [REQ-4] Reserved names are rejected before tmux is called.
: > "$TMP/log"
if PATH="$TMP/bin:$PATH" TMUX_LOG="$TMP/log" TMUX_EXISTS="$TMP/exists" PI_TMUX_SESSION=pi-main "$ROOT/pi.sh"; then
  echo 'reserved name was accepted' >&2
  exit 1
fi
[[ ! -s "$TMP/log" ]]

[[ -x "$ROOT/pi.sh" ]]
printf 'all pi.sh tests passed\n'
