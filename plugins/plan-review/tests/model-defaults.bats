#!/usr/bin/env bats
# Model selection through the real hook and generic second-opinion entry points.
# Given isolated CLI/REST stubs, verify the selected model at each wire boundary.

setup() {
  load 'test_helper/common-setup'
  common_setup
  printf '%s' 'Review the artifact.' > "${TEST_TEMP_DIR}/rubric.txt"
}

teardown() {
  common_teardown
}

# Preserve the existing response fixture, but capture argv without flattening it.
create_capturing_agy() {
  if [ "${1:-success}" = "failure" ]; then
    create_failing_engine "agy" 1
  else
    create_mock_engine "agy" '<verdict>APPROVE</verdict>'
  fi
  mv "${MOCK_BIN}/agy" "${MOCK_BIN}/agy-response"
  cat > "${MOCK_BIN}/agy" <<'MOCK_EOF'
#!/bin/bash
printf '%s\0' "$@" > "${MOCK_BIN}/../agy-argv"
exec "${MOCK_BIN}/agy-response" "$@"
MOCK_EOF
  chmod +x "${MOCK_BIN}/agy"
}

run_model_entry() {
  case "$1" in
    hook)
      INPUT=$(build_input plan="Review model selection.")
      run_hook
      assert_ack_approve_json
      ;;
    driver)
      SO_STDIN="Review model selection."
      run_second_opinion --system-prompt-file "${TEST_TEMP_DIR}/rubric.txt"
      [ "$SO_EXIT" -eq 0 ]
      [ "$SO_STDOUT" = '<verdict>APPROVE</verdict>' ]
      ;;
    *) return 1 ;;
  esac
}

assert_agy_model() {
  python3 - "${TEST_TEMP_DIR}/agy-argv" "$1" <<'PY'
from pathlib import Path
import sys

raw = Path(sys.argv[1]).read_bytes()
assert raw.endswith(b"\0"), "missing argv terminator"
argv = [arg.decode() for arg in raw[:-1].split(b"\0")]
assert argv[:3] == ["--model", sys.argv[2], "--sandbox"], argv[:3]
assert argv.count("--model") == 1, "expected one --model flag"
assert argv[argv.index("--output-format") + 1] == "json", "expected JSON output"
PY
}

check_cli_model() {
  local entry="$1" state="$2" expected="$3"
  case "$state" in
    unset) unset AGY_MODEL ;;
    empty) export AGY_MODEL="" ;;
    override) export AGY_MODEL="$expected" ;;
    *) return 1 ;;
  esac
  export GEMINI_MODEL="rest-only-model"
  create_capturing_agy

  run_model_entry "$entry"
  assert_agy_model "$expected"
}

check_rest_model() {
  local entry="$1" state="$2" expected="$3"
  case "$state" in
    unset) unset GEMINI_MODEL ;;
    empty) export GEMINI_MODEL="" ;;
    override) export GEMINI_MODEL="$expected" ;;
    *) return 1 ;;
  esac
  export AGY_MODEL="Gemini CLI Override (High)"
  export REVIEW_API_URL="https://review.example.invalid"
  export REVIEW_API_KEY="test-key"
  create_capturing_agy failure
  local payload="${TEST_TEMP_DIR}/rest-payload.json"
  create_mock_curl_sse_capture '<verdict>APPROVE</verdict>' "$payload"

  run_model_entry "$entry"
  assert_agy_model "$AGY_MODEL"
  jq -e --arg model "$expected" '
    keys == ["max_tokens", "messages", "model", "stream", "temperature"]
    and .model == $model
    and .max_tokens == 16000
    and .temperature == 0.1
    and .stream == true
    and (.messages | length) == 2
    and .messages[0].role == "system"
    and .messages[1].role == "user"
    and ([.messages[].content | type == "string" and length > 0] | all)
  ' "$payload"
}

# Given an unset or empty AGY_MODEL, both entry points select Argon High.
# A nonempty override is preserved as one argv, independently of GEMINI_MODEL.
@test "models hook: unset AGY_MODEL selects Argon High as one argv" {
  check_cli_model hook unset 'Gemini 4 Argon (High)'
}

@test "models hook: empty AGY_MODEL selects Argon High as one argv" {
  check_cli_model hook empty 'Gemini 4 Argon (High)'
}

@test "models hook: nonempty AGY_MODEL override stays one argv" {
  check_cli_model hook override 'Custom CLI Model (Low)'
}

@test "models driver: unset AGY_MODEL selects Argon High as one argv" {
  check_cli_model driver unset 'Gemini 4 Argon (High)'
}

@test "models driver: empty AGY_MODEL selects Argon High as one argv" {
  check_cli_model driver empty 'Gemini 4 Argon (High)'
}

@test "models driver: nonempty AGY_MODEL override stays one argv" {
  check_cli_model driver override 'Custom CLI Model (Low)'
}

# Given a failed CLI call, REST uses its own default/override and original schema.
@test "models hook REST: unset GEMINI_MODEL preserves API default after CLI failure" {
  check_rest_model hook unset 'gemini-3.1-pro-preview'
}

@test "models hook REST: empty GEMINI_MODEL preserves API default after CLI failure" {
  check_rest_model hook empty 'gemini-3.1-pro-preview'
}

@test "models hook REST: nonempty GEMINI_MODEL overrides only the API model" {
  check_rest_model hook override 'custom-rest-model'
}

@test "models driver REST: unset GEMINI_MODEL preserves API default after CLI failure" {
  check_rest_model driver unset 'gemini-3.1-pro-preview'
}

@test "models driver REST: empty GEMINI_MODEL preserves API default after CLI failure" {
  check_rest_model driver empty 'gemini-3.1-pro-preview'
}

@test "models driver REST: nonempty GEMINI_MODEL overrides only the API model" {
  check_rest_model driver override 'custom-rest-model'
}
