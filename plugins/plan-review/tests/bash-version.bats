#!/usr/bin/env bats
# Old Bash is supported only far enough to emit the entry-specific refusal.

setup() {
  load 'test_helper/common-setup'
  bats_require_minimum_version 1.5.0
  common_setup
  LEGACY_BASH=/bin/bash
  if [ "$($LEGACY_BASH -c 'printf "%s" "${BASH_VERSINFO[0]}"')" -ge 5 ]; then
    skip 'This host has no legacy /bin/bash; refusal requires a real old Bash.'
  fi
  mkdir "${TEST_TEMP_DIR}/empty-bin"
  LEGACY_INPUT=$(build_input)
  printf 'Review rules' > "${TEST_TEMP_DIR}/rules.txt"
  printf 'Artifact' > "${TEST_TEMP_DIR}/artifact.txt"
}

teardown() {
  common_teardown
}

# The rejected runtime has no external commands or libs available. The Bats
# process retains its own PATH for assertions and fixture management.
run_legacy_entry() {
  run --separate-stderr env -u BASH_ENV -u ENV \
    PATH="${LEGACY_PATH:-${TEST_TEMP_DIR}/empty-bin}" "$LEGACY_BASH" "$@" <<< "$LEGACY_INPUT"
}

assert_legacy_refusal() {
  local entry="$1" message
  case "$entry" in
    second-opinion.sh)
      [ "$status" -eq 1 ]
      [ -z "$output" ]
      message="$stderr"
      ;;
    precompact-review.sh)
      [ "$status" -eq 0 ]
      [ -z "$stderr" ]
      printf '%s' "$output" | jq -e '.continue == true and (has("hookSpecificOutput") | not)' >/dev/null
      message=$(printf '%s' "$output" | jq -r '.systemMessage')
      ;;
    *)
      [ "$status" -eq 0 ]
      [ -z "$stderr" ]
      printf '%s' "$output" | jq -e '.hookSpecificOutput | .hookEventName == "PreToolUse" and .permissionDecision == "deny"' >/dev/null
      message=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')
      ;;
  esac
  [[ "$message" == *'Bash 5.0+'* ]]
  [[ "$message" == *'Homebrew'* ]]
  [[ "$message" == *'PATH'* ]]
  [[ "$message" == *'new Claude Code process'* ]]
}

runtime_state_snapshot() {
  python3 - "$REVIEW_COUNTER_DIR" "$REVIEW_LOG_DIR" <<'PYTHON'
import hashlib
import json
from pathlib import Path
import sys
print(json.dumps([
    (str(path), path.stat().st_mtime_ns, hashlib.sha256(path.read_bytes()).hexdigest())
    for root in sys.argv[1:] for path in sorted(Path(root).rglob('*')) if path.is_file()
]))
PYTHON
}

@test "runtime: all four entry shebangs select Bash from PATH" {
  local entry first_line
  for entry in plan-review.sh dispatch-check.sh precompact-review.sh second-opinion.sh; do
    IFS= read -r first_line < "${BATS_TEST_DIRNAME}/../scripts/$entry"
    [ "$first_line" = '#!/usr/bin/env bash' ]
  done
}

@test "runtime: legacy PreToolUse entries deny without external dependencies" {
  local entry
  for entry in plan-review.sh dispatch-check.sh; do
    run_legacy_entry "${BATS_TEST_DIRNAME}/../scripts/$entry"
    assert_legacy_refusal "$entry"
  done
}

@test "runtime: legacy PreCompact continues with an upgrade message, not recovery" {
  set_counter_value 1 test-session 1
  run_legacy_entry "$PRECOMPACT_SCRIPT"
  assert_legacy_refusal precompact-review.sh
  [[ "$output" != *'PLAN REVIEW IN PROGRESS'* ]]
}

@test "runtime: legacy CLI refuses before argument parsing with empty stdout" {
  run_legacy_entry "$SECOND_OPINION_SCRIPT" --invalid-option
  assert_legacy_refusal second-opinion.sh
  [[ "$stderr" != *'unknown option'* ]]
}

@test "runtime: all legacy entries return while stdin remains open and empty" {
  run python3 - "${BATS_TEST_DIRNAME}/../scripts" <<'PYTHON'
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
entries = ['plan-review.sh', 'dispatch-check.sh', 'precompact-review.sh', 'second-opinion.sh']
env = os.environ.copy()
for key in ['BASH_ENV', 'ENV']:
    env.pop(key, None)
results = []
for entry in entries:
    proc = subprocess.Popen(['/bin/bash', str(Path(sys.argv[1]) / entry)],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=env, start_new_session=True)
    timed_out = False
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(proc.pid, signal.SIGKILL)
    # Close stdin only AFTER exit (or precise timeout cleanup).
    stdout, stderr = proc.communicate()
    results.append({'entry': entry, 'timeout': timed_out, 'exit': proc.returncode,
                    'stdout': stdout.decode(), 'stderr': stderr.decode()})
print(json.dumps(results))
PYTHON
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e 'length == 4 and all(.[];
    .timeout == false and
    if .entry == "second-opinion.sh" then
      .exit == 1 and .stdout == "" and (.stderr | contains("Bash 5.0+"))
    elif .entry == "precompact-review.sh" then
      .exit == 0 and .stderr == "" and
      (.stdout | fromjson | .continue == true and (.systemMessage | contains("Bash 5.0+")))
    else
      .exit == 0 and .stderr == "" and
      (.stdout | fromjson | .hookSpecificOutput | .permissionDecision == "deny" and
        (.permissionDecisionReason | contains("Bash 5.0+")))
    end)' >/dev/null
}

@test "runtime: old-version refusal precedes damaged source dependencies" {
  setup_script_copy
  local lib entry
  for lib in common.sh manifest.sh consult.sh; do
    printf '%s\n' 'unclosed " syntax (' > "${COPY_SCRIPT_DIR}/lib/$lib"
  done
  for entry in plan-review.sh dispatch-check.sh second-opinion.sh; do
    run_legacy_entry "${COPY_SCRIPT_DIR}/$entry"
    assert_legacy_refusal "$entry"
  done
}

@test "runtime: legacy refusal neither changes state nor invokes an engine" {
  set_counter_value 1 test-session 2
  printf 'history' > "${REVIEW_COUNTER_DIR}/.review-history-test-session"
  printf 'conversation' > "${REVIEW_COUNTER_DIR}/.conversation-test-session"
  printf 'dispatch sentinel' > "${REVIEW_COUNTER_DIR}/.dispatch-test-session.json"
  create_mock_engine agy '<verdict>APPROVE</verdict>Must not be called.'
  local before entry LEGACY_PATH="$PATH"
  before=$(runtime_state_snapshot)
  for entry in plan-review.sh dispatch-check.sh precompact-review.sh second-opinion.sh; do
    run_legacy_entry "${BATS_TEST_DIRNAME}/../scripts/$entry" \
      --system-prompt-file "${TEST_TEMP_DIR}/rules.txt" --prompt-file "${TEST_TEMP_DIR}/artifact.txt"
    assert_legacy_refusal "$entry"
    [ "$(runtime_state_snapshot)" = "$before" ]
    [ ! -e "${TEST_TEMP_DIR}/.agy-args-agy" ]
  done
}

@test "runtime: disable and recursive switches cannot bypass the version requirement" {
  export REVIEW_DISABLED=1 GEMINI_REVIEW_OFF=1 DISPATCH_CHECK_DISABLED=1
  export PLAN_REVIEW_RUNNING=1 REVIEW_DRY_RUN=1
  local entry LEGACY_PATH="$PATH"
  for entry in plan-review.sh dispatch-check.sh precompact-review.sh second-opinion.sh; do
    run_legacy_entry "${BATS_TEST_DIRNAME}/../scripts/$entry"
    assert_legacy_refusal "$entry"
  done
}
