#!/usr/bin/env bash
# End-to-end tests for scripts/conversation-log.sh.
# One test per Gherkin scenario in
# specs/conversation-log-script/conversation-log.feature ([REQ-n]), plus
# supplementary edge cases (boundary week, sweep on error calls, foreign cwd).
# Plain bash — no framework dependencies.
# SC2317: test functions are invoked indirectly via run_test; SC2016: snippets
# passed to assert_sh are deliberately single-quoted and expand in a child bash.
# shellcheck disable=SC2317,SC2016
set -u

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
SCRIPT="$ROOT/scripts/conversation-log.sh"
REAL_DATE=$(command -v date)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- fake `date` shim ----------------------------------------------------
# The script derives week keys/timestamps from `date`; the shim shifts "now"
# to $FAKE_NOW so weekly rotation and 6-month retention are testable without
# waiting for real time to pass. Everything else forwards to the real date.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/date" <<EOF
#!/usr/bin/env bash
real="$REAL_DATE"
now=\${FAKE_NOW:-now}
case "\$*" in
  '-u +%Y-%m-%dT%H:%M:%SZ')        exec "\$real" -u -d "\$now" +%Y-%m-%dT%H:%M:%SZ ;;
  '-u -d 6 months ago +%G-W%V')    exec "\$real" -u -d "\$now -6 months" +%G-W%V ;;
  '-u -d '*' +%G-W%V')             exec "\$real" "\$@" ;;   # week from a (possibly faked) timestamp
  '-u +%G-W%V')                    exec "\$real" -u -d "\$now" +%G-W%V ;;
  *)                               exec "\$real" "\$@" ;;
esac
EOF
chmod +x "$TMP/bin/date"

# --- helpers -------------------------------------------------------------
PASS=0
FAIL=0
FAILED_TESTS=()

week_of() { "$REAL_DATE" -u -d "$1" +%G-W%V; }

fresh() { # reset per-test state; $1 = unique test id (log dir name)
  LOGS="$TMP/$1"
  RUN_CWD=$ROOT
  USE_DEFAULT_DIR=0
  FAKE_NOW=""
  OUT=""
  ERR=""
  RC=0
}

run_script() { # capture RC/OUT/ERR; env via LOGS/RUN_CWD/USE_DEFAULT_DIR/FAKE_NOW
  local rc=0 cwd=${RUN_CWD:-$ROOT}
  if [ "$USE_DEFAULT_DIR" = 1 ]; then
    OUT=$(cd "$cwd" && env -u CONVERSATION_LOG_DIR \
      PATH="$TMP/bin:$PATH" FAKE_NOW="$FAKE_NOW" \
      "$SCRIPT" "$@" 2>"$TMP/err") || rc=$?
  else
    OUT=$(cd "$cwd" && env CONVERSATION_LOG_DIR="$LOGS" \
      PATH="$TMP/bin:$PATH" FAKE_NOW="$FAKE_NOW" \
      "$SCRIPT" "$@" 2>"$TMP/err") || rc=$?
  fi
  ERR=$(<"$TMP/err")
  RC=$rc
  export OUT ERR RC LOGS
}

assert() { # $1 = description, rest = command
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    printf '    ok   - %s\n' "$desc"
  else
    FAIL=$((FAIL + 1))
    printf '    FAIL - %s\n' "$desc"
  fi
}

assert_sh() { # $1 = description, $2 = shell snippet (sees exported OUT/ERR/RC/LOGS)
  local desc=$1 snippet=$2
  if bash -c "$snippet" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    printf '    ok   - %s\n' "$desc"
  else
    FAIL=$((FAIL + 1))
    printf '    FAIL - %s\n' "$desc"
  fi
}

run_test() { # $1 = scenario name, $2 = function
  local name=$1 fn=$2 before=$FAIL
  printf '== %s\n' "$name"
  "$fn"
  if [ "$FAIL" -eq "$before" ]; then
    printf '   PASS\n'
  else
    FAILED_TESTS+=("$name")
  fi
}

# --- [REQ-1] Append an entry to the current week's log -------------------
req_1() {
  fresh req1
  run_script append conversation "discussed rotation design"
  local f
  f="$LOGS/$("$REAL_DATE" -u +%G-W%V).log"
  assert "append exits 0" test "$RC" -eq 0
  assert "current-week file created" test -f "$f"
  assert "exactly one line" test "$(grep -c '' "$f")" -eq 1
  assert_sh "entry is timestamp<TAB>kind<TAB>message" \
    "grep -qP '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z\tconversation\tdiscussed rotation design\$' '$f'"
  assert "stdout silent" test -z "$OUT"
  assert "stderr silent" test -z "$ERR"
}

# --- [REQ-2] Fold embedded newlines so an entry stays on one line --------
req_2() {
  fresh req2
  run_script append operation "first line
second line"
  local f
  f="$LOGS/$("$REAL_DATE" -u +%G-W%V).log"
  assert "append exits 0" test "$RC" -eq 0
  assert "file has exactly one physical line" test "$(grep -c '' "$f")" -eq 1
  assert_sh "newline stored as escaped \\\\n" "grep -qF 'first line\nsecond line' '$f'"
}

# --- [REQ-3] Start a new log file when the ISO week changes --------------
req_3() {
  fresh req3
  FAKE_NOW="2026-06-15"
  run_script append conversation "old week message"
  local old_f
  old_f="$LOGS/$(week_of 2026-06-15).log"
  FAKE_NOW="2026-06-29"
  run_script append conversation "new week message"
  local new_f
  new_f="$LOGS/$(week_of 2026-06-29).log"
  assert "second append exits 0" test "$RC" -eq 0
  assert "new week file created" test -f "$new_f"
  assert "old week file still exists" test -f "$old_f"
  assert "old week file untouched (1 line)" test "$(grep -c '' "$old_f")" -eq 1
  assert "new week file has the new entry" \
    grep -q "new week message" "$new_f"
}

# --- [REQ-4] Remove log files older than 6 months on every call ----------
req_4() {
  fresh req4
  FAKE_NOW="2026-06-15"
  local old
  old="$LOGS/$(week_of '2026-06-15 -7 months').log"
  local recent
  recent="$LOGS/$(week_of '2026-06-15 -2 months').log"
  mkdir -p "$LOGS"
  : > "$old"
  : > "$recent"
  run_script append conversation "after sweep"
  assert "append exits 0" test "$RC" -eq 0
  assert "file older than 6 months deleted" test ! -e "$old"
  assert "recent file kept" test -f "$recent"
  assert "current week file got the entry" \
    grep -q "after sweep" "$LOGS/$(week_of 2026-06-15).log"
}

# --- [REQ-5] Create the log directory on demand --------------------------
req_5() {
  fresh req5
  USE_DEFAULT_DIR=1
  RUN_CWD=$TMP
  run_script append conversation "created the directory"
  local f
  f="$ROOT/logs/conversations/$("$REAL_DATE" -u +%G-W%V).log"
  assert "append exits 0" test "$RC" -eq 0
  assert "default dir created inside the repo" test -d "$ROOT/logs/conversations"
  assert "entry written to default location" test -f "$f"
  rm -rf "$ROOT/logs" # leave the worktree clean
}

# --- [REQ-6] Keep the log directory out of git ---------------------------
req_6() {
  fresh req6
  assert_sh ".gitignore ignores logs/conversations files" \
    "cd '$ROOT' && git check-ignore -q logs/conversations/2099-W01.log"
}

# --- [REQ-7] Never emit existing log content -----------------------------
req_7() {
  fresh req7
  local f
  f="$LOGS/$("$REAL_DATE" -u +%G-W%V).log"
  mkdir -p "$LOGS"
  printf 'SECRET-POISON stored entry\n' > "$f"
  local all="" append_rc
  run_script append conversation "quiet append"
  append_rc=$RC
  all="$all$OUT$ERR"
  run_script sweep
  all="$all$OUT$ERR"
  run_script --help
  all="$all$OUT$ERR"
  run_script
  all="$all$OUT$ERR"
  assert "append exits 0" test "$append_rc" -eq 0
  assert_sh "no command leaked stored content" \
    "case '$all' in *SECRET-POISON*) exit 1;; esac"
}

# --- [REQ-8] Never read existing logs during normal operation ------------
req_8() {
  fresh req8
  local f
  f="$LOGS/$("$REAL_DATE" -u +%G-W%V).log"
  mkdir -p "$LOGS"
  printf 'existing unreadable entry\n' > "$f"
  chmod 222 "$f" # write-only: append must work without reading
  local before after
  before=$(stat -c %s "$f")
  run_script append conversation "appended despite no read permission"
  after=$(stat -c %s "$f")
  assert "append exits 0 on a write-only log" test "$RC" -eq 0
  assert "entry appended (file grew)" test "$after" -gt "$before"
  chmod 644 "$f"
  assert "new entry present" grep -q "appended despite no read permission" "$f"
}

# --- [REQ-9] Reject invalid usage without writing an entry ---------------
req_9() {
  fresh req9
  run_script
  assert "no args: non-zero exit" test "$RC" -ne 0
  assert_sh "no args: stderr starts with ERROR:" 'case "$ERR" in ERROR:*) exit 0;; *) exit 1;; esac'
  assert "no args: nothing written" test ! -e "$LOGS"
  run_script append "Bad Kind!" "message"
  assert "invalid kind: non-zero exit" test "$RC" -ne 0
  assert_sh "invalid kind: stderr starts with ERROR:" 'case "$ERR" in ERROR:*) exit 0;; *) exit 1;; esac'
  assert "invalid kind: nothing written" test ! -e "$LOGS"
  run_script append conversation
  assert "missing message: non-zero exit" test "$RC" -ne 0
  assert "missing message: nothing written" test ! -e "$LOGS"
}

# --- [REQ-10] Document usage and the read-on-demand rule in help ---------
req_10() {
  fresh req10
  run_script --help
  assert "help exits 0" test "$RC" -eq 0
  assert_sh "help shows the usage line" 'grep -q "usage:" <<<"$OUT"'
  assert_sh "help lists the commands" 'grep -q "append" <<<"$OUT" && grep -q "sweep" <<<"$OUT"'
  assert_sh "help states the read-on-demand rule" \
    'grep -qi "operational issues" <<<"$OUT"'
}

# --- supplementaries -----------------------------------------------------
sup_sweep_on_help() {
  fresh sup1
  local stale
  stale="$LOGS/$(week_of '2020-01-06').log"
  mkdir -p "$LOGS"
  : > "$stale"
  run_script --help
  assert "stale file removed by --help call" test ! -e "$stale"
}

sup_sweep_on_error() {
  fresh sup2
  local stale
  stale="$LOGS/$(week_of '2020-01-06').log"
  mkdir -p "$LOGS"
  : > "$stale"
  run_script
  assert "stale file removed even by a failed call" test ! -e "$stale"
}

sup_boundary_week() {
  fresh sup3
  FAKE_NOW="2026-06-15"
  local cutoff
  cutoff="$LOGS/$(week_of '2026-06-15 -6 months').log"
  local kept
  kept="$LOGS/$(week_of '2026-06-15 -5 months').log"
  mkdir -p "$LOGS"
  : > "$cutoff"
  : > "$kept"
  run_script sweep
  assert "file in the 6-month boundary week deleted" test ! -e "$cutoff"
  assert "file newer than boundary kept" test -f "$kept"
}

sup_foreign_cwd() {
  fresh sup4
  RUN_CWD=$TMP
  run_script append operation "logged from elsewhere"
  assert "append works from a foreign cwd" test "$RC" -eq 0
  assert "entry written" \
    grep -q "logged from elsewhere" "$LOGS/$("$REAL_DATE" -u +%G-W%V).log"
}

sup_operation_second_entry() {
  fresh sup5
  run_script append conversation "first"
  run_script append operation "second"
  local f
  f="$LOGS/$("$REAL_DATE" -u +%G-W%V).log"
  assert "second entry appended to same file" test "$(grep -c '' "$f")" -eq 2
  assert_sh "kinds recorded per line" \
    "grep -qP '\tconversation\t' '$f' && grep -qP '\toperation\t' '$f'"
}

sup_unmatched_names_untouched() {
  fresh sup6
  mkdir -p "$LOGS"
  : > "$LOGS/not-a-week.log"
  : > "$LOGS/notes.txt"
  run_script sweep
  assert "non-week filename left alone" test -f "$LOGS/not-a-week.log"
  assert "non-.log file left alone" test -f "$LOGS/notes.txt"
}

# --- run -----------------------------------------------------------------
[ -x "$SCRIPT" ] || printf 'NOTE: %s missing (RED phase)\n' "$SCRIPT"

run_test "Append an entry to the current week's log [REQ-1]" req_1
run_test "Fold embedded newlines so an entry stays on one line [REQ-2]" req_2
run_test "Start a new log file when the ISO week changes [REQ-3]" req_3
run_test "Remove log files older than 6 months on every call [REQ-4]" req_4
run_test "Create the log directory on demand [REQ-5]" req_5
run_test "Keep the log directory out of git [REQ-6]" req_6
run_test "Never emit existing log content [REQ-7]" req_7
run_test "Never read existing logs during normal operation [REQ-8]" req_8
run_test "Reject invalid usage without writing an entry [REQ-9]" req_9
run_test "Document usage and the read-on-demand rule in help [REQ-10]" req_10
run_test "supplementary: sweep runs on --help" sup_sweep_on_help
run_test "supplementary: sweep runs on failed calls" sup_sweep_on_error
run_test "supplementary: boundary week is deleted, newer kept" sup_boundary_week
run_test "supplementary: safe to run from a foreign cwd" sup_foreign_cwd
run_test "supplementary: operation entry joins the same weekly file" sup_operation_second_entry
run_test "supplementary: unmatched filenames are never touched" sup_unmatched_names_untouched

printf '\n%d assertions passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed tests:\n'
  printf '  - %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
exit 0
