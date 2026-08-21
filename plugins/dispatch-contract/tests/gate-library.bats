#!/usr/bin/env bats
# BDD coverage for the dispatch-contract shared gate library loader.

setup() {
  load 'test_helper/common-setup'
  common_setup
  GATE_LIBRARY="${BATS_TEST_DIRNAME}/../hooks/lib/gate.sh"
}

teardown() {
  common_teardown
}

@test "gate library: gate_require_library sources a library with all required helpers" {
  local library="$TEST_TEMP_DIR/agent-kind.sh"
  printf '%s\n' \
    'normalize_agent_type() { :; }' \
    'is_runtime_model_agent() { :; }' > "$library"

  run bash -c '. "$1"; gate_require_library test-gate "$2" normalize_agent_type is_runtime_model_agent' \
    bash "$GATE_LIBRARY" "$library"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "gate library: source failure emits unavailable degrade and returns one" {
  local library="$TEST_TEMP_DIR/missing-agent-kind.sh"

  run bash -c '. "$1"; gate_require_library test-gate "$2" normalize_agent_type' \
    bash "$GATE_LIBRARY" "$library"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[GATE-DEGRADE] test-gate: missing-agent-kind.sh unavailable"* ]]
}

@test "gate library: missing required helper emits lacks-required-helpers degrade and returns one" {
  local library="$TEST_TEMP_DIR/incomplete-agent-kind.sh"
  printf '%s\n' 'normalize_agent_type() { :; }' > "$library"

  run bash -c '. "$1"; gate_require_library test-gate "$2" normalize_agent_type is_runtime_model_agent' \
    bash "$GATE_LIBRARY" "$library"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[GATE-DEGRADE] test-gate: incomplete-agent-kind.sh lacks required helpers"* ]]
}
