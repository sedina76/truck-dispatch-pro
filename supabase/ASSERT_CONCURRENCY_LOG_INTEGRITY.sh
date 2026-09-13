#!/usr/bin/env bash
# ============================================================================
# ASSERT_CONCURRENCY_LOG_INTEGRITY.sh -- Phase 3B.3C.2, Section B (extended
# in Phase 3B.3C.3, Section E): a static/log integrity checker that catches
# the false-pass defect class found in TEST_CONCURRENCY_0141_integration_
# lifecycle.sh (a "!! FAIL" line printed, but the script's own FAIL
# accounting variable never set, so it exited 0 and printed PASSED anyway)
# AND several related, more subtle classes the original (Phase 3B.3C.2)
# version did NOT catch: an uncollected/un-checked background exit code, a
# `wait ... || true` that swallows a failure, a pipeline that silently
# drops a psql failure's exit code, and a raw PostgreSQL ERROR that leaks
# into a log the script still declares PASSED. Marker-proximity (is FAIL=1
# within 5 lines of an echoed "!! FAIL") is ONE signal among several here,
# never the only one.
#
# This does NOT re-run any concurrency script itself -- it inspects an
# ALREADY-CAPTURED combined stdout+stderr log (and, when available, the
# script's own real exit code) or a script's SOURCE file.
#
# --log mode rules (rejects the log if ANY apply):
#   1. a known failure marker ("!! FAIL"/"!!FAIL") exists anywhere, AND the
#      provided exit code is 0.
#   2. a "PASSED" banner exists together with any failure marker, anywhere
#      in the log, regardless of the reported exit code.
#   3. a "PASSED" banner exists, AND a raw PostgreSQL "ERROR:" line appears
#      in the log strictly AFTER the LAST "-> OK"/"OK (" success annotation
#      -- an error that leaked in after every explained/expected outcome
#      was already printed, with nothing afterward acknowledging it, yet
#      the script still declared success. (An ERROR that appears BEFORE or
#      alongside an "OK (...)" annotation is assumed already accounted for
#      -- this corpus's own established idiom for an intentionally-
#      triggered rejection test.)
#
# --check-script mode rules (rejects the script if ANY apply):
#   (a) every `echo "!! FAIL...`/`echo "!!FAIL...` occurrence must be
#       followed, within the next 5 lines, by a `FAIL=1` (or
#       `FAIL=$((FAIL+1))`) assignment.
#   (b) the final `exit` statement must be variable-driven (`exit "$FAIL"`
#       or equivalent), never a literal `exit 0`.
#   (c) every backgrounded job's PID variable (`PNAME=$!`) must be `wait`-ed
#       on somewhere later in the file -- checked per-variable, tolerant of
#       either exit-code-variable capture or output-content verification as
#       the collection strategy, as long as the PID itself is waited on.
#   (d) NEW (Section E): `wait "$PID"` must never be immediately followed by
#       `|| true` (or `|| :`) on the same logical statement -- that
#       unconditionally discards a nonzero exit status right where it would
#       otherwise be visible to `set -e` or a later `$?`/captured-variable
#       check.
#   (e) NEW (Section E): every `VAR=$?` that immediately follows a `wait`
#       must have `$VAR` (or `${VAR}`) referenced in at least one later `if`
#       condition alongside a numeric-inequality operator (`-ne`, `!=`,
#       `-gt`, `>`) -- captured but never actually tested is the same class
#       of defect as never captured at all.
#   (f) NEW (Section E): a `${PSQL[@]}`/`psql` invocation piped into another
#       command (`| grep`, `| head`, ...) is flagged if the script does not
#       have `pipefail` set anywhere before that point -- without it, a
#       failing psql's exit code is silently replaced by the pipeline's
#       last command's exit code.
# ============================================================================
set -euo pipefail

usage() {
  echo "Usage: $0 --log <logfile> --exit-code <n>" >&2
  echo "       $0 --check-script <script.sh>" >&2
  exit 2
}

MODE=""
LOGFILE=""
EXITCODE=""
SCRIPTFILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --log) LOGFILE="$2"; MODE="log"; shift 2 ;;
    --exit-code) EXITCODE="$2"; shift 2 ;;
    --check-script) SCRIPTFILE="$2"; MODE="script"; shift 2 ;;
    *) usage ;;
  esac
done

FAILMARKER_PATTERN='!! ?FAIL'
OKMARKER_PATTERN='(-> OK|OK \()'

check_log() {
  local log="$1" ec="$2"
  local bad=0

  if [ -z "$log" ] || [ ! -f "$log" ]; then
    echo "ASSERT_CONCURRENCY_LOG_INTEGRITY: log file not found: $log" >&2
    return 2
  fi

  local has_marker=0
  if grep -qE "$FAILMARKER_PATTERN" "$log"; then
    has_marker=1
  fi

  local has_passed=0
  if grep -qE '(^|[^A-Za-z])PASSED([^A-Za-z]|$)' "$log"; then
    has_passed=1
  fi

  # Rule 1: a failure marker exists but the caller reports a zero exit code.
  if [ "$has_marker" -eq 1 ] && [ "$ec" = "0" ]; then
    echo "!! INTEGRITY VIOLATION: log '$log' contains a failure marker but was reported as exit code 0:"
    grep -nE "$FAILMARKER_PATTERN" "$log" | sed 's/^/    /'
    bad=1
  fi

  # Rule 2: a PASSED banner exists together with any failure marker,
  # regardless of what exit code was reported (the PASSED banner itself is
  # the thing under suspicion here -- this is the exact 0141 defect shape:
  # FAIL stayed 0 internally, so both the marker AND "PASSED" appear in
  # the SAME log).
  if [ "$has_marker" -eq 1 ] && [ "$has_passed" -eq 1 ]; then
    echo "!! INTEGRITY VIOLATION: log '$log' contains BOTH a failure marker AND a PASSED banner -- this is precisely the false-pass defect class (TEST_CONCURRENCY_0141, Phase 3B.3C.1 report):"
    grep -nE "$FAILMARKER_PATTERN" "$log" | sed 's/^/    marker: /'
    grep -nE '(^|[^A-Za-z])PASSED([^A-Za-z]|$)' "$log" | sed 's/^/    passed: /'
    bad=1
  fi

  # Rule 3 (Section E, new): a raw, unexplained PostgreSQL ERROR that
  # leaked in AFTER the last "-> OK"/"OK (" annotation, in a log that
  # still declares PASSED. An ERROR appearing before/alongside an OK
  # annotation is this corpus's own established idiom for an
  # intentionally-triggered rejection (e.g. a unique_violation test) and
  # is not flagged.
  if [ "$has_passed" -eq 1 ]; then
    local last_ok_line trailing_errors
    last_ok_line="$(grep -nE "$OKMARKER_PATTERN" "$log" | tail -1 | cut -d: -f1 || true)"
    if [ -z "$last_ok_line" ]; then last_ok_line=0; fi
    trailing_errors="$(awk -v start="$last_ok_line" 'NR > start && /^ERROR:/ { print NR": "$0 }' "$log")"
    if [ -n "$trailing_errors" ]; then
      echo "!! INTEGRITY VIOLATION: log '$log' declares PASSED, but a raw PostgreSQL ERROR appears AFTER the last acknowledged (-> OK / OK (...)) annotation -- an unexplained background/trailing failure the script never accounted for:"
      echo "$trailing_errors" | sed 's/^/    /'
      bad=1
    fi
  fi

  if [ "$bad" -eq 0 ]; then
    echo "OK: '$log' (exit=$ec) is internally consistent -- no failure marker without a nonzero exit, no PASSED banner coexisting with a failure marker or an unexplained trailing ERROR."
  fi
  return "$bad"
}

check_script() {
  local script="$1"
  local bad=0

  if [ ! -f "$script" ]; then
    echo "ASSERT_CONCURRENCY_LOG_INTEGRITY: script not found: $script" >&2
    return 2
  fi

  # (a) every "!! FAIL"/"!!FAIL" echo must be followed within 5 lines by a
  # FAIL=1 (or FAIL=$((FAIL+1))) assignment in the same file.
  local total_lines
  total_lines="$(wc -l < "$script" | tr -d ' ')"
  while IFS=: read -r lineno _rest; do
    [ -z "$lineno" ] && continue
    local window_end=$((lineno + 5))
    [ "$window_end" -gt "$total_lines" ] && window_end="$total_lines"
    local window
    window="$(sed -n "${lineno},${window_end}p" "$script")"
    if ! echo "$window" | grep -qE 'FAIL=1|FAIL=\$\(\(FAIL'; then
      echo "!! SCRIPT DEFECT ($script:$lineno): a failure marker is echoed but no FAIL=1 (or FAIL=\$((FAIL+1))) assignment appears within the next 5 lines:"
      sed -n "${lineno}p" "$script" | sed 's/^/    /'
      bad=1
    fi
  done < <(grep -nE "echo \"$FAILMARKER_PATTERN" "$script" || true)

  # (b) final exit must be variable-driven (exit "$FAIL" / exit $FAIL /
  # exit "${FAIL}"), never an unconditional literal `exit 0` as the LAST
  # exit statement in the file.
  local last_exit
  last_exit="$(grep -nE '^\s*exit ' "$script" | tail -1 || true)"
  if [ -n "$last_exit" ]; then
    if echo "$last_exit" | grep -qE 'exit\s+0\s*$'; then
      echo "!! SCRIPT DEFECT ($script): the final exit statement is an unconditional 'exit 0', not variable-driven: $last_exit"
      bad=1
    fi
  else
    echo "!! SCRIPT DEFECT ($script): no explicit final 'exit' statement found -- the script's true/false exit status is whatever the last command happened to return, not an accumulated assertion result."
    bad=1
  fi

  # (c) every backgrounded job's PID variable (the standard `PNAME=$!`
  # convention used throughout this test suite, immediately after a `&`
  # launch) must be `wait`-ed on somewhere later in the file -- a PID
  # captured but never waited on means that job's exit status (success or
  # failure) is permanently discarded by the OS once the process reaps,
  # the literal "uncollected background process status" defect class.
  # Checked per-variable (not a single whole-file pattern) to avoid false
  # positives against scripts that verify backgrounded sessions via their
  # OUTPUT CONTENT (grep on the captured .out file) rather than via a
  # named exit-code variable -- both are legitimate collection strategies
  # as long as the PID itself is actually waited on.
  local pid_vars
  pid_vars="$(grep -oE '^[A-Za-z0-9_]+=\$!' "$script" | sed 's/=\$!$//' | sort -u || true)"
  if [ -n "$pid_vars" ]; then
    while IFS= read -r pidvar; do
      [ -z "$pidvar" ] && continue
      if ! grep -qE "wait[[:space:]]+\"?\\\$\{?${pidvar}\}?\"?" "$script"; then
        echo "!! SCRIPT DEFECT ($script): background job PID variable '$pidvar' is assigned ('$pidvar=\$!') but never passed to 'wait' anywhere in the file -- its exit status is uncollected."
        bad=1
      fi
    done <<< "$pid_vars"
  fi

  # (d) Section E, new: `wait ... || true` (or `|| :`) unconditionally
  # discards a nonzero wait exit status right where it would otherwise be
  # visible. Tolerated ONLY when the script verifies that job's outcome
  # some other way afterward (this corpus's own established idiom: `||
  # true` to stop `set -e` aborting on an ACCEPTED-but-nonzero exit,
  # followed by inspecting the job's captured output file or re-querying
  # DB state -- see e.g. TEST_CONCURRENCY_0132's session C/D race). Only
  # flagged when NEITHER follows within the next 15 lines -- a wait whose
  # result is discarded with nothing else ever checking what happened.
  local swallowed_waits
  swallowed_waits="$(grep -noE 'wait[[:space:]]+"?\$\{?[A-Za-z0-9_]+\}?"?[[:space:]]*\|\|[[:space:]]*(true|:)([[:space:];]|$)' "$script" || true)"
  if [ -n "$swallowed_waits" ]; then
    while IFS=: read -r lineno _rest; do
      [ -z "$lineno" ] && continue
      local window_end=$((lineno + 15))
      [ "$window_end" -gt "$total_lines" ] && window_end="$total_lines"
      local window
      window="$(sed -n "${lineno},${window_end}p" "$script")"
      if ! echo "$window" | grep -qE '\bcat[[:space:]]+"|grep[[:space:]]+-[a-zA-Z]*q?[a-zA-Z]*[[:space:]]+.*(\.out|\.err|\.log)"|Q[[:space:]]*\(|"\$\{PSQL\[@\]\}"'; then
        echo "!! SCRIPT DEFECT ($script:$lineno): a 'wait ... || true' (or '|| :') pattern discards the background job's exit status, and no output/DB-state verification appears in the following 15 lines -- the job's outcome is never checked at all, by exit code or otherwise:"
        sed -n "${lineno}p" "$script" | sed 's/^/    /'
        bad=1
      fi
    done <<< "$swallowed_waits"
  fi

  # (e) Section E, new: an exit-code variable captured right after a
  # `wait` (the `VAR=$?` idiom) must actually be TESTED somewhere later,
  # not merely captured and left unused. Only applies to scripts that use
  # this specific named-capture idiom at all (scripts that instead verify
  # backgrounded sessions via output-content grepping, per (c) above, are
  # unaffected -- they never introduce a VAR=$? in the first place).
  local capture_lines
  capture_lines="$(grep -noE '^[A-Za-z0-9_]+=\$\?' "$script" || true)"
  if [ -n "$capture_lines" ]; then
    while IFS=: read -r lineno assign; do
      [ -z "$lineno" ] && continue
      local varname
      varname="${assign%%=*}"
      # Only enforce this for a capture that immediately follows a `wait`
      # on the prior non-blank line -- a `VAR=$?` after some OTHER command
      # (e.g. a plain psql call) is a different, unrelated idiom this
      # rule does not govern.
      local prev_line
      prev_line="$(sed -n "$((lineno - 1))p" "$script")"
      if echo "$prev_line" | grep -qE '^\s*(set \+e;\s*)?wait\b'; then
        if ! grep -qE "\\\$\{?${varname}\}?[[:space:]]*(-ne|-gt|!=|>)[[:space:]]*(0|\"?0\"?)" "$script"; then
          echo "!! SCRIPT DEFECT ($script:$lineno): background exit-status variable '$varname' is captured right after a 'wait' but is never tested against nonzero anywhere in the file -- captured-but-unchecked is the same defect class as never captured."
          bad=1
        fi
      fi
    done <<< "$capture_lines"
  fi

  # (f) Section E, new: a psql/${PSQL[@]} invocation piped into another
  # command, with no `pipefail` anywhere before that line -- without it, a
  # failing psql's own exit code is silently replaced by the last command
  # in the pipeline (e.g. `grep`), and a failure can go completely unseen.
  local pipefail_line
  pipefail_line="$(grep -nE 'pipefail' "$script" | head -1 | cut -d: -f1 || true)"
  local piped_psql
  piped_psql="$(grep -nE '(\$\{PSQL\[@\]\}|(^|[^A-Za-z_])psql\b)[^|]*\|[[:space:]]*[A-Za-z]' "$script" || true)"
  if [ -n "$piped_psql" ]; then
    while IFS=: read -r lineno _rest; do
      [ -z "$lineno" ] && continue
      if [ -z "$pipefail_line" ] || [ "$lineno" -lt "$pipefail_line" ]; then
        echo "!! SCRIPT DEFECT ($script:$lineno): a psql invocation is piped into another command with no 'pipefail' set before this point -- a failing psql's exit code would be silently replaced by the pipeline's last command:"
        sed -n "${lineno}p" "$script" | sed 's/^/    /'
        bad=1
      fi
    done <<< "$piped_psql"
  fi

  if [ "$bad" -eq 0 ]; then
    echo "OK: '$script' -- every failure marker sets FAIL accounting, the final exit is variable-driven, background jobs have their exit status collected and (where captured by name) actually tested, no wait swallows its own exit status, and no un-pipefail'd psql pipeline can silently drop a failure."
  fi
  return "$bad"
}

case "$MODE" in
  log)
    [ -z "$EXITCODE" ] && usage
    check_log "$LOGFILE" "$EXITCODE"
    exit $?
    ;;
  script)
    check_script "$SCRIPTFILE"
    exit $?
    ;;
  *)
    usage
    ;;
esac
