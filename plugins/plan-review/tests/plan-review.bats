#!/usr/bin/env bats
# BDD test suite for plan-review hook.
#
# Covers all logic branches: guard layer, counter safety valve, plan extraction,
# dry-run, engine call error handling, verdict extraction (including the core
# set -e bug fix), branch behavior, and counter management.
#
# Dependencies: bats-core, jq

setup() {
  load 'test_helper/common-setup'
  common_setup
}

teardown() {
  common_teardown
}

# =============================================================================
# Guard Layer (early exits, no engine call)
# =============================================================================

# 1. jq missing → fail-open
@test "guard: jq missing → exit 0 (fail-open)" {
  # Build input BEFORE restricting PATH (build_input needs jq)
  INPUT=$(build_input)

  # Create a restricted PATH with only essential commands, no jq
  local restricted_bin="${TEST_TEMP_DIR}/restricted_bin"
  mkdir -p "$restricted_bin"

  # Symlink only the essentials but NOT jq
  for cmd in bash cat grep head tr printf mkdir rm find xargs ls echo mktemp chmod sed; do
    local cmd_path
    cmd_path=$(command -v "$cmd" 2>/dev/null) || continue
    ln -sf "$cmd_path" "${restricted_bin}/${cmd}"
  done

  # Override PATH to exclude jq
  local orig_path="$PATH"
  export PATH="$restricted_bin"

  run_hook
  export PATH="$orig_path"

  assert_allowed
  [[ "$HOOK_STDERR" == *"missing jq"* ]]
}

# 2. Recursive guard
@test "guard: PLAN_REVIEW_RUNNING=1 → exit 0" {
  export PLAN_REVIEW_RUNNING=1
  INPUT=$(build_input)
  run_hook
  assert_allowed
}

# 3. Global disable
@test "guard: REVIEW_DISABLED=1 → exit 0" {
  export REVIEW_DISABLED=1
  INPUT=$(build_input)
  run_hook
  assert_allowed
}

# 4. Non-ExitPlanMode tool
@test "guard: tool_name=Read → exit 0" {
  INPUT=$(build_input tool_name=Read)
  run_hook
  assert_allowed
}

# 5. Empty session_id
@test "guard: empty session_id → exit 0" {
  INPUT=$(build_input session_id=)
  run_hook
  assert_allowed
}

# =============================================================================
# Counter Safety Valve
# =============================================================================

# 6. Max rounds reached → allow through
@test "counter: max rounds reached → exit 0, counter deleted" {
  set_counter_value 3
  export REVIEW_MAX_ROUNDS=3
  INPUT=$(build_input)
  run_hook

  assert_allowed
  [[ "$HOOK_STDERR" == *"Max reviews"* ]]
  # Counter file should be deleted
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-count-test-session" ]
}

# 7. Below max rounds → proceeds to review
@test "counter: below max rounds → calls engine" {
  set_counter_value 2
  export REVIEW_MAX_ROUNDS=3
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>\nAll good."
  INPUT=$(build_input)
  run_hook

  assert_approve_json
}

# =============================================================================
# Plan Extraction
# =============================================================================

# 8. Plan from tool_input.plan
@test "plan: extract from tool_input.plan" {
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>\nLGTM."
  INPUT=$(build_input plan="My specific plan content")
  run_hook

  assert_approve_json
}

# 9. Plan from fallback file
@test "plan: fallback to plan file when tool_input has no plan" {
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>\nLGTM."
  create_plan_file "Plan from file system"
  INPUT=$(build_input_no_plan)
  run_hook

  assert_approve_json
}

# 10. No plan anywhere → allow
@test "plan: no plan content → exit 0" {
  INPUT=$(build_input_no_plan)
  run_hook

  assert_allowed
}

# =============================================================================
# Dry Run
# =============================================================================

# 11. Dry-run mode → synthetic APPROVE
@test "dry-run: REVIEW_DRY_RUN=1 → exit 0, no engine call" {
  export REVIEW_DRY_RUN=1
  # No mock engine created — if script tries to call one, it'll fail
  INPUT=$(build_input)
  run_hook

  assert_approve_json
}

# =============================================================================
# Engine Call Error Handling
# =============================================================================

# 12. Engine CLI not in PATH → fail-open
@test "engine: CLI not found → exit 0 (fail-open)" {
  # Don't create any mock — gemini won't exist in MOCK_BIN
  # But we need to ensure it's not found anywhere else either
  # Remove gemini from PATH by unsetting and reconstructing
  INPUT=$(build_input)

  # Temporarily override command lookup: hide real gemini if installed
  local clean_path="${MOCK_BIN}"
  local orig_path="$PATH"

  # Build PATH without any directory containing gemini
  while IFS=: read -r -d: dir || [ -n "$dir" ]; do
    if [ -d "$dir" ] && [ ! -x "${dir}/gemini" ]; then
      clean_path="${clean_path}:${dir}"
    fi
  done <<< "${orig_path}:"

  export PATH="$clean_path"
  run_hook
  export PATH="$orig_path"

  assert_allowed
  [[ "$HOOK_STDERR" == *"[WARNING]"* ]]
  [[ "$HOOK_STDERR" == *"not found"* ]]
}

# 13. Engine call fails (non-zero exit) — retried then fail-open
@test "engine: call fails → retry then exit 0 (fail-open)" {
  create_failing_engine "gemini" 1
  INPUT=$(build_input)
  run_hook

  assert_allowed
  [[ "$HOOK_STDERR" == *"retrying"* ]]
  [[ "$HOOK_STDERR" == *"[WARNING]"* ]]
}

# 14. Engine returns empty response — retried then fail-open
@test "engine: empty response → retry then exit 0" {
  create_mock_engine "gemini" ""
  INPUT=$(build_input)
  run_hook

  assert_allowed
  [[ "$HOOK_STDERR" == *"[WARNING]"* ]]
}

# =============================================================================
# Verdict Extraction (core bug fix validation)
# =============================================================================

# 15. Standard APPROVE tag
@test "verdict: standard APPROVE → allow JSON" {
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
Plan looks solid."
  INPUT=$(build_input)
  run_hook

  assert_approve_json
}

# 16. Standard CONCERNS tag
@test "verdict: standard CONCERNS → deny JSON" {
  create_mock_engine "gemini" "<verdict>CONCERNS</verdict>
Missing error handling."
  INPUT=$(build_input)
  run_hook

  assert_deny_json
}

# 17. Standard REJECT tag
@test "verdict: standard REJECT → deny JSON" {
  create_mock_engine "gemini" "<verdict>REJECT</verdict>
Fundamentally flawed approach."
  INPUT=$(build_input)
  run_hook

  assert_deny_json
}

# 18. Mixed case → normalized
@test "verdict: mixed case <Verdict>approve</Verdict> → APPROVE" {
  create_mock_engine "gemini" "<Verdict>approve</Verdict>
Looks fine."
  INPUT=$(build_input)
  run_hook

  assert_approve_json
}

# 19. BUG FIX: No verdict tag → fail-closed as CONCERNS (no crash)
@test "verdict: no verdict tag (BUG FIX) → CONCERNS, deny JSON, no crash" {
  create_mock_engine "gemini" "This plan has some issues but overall looks decent.
I would suggest improving error handling."
  INPUT=$(build_input)
  run_hook

  # Must NOT crash — exit 0
  [ "$HOOK_EXIT" -eq 0 ]
  # Must fail-closed to CONCERNS
  assert_deny_json
  # Must emit warning to stderr
  [[ "$HOOK_STDERR" == *"verdict tag missing or malformed"* ]]
}

# 20. Verdict tag with whitespace
@test "verdict: whitespace inside tag → extracted correctly" {
  create_mock_engine "gemini" "<verdict> CONCERNS </verdict>
Needs work."
  INPUT=$(build_input)
  run_hook

  assert_deny_json
}

# 21. Verdict typo → fail-closed
@test "verdict: misspelled verdict → CONCERNS (fail-closed)" {
  create_mock_engine "gemini" "<verdict>APPROV</verdict>
Almost right."
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  [[ "$HOOK_STDERR" == *"verdict tag missing or malformed"* ]]
}

# =============================================================================
# Branch Behavior + Counter Management
# =============================================================================

# 22. APPROVE → clear counter
@test "branch: APPROVE → counter file deleted" {
  set_counter_value 2
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
All good."
  INPUT=$(build_input)
  run_hook

  assert_approve_json
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-count-test-session" ]
}

# 23. CONCERNS → increment counter
@test "branch: CONCERNS → counter incremented" {
  create_mock_engine "gemini" "<verdict>CONCERNS</verdict>
Issues found."
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  local count
  count=$(get_counter_value)
  [ "$count" -eq 1 ]
}

# 24a. Allow JSON structure validation
@test "branch: APPROVE JSON has correct structure" {
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
Plan looks solid."
  INPUT=$(build_input)
  run_hook

  # Validate full JSON structure
  local event_name decision reason
  event_name=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.hookEventName')
  decision=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecision')
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')

  [ "$event_name" = "PreToolUse" ]
  [ "$decision" = "allow" ]
  # Reason should contain the review content
  [[ "$reason" == *"Plan looks solid"* ]]
  # Reason should contain APPROVED header
  [[ "$reason" == *"APPROVED"* ]]
}

# 24b. Allow JSON with round info (multi-round APPROVE)
@test "branch: APPROVE after prior rounds includes round info" {
  set_counter_value 2
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
All resolved."
  INPUT=$(build_input)
  run_hook

  assert_approve_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  # Should show round 3 (ATTEMPT=2 → round 2+1=3)
  [[ "$reason" == *"Round 3/3"* ]]
}

# 24c. Deny JSON structure validation
@test "branch: deny JSON has correct structure" {
  create_mock_engine "gemini" "<verdict>CONCERNS</verdict>
Critical issues."
  INPUT=$(build_input)
  run_hook

  # Validate full JSON structure
  local event_name decision reason
  event_name=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.hookEventName')
  decision=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecision')
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')

  [ "$event_name" = "PreToolUse" ]
  [ "$decision" = "deny" ]
  # Reason should contain the review content
  [[ "$reason" == *"Critical issues"* ]]
  # Reason should contain round info
  [[ "$reason" == *"Round"* ]]
}

# 25. Full 3-round consultation flow
@test "flow: 3 rounds CONCERNS then safety valve releases" {
  export REVIEW_MAX_ROUNDS=3
  create_mock_engine "gemini" "<verdict>CONCERNS</verdict>
Still not good enough."

  # Round 1: CONCERNS → deny, counter=1
  INPUT=$(build_input)
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 1 ]

  # Round 2: CONCERNS → deny, counter=2
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 2 ]

  # Round 3: CONCERNS → deny, counter=3
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 3 ]

  # Round 4: counter=3 >= MAX_ROUNDS=3 → safety valve, exit 0
  run_hook
  assert_allowed
  [[ "$HOOK_STDERR" == *"Max reviews"* ]]
  # Counter file should be cleaned up
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-count-test-session" ]
}

# =============================================================================
# Engine Retry Behavior
# =============================================================================

# 29. First call fails, retry succeeds → uses retry result
@test "retry: first call fails, retry succeeds → uses retry result" {
  create_flaky_engine "gemini" "<verdict>APPROVE</verdict>
Looks good after retry."
  INPUT=$(build_input)
  run_hook

  assert_approve_json
  # First attempt failed, should see retrying message
  [[ "$HOOK_STDERR" == *"retrying"* ]]
  # Retry succeeded — no WARNING
  [[ "$HOOK_STDERR" != *"[WARNING]"* ]]
}

# 30. First call empty, retry returns content → uses retry content
@test "retry: first call empty, retry returns content → uses retry content" {
  create_flaky_engine "gemini" "<verdict>CONCERNS</verdict>
Issues found on retry." "empty"
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  # First attempt was empty, should see retrying message
  [[ "$HOOK_STDERR" == *"retrying"* ]]
  # Retry succeeded — no WARNING
  [[ "$HOOK_STDERR" != *"[WARNING]"* ]]
}

# 31. Both attempts fail → fail-open with explicit WARNING
@test "retry: both attempts fail → fail-open with WARNING" {
  export REVIEW_ENGINE="claude"
  create_failing_engine "claude" 1
  INPUT=$(build_input)
  run_hook

  assert_allowed
  [[ "$HOOK_STDERR" == *"[WARNING]"* ]]
  [[ "$HOOK_STDERR" == *"引擎调用失败"* ]]
}

# =============================================================================
# Penetration Defense (审阅穿透防御)
# =============================================================================

# 26. Safety valve releases, then new plan enters fresh review cycle
@test "flow: new cycle starts fresh after safety valve releases" {
  export REVIEW_MAX_ROUNDS=3
  create_mock_engine "gemini" "<verdict>CONCERNS</verdict>
Not good enough."
  INPUT=$(build_input)

  # Exhaust all 3 rounds: deny, deny, deny
  run_hook; assert_deny_json; [ "$(get_counter_value)" -eq 1 ]
  run_hook; assert_deny_json; [ "$(get_counter_value)" -eq 2 ]
  run_hook; assert_deny_json; [ "$(get_counter_value)" -eq 3 ]

  # Round 4: safety valve fires, counter deleted
  run_hook
  assert_allowed
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-count-test-session" ]

  # New plan submitted — engine now approves (simulates fresh review)
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
LGTM after revision."
  INPUT=$(build_input plan="Revised plan v2")
  run_hook

  # Must go through engine (APPROVE), not short-circuit
  assert_approve_json
  # Counter should be cleaned up by APPROVE branch
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-count-test-session" ]
}

# 27. Engine failure does not touch counter (fail-open, counter unchanged)
@test "flow: engine failure does not modify counter" {
  INPUT=$(build_input)

  # No counter file exists initially
  [ "$(get_counter_value)" -eq 0 ]

  # Engine fails → fail-open, counter must remain untouched
  create_failing_engine "gemini" 1
  run_hook
  assert_allowed

  # Counter file must NOT exist (engine failure should not create one)
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-count-test-session" ]
  [ "$(get_counter_value)" -eq 0 ]
}

# 28. Engine failure mid-cycle preserves existing counter value
@test "flow: engine failure mid-cycle preserves counter" {
  export REVIEW_MAX_ROUNDS=3
  INPUT=$(build_input)

  # Round 1: normal CONCERNS → counter=1
  create_mock_engine "gemini" "<verdict>CONCERNS</verdict>
Issues found."
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 1 ]

  # Round 2: engine crashes → fail-open, counter must stay at 1
  create_failing_engine "gemini" 1
  run_hook
  assert_allowed
  [ "$(get_counter_value)" -eq 1 ]

  # Round 3: engine recovers → CONCERNS, counter=2 (continues from 1)
  create_mock_engine "gemini" "<verdict>CONCERNS</verdict>
Still has issues."
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 2 ]
}
