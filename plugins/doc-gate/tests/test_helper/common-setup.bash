#!/bin/bash
# Test infrastructure for doc-gate hook BDD tests.

GATE_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/skill-gate.sh"
MARKER_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/skill-marker.sh"

# --- Setup / Teardown ---

common_setup() {
  TEST_TEMP_DIR=$(mktemp -d)

  export SKILL_GATE_DIR="${TEST_TEMP_DIR}/gate"
  export SKILL_GATE_LOG_DIR="${TEST_TEMP_DIR}/logs"

  mkdir -p "$SKILL_GATE_DIR" "$SKILL_GATE_LOG_DIR"

  export SKILL_GATE_DISABLED="0"
  export SKILL_GATE_STALE_MIN="120"

  unset REVIEW_LOG_DIR
}

common_teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

# --- Input Construction ---

# build_edit_input [file_path=X] [session_id=Y]
build_edit_input() {
  local file_path="/project/docs/guide.md"
  local session_id="test-session"

  for arg in "$@"; do
    local key="${arg%%=*}"
    local val="${arg#*=}"
    case "$key" in
      file_path)   file_path="$val" ;;
      session_id)  session_id="$val" ;;
    esac
  done

  jq -n \
    --arg fp "$file_path" \
    --arg sid "$session_id" \
    '{
      tool_name: "Edit",
      session_id: $sid,
      tool_input: { file_path: $fp, old_string: "old", new_string: "new" }
    }'
}

# build_write_input [file_path=X] [session_id=Y]
build_write_input() {
  local file_path="/project/docs/guide.md"
  local session_id="test-session"

  for arg in "$@"; do
    local key="${arg%%=*}"
    local val="${arg#*=}"
    case "$key" in
      file_path)   file_path="$val" ;;
      session_id)  session_id="$val" ;;
    esac
  done

  jq -n \
    --arg fp "$file_path" \
    --arg sid "$session_id" \
    '{
      tool_name: "Write",
      session_id: $sid,
      tool_input: { file_path: $fp, content: "content" }
    }'
}

# build_skill_input [skill=X] [session_id=Y]
build_skill_input() {
  local skill="doc-maintenance"
  local session_id="test-session"

  for arg in "$@"; do
    local key="${arg%%=*}"
    local val="${arg#*=}"
    case "$key" in
      skill)       skill="$val" ;;
      session_id)  session_id="$val" ;;
    esac
  done

  jq -n \
    --arg s "$skill" \
    --arg sid "$session_id" \
    '{
      tool_name: "Skill",
      session_id: $sid,
      tool_input: { skill: $s, args: "" }
    }'
}

# build_raw_input <tool_name> [session_id=Y]
build_raw_input() {
  local tool_name="$1"
  local session_id="test-session"

  for arg in "${@:2}"; do
    local key="${arg%%=*}"
    local val="${arg#*=}"
    case "$key" in
      session_id) session_id="$val" ;;
    esac
  done

  jq -n \
    --arg tn "$tool_name" \
    --arg sid "$session_id" \
    '{tool_name: $tn, session_id: $sid, tool_input: {}}'
}

# --- Marker Helpers ---

# create_gate_marker [skill_name] [session_id]
create_gate_marker() {
  local skill="${1:-doc-maintenance}"
  local session="${2:-test-session}"
  printf '%s' "$(date +%s)" > "$SKILL_GATE_DIR/.skill-gate-${session}-${skill}"
}

# --- Run Helpers ---

# run_gate
run_gate() {
  local input="${INPUT:-$(build_edit_input)}"

  HOOK_STDOUT=""
  HOOK_STDERR=""
  HOOK_EXIT=0

  local stderr_file
  stderr_file=$(mktemp)

  HOOK_STDOUT=$(bash "$GATE_SCRIPT" <<< "$input" 2>"$stderr_file") || HOOK_EXIT=$?
  HOOK_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

# run_marker
run_marker() {
  local input="${INPUT:-$(build_skill_input)}"

  HOOK_STDOUT=""
  HOOK_STDERR=""
  HOOK_EXIT=0

  local stderr_file
  stderr_file=$(mktemp)

  HOOK_STDOUT=$(bash "$MARKER_SCRIPT" <<< "$input" 2>"$stderr_file") || HOOK_EXIT=$?
  HOOK_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

# run_gate_raw_stdin <literal_input>
run_gate_raw_stdin() {
  local raw_input="$1"
  HOOK_STDOUT="" HOOK_STDERR="" HOOK_EXIT=0
  local stderr_file
  stderr_file=$(mktemp)
  HOOK_STDOUT=$(printf '%s' "$raw_input" | bash "$GATE_SCRIPT" 2>"$stderr_file") || HOOK_EXIT=$?
  HOOK_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

# --- Assertion Helpers ---

# assert_allowed — exit 0, no deny in stdout
assert_allowed() {
  [ "$HOOK_EXIT" -eq 0 ] || {
    echo "Expected exit 0, got $HOOK_EXIT"
    echo "stderr: $HOOK_STDERR"
    return 1
  }
  if [ -n "$HOOK_STDOUT" ] && echo "$HOOK_STDOUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    echo "Expected allow, got deny: $HOOK_STDOUT"
    return 1
  fi
}

# assert_deny_json — exit 0, valid JSON with permissionDecision=deny
assert_deny_json() {
  [ "$HOOK_EXIT" -eq 0 ] || {
    echo "Expected exit 0, got $HOOK_EXIT"
    echo "stderr: $HOOK_STDERR"
    return 1
  }
  echo "$HOOK_STDOUT" | jq . >/dev/null 2>&1 || {
    echo "stdout is not valid JSON: $HOOK_STDOUT"
    return 1
  }
  local decision
  decision=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecision')
  [ "$decision" = "deny" ] || {
    echo "Expected permissionDecision=deny, got: $decision"
    return 1
  }
  # Must carry hookEventName — the framework rejects any hookSpecificOutput
  # missing it ("Hook JSON output validation failed").
  local event_name
  event_name=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.hookEventName')
  [ "$event_name" = "PreToolUse" ] || {
    echo "Expected hookSpecificOutput.hookEventName=PreToolUse, got: '$event_name'"
    echo "stdout: $HOOK_STDOUT"
    return 1
  }
}

# assert_log_contains <pattern>
assert_log_contains() {
  local pattern="$1"
  local log_file="${SKILL_GATE_LOG_DIR}/skill-gate.log"
  [ -f "$log_file" ] || { echo "Log file missing: $log_file"; return 1; }
  grep -q -- "$pattern" "$log_file" || { echo "Pattern '$pattern' not found in log:"; cat "$log_file"; return 1; }
}
