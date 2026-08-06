#!/usr/bin/env bats
# BDD test suite for second-opinion.sh — the out-of-plugin driver built on
# lib/consult.sh's run_consultation() (PR2 of issue #165).
#
# Scope: this driver is NOT a pure pass-through — it owns four pieces of
# logic the hook does not need to test in isolation: argument parsing,
# ordered concatenation of --system-prompt-file, session-key derivation
# (plan_hash reuse over label + assembled system-prompt bytes), and input
# validation (fail-loud on missing/malformed args). Reuses
# common-setup.bash's mock-engine infrastructure (create_mock_engine,
# agy_args, create_failing_engine) — same isolation guarantees as
# plan-review.bats (isolated REVIEW_COUNTER_DIR/MOCK_BIN/LOG_DIR per test).
#
# Dependencies: bats-core, jq (not required by the driver itself, but by
# common-setup.bash's build_input helper used incidentally by shared setup)

setup() {
  load 'test_helper/common-setup'
  common_setup
}

teardown() {
  common_teardown
}

# =============================================================================
# Argument parsing
# =============================================================================

# 1. Single --system-prompt-file + --prompt-file → success, review body only
@test "args: single --system-prompt-file + --prompt-file succeeds" {
  create_mock_engine "agy" "Single file review."
  local sys_file="${TEST_TEMP_DIR}/sys.md"
  local artifact_file="${TEST_TEMP_DIR}/artifact.md"
  printf 'System rubric.' > "$sys_file"
  printf 'Artifact body.' > "$artifact_file"

  run_second_opinion --system-prompt-file "$sys_file" --prompt-file "$artifact_file"

  [ "$SO_EXIT" -eq 0 ]
  [ "$SO_STDOUT" = "Single file review." ]
}

# 2. Multiple --system-prompt-file (repeatable) → success
@test "args: multiple --system-prompt-file (repeatable) succeeds" {
  create_mock_engine "agy" "Multi file review."
  local sys1="${TEST_TEMP_DIR}/sys1.md"
  local sys2="${TEST_TEMP_DIR}/sys2.md"
  local artifact_file="${TEST_TEMP_DIR}/artifact.md"
  printf 'Part one.' > "$sys1"
  printf 'Part two.' > "$sys2"
  printf 'Artifact body.' > "$artifact_file"

  run_second_opinion --system-prompt-file "$sys1" --system-prompt-file "$sys2" --prompt-file "$artifact_file"

  [ "$SO_EXIT" -eq 0 ]
  [ "$SO_STDOUT" = "Multi file review." ]
}

# 3. Missing --system-prompt-file entirely → fail loud
@test "args: missing --system-prompt-file fails loud with empty stdout" {
  local artifact_file="${TEST_TEMP_DIR}/artifact.md"
  printf 'Artifact body.' > "$artifact_file"

  run_second_opinion --prompt-file "$artifact_file"

  [ "$SO_EXIT" -ne 0 ]
  [ -z "$SO_STDOUT" ]
  [[ "$SO_STDERR" == *"--system-prompt-file is required"* ]]
}

# 4. Nonexistent --system-prompt-file path → fail loud
@test "args: nonexistent --system-prompt-file path fails loud" {
  local artifact_file="${TEST_TEMP_DIR}/artifact.md"
  printf 'Artifact body.' > "$artifact_file"

  run_second_opinion --system-prompt-file "${TEST_TEMP_DIR}/does-not-exist.md" --prompt-file "$artifact_file"

  [ "$SO_EXIT" -ne 0 ]
  [ -z "$SO_STDOUT" ]
  [[ "$SO_STDERR" == *"not found or empty"* ]]
}

# 5. Empty --system-prompt-file file (exists, zero bytes) → fail loud
@test "args: empty --system-prompt-file file fails loud" {
  local sys_file="${TEST_TEMP_DIR}/empty-sys.md"
  local artifact_file="${TEST_TEMP_DIR}/artifact.md"
  : > "$sys_file"
  printf 'Artifact body.' > "$artifact_file"

  run_second_opinion --system-prompt-file "$sys_file" --prompt-file "$artifact_file"

  [ "$SO_EXIT" -ne 0 ]
  [ -z "$SO_STDOUT" ]
  [[ "$SO_STDERR" == *"not found or empty"* ]]
}

# 6. Unknown parameter → rejected
@test "args: unknown parameter is rejected" {
  local sys_file="${TEST_TEMP_DIR}/sys.md"
  printf 'System rubric.' > "$sys_file"

  run_second_opinion --system-prompt-file "$sys_file" --bogus-flag foo

  [ "$SO_EXIT" -ne 0 ]
  [[ "$SO_STDERR" == *"unknown argument"* ]]
}

# 7. Flag given without a following value → rejected (not a hang / index error)
@test "args: --system-prompt-file with no value is rejected" {
  run_second_opinion --system-prompt-file

  [ "$SO_EXIT" -ne 0 ]
  [[ "$SO_STDERR" == *"requires a value"* ]]
}

# =============================================================================
# Concatenation order
# =============================================================================

# 8. Two --system-prompt-file are concatenated in command-line order — assert
#    the ACTUAL bytes reaching the engine (agy_args captures the -p argument).
@test "concat: two --system-prompt-file concatenate in command-line order" {
  create_mock_engine "agy" "ok"
  local sys1="${TEST_TEMP_DIR}/sys1.md"
  local sys2="${TEST_TEMP_DIR}/sys2.md"
  local artifact_file="${TEST_TEMP_DIR}/artifact.md"
  printf 'AAAA_FIRST' > "$sys1"
  printf 'BBBB_SECOND' > "$sys2"
  printf 'the-artifact' > "$artifact_file"

  run_second_opinion --system-prompt-file "$sys1" --system-prompt-file "$sys2" --prompt-file "$artifact_file"
  [ "$SO_EXIT" -eq 0 ]

  local args
  args=$(agy_args "agy")
  # AAAA_FIRST must appear before BBBB_SECOND in the captured -p payload.
  # bash's own ${var%%pattern} strips everything from the first match
  # onward — comparing the stripped length to the original tells us the
  # match position without piping a multiline string through awk/grep
  # (awk's `index()` chokes on embedded newlines: "newline in string").
  local before_first before_second
  before_first="${args%%AAAA_FIRST*}"
  before_second="${args%%BBBB_SECOND*}"
  [ "${#before_first}" -lt "${#args}" ]
  [ "${#before_second}" -lt "${#args}" ]
  [ "${#before_first}" -lt "${#before_second}" ]

  # Reversed order must reverse the byte order too (proves it's not
  # coincidental / hardcoded).
  run_second_opinion --system-prompt-file "$sys2" --system-prompt-file "$sys1" --prompt-file "$artifact_file"
  [ "$SO_EXIT" -eq 0 ]
  args=$(agy_args "agy")
  before_first="${args%%BBBB_SECOND*}"
  before_second="${args%%AAAA_FIRST*}"
  [ "${#before_first}" -lt "${#args}" ]
  [ "${#before_second}" -lt "${#args}" ]
  [ "${#before_first}" -lt "${#before_second}" ]
}

# =============================================================================
# Body source: --prompt-file / stdin / precedence
# =============================================================================

# 9. Body via --prompt-file
@test "body: --prompt-file supplies the artifact body" {
  create_mock_engine "agy" "ok"
  local sys_file="${TEST_TEMP_DIR}/sys.md"
  local artifact_file="${TEST_TEMP_DIR}/artifact.md"
  printf 'System rubric.' > "$sys_file"
  printf 'BODY_FROM_FILE' > "$artifact_file"

  run_second_opinion --system-prompt-file "$sys_file" --prompt-file "$artifact_file"

  [ "$SO_EXIT" -eq 0 ]
  local args
  args=$(agy_args "agy")
  [[ "$args" == *"BODY_FROM_FILE"* ]]
}

# 10. Body via stdin (no --prompt-file given)
@test "body: stdin supplies the artifact body when --prompt-file is omitted" {
  create_mock_engine "agy" "ok"
  local sys_file="${TEST_TEMP_DIR}/sys.md"
  printf 'System rubric.' > "$sys_file"

  SO_STDIN="BODY_FROM_STDIN"
  run_second_opinion --system-prompt-file "$sys_file"
  unset SO_STDIN

  [ "$SO_EXIT" -eq 0 ]
  local args
  args=$(agy_args "agy")
  [[ "$args" == *"BODY_FROM_STDIN"* ]]
}

# 11. Precedence: both --prompt-file and stdin given → --prompt-file wins
@test "body: --prompt-file takes precedence over stdin when both given" {
  create_mock_engine "agy" "ok"
  local sys_file="${TEST_TEMP_DIR}/sys.md"
  local artifact_file="${TEST_TEMP_DIR}/artifact.md"
  printf 'System rubric.' > "$sys_file"
  printf 'BODY_FROM_FILE' > "$artifact_file"

  SO_STDIN="BODY_FROM_STDIN"
  run_second_opinion --system-prompt-file "$sys_file" --prompt-file "$artifact_file"
  unset SO_STDIN

  [ "$SO_EXIT" -eq 0 ]
  local args
  args=$(agy_args "agy")
  [[ "$args" == *"BODY_FROM_FILE"* ]]
  [[ "$args" != *"BODY_FROM_STDIN"* ]]
}

# =============================================================================
# fail loud
# =============================================================================

# 12. Engines exhausted (CLI fails, no REST configured) → nonzero exit, empty stdout
@test "fail-loud: all engines exhausted → nonzero exit and empty stdout" {
  create_failing_engine "agy" 1
  local sys_file="${TEST_TEMP_DIR}/sys.md"
  local artifact_file="${TEST_TEMP_DIR}/artifact.md"
  printf 'System rubric.' > "$sys_file"
  printf 'Artifact body.' > "$artifact_file"

  run_second_opinion --system-prompt-file "$sys_file" --prompt-file "$artifact_file"

  [ "$SO_EXIT" -ne 0 ]
  [ -z "$SO_STDOUT" ]
  [[ "$SO_STDERR" == *"engines exhausted"* ]]
}

# =============================================================================
# Session key derivation (Section B robustness claim — direct verification)
# =============================================================================

# 13. Same label + same system prompt → same key (same CONV_FILE path is
#     reused, proven by seeing --conversation on the SECOND call).
@test "session: same label + same system prompt reuses the same session key" {
  create_mock_engine "agy" "review body"
  local sys_file="${TEST_TEMP_DIR}/sys.md"
  local artifact_file="${TEST_TEMP_DIR}/artifact.md"
  printf 'Stable rubric.' > "$sys_file"
  printf 'Artifact body.' > "$artifact_file"

  run_second_opinion --system-prompt-file "$sys_file" --prompt-file "$artifact_file" --session "same-label"
  [ "$SO_EXIT" -eq 0 ]
  local args_round1
  args_round1=$(agy_args "agy")
  [[ "$args_round1" != *"--conversation"* ]]

  run_second_opinion --system-prompt-file "$sys_file" --prompt-file "$artifact_file" --session "same-label"
  [ "$SO_EXIT" -eq 0 ]
  local args_round2
  args_round2=$(agy_args "agy")
  [[ "$args_round2" == *"--conversation aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"* ]]
}

# 14. Same label + one byte changed in system prompt → different key (no
#     --conversation on the second call — the old session file is orphaned
#     under its old hash, a NEW hash path has no prior conversation_id).
@test "session: same label + one-byte-changed system prompt derives a different key" {
  create_mock_engine "agy" "review body"
  local sys_file="${TEST_TEMP_DIR}/sys.md"
  local artifact_file="${TEST_TEMP_DIR}/artifact.md"
  printf 'Stable rubric A.' > "$sys_file"
  printf 'Artifact body.' > "$artifact_file"

  run_second_opinion --system-prompt-file "$sys_file" --prompt-file "$artifact_file" --session "same-label"
  [ "$SO_EXIT" -eq 0 ]

  # Change exactly one byte (A -> B) in the system prompt.
  printf 'Stable rubric B.' > "$sys_file"

  run_second_opinion --system-prompt-file "$sys_file" --prompt-file "$artifact_file" --session "same-label"
  [ "$SO_EXIT" -eq 0 ]
  local args_round2
  args_round2=$(agy_args "agy")
  [[ "$args_round2" != *"--conversation"* ]]
}

# =============================================================================
# label charset validation
# =============================================================================

# 15. Label containing "/" → error exit
@test "session: label with a slash is rejected" {
  local sys_file="${TEST_TEMP_DIR}/sys.md"
  printf 'System rubric.' > "$sys_file"

  run_second_opinion --system-prompt-file "$sys_file" --session "has/slash"

  [ "$SO_EXIT" -ne 0 ]
  [[ "$SO_STDERR" == *"invalid --session label"* ]]
}

# 16. Label containing ".." → error exit
@test "session: label with path traversal (..) is rejected" {
  local sys_file="${TEST_TEMP_DIR}/sys.md"
  printf 'System rubric.' > "$sys_file"

  run_second_opinion --system-prompt-file "$sys_file" --session "../escape"

  [ "$SO_EXIT" -ne 0 ]
  [[ "$SO_STDERR" == *"invalid --session label"* ]]
}

# =============================================================================
# No --session → temp file, single-round stateless
# =============================================================================

# 17. No --session given → succeeds, no --conversation ever passed, and no
#     leftover .so-* session file is created under REVIEW_COUNTER_DIR.
@test "session: no --session uses a temp file and stays single-round stateless" {
  create_mock_engine "agy" "review body"
  local sys_file="${TEST_TEMP_DIR}/sys.md"
  local artifact_file="${TEST_TEMP_DIR}/artifact.md"
  printf 'System rubric.' > "$sys_file"
  printf 'Artifact body.' > "$artifact_file"

  run_second_opinion --system-prompt-file "$sys_file" --prompt-file "$artifact_file"
  [ "$SO_EXIT" -eq 0 ]
  local args
  args=$(agy_args "agy")
  [[ "$args" != *"--conversation"* ]]

  # No .so-* file left behind in the shared counter dir.
  local leftover
  leftover=$(find "$REVIEW_COUNTER_DIR" -maxdepth 1 -name '.so-*' 2>/dev/null)
  [ -z "$leftover" ]
}

# =============================================================================
# REVIEW_HOOK_BUDGET unset does not crash
# =============================================================================

# 18. REVIEW_HOOK_BUDGET left unset — run_consultation() internally defaults
#     it to 595 before any code path (including rest.sh) reads it. Must not
#     crash under `set -u`.
@test "env: REVIEW_HOOK_BUDGET unset does not crash the driver" {
  create_mock_engine "agy" "review body"
  local sys_file="${TEST_TEMP_DIR}/sys.md"
  local artifact_file="${TEST_TEMP_DIR}/artifact.md"
  printf 'System rubric.' > "$sys_file"
  printf 'Artifact body.' > "$artifact_file"

  unset REVIEW_HOOK_BUDGET
  run_second_opinion --system-prompt-file "$sys_file" --prompt-file "$artifact_file"

  [ "$SO_EXIT" -eq 0 ]
  [ "$SO_STDOUT" = "review body" ]
}

# =============================================================================
# bash -n coverage note
# =============================================================================
# second-opinion.sh's syntax is already covered by plan-review.bats test 115
# ("dispatch-economy: bash -n reports no syntax errors after heredoc
# refactor"), whose glob is `find scripts -name '*.sh'` — this new file lands
# under scripts/ and is picked up automatically, no separate test needed here.
