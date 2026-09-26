#!/usr/bin/env bash
# Append a conversation/operation entry to the orchestrator's weekly log.
# One file per ISO week in a gitignored folder; a 6-month retention sweep
# runs on every call. The script never reads or prints existing log content —
# logs are read only on demand, to resolve operational issues (AGENTS.md,
# helper-scripts table).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_sub-common.sh
source "$SCRIPT_DIR/_sub-common.sh"

usage_text() {
  cat <<EOF
usage: ${0##*/} append <kind> <message...>
       ${0##*/} sweep
       ${0##*/} --help

Append a single-line entry to the weekly log
<log-dir>/<ISO-week>.log (e.g. 2026-W39.log), where <log-dir> defaults to
<repo>/logs/conversations (gitignored). Kind is a lowercase slug such as
"conversation" or "operation". The 6-month retention sweep runs on every
invocation, before anything else.

Commands:
  append <kind> <message...>  run the sweep, then append one entry
  sweep                       run only the 6-month retention sweep
  --help                      show this help

Logs are only read to resolve operational issues; normal operation writes
and deletes files without ever reading or printing their content.

Environment:
  CONVERSATION_LOG_DIR        log directory (default <repo>/logs/conversations)
EOF
}

usage() { die "usage: ${0##*/} append <kind> <message...> | sweep | --help"; }

# Make a value safe as a single log line: backslashes first (so escaped
# sequences stay reversible), then TAB/CR/LF. One entry is always one line.
escape_field() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//$'\n'/\\n}
  printf '%s' "$s"
}

# Retention: weekly files are named YYYY-Www (zero padded), so week keys
# compare correctly as plain strings. Delete a file when its key sorts at or
# before the ISO week of "6 months ago" — every surviving file then contains
# only entries strictly newer than the retention limit. The sweep lists and
# unlinks; it never reads log content. Non-matching names are left alone.
sweep_stale_logs() { # $1=log dir, $2=cutoff week key
  local dir=$1 cutoff=$2 f key
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.log; do
    [ -e "$f" ] || continue
    key=${f##*/}
    key=${key%.log}
    [[ "$key" =~ ^[0-9]{4}-W[0-9]{2}$ ]] || continue
    if [[ "$key" < "$cutoff" || "$key" == "$cutoff" ]]; then
      rm -f "$f" || warn "could not remove stale log: $f"
    fi
  done
}

main() {
  export LC_ALL=C   # byte-wise week-key comparison

  local dir cutoff
  dir=${CONVERSATION_LOG_DIR:-$(repo_root "$SCRIPT_DIR")/logs/conversations}
  need date
  cutoff=$(date -u -d '6 months ago' +%G-W%V)

  # Retention runs on EVERY call — before argument dispatch, so --help and
  # failed invocations sweep as well.
  sweep_stale_logs "$dir" "$cutoff"

  case "${1:-}" in
    append)
      [ "$#" -ge 3 ] || usage
      local kind=$2
      [[ "$kind" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
        || die "invalid kind: $kind (lowercase slug expected, e.g. conversation)"
      shift 2
      local msg=$*
      [ -n "$msg" ] || die "empty message"
      mkdir -p "$dir"
      local ts week
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      # Derive the week key from the entry's own timestamp so the two can
      # never disagree across a UTC week rollover.
      week=$(date -u -d "$ts" +%G-W%V)
      printf '%s\t%s\t%s\n' "$ts" "$kind" "$(escape_field "$msg")" \
        >> "$dir/$week.log"
      ;;
    sweep) : ;;   # the sweep above was the whole job
    --help|help|-h) usage_text ;;
    *) usage ;;
  esac
}

main "$@"
