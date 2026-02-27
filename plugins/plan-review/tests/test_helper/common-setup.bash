#!/bin/bash
# Common test infrastructure for plan-review hook BDD tests.
#
# Provides: isolated temp dirs, mock engine generators, input builders,
# assertion helpers. All paths are injected via env vars so production
# paths are never touched.

# Path to the script under test
HOOK_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/plan-review.sh"

# --- Setup / Teardown ---

common_setup() {
  TEST_TEMP_DIR=$(mktemp -d)

  # Isolated directories for all script paths
  export MOCK_BIN="${TEST_TEMP_DIR}/bin"
  export REVIEW_COUNTER_DIR="${TEST_TEMP_DIR}/counters"
  export REVIEW_PLAN_DIR="${TEST_TEMP_DIR}/plans"
  export REVIEW_LOG_DIR="${TEST_TEMP_DIR}/logs"

  mkdir -p "$MOCK_BIN" "$REVIEW_COUNTER_DIR" "$REVIEW_PLAN_DIR" "$REVIEW_LOG_DIR"

  # Prepend MOCK_BIN to PATH so mock engines are found first
  export PATH="${MOCK_BIN}:${PATH}"

  # Sane defaults: gemini engine, not disabled, not dry-run, 3 rounds
  export REVIEW_ENGINE="gemini"
  export REVIEW_DISABLED="0"
  export REVIEW_DRY_RUN="0"
  export REVIEW_MAX_ROUNDS="3"

  # Zero retry delay in tests (production: 2s)
  export REVIEW_RETRY_DELAY=0

  # Prevent recursive guard from firing
  unset PLAN_REVIEW_RUNNING

  # Prevent legacy env vars from leaking in
  unset GEMINI_REVIEW_OFF
  unset GEMINI_DRY_RUN
  unset GEMINI_MAX_REVIEWS
}

common_teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

# --- Mock Engine Generators ---

# create_mock_engine <name> <output>
#   Creates an executable mock at MOCK_BIN/<name> that prints <output> to stdout.
create_mock_engine() {
  local name="$1"
  local output="$2"
  cat > "${MOCK_BIN}/${name}" << MOCK_EOF
#!/bin/bash
cat << 'ENGINE_OUTPUT'
${output}
ENGINE_OUTPUT
MOCK_EOF
  chmod +x "${MOCK_BIN}/${name}"
}

# create_failing_engine <name> <exit_code>
#   Creates a mock that always fails with the given exit code.
create_failing_engine() {
  local name="$1"
  local exit_code="$2"
  cat > "${MOCK_BIN}/${name}" << MOCK_EOF
#!/bin/bash
exit ${exit_code}
MOCK_EOF
  chmod +x "${MOCK_BIN}/${name}"
}

# create_flaky_engine <name> <success_output> [first_behavior]
#   First call fails or returns empty, subsequent calls return success_output.
#   first_behavior: "exit" (default) → exit 1 on first call
#                   "empty" → return empty string on first call
#   State file lives in TEST_TEMP_DIR (per-test isolation, teardown auto-cleans).
create_flaky_engine() {
  local name="$1"
  local output="$2"
  local first_behavior="${3:-exit}"
  local state_file="${TEST_TEMP_DIR}/.flaky-${name}-state"
  local first_action="exit 1"
  [ "$first_behavior" != "empty" ] || first_action="exit 0"

  cat > "${MOCK_BIN}/${name}" << MOCK_EOF
#!/bin/bash
if [ ! -f "${state_file}" ]; then
  touch "${state_file}"
  ${first_action}
fi
cat << 'ENGINE_OUTPUT'
${output}
ENGINE_OUTPUT
MOCK_EOF
  chmod +x "${MOCK_BIN}/${name}"
}

# --- Input Construction ---

# build_input [key=value ...]
#   Constructs a JSON hook input. Defaults:
#     tool_name=ExitPlanMode, session_id=test-session, plan="Test plan content"
#   Override any field: build_input tool_name=Read session_id=abc plan="my plan"
build_input() {
  local tool_name="ExitPlanMode"
  local session_id="test-session"
  local plan="Test plan content"
  local cwd="/tmp"
  local transcript_path=""

  for arg in "$@"; do
    local key="${arg%%=*}"
    local val="${arg#*=}"
    case "$key" in
      tool_name)       tool_name="$val" ;;
      session_id)      session_id="$val" ;;
      plan)            plan="$val" ;;
      cwd)             cwd="$val" ;;
      transcript_path) transcript_path="$val" ;;
    esac
  done

  # Build JSON with jq for proper escaping
  jq -n \
    --arg tn "$tool_name" \
    --arg sid "$session_id" \
    --arg p "$plan" \
    --arg cwd "$cwd" \
    --arg tp "$transcript_path" \
    '{
      tool_name: $tn,
      session_id: $sid,
      tool_input: { plan: $p },
      cwd: $cwd,
      transcript_path: $tp
    }'
}

# build_input_no_plan [key=value ...]
#   Constructs input without a plan field in tool_input.
build_input_no_plan() {
  local tool_name="ExitPlanMode"
  local session_id="test-session"
  local cwd="/tmp"

  for arg in "$@"; do
    local key="${arg%%=*}"
    local val="${arg#*=}"
    case "$key" in
      tool_name)  tool_name="$val" ;;
      session_id) session_id="$val" ;;
      cwd)        cwd="$val" ;;
    esac
  done

  jq -n \
    --arg tn "$tool_name" \
    --arg sid "$session_id" \
    --arg cwd "$cwd" \
    '{
      tool_name: $tn,
      session_id: $sid,
      tool_input: {},
      cwd: $cwd
    }'
}

# --- Plan File Helpers ---

# create_plan_file <content>
#   Writes a .md file in REVIEW_PLAN_DIR with the given content.
create_plan_file() {
  local content="$1"
  local filename="${2:-test-plan.md}"
  printf '%s' "$content" > "${REVIEW_PLAN_DIR}/${filename}"
}

# --- Counter Helpers ---

# get_counter_value
#   Reads the counter file for session "test-session". Returns 0 if missing.
get_counter_value() {
  local session="${1:-test-session}"
  cat "${REVIEW_COUNTER_DIR}/.review-count-${session}" 2>/dev/null || echo "0"
}

# set_counter_value <value> [session_id]
#   Sets the counter file for the given session.
set_counter_value() {
  local value="$1"
  local session="${2:-test-session}"
  echo "$value" > "${REVIEW_COUNTER_DIR}/.review-count-${session}"
}

# --- Run Hook ---

# run_hook
#   Feeds INPUT (must be set by caller or defaults to build_input) through the
#   hook script via stdin. Env vars must be exported BEFORE calling run_hook.
#   Sets: HOOK_STDOUT, HOOK_STDERR, HOOK_EXIT
run_hook() {
  local input="${INPUT:-$(build_input)}"

  HOOK_STDOUT=""
  HOOK_STDERR=""
  HOOK_EXIT=0

  local stderr_file
  stderr_file=$(mktemp)

  # Direct invocation — no eval, no exec indirection, no quote destruction.
  HOOK_STDOUT=$(bash "$HOOK_SCRIPT" <<< "$input" 2>"$stderr_file") || HOOK_EXIT=$?
  HOOK_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

# --- Assertion Helpers ---

# assert_allowed
#   Verifies: exit 0, no deny JSON in stdout.
assert_allowed() {
  [ "$HOOK_EXIT" -eq 0 ] || {
    echo "Expected exit 0, got $HOOK_EXIT"
    echo "stderr: $HOOK_STDERR"
    return 1
  }
  # stdout should NOT contain permissionDecision:deny
  if echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
    echo "Expected no deny JSON, got: $HOOK_STDOUT"
    return 1
  fi
}

# assert_deny_json
#   Verifies: exit 0, stdout is valid JSON with permissionDecision=deny.
assert_deny_json() {
  [ "$HOOK_EXIT" -eq 0 ] || {
    echo "Expected exit 0, got $HOOK_EXIT"
    echo "stderr: $HOOK_STDERR"
    return 1
  }
  # Must be valid JSON
  echo "$HOOK_STDOUT" | jq . >/dev/null 2>&1 || {
    echo "stdout is not valid JSON: $HOOK_STDOUT"
    return 1
  }
  # Must contain permissionDecision=deny
  local decision
  decision=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecision')
  [ "$decision" = "deny" ] || {
    echo "Expected permissionDecision=deny, got: $decision"
    return 1
  }
}
