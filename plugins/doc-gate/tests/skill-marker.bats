#!/usr/bin/env bats
# BDD tests for skill-marker.sh (PreToolUse:Skill hook)

setup() {
  load 'test_helper/common-setup'
  common_setup
}

teardown() {
  common_teardown
}

# --- Tracked skill creates marker ---

@test "tracked skill: doc-maintenance → marker created" {
  INPUT=$(build_skill_input)
  run_marker
  [ "$HOOK_EXIT" -eq 0 ]
  [ -f "$SKILL_GATE_DIR/.skill-gate-test-session-doc-maintenance" ]
}

@test "tracked skill: marker contains timestamp" {
  INPUT=$(build_skill_input)
  run_marker
  local content
  content=$(cat "$SKILL_GATE_DIR/.skill-gate-test-session-doc-maintenance")
  [[ "$content" =~ ^[0-9]+$ ]]
}

@test "tracked skill: always exit 0, never deny" {
  INPUT=$(build_skill_input)
  run_marker
  assert_allowed
  [ -z "$HOOK_STDOUT" ]
}

# --- Untracked skill ---

@test "untracked skill: other-skill → no marker" {
  INPUT=$(build_skill_input skill=other-skill)
  run_marker
  [ ! -f "$SKILL_GATE_DIR/.skill-gate-test-session-other-skill" ]
}

# --- Guard: wrong tool_name ---

@test "guard: tool_name=Edit → no marker" {
  INPUT=$(build_raw_input "Edit")
  run_marker
  local count
  count=$(find "$SKILL_GATE_DIR" -name '.skill-gate-*' | wc -l)
  [ "$count" -eq 0 ]
}

# --- Guard: missing session_id ---

@test "guard: empty session_id → no marker" {
  INPUT=$(build_skill_input session_id=)
  run_marker
  local count
  count=$(find "$SKILL_GATE_DIR" -name '.skill-gate-*' | wc -l)
  [ "$count" -eq 0 ]
}

# --- Guard: missing skill name ---

@test "guard: empty skill → no marker" {
  INPUT=$(build_skill_input skill=)
  run_marker
  local count
  count=$(find "$SKILL_GATE_DIR" -name '.skill-gate-*' | wc -l)
  [ "$count" -eq 0 ]
}

# --- Kill switch ---

@test "kill switch: DISABLED=1 → no marker" {
  export SKILL_GATE_DISABLED=1
  INPUT=$(build_skill_input)
  run_marker
  [ ! -f "$SKILL_GATE_DIR/.skill-gate-test-session-doc-maintenance" ]
}

# --- Fail-open: jq missing ---

@test "fail-open: jq missing → exit 0, no marker" {
  local mock_bin="${TEST_TEMP_DIR}/nojq"
  mkdir -p "$mock_bin"
  # Empty PATH with only basic commands, no jq
  PATH="$mock_bin:/usr/bin:/bin" INPUT=$(build_skill_input) run_marker
  [ "$HOOK_EXIT" -eq 0 ]
}

# --- Logging ---

@test "logging: marker write logged" {
  INPUT=$(build_skill_input)
  run_marker
  assert_log_contains "marker-written"
  assert_log_contains "doc-maintenance"
}
