#!/usr/bin/env bash
# Behavioural tests for prepare_child_agent_dir (scripts/_sub-common.sh).
# One test per Scenario in specs/child-model-defaults/child-model-defaults.feature.
#
# Every test sources the script under test in a subshell with an isolated
# $HOME (fixture written into $HOME/.pi/agent/settings.json) and asserts on
# the produced child settings.json — no real ~/.pi state is ever read or
# touched. SUB_COMMON_UNDER_TEST overrides the script under test so the
# pre-change implementation can be exercised (RED) without modifying the tree.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMMON=${SUB_COMMON_UNDER_TEST:-$ROOT/scripts/_sub-common.sh}

failures=0
fail() { printf '  ASSERT FAILED: %s\n' "$*" >&2; exit 1; }

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

# prepare <fixture-fn> [VAR=value ...]
# Runs prepare_child_agent_dir with $HOME redirected to a scratch dir whose
# .pi/agent/settings.json comes from <fixture-fn>; extra VAR=value pairs are
# applied to the child environment (e.g. PATH=… to hide jq).
# Sets: RC (exit status), ERR (stderr), SETTINGS (produced settings.json).
SB=
prepare() {
  local fixture=$1; shift
  SB=$(mktemp -d "$SCRATCH/case.XXXXXX")
  mkdir -p "$SB/home/.pi/agent"
  "$fixture" "$SB/home/.pi/agent"
  RC=0
  OUT=$(env HOME="$SB/home" "$@" bash -c \
    "source '$COMMON'; prepare_child_agent_dir '$SB/agent-dir'" \
    2>"$SB/stderr") || RC=$?
  ERR=$(cat "$SB/stderr")
  SETTINGS=$(cat "$SB/agent-dir/settings.json" 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Fixtures: contents of $HOME/.pi/agent/settings.json
# ---------------------------------------------------------------------------

fx_full() {
  cat > "$1/settings.json" <<'JSON'
{"defaultProvider":"anthropic","defaultModel":"claude-sonnet-4-6","enabledModels":["anthropic/claude-sonnet-4-6","openai/gpt-5"],"packages":["evil-ext"],"otherKey":"drop-me"}
JSON
}
fx_nulls() {
  printf '%s\n' '{"defaultProvider":null,"defaultModel":null,"enabledModels":null}' \
    > "$1/settings.json"
}
fx_missing() { :; }
fx_malformed() { printf '{not valid json' > "$1/settings.json"; }
fx_array() { printf '[1,2,3]\n' > "$1/settings.json"; }

# PATH without jq (bash/rm/mkdir/ln are the only externals the function runs).
no_jq_path() {
  local d="$SCRATCH/no-jq-bin" p
  mkdir -p "$d"
  for p in bash rm mkdir ln; do ln -sf "$(command -v "$p")" "$d/$p"; done
  printf '%s' "$d"
}

jq_ok() { command -v jq >/dev/null 2>&1 || { printf '  SKIP: jq not on PATH\n' >&2; return 0; }; }

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

t_req1_inherits_model_defaults_from_global_settings() {
  jq_ok || return 0
  prepare fx_full
  [ "$RC" -eq 0 ] || fail "exit=$RC stderr=$ERR"
  [ "$OUT" = "$SB/agent-dir" ] || fail "expected echoed dest dir, got: $OUT"
  printf '%s' "$SETTINGS" | jq -e '
    .defaultProvider == "anthropic"
    and .defaultModel == "claude-sonnet-4-6"
    and .enabledModels == ["anthropic/claude-sonnet-4-6","openai/gpt-5"]
    and .packages == []
    and (keys | length == 4)' >/dev/null \
    || fail "expected the three inherited model keys + packages, got: $SETTINGS"
}

t_req2_drops_null_valued_model_keys() {
  jq_ok || return 0
  prepare fx_nulls
  [ "$RC" -eq 0 ] || fail "exit=$RC stderr=$ERR"
  printf '%s' "$SETTINGS" | jq -e '. == {"packages":[]}' >/dev/null \
    || fail "null-valued keys must be dropped, got: $SETTINGS"
}

t_req3_never_inherits_packages_or_unrelated_keys() {
  jq_ok || return 0
  prepare fx_full
  [ "$RC" -eq 0 ] || fail "exit=$RC stderr=$ERR"
  printf '%s' "$SETTINGS" | jq -e '
    .packages == []
    and (has("otherKey") | not)
    and (keys - ["defaultProvider","defaultModel","enabledModels","packages"] == [])' >/dev/null \
    || fail "global packages/otherKey leaked or model keys missing: $SETTINGS"
}

t_req4_packages_only_when_global_settings_missing() {
  jq_ok || return 0
  prepare fx_missing
  [ "$RC" -eq 0 ] || fail "exit=$RC stderr=$ERR"
  printf '%s' "$SETTINGS" | jq -e '. == {"packages":[]}' >/dev/null \
    || fail "expected packages-only file, got: $SETTINGS"
}

t_req5_packages_only_when_global_settings_malformed() {
  jq_ok || return 0
  prepare fx_malformed
  [ "$RC" -eq 0 ] || fail "exit=$RC stderr=$ERR"
  printf '%s' "$SETTINGS" | jq -e '. == {"packages":[]}' >/dev/null \
    || fail "expected packages-only file, got: $SETTINGS"
}

t_req6_packages_only_when_global_settings_wrong_shape() {
  jq_ok || return 0
  prepare fx_array
  [ "$RC" -eq 0 ] || fail "exit=$RC stderr=$ERR"
  printf '%s' "$SETTINGS" | jq -e '. == {"packages":[]}' >/dev/null \
    || fail "expected packages-only file, got: $SETTINGS"
}

t_req7_packages_only_when_jq_unavailable() {
  prepare fx_full "PATH=$(no_jq_path)"
  [ "$RC" -eq 0 ] || fail "exit=$RC stderr=$ERR"
  [ -z "$ERR" ] || fail "expected silence on stderr, got: $ERR"
  printf '%s' "$SETTINGS" | jq -e '. == {"packages":[]}' >/dev/null \
    || fail "expected packages-only file, got: ${SETTINGS:-<empty>}"
}

t_req8_shellcheck_and_bash_n_clean() {
  bash -n "$COMMON" || fail "bash -n reported syntax errors"
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  SKIP: shellcheck not on PATH\n' >&2
    return 0
  fi
  shellcheck "$COMMON" || fail "shellcheck reported findings"
}

run() {
  local name=$1 fn=$2 out
  if out=$( "$fn" 2>&1 ); then
    printf 'ok     %s\n' "$name"
  else
    printf 'NOT OK %s\n%s\n' "$name" "$out"
    failures=$((failures + 1))
  fi
}

run "[REQ-1] inherit model defaults from the global settings"   t_req1_inherits_model_defaults_from_global_settings
run "[REQ-2] drop null-valued model keys"                       t_req2_drops_null_valued_model_keys
run "[REQ-3] never inherit packages or unrelated keys"          t_req3_never_inherits_packages_or_unrelated_keys
run "[REQ-4] packages-only file when settings missing"          t_req4_packages_only_when_global_settings_missing
run "[REQ-5] packages-only file when settings malformed"        t_req5_packages_only_when_global_settings_malformed
run "[REQ-6] packages-only file when settings wrong-shaped"     t_req6_packages_only_when_global_settings_wrong_shape
run "[REQ-7] packages-only file when jq unavailable"            t_req7_packages_only_when_jq_unavailable
run "[REQ-8] shellcheck and bash -n clean"                      t_req8_shellcheck_and_bash_n_clean

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi
printf '\nall tests passed\n'
