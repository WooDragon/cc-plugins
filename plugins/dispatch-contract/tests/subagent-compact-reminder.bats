#!/usr/bin/env bats

setup() {
  ROOT="${BATS_TEST_DIRNAME}/.."
  CHECK="${BATS_TEST_DIRNAME}/test_helper/compact-reminder-cases.py"
}

@test "compact reminder: threshold, every check, resume and independent teammates" {
  run python3 "$CHECK" "$ROOT" thresholds
  [ "$status" -eq 0 ]
}

@test "compact reminder: completed auto UUIDs only and main exclusion" {
  run python3 "$CHECK" "$ROOT" events
  [ "$status" -eq 0 ]
}

@test "compact reminder: root fork and nested rewritten inherited UUIDs" {
  run python3 "$CHECK" "$ROOT" inheritance
  [ "$status" -eq 0 ]
}

@test "compact reminder: multilevel fork refs and explicit nested parent" {
  run python3 "$CHECK" "$ROOT" parents
  [ "$status" -eq 0 ]
}

@test "compact reminder: adopted sessions and transcript subdirectories" {
  run python3 "$CHECK" "$ROOT" adopt
  [ "$status" -eq 0 ]
}

@test "compact reminder: unknown damaged sources do not hide valid instances" {
  run python3 "$CHECK" "$ROOT" unknown
  [ "$status" -eq 0 ]
}

@test "compact reminder: exact PostToolUse wiring and child isolation" {
  run python3 "$CHECK" "$ROOT" wiring
  [ "$status" -eq 0 ]
}

@test "compact reminder: missing files, FIFO and missing Python fail open" {
  run python3 "$CHECK" "$ROOT" files
  [ "$status" -eq 0 ]
}
