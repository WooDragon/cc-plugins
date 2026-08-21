#!/usr/bin/env bats
# BDD tests for Manifest v2 signature-set enforcement in dispatch-check.sh.
#
# Given an approved v2 dispatch state, Agent and Task calls must match a
# declared preset/runtime signature. Malformed, stale, and v1 state stays
# fail-open so an unavailable guard cannot block userspace.

setup() {
  load 'test_helper/common-setup'
  common_setup
  unset DISPATCH_CHECK_DISABLED
}

teardown() {
  common_teardown
}

VALID_V2_DISPATCH='{
  "schema_version": 2,
  "plan_hash": "abc123",
  "created_at": 1700000000,
  "requires_dispatch_check": true,
  "steps": [
    {"id":"1","location":"main","subagent_type":null,"model_source":null,"model":null,"depends_on":null,"parallel_with":null},
    {"id":"2","location":"agent","subagent_type":"dev-econ","model_source":"preset","model":null,"depends_on":"1","parallel_with":null},
    {"id":"3","location":"agent","subagent_type":"Explore","model_source":"runtime","model":"haiku","depends_on":"1","parallel_with":null}
  ],
  "allowed_signatures": [
    {"subagent_type":"dev-econ","model_source":"preset"},
    {"subagent_type":"Explore","model_source":"runtime","model":"haiku"}
  ]
}'

# =============================================================================
# Manifest v2: declared signature acceptance
# =============================================================================

@test "dispatch v2: preset signature accepts matching type with model omitted" {
  create_dispatch_file "test-session" "$VALID_V2_DISPATCH"
  INPUT=$(build_agent_input subagent_type=dev-econ)
  run_dispatch_check

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "dispatch v2: runtime signature accepts exact type and model" {
  create_dispatch_file "test-session" "$VALID_V2_DISPATCH"
  INPUT=$(build_agent_input subagent_type=Explore model=haiku)
  run_dispatch_check

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "dispatch v2: repeated matching signature remains allowed" {
  create_dispatch_file "test-session" "$VALID_V2_DISPATCH"
  INPUT=$(build_agent_input subagent_type=Explore model=haiku)

  run_dispatch_check
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]

  run_dispatch_check
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

# =============================================================================
# Manifest v2: undeclared or malformed calls deny
# =============================================================================

@test "dispatch v2: preset call with explicit model denies" {
  create_dispatch_file "test-session" "$VALID_V2_DISPATCH"
  INPUT=$(build_agent_input subagent_type=dev-econ model=haiku)
  run_dispatch_check

  assert_deny_json
  [[ "$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" == *"omit model"* ]]
}

@test "dispatch v2: preset call with wrong type denies" {
  create_dispatch_file "test-session" "$VALID_V2_DISPATCH"
  INPUT=$(build_agent_input subagent_type=worker-econ)
  run_dispatch_check

  assert_deny_json
  [[ "$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" == *"signature"* ]]
}

@test "dispatch v2: runtime call with wrong model denies" {
  create_dispatch_file "test-session" "$VALID_V2_DISPATCH"
  INPUT=$(build_agent_input subagent_type=Explore model=sonnet)
  run_dispatch_check

  assert_deny_json
  [[ "$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" == *"signature"* ]]
}

@test "dispatch v2: runtime call with wrong type denies" {
  create_dispatch_file "test-session" "$VALID_V2_DISPATCH"
  INPUT=$(build_agent_input subagent_type=dev model=haiku)
  run_dispatch_check

  assert_deny_json
  [[ "$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" == *"signature"* ]]
}

@test "dispatch v2: runtime call missing model denies" {
  create_dispatch_file "test-session" "$VALID_V2_DISPATCH"
  INPUT=$(build_agent_input subagent_type=Explore)
  run_dispatch_check

  assert_deny_json
  [[ "$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" == *"signature"* ]]
}

# =============================================================================
# Agent / Task compatibility
# =============================================================================

@test "dispatch v2: Task accepts the same preset signature as Agent" {
  create_dispatch_file "test-session" "$VALID_V2_DISPATCH"
  INPUT=$(build_agent_input tool_name=Task subagent_type=dev-econ)
  run_dispatch_check

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "dispatch v2: Task rejects the same wrong runtime model as Agent" {
  create_dispatch_file "test-session" "$VALID_V2_DISPATCH"
  INPUT=$(build_agent_input tool_name=Task subagent_type=Explore model=sonnet)
  run_dispatch_check

  assert_deny_json
}

# =============================================================================
# Fail-open paths and legacy migration
# =============================================================================

@test "dispatch: no dispatch file allows silently" {
  INPUT=$(build_agent_input subagent_type=Explore model=haiku)
  run_dispatch_check

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "dispatch: jq missing allows silently" {
  INPUT=$(build_agent_input subagent_type=Explore model=sonnet)
  local restricted_bin="${TEST_TEMP_DIR}/restricted-bin"
  mkdir -p "$restricted_bin"
  local command_name command_path
  for command_name in bash cat mktemp rm; do
    command_path=$(command -v "$command_name")
    ln -s "$command_path" "${restricted_bin}/${command_name}"
  done
  local original_path="$PATH"
  export PATH="$restricted_bin"
  run_dispatch_check
  export PATH="$original_path"

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "dispatch: missing session_id allows silently" {
  create_dispatch_file "test-session" "$VALID_V2_DISPATCH"
  INPUT=$(build_agent_input session_id= subagent_type=Explore model=sonnet)
  run_dispatch_check

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "dispatch: requires_dispatch_check false allows silently" {
  local disabled_state
  disabled_state=$(printf '%s' "$VALID_V2_DISPATCH" | jq '.requires_dispatch_check = false')
  create_dispatch_file "test-session" "$disabled_state"
  INPUT=$(build_agent_input subagent_type=Explore model=sonnet)
  run_dispatch_check

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "dispatch v1: state without schema_version emits migration prompt and skips matching" {
  create_dispatch_file "test-session" '{"plan_hash":"old","requires_dispatch_check":true,"steps":[]}'
  INPUT=$(build_agent_input subagent_type=wrong model=wrong)
  run_dispatch_check

  assert_approve_json
  [[ "$(echo "$HOOK_STDOUT" | jq -r '.systemMessage')" == *"Manifest v1"* ]]
  [[ "$(echo "$HOOK_STDOUT" | jq -r '.systemMessage')" == *"schema_version: 2"* ]]
}

@test "dispatch: corrupt state allows silently" {
  create_dispatch_file "test-session" 'not-valid-json{{{{'
  INPUT=$(build_agent_input)
  run_dispatch_check

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "dispatch: structurally invalid v2 state allows silently" {
  create_dispatch_file "test-session" '{"schema_version":2,"requires_dispatch_check":true,"steps":[],"allowed_signatures":[{"subagent_type":"Explore","model_source":"runtime"}]}'
  INPUT=$(build_agent_input subagent_type=Explore)
  run_dispatch_check

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}


@test "dispatch: state with signatures not derived from steps allows silently" {
  local mismatched_state
  mismatched_state=$(printf '%s' "$VALID_V2_DISPATCH" | jq '.allowed_signatures = [{"subagent_type":"worker","model_source":"runtime","model":"sonnet"}]')
  create_dispatch_file "test-session" "$mismatched_state"
  INPUT=$(build_agent_input)
  run_dispatch_check

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "dispatch: stale state allows silently and removes file" {
  create_dispatch_file "test-session" "$VALID_V2_DISPATCH"
  local dispatch_file="${REVIEW_COUNTER_DIR}/.dispatch-test-session.json"
  touch -t 200001010000 "$dispatch_file"
  INPUT=$(build_agent_input)
  run_dispatch_check

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
  [ ! -f "$dispatch_file" ]
}

@test "dispatch: disabled kill switch allows silently" {
  export DISPATCH_CHECK_DISABLED=1
  create_dispatch_file "test-session" "$VALID_V2_DISPATCH"
  INPUT=$(build_agent_input subagent_type=Explore model=sonnet)
  run_dispatch_check

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "dispatch: non-Agent/Task tool allows silently" {
  create_dispatch_file "test-session" "$VALID_V2_DISPATCH"
  INPUT=$(build_agent_input tool_name=Read)
  run_dispatch_check

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}


# =============================================================================
# Mutation guard
# =============================================================================

@test "mutation: runtime model comparator has one executable hit" {
  create_dispatch_file "test-session" "$VALID_V2_DISPATCH"
  INPUT=$(build_agent_input subagent_type=Explore model=sonnet)

  # Baseline: an undeclared runtime model is denied by the production script.
  run_dispatch_check
  assert_deny_json

  local copy_dir="${TEST_TEMP_DIR}/dispatch-copy"
  local copy="${copy_dir}/dispatch-check.sh"
  mkdir -p "${copy_dir}/lib"
  cp "$DISPATCH_SCRIPT" "$copy"
  cp "${BATS_TEST_DIRNAME}/../scripts/lib/manifest.sh" "${copy_dir}/lib/manifest.sh"
  local mutation_count
  mutation_count=$(grep -cF -- '--arg model "$CALL_MODEL"' "$copy")
  [ "$mutation_count" -eq 1 ] || {
    echo "expected one runtime-model comparator, found $mutation_count"
    return 1
  }

  # Change only the copied comparator. If this mutation stops the deny, the
  # baseline assertion above is attached to the actual production branch.
  perl -0pi -e 's/--arg model "\$CALL_MODEL"/--arg model "haiku"/' "$copy"
  mutated_count=$(grep -cF -- '--arg model "haiku"' "$copy")
  [ "$mutated_count" -eq 1 ] || {
    echo "expected one mutated runtime-model comparator, found $mutated_count"
    return 1
  }

  DISPATCH_SCRIPT="$copy"
  run_dispatch_check
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}
