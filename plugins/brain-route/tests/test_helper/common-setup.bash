#!/bin/bash
# Test infrastructure for brain-route hook BDD tests.

GATE_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/brain-route-gate.sh"

# --- Setup / Teardown ---

common_setup() {
  TEST_TEMP_DIR=$(mktemp -d)

  export BRAIN_ROUTE_GATE_DIR="${TEST_TEMP_DIR}/gate"
  mkdir -p "$BRAIN_ROUTE_GATE_DIR"

  export BRAIN_ROUTE_DISABLED="0"
  export BRAIN_ROUTE_STALE_MIN="120"
  unset BRAIN_ROUTE_MIN_HITS

  unset SKILL_GATE_DIR
}

common_teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

# --- Input Construction ---

# build_write_input [file_path=X] [session_id=Y] [content=Z]
build_write_input() {
  local file_path="/project/projects/x/memory/lesson.md"
  local session_id="test-session"
  local content="just some notes"

  for arg in "$@"; do
    local key="${arg%%=*}"
    local val="${arg#*=}"
    case "$key" in
      file_path)   file_path="$val" ;;
      session_id)  session_id="$val" ;;
      content)     content="$val" ;;
    esac
  done

  jq -n \
    --arg fp "$file_path" \
    --arg sid "$session_id" \
    --arg c "$content" \
    '{
      tool_name: "Write",
      session_id: $sid,
      tool_input: { file_path: $fp, content: $c }
    }'
}

# build_edit_input [file_path=X] [session_id=Y] [new_string=Z]
build_edit_input() {
  local file_path="/project/projects/x/memory/lesson.md"
  local session_id="test-session"
  local new_string="just some notes"

  for arg in "$@"; do
    local key="${arg%%=*}"
    local val="${arg#*=}"
    case "$key" in
      file_path)   file_path="$val" ;;
      session_id)  session_id="$val" ;;
      new_string)  new_string="$val" ;;
    esac
  done

  jq -n \
    --arg fp "$file_path" \
    --arg sid "$session_id" \
    --arg ns "$new_string" \
    '{
      tool_name: "Edit",
      session_id: $sid,
      tool_input: { file_path: $fp, old_string: "old", new_string: $ns }
    }'
}

# --- Marker Helpers ---

# create_route_marker [file_path] [session_id]
create_route_marker() {
  local file_path="${1:-/project/projects/x/memory/lesson.md}"
  local session="${2:-test-session}"
  local hash
  hash=$(printf '%s' "$file_path" | shasum -a 256 | cut -c1-16)
  printf '%s' "$(date +%s)" > "$BRAIN_ROUTE_GATE_DIR/.brain-route-${session}-${hash}"
}

# --- Run Helpers ---

# run_gate
run_gate() {
  local input="${INPUT:-$(build_write_input)}"

  HOOK_STDOUT=""
  HOOK_STDERR=""
  HOOK_EXIT=0

  local stderr_file
  stderr_file=$(mktemp)

  HOOK_STDOUT=$(bash "$GATE_SCRIPT" <<< "$input" 2>"$stderr_file") || HOOK_EXIT=$?
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
  local event_name
  event_name=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.hookEventName')
  [ "$event_name" = "PreToolUse" ] || {
    echo "Expected hookSpecificOutput.hookEventName=PreToolUse, got: '$event_name'"
    echo "stdout: $HOOK_STDOUT"
    return 1
  }
}
