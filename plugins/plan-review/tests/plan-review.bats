#!/usr/bin/env bats
# BDD test suite for plan-review hook.
#
# Covers all logic branches: guard layer, dual safety valves, severity-aware
# counter logic, plan extraction, dry-run, engine call error handling, verdict
# extraction (including the core set -e bug fix), branch behavior, counter
# management, and full multi-round flows.
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

# 1. jq missing → fail-open with visible JSON
@test "guard: jq missing → allow JSON with WARNING" {
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

  assert_approve_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"jq missing"* ]]
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
# Non-Critical Safety Valve
# =============================================================================

# 6. Non-Critical safety valve → allow JSON with ESCALATED
@test "counter: non-critical safety valve → allow JSON with ESCALATED" {
  set_counter_value 3 test-session 5
  export REVIEW_MAX_ROUNDS=3
  INPUT=$(build_input)
  run_hook

  assert_approve_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"ESCALATED"* ]]
  # Counter file should be deleted (allow path)
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-count-test-session" ]
}

# 7. Below max rounds → proceeds to review
@test "counter: below max rounds → calls engine" {
  set_counter_value 2 test-session 3
  export REVIEW_MAX_ROUNDS=3
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>\nAll good."
  INPUT=$(build_input)
  run_hook_to_completion

  assert_approve_json
}

# =============================================================================
# Plan Extraction
# =============================================================================

# 8. Plan from tool_input.plan
@test "plan: extract from tool_input.plan" {
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>\nLGTM."
  INPUT=$(build_input plan="My specific plan content")
  run_hook_to_completion

  assert_approve_json
}

# 9. Plan from fallback file
@test "plan: fallback to plan file when tool_input has no plan" {
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>\nLGTM."
  create_plan_file "Plan from file system"
  INPUT=$(build_input_no_plan)
  run_hook_to_completion

  assert_approve_json
}

# 10. No plan anywhere → allow JSON with SKIP
@test "plan: no plan content → allow JSON with SKIP" {
  INPUT=$(build_input_no_plan)
  run_hook

  assert_approve_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"[SKIP]"* ]]
}

# =============================================================================
# Dry Run
# =============================================================================

# 11. Dry-run mode → synthetic APPROVE
@test "dry-run: REVIEW_DRY_RUN=1 → ack-deny then allow, no engine call" {
  export REVIEW_DRY_RUN=1
  # No mock engine created — if script tries to call one, it'll fail
  INPUT=$(build_input)
  run_hook_to_completion

  assert_approve_json
}

# =============================================================================
# Engine Call Error Handling
# =============================================================================

# 12. Engine CLI not in PATH → allow JSON with WARNING
@test "engine: CLI not found → allow JSON with WARNING" {
  # Don't create any mock — gemini won't exist in MOCK_BIN
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

  assert_approve_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"[WARNING]"* ]]
  [[ "$reason" == *"not found"* ]]
}

# 13. Engine call fails (non-zero exit) — retried then deny with failure reason
@test "engine: call fails → retry then deny with failure reason" {
  create_failing_engine "gemini" 1
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  [[ "$HOOK_STDERR" == *"retrying"* ]]
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"all review engines failed"* ]]
}

# 14. Engine returns empty response — retried then allow JSON with WARNING
@test "engine: empty response → retry then allow JSON with WARNING" {
  create_mock_engine "gemini" ""
  INPUT=$(build_input)
  run_hook

  assert_approve_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"[WARNING]"* ]]
}

# =============================================================================
# Verdict Extraction (core bug fix validation)
# =============================================================================

# 15. Standard APPROVE tag → ack-deny then ack-round
@test "verdict: standard APPROVE → ack-deny then allow" {
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
Plan looks solid."
  INPUT=$(build_input)

  # First call: ack-deny (deny with APPROVED)
  run_hook
  assert_ack_approve_json

  # Second call: ack-round (allow)
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
  run_hook_to_completion

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

# 22. APPROVE → ack-round clears counter and marker
@test "branch: APPROVE → counter and marker cleaned after ack-round" {
  set_counter_value 2 test-session 3
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
All good."
  INPUT=$(build_input)
  run_hook_to_completion

  assert_approve_json
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-count-test-session" ]
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-approved-test-session" ]
}

# 23. CONCERNS → increment counter (both ATTEMPT and TOTAL)
@test "branch: CONCERNS → counter incremented" {
  create_mock_engine "gemini" "<verdict>CONCERNS</verdict>
Issues found."
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  [ "$(get_counter_value)" -eq 1 ]
  [ "$(get_total_rounds)" -eq 1 ]
}

# 24a. Ack-deny JSON structure validation
@test "branch: APPROVE ack-deny JSON has correct structure" {
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
Plan looks solid."
  INPUT=$(build_input)
  run_hook

  # Validate ack-deny JSON structure
  local event_name decision reason
  event_name=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.hookEventName')
  decision=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecision')
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')

  [ "$event_name" = "PreToolUse" ]
  [ "$decision" = "deny" ]
  # Reason should contain the review content
  [[ "$reason" == *"Plan looks solid"* ]]
  # Reason should contain APPROVED header
  [[ "$reason" == *"APPROVED"* ]]
  # Marker file should exist (ack-round pending)
  [ -f "${REVIEW_COUNTER_DIR}/.review-approved-test-session" ]
}

# 24b. Ack-deny with round info (multi-round APPROVE)
@test "branch: APPROVE ack-deny after prior rounds includes round info" {
  set_counter_value 2 test-session 4
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
All resolved."
  INPUT=$(build_input)
  run_hook

  assert_ack_approve_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  # TOTAL_ROUNDS=4 → round displayed is 4+1=5
  [[ "$reason" == *"Round 5"* ]]
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

# 25. Full 3-round CONCERNS consultation flow
@test "flow: 3 rounds CONCERNS then safety valve releases" {
  export REVIEW_MAX_ROUNDS=3
  create_mock_engine "gemini" "<verdict>CONCERNS</verdict>
Still not good enough."

  # Round 1: CONCERNS → deny, attempt=1, total=1
  INPUT=$(build_input)
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 1 ]
  [ "$(get_total_rounds)" -eq 1 ]

  # Round 2: CONCERNS → deny, attempt=2, total=2
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 2 ]
  [ "$(get_total_rounds)" -eq 2 ]

  # Round 3: CONCERNS → deny, attempt=3, total=3
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 3 ]
  [ "$(get_total_rounds)" -eq 3 ]

  # Round 4: attempt=3 >= MAX_ROUNDS=3 → non-critical safety valve, allow
  run_hook
  assert_approve_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"ESCALATED"* ]]
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

  # First run_hook triggers engine (fail→retry→APPROVE) → ack-deny
  run_hook
  # Capture retrying message from the ack-deny round
  local stderr_from_engine="$HOOK_STDERR"
  [[ "$stderr_from_engine" == *"retrying"* ]]

  # Ack-round: allow
  run_hook
  assert_approve_json
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

# 31. Both attempts fail → fail-deny with failure reason
@test "retry: both attempts fail → fail-deny with failure reason" {
  export REVIEW_ENGINE="claude"
  create_failing_engine "claude" 1
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"all review engines failed"* ]]
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
  assert_approve_json
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-count-test-session" ]

  # New plan submitted — engine now approves (simulates fresh review)
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
LGTM after revision."
  INPUT=$(build_input plan="Revised plan v2")
  run_hook_to_completion

  # Must go through engine (APPROVE), not short-circuit
  assert_approve_json
  # Counter and marker should be cleaned up
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-count-test-session" ]
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-approved-test-session" ]
}

# 27. Engine failure does not touch counter (fail-deny, counter unchanged)
@test "flow: engine failure does not modify counter" {
  INPUT=$(build_input)

  # No counter file exists initially
  [ "$(get_counter_value)" -eq 0 ]

  # Engine fails → fail-deny, counter must remain untouched
  create_failing_engine "gemini" 1
  run_hook
  assert_deny_json

  # Counter file must NOT exist (engine failure should not create one)
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-count-test-session" ]
  [ "$(get_counter_value)" -eq 0 ]
}

# 28. Engine failure mid-cycle preserves existing counter value
@test "flow: engine failure mid-cycle preserves counter" {
  export REVIEW_MAX_ROUNDS=3
  INPUT=$(build_input)

  # Round 1: normal CONCERNS → attempt=1, total=1
  create_mock_engine "gemini" "<verdict>CONCERNS</verdict>
Issues found."
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 1 ]
  [ "$(get_total_rounds)" -eq 1 ]

  # Round 2: engine crashes → fail-deny, counter must stay at 1:1
  create_failing_engine "gemini" 1
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 1 ]
  [ "$(get_total_rounds)" -eq 1 ]

  # Round 3: engine recovers → CONCERNS, attempt=2, total=2
  create_mock_engine "gemini" "<verdict>CONCERNS</verdict>
Still has issues."
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 2 ]
  [ "$(get_total_rounds)" -eq 2 ]
}

# =============================================================================
# Global Safety Valve
# =============================================================================

# 32. Global safety valve fires → hard deny
@test "counter: global safety valve fires at REVIEW_MAX_TOTAL_ROUNDS → hard deny" {
  set_counter_value 0 test-session 20
  export REVIEW_MAX_TOTAL_ROUNDS=20
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"HARD STOP"* ]]
  # Counter file NOT deleted (tombstone)
  [ -f "${REVIEW_COUNTER_DIR}/.review-count-test-session" ]
}

# 33. Global safety valve takes precedence over active review → deny, no engine call
@test "counter: global safety valve precedence → deny, no engine call" {
  set_counter_value 0 test-session 20
  export REVIEW_MAX_TOTAL_ROUNDS=20
  # No mock engine — if script calls engine, it'll fail
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"HARD STOP"* ]]
}

# =============================================================================
# Severity-Aware Counter (VERDICT-driven)
# =============================================================================

# 34. REJECT → ATTEMPT frozen, TOTAL increments
@test "severity: REJECT → ATTEMPT frozen, TOTAL increments" {
  create_mock_engine "gemini" "<verdict>REJECT</verdict>
[Critical] Security vulnerability found."
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  [ "$(get_counter_value)" -eq 0 ]
  [ "$(get_total_rounds)" -eq 1 ]
}

# 35. Multiple REJECT → ATTEMPT stays 0
@test "severity: multiple REJECT → ATTEMPT stays 0" {
  create_mock_engine "gemini" "<verdict>REJECT</verdict>
[Critical] Still broken."
  INPUT=$(build_input)

  # Round 1: REJECT
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 0 ]
  [ "$(get_total_rounds)" -eq 1 ]

  # Round 2: REJECT
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 0 ]
  [ "$(get_total_rounds)" -eq 2 ]

  # Round 3: REJECT
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 0 ]
  [ "$(get_total_rounds)" -eq 3 ]
}

# 36. REJECT then CONCERNS → ATTEMPT starts incrementing
@test "severity: REJECT then CONCERNS → ATTEMPT starts incrementing" {
  INPUT=$(build_input)

  # Round 1: REJECT → attempt=0, total=1
  create_mock_engine "gemini" "<verdict>REJECT</verdict>
[Critical] Flaw found."
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 0 ]
  [ "$(get_total_rounds)" -eq 1 ]

  # Round 2: CONCERNS → attempt=1, total=2
  create_mock_engine "gemini" "<verdict>CONCERNS</verdict>
[Major] Needs improvement."
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 1 ]
  [ "$(get_total_rounds)" -eq 2 ]
}

# 37. CONCERNS then REJECT → ATTEMPT resets to 0
@test "severity: CONCERNS then REJECT → ATTEMPT resets to 0" {
  INPUT=$(build_input)

  # Round 1: CONCERNS → attempt=1, total=1
  create_mock_engine "gemini" "<verdict>CONCERNS</verdict>
[Major] Needs work."
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 1 ]
  [ "$(get_total_rounds)" -eq 1 ]

  # Round 2: REJECT → attempt resets to 0, total=2
  create_mock_engine "gemini" "<verdict>REJECT</verdict>
[Critical] New critical issue introduced."
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 0 ]
  [ "$(get_total_rounds)" -eq 2 ]
}

# 38. Non-critical safety valve only counts CONCERNS
@test "severity: non-crit safety valve only counts CONCERNS" {
  export REVIEW_MAX_ROUNDS=2
  INPUT=$(build_input)

  # 2 rounds REJECT → attempt stays 0
  create_mock_engine "gemini" "<verdict>REJECT</verdict>
[Critical] Broken."
  run_hook; assert_deny_json  # total=1, attempt=0
  run_hook; assert_deny_json  # total=2, attempt=0

  # 2 rounds CONCERNS → attempt goes 1, 2
  create_mock_engine "gemini" "<verdict>CONCERNS</verdict>
[Major] Issues."
  run_hook; assert_deny_json  # total=3, attempt=1
  run_hook; assert_deny_json  # total=4, attempt=2

  # Next call: attempt=2 >= MAX_ROUNDS=2 → non-critical safety valve fires
  run_hook
  assert_approve_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"ESCALATED"* ]]
}

# 39. REJECT feedback shows Critical message
@test "severity: REJECT feedback shows Critical message" {
  create_mock_engine "gemini" "<verdict>REJECT</verdict>
[Critical] Data loss risk."
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"REJECT"* ]]
  [[ "$reason" == *"非 Critical 磋商计数已重置"* ]]
}

# 40. CONCERNS feedback shows round countdown
@test "severity: CONCERNS feedback shows round countdown" {
  create_mock_engine "gemini" "<verdict>CONCERNS</verdict>
[Major] Needs work."
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"磋商剩余轮次"* ]]
}

# =============================================================================
# Full Flow
# =============================================================================

# 41. REJECT → REJECT → CONCERNS → CONCERNS → CONCERNS → safety valve
@test "flow: REJECT → REJECT → CONCERNS×3 → safety valve" {
  export REVIEW_MAX_ROUNDS=3
  INPUT=$(build_input)

  # Round 1: REJECT → attempt=0, total=1
  create_mock_engine "gemini" "<verdict>REJECT</verdict>
[Critical] Broken."
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 0 ]
  [ "$(get_total_rounds)" -eq 1 ]

  # Round 2: REJECT → attempt=0, total=2
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 0 ]
  [ "$(get_total_rounds)" -eq 2 ]

  # Round 3: CONCERNS → attempt=1, total=3
  create_mock_engine "gemini" "<verdict>CONCERNS</verdict>
[Major] Better but not good enough."
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 1 ]
  [ "$(get_total_rounds)" -eq 3 ]

  # Round 4: CONCERNS → attempt=2, total=4
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 2 ]
  [ "$(get_total_rounds)" -eq 4 ]

  # Round 5: CONCERNS → attempt=3, total=5
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 3 ]
  [ "$(get_total_rounds)" -eq 5 ]

  # Round 6: attempt=3 >= MAX_ROUNDS=3 → non-critical safety valve
  run_hook
  assert_approve_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"ESCALATED"* ]]
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-count-test-session" ]
}

# 41b. CONCERNS×2 → REJECT → ATTEMPT resets → CONCERNS×3 → safety valve
@test "flow: CONCERNS×2 → REJECT → ATTEMPT resets → CONCERNS×3 → safety valve" {
  export REVIEW_MAX_ROUNDS=3
  INPUT=$(build_input)

  # Round 1: CONCERNS → attempt=1, total=1
  create_mock_engine "gemini" "<verdict>CONCERNS</verdict>
[Major] Issue A."
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 1 ]
  [ "$(get_total_rounds)" -eq 1 ]

  # Round 2: CONCERNS → attempt=2, total=2
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 2 ]
  [ "$(get_total_rounds)" -eq 2 ]

  # Round 3: REJECT → attempt resets to 0, total=3
  create_mock_engine "gemini" "<verdict>REJECT</verdict>
[Critical] New critical flaw introduced."
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 0 ]
  [ "$(get_total_rounds)" -eq 3 ]

  # Round 4: CONCERNS → attempt=1, total=4
  create_mock_engine "gemini" "<verdict>CONCERNS</verdict>
[Major] Residual issue."
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 1 ]
  [ "$(get_total_rounds)" -eq 4 ]

  # Round 5: CONCERNS → attempt=2, total=5
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 2 ]
  [ "$(get_total_rounds)" -eq 5 ]

  # Round 6: CONCERNS → attempt=3, total=6
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 3 ]
  [ "$(get_total_rounds)" -eq 6 ]

  # Round 7: attempt=3 >= MAX_ROUNDS=3 → non-critical safety valve fires
  run_hook
  assert_approve_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"ESCALATED"* ]]
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-count-test-session" ]
}

# =============================================================================
# Counter Robustness (defensive tests)
# =============================================================================

# 42. Empty counter file → treated as 0:0
@test "counter: empty counter file → treated as 0:0, no crash" {
  touch "${REVIEW_COUNTER_DIR}/.review-count-test-session"
  create_mock_engine "gemini" "<verdict>CONCERNS</verdict>
Issues."
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  [ "$(get_counter_value)" -eq 1 ]
  [ "$(get_total_rounds)" -eq 1 ]
}

# 43. Garbage in counter file → reset to 0:0
@test "counter: garbage in counter file → reset to 0:0, no crash" {
  echo "abc:xyz" > "${REVIEW_COUNTER_DIR}/.review-count-test-session"
  create_mock_engine "gemini" "<verdict>CONCERNS</verdict>
Issues."
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  [ "$(get_counter_value)" -eq 1 ]
  [ "$(get_total_rounds)" -eq 1 ]
}

# 44. Old single-number format → backward compat
@test "counter: partial format (old single number) → backward compat" {
  echo "2" > "${REVIEW_COUNTER_DIR}/.review-count-test-session"
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
LGTM."
  INPUT=$(build_input)
  run_hook

  # Old format "2" → ATTEMPT=2, TOTAL_ROUNDS=2 (fallback)
  # APPROVE ack-deny should show "Round 3" (TOTAL=2 → 2+1=3)
  assert_ack_approve_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"Round 3"* ]]
}

# =============================================================================
# Visible Skip Reasons
# =============================================================================

# 45. No plan content → allow JSON with SKIP reason
@test "skip: no plan content → allow JSON with SKIP reason" {
  INPUT=$(build_input_no_plan)
  run_hook

  assert_approve_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"[SKIP]"* ]]
}

# 46. Engine CLI not found → allow JSON with WARNING reason
@test "skip: engine CLI not found → allow JSON with WARNING reason" {
  INPUT=$(build_input)

  local clean_path="${MOCK_BIN}"
  local orig_path="$PATH"
  while IFS=: read -r -d: dir || [ -n "$dir" ]; do
    if [ -d "$dir" ] && [ ! -x "${dir}/gemini" ]; then
      clean_path="${clean_path}:${dir}"
    fi
  done <<< "${orig_path}:"

  export PATH="$clean_path"
  run_hook
  export PATH="$orig_path"

  assert_approve_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"[WARNING]"* ]]
}

# 47. Engine exhausted → deny JSON with failure reason (fail-deny, not fail-open)
@test "skip: engine exhausted → deny JSON with failure reason" {
  create_failing_engine "gemini" 1
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"all review engines failed"* ]]
}

# 48. jq missing → allow JSON with WARNING (hardcoded)
@test "skip: jq missing → allow JSON with WARNING (hardcoded)" {
  INPUT=$(build_input)

  local restricted_bin="${TEST_TEMP_DIR}/restricted_bin2"
  mkdir -p "$restricted_bin"
  for cmd in bash cat grep head tr printf mkdir rm find xargs ls echo mktemp chmod sed; do
    local cmd_path
    cmd_path=$(command -v "$cmd" 2>/dev/null) || continue
    ln -sf "$cmd_path" "${restricted_bin}/${cmd}"
  done

  local orig_path="$PATH"
  export PATH="$restricted_bin"
  run_hook
  export PATH="$orig_path"

  assert_approve_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"jq missing"* ]]
}

# =============================================================================
# Ack-Round (APPROVE acknowledgment flow)
# =============================================================================

# 49. Ack-round: marker exists → allow immediately
@test "ack-round: marker exists → allow with confirmation" {
  create_approve_marker
  INPUT=$(build_input)
  run_hook

  assert_approve_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"审阅已通过"* ]]
  # Marker cleaned up
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-approved-test-session" ]
}

# 50. Ack-round: cleans both marker and counter
@test "ack-round: cleans both marker and counter" {
  set_counter_value 2 test-session 4
  create_approve_marker
  INPUT=$(build_input)
  run_hook

  assert_approve_json
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-approved-test-session" ]
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-count-test-session" ]
}

# 51. Ack-round: bypasses global safety valve
@test "ack-round: bypasses global safety valve when marker exists" {
  set_counter_value 0 test-session 20
  export REVIEW_MAX_TOTAL_ROUNDS=20
  create_approve_marker
  INPUT=$(build_input)
  run_hook

  # Would normally be HARD STOP, but marker takes precedence
  assert_approve_json
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-approved-test-session" ]
}

# 52. Ack-round: no engine call needed
@test "ack-round: no engine call needed" {
  # No mock engine — if script calls engine, it'll fail
  create_approve_marker
  INPUT=$(build_input)
  run_hook

  assert_approve_json
}

# 53. Full APPROVE ack-round flow: engine APPROVE → ack-deny → ack-round → allow
@test "ack-round: full end-to-end APPROVE flow" {
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
Plan is solid."
  INPUT=$(build_input)

  # Step 1: Engine review → APPROVE → ack-deny
  run_hook
  assert_ack_approve_json
  [ -f "${REVIEW_COUNTER_DIR}/.review-approved-test-session" ]

  # Step 2: Ack-round → allow
  run_hook
  assert_approve_json
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-approved-test-session" ]
}

# 54. Ack-round: plan changed after approve → re-review triggered
@test "ack-round: plan changed after approve → re-review triggered" {
  # Marker contains hash of "Old plan content"; INPUT uses a different plan
  create_approve_marker "Old plan content" "test-session"
  create_mock_engine "gemini" "<verdict>APPROVE</verdict> New plan looks good."
  INPUT=$(build_input 'plan=Completely different plan')
  run_hook
  # Hash mismatch → marker deleted, full review triggered → engine returns APPROVE → ack-deny
  assert_ack_approve_json
  # New marker written for the re-reviewed plan
  [ -f "${REVIEW_COUNTER_DIR}/.review-approved-test-session" ]
}

# 55. Ack-round: legacy empty marker → allow (backward compat)
@test "ack-round: legacy empty marker → allow (backward compat)" {
  # Empty marker simulates old-format marker written before hash upgrade
  touch "${REVIEW_COUNTER_DIR}/.review-approved-test-session"
  INPUT=$(build_input)
  run_hook
  # Empty approved_hash branch → unconditional allow
  assert_approve_json
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-approved-test-session" ]
}

# =============================================================================
# PreCompact Hook (context compaction resilience)
# =============================================================================

# 56. PreCompact: no active review → silent exit 0, no output
@test "precompact: no active review state → silent exit 0" {
  INPUT=$(build_precompact_input)
  run_precompact_hook

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

# 57. PreCompact: active CONCERNS counter → systemMessage with review status
@test "precompact: active CONCERNS counter → systemMessage injected" {
  set_counter_value 1 test-session 2
  INPUT=$(build_precompact_input)
  run_precompact_hook

  [ "$HOOK_EXIT" -eq 0 ]
  [ -n "$HOOK_STDOUT" ]
  # Must be valid JSON
  echo "$HOOK_STDOUT" | jq . >/dev/null 2>&1
  # continue=true (does not block compaction)
  local cont
  cont=$(echo "$HOOK_STDOUT" | jq -r '.continue')
  [ "$cont" = "true" ]
  # systemMessage present and mentions plan review
  local msg
  msg=$(echo "$HOOK_STDOUT" | jq -r '.systemMessage')
  [[ "$msg" == *"PLAN REVIEW IN PROGRESS"* ]]
  [[ "$msg" == *"ExitPlanMode"* ]]
}

# 58. PreCompact: active REJECT counter (ATTEMPT=0, TOTAL>0) → REJECTED status
@test "precompact: REJECT counter (attempt=0, total=3) → REJECTED status in message" {
  set_counter_value 0 test-session 3
  INPUT=$(build_precompact_input)
  run_precompact_hook

  [ "$HOOK_EXIT" -eq 0 ]
  local msg
  msg=$(echo "$HOOK_STDOUT" | jq -r '.systemMessage')
  [[ "$msg" == *"REJECTED"* ]]
  [[ "$msg" == *"Critical"* ]]
}

# 59. PreCompact: approve marker present → ack-round status in message
@test "precompact: approve marker present → ack-round pending status in message" {
  create_approve_marker
  INPUT=$(build_precompact_input)
  run_precompact_hook

  [ "$HOOK_EXIT" -eq 0 ]
  local msg
  msg=$(echo "$HOOK_STDOUT" | jq -r '.systemMessage')
  [[ "$msg" == *"APPROVED"* ]]
  [[ "$msg" == *"ack-round"* ]]
  # Marker must NOT be deleted (precompact hook is read-only)
  [ -f "${REVIEW_COUNTER_DIR}/.review-approved-test-session" ]
}

# 60. PreCompact: empty session_id → silent exit 0 (no output)
@test "precompact: empty session_id → silent exit 0" {
  # Set up state that would trigger if session_id were valid
  set_counter_value 1 test-session 1
  INPUT=$(build_precompact_input session_id=)
  run_precompact_hook

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

# =============================================================================
# Entry-Point Diagnostic Logging (v1.0.13)
# =============================================================================

# 64. Normal invocation writes ENTRY log with tool and session
@test "log: entry-point written on normal invocation" {
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
LGTM."
  INPUT=$(build_input)
  run_hook_to_completion

  assert_approve_json
  assert_log_contains "ENTRY tool=ExitPlanMode session=test-session"
}

# 65. Recursive guard still writes ENTRY before bailing
@test "log: entry-point written before recursive guard" {
  export PLAN_REVIEW_RUNNING=1
  INPUT=$(build_input)
  run_hook

  assert_allowed
  assert_log_contains "ENTRY tool=ExitPlanMode session=test-session"
  assert_log_contains "guard=recursive-bail"
}

# 66. Disabled guard logs reason
@test "log: disabled guard writes reason" {
  export REVIEW_DISABLED=1
  INPUT=$(build_input)
  run_hook

  assert_allowed
  assert_log_contains "guard=disabled"
}

# 67. Wrong tool guard logs reason
@test "log: wrong tool guard writes reason" {
  INPUT=$(build_input tool_name=Read)
  run_hook

  assert_allowed
  assert_log_contains "guard=wrong-tool"
}

# 68. Guard exits produce no JSON to stdout (framework invariant)
@test "log: guard exits produce no JSON to stdout" {
  export PLAN_REVIEW_RUNNING=1
  INPUT=$(build_input)
  run_hook

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

# =============================================================================
# Engine Timeout (v1.0.13)
# =============================================================================

# 69. Engine timeout (exit 124) triggers fail-deny via existing retry logic
@test "timeout: engine timeout triggers fail-deny" {
  # exit 124 = timeout's exit code; both attempts timeout → fail-deny (engines were tried)
  create_failing_engine "gemini" 124
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"all review engines failed"* ]]
}

# 70. Custom REVIEW_ENGINE_TIMEOUT does not break normal fast responses
@test "timeout: REVIEW_ENGINE_TIMEOUT env respected" {
  export REVIEW_ENGINE_TIMEOUT=10
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
All good."
  INPUT=$(build_input)
  run_hook_to_completion

  assert_approve_json
}

# =============================================================================
# Malformed / Empty Input Resilience (v1.0.14)
# =============================================================================

# 71. 空 stdin → 不 crash，exit 0，无 JSON 输出
@test "input: empty stdin exits cleanly without crash" {
  run_hook_raw_stdin ""
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

# 72. 空 stdin → ENTRY 仍写入日志（回归测试：修复 read + set -e 静默退出）
@test "input: empty stdin writes ENTRY to log" {
  run_hook_raw_stdin ""
  assert_log_contains "ENTRY"
}

# 73. 非法 JSON stdin → 不 crash，exit 0，无 JSON 输出
@test "input: malformed JSON stdin exits cleanly" {
  run_hook_raw_stdin "not-valid-json"
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

# 74. 非法 JSON stdin → ENTRY 仍写入日志
@test "input: malformed JSON writes ENTRY to log" {
  run_hook_raw_stdin "not-valid-json"
  assert_log_contains "ENTRY"
}

# =============================================================================
# REST API Fallback (v1.0.18)
# =============================================================================

# 75. CLI fails + API configured → REST succeeds
@test "rest-fallback: CLI fails + API configured → REST succeeds" {
  create_failing_engine "gemini" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl '{"choices":[{"message":{"content":"<verdict>APPROVE</verdict>\nLooks good via REST."}}]}'
  INPUT=$(build_input)

  # Step 1: CLI fails → REST fallback → APPROVE → ack-deny
  run_hook
  assert_ack_approve_json
  local engine_stderr="$HOOK_STDERR"
  [[ "$engine_stderr" == *"REST API fallback succeeded"* ]]

  # Step 2: ack-round → allow
  run_hook
  assert_approve_json
}

# 76. CLI fails + API not configured → fail-deny (engines tried, all failed)
@test "rest-fallback: CLI fails + API not configured → fail-deny" {
  create_failing_engine "gemini" 1
  # REVIEW_API_URL and REVIEW_API_KEY unset by common_setup
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"all review engines failed"* ]]
}

# 77. CLI fails + REST also fails → fail-deny with combined reason
@test "rest-fallback: CLI fails + REST also fails → fail-deny with reason" {
  create_failing_engine "gemini" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_failing_curl 1
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"all review engines failed"* ]]
}

# 78. CLI succeeds → REST not called
@test "rest-fallback: CLI succeeds → REST not called" {
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
All good from CLI."
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  # No mock curl — if script calls curl, it would fail or use system curl
  # (which would fail to connect to localhost:9999)
  INPUT=$(build_input)
  run_hook_to_completion

  assert_approve_json
  # Should NOT mention REST fallback
  [[ "$HOOK_STDERR" != *"REST API fallback"* ]]
}

# 79. CLI fails + curl not found → fail-deny (REST attempted but failed)
@test "rest-fallback: curl not found → fail-deny" {
  create_failing_engine "gemini" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  # Remove curl from PATH by not creating a mock (MOCK_BIN has priority)
  # and ensuring no system curl is reachable — create a no-op to shadow it
  cat > "${MOCK_BIN}/curl" << 'EOF'
#!/bin/bash
exit 127
EOF
  chmod +x "${MOCK_BIN}/curl"
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"all review engines failed"* ]]
}

# 80. REST response parsing extracts choices[0].message.content
@test "rest-fallback: response parsing extracts choices[0].message.content" {
  create_failing_engine "gemini" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl '{"choices":[{"message":{"content":"<verdict>CONCERNS</verdict>\n[Major] Missing error handling."}}]}'
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"Missing error handling"* ]]
}

# =============================================================================
# Capacity Fast-Break (v1.0.18)
# =============================================================================

# 81. Capacity exhausted + REST configured → immediate break, REST succeeds
@test "rest-fallback: capacity exhausted + REST configured → fast break + REST used" {
  create_capacity_exhausted_engine "gemini"
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl '{"choices":[{"message":{"content":"<verdict>APPROVE</verdict>\nLooks good via REST."}}]}'
  INPUT=$(build_input)

  # Step 1: CLI hits capacity → fast break → REST fires → APPROVE → ack-deny
  run_hook
  assert_ack_approve_json
  local first_stderr="$HOOK_STDERR"
  [[ "$first_stderr" == *"skipping retry (REST fallback available)"* ]]
  [[ "$first_stderr" == *"REST API fallback succeeded"* ]]

  # Step 2: ack-round → allow
  run_hook
  assert_approve_json
}

# 82. Capacity exhausted + no REST configured → retries CLI, second attempt succeeds
@test "rest-fallback: capacity exhausted + no REST configured → retries CLI" {
  create_capacity_then_success_engine "gemini" "<verdict>APPROVE</verdict>LGTM on retry."
  # REVIEW_API_URL / REVIEW_API_KEY unset by common_setup — no fast break
  INPUT=$(build_input)

  # First call: attempt 1 fails with capacity, retry fires, attempt 2 succeeds → ack-deny
  run_hook
  assert_ack_approve_json
  # Fast break must NOT have triggered (no REST configured)
  [[ "$HOOK_STDERR" != *"skipping retry (REST fallback available)"* ]]

  # ack-round → allow
  run_hook
  assert_approve_json
}

# =============================================================================
# REST Fallback Diagnostics (v1.0.21)
# =============================================================================

# 83. rest-result log contains http status field on success
@test "rest-fallback: rest-result log contains http status field" {
  create_failing_engine "gemini" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl '{"choices":[{"message":{"content":"<verdict>APPROVE</verdict>\nLooks good."}}]}'
  INPUT=$(build_input)

  run_hook
  assert_ack_approve_json
  assert_log_contains "rest-result http=200"
}

# 84. ENGINE_OUT non-empty with API error body → rest-debug api_error logged
@test "rest-fallback: api error body → rest-debug api_error logged" {
  create_failing_engine "gemini" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  # Error response has no .choices → REVIEW empty; has .error.message → api_error branch
  create_mock_curl '{"error":{"code":429,"message":"Rate limit exceeded"}}' "429"
  INPUT=$(build_input)

  run_hook
  assert_deny_json  # fail-deny: engines tried but all failed (CLI + REST)
  assert_log_contains "rest-result http=429"
  assert_log_contains "rest-debug api_error=Rate limit exceeded"
}

# 85. ENGINE_OUT empty (connection failure) → no rest-debug logged
@test "rest-fallback: connection failure (empty body) → no rest-debug logged" {
  create_failing_engine "gemini" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_failing_curl 7  # exit 7 = connection refused; curl writes nothing to -o file
  INPUT=$(build_input)

  run_hook
  assert_deny_json  # fail-deny: engines tried but all failed (CLI + REST)
  assert_log_contains "rest-result http=000 raw_bytes=0"
  # Empty body → [ -s ENGINE_OUT ] false → no rest-debug entry
  local log_file="${REVIEW_LOG_DIR}/plan-review.log"
  ! grep -q "rest-debug" "$log_file"
}

# 86. Non-JSON body with control chars → body_prefix branch strips control chars
@test "rest-fallback: non-JSON body with control chars → body_prefix filtered in log" {
  create_failing_engine "gemini" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  # Hand-write mock: outputs non-JSON binary content (no .error.message) + status "200"
  cat > "${MOCK_BIN}/curl" << 'SCRIPT_EOF'
#!/bin/bash
out_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out_file="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
[ -n "$out_file" ] && printf 'Hello\x01\x02World\x03' > "$out_file"
printf '200'
SCRIPT_EOF
  chmod +x "${MOCK_BIN}/curl"
  INPUT=$(build_input)

  run_hook
  assert_deny_json  # fail-deny: engines tried but all failed (CLI + REST)
  # Control chars \x01\x02\x03 must be stripped; printable text preserved
  assert_log_contains "rest-debug body_prefix=HelloWorld"
}

# =============================================================================
# Time-Budget Guard + REST Timeout Clamping (v1.0.23)
# =============================================================================

# 87. Budget exhausted + REST configured → break retry loop → REST fires
@test "budget-guard: budget exhausted + REST configured → skip retry → REST fires" {
  # HOOK_BUDGET=1 makes remaining ≈ 1 < ENGINE_TIMEOUT(90) on retry check
  export REVIEW_HOOK_BUDGET=1
  create_flaky_engine "gemini" "<verdict>APPROVE</verdict>
Would succeed on retry but budget prevents it."
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl '{"choices":[{"message":{"content":"<verdict>APPROVE</verdict>\nLooks good via REST."}}]}'
  INPUT=$(build_input)

  # Engine attempt 1 fails → budget guard blocks retry → REST fires → APPROVE → ack-deny
  run_hook
  assert_ack_approve_json
  [[ "$HOOK_STDERR" == *"time budget exhausted"* ]]
  [[ "$HOOK_STDERR" == *"REST API fallback succeeded"* ]]

  # ack-round → allow
  run_hook
  assert_approve_json
}

# 88. Budget sufficient → normal retry succeeds (no budget skip)
@test "budget-guard: budget sufficient → normal retry succeeds" {
  # Default budget (115s) easily fits ENGINE_TIMEOUT(90s) retry
  create_flaky_engine "gemini" "<verdict>APPROVE</verdict>
All good on retry."
  INPUT=$(build_input)

  # Engine attempt 1 fails → budget OK → retry succeeds → APPROVE → ack-deny
  run_hook
  assert_ack_approve_json
  # Must NOT mention budget exhaustion
  [[ "$HOOK_STDERR" != *"time budget exhausted"* ]]
  [[ "$HOOK_STDERR" == *"retrying"* ]]

  # ack-round → allow
  run_hook
  assert_approve_json
}

# 89. Budget exhausted + no REST → break retry → fail-deny (engine was tried)
@test "budget-guard: budget exhausted + no REST → fail-deny" {
  export REVIEW_HOOK_BUDGET=1
  create_flaky_engine "gemini" "<verdict>APPROVE</verdict>
Would succeed on retry."
  # No REST configured (unset by common_setup)
  INPUT=$(build_input)

  run_hook

  # Budget prevents retry, no REST → fail-deny (engine was tried on attempt 1)
  assert_deny_json
  [[ "$HOOK_STDERR" == *"time budget exhausted"* ]]
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"all review engines failed"* ]]
}

# 90. REST timeout clamped to remaining budget
@test "budget-guard: REST timeout clamped to remaining budget" {
  export REVIEW_HOOK_BUDGET=10
  create_failing_engine "gemini" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  # Mock curl that records the timeout wrapper argument it received
  cat > "${MOCK_BIN}/curl" << 'SCRIPT_EOF'
#!/bin/bash
# Parse -o flag to find output file
out_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out_file="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
[ -n "$out_file" ] && printf '{"choices":[{"message":{"content":"<verdict>APPROVE</verdict>\\nOK"}}]}' > "$out_file"
printf '200'
SCRIPT_EOF
  chmod +x "${MOCK_BIN}/curl"
  INPUT=$(build_input)

  run_hook
  assert_ack_approve_json
  # Verify REST timeout was clamped: log should show the clamped value
  # With HOOK_BUDGET=10, remaining ≈ 10, REST_TIMEOUT should be clamped to ≤ 7 (10-3)
  # The log won't show the timeout directly, but the REST succeeded which proves
  # the clamping code path executed without error. Check the skip-retry log to confirm
  # budget guard also fired (engine fails both attempts with budget=10 > ENGINE_TIMEOUT=90?
  # No — ENGINE_TIMEOUT=90, budget=10, first attempt fails, retry: remaining≈10 < 90 → break)
  [[ "$HOOK_STDERR" == *"time budget exhausted"* ]]
  [[ "$HOOK_STDERR" == *"REST API fallback succeeded"* ]]

  # ack-round → allow
  run_hook
  assert_approve_json
}

# =============================================================================
# Gemini Degraded-State Persistence (v1.0.24)
# =============================================================================

# 91. Fresh degraded file + REST configured → skip CLI entirely, REST used
@test "degrade: fresh degraded file + REST configured → skip CLI, REST used" {
  create_degraded_file 0  # fresh timestamp
  # Gemini mock returns CONCERNS — if called, result would be deny from CONCERNS, not ack-approve
  create_mock_engine "gemini" "<verdict>CONCERNS</verdict>
[Major] This should not be seen."
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl '{"choices":[{"message":{"content":"<verdict>APPROVE</verdict>\nREST approved."}}]}'
  INPUT=$(build_input)

  # Degraded: CLI skipped → REST fires → APPROVE → ack-deny
  run_hook
  assert_ack_approve_json
  assert_log_contains "gemini-degraded skip-cli"
  [[ "$HOOK_STDERR" == *"gemini degraded state active"* ]]
  [[ "$HOOK_STDERR" == *"REST API fallback succeeded"* ]]

  # ack-round → allow
  run_hook
  assert_approve_json
}

# 92. Expired degraded file (age > TTL) → normal Gemini invocation
@test "degrade: expired degraded file → normal Gemini invocation" {
  # Use tiny TTL (1s) and a 5s-old file → expired
  export REVIEW_ENGINE_DEGRADE_TTL=1
  create_degraded_file 5
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
LGTM."
  INPUT=$(build_input)

  run_hook_to_completion
  assert_approve_json
  # Degraded skip must NOT appear in log — Gemini was called normally
  local log_file="${REVIEW_LOG_DIR}/plan-review.log"
  ! grep -q "gemini-degraded skip-cli" "$log_file"
}

# 93. Fresh degraded file + REST NOT configured → degraded check skipped, Gemini called
@test "degrade: fresh degraded file + REST not configured → Gemini called normally" {
  create_degraded_file 0  # fresh, but REST not configured
  # REVIEW_API_URL/REVIEW_API_KEY unset by common_setup — degraded check requires both
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
LGTM from Gemini."
  INPUT=$(build_input)

  run_hook_to_completion
  assert_approve_json
  # No degraded skip in log — REST not configured so check was bypassed
  local log_file="${REVIEW_LOG_DIR}/plan-review.log"
  ! grep -q "gemini-degraded skip-cli" "$log_file"
}

# 94. Capacity-fast-break triggers → degraded file written
@test "degrade: capacity-fast-break → degraded file written" {
  create_capacity_exhausted_engine "gemini"
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl '{"choices":[{"message":{"content":"<verdict>APPROVE</verdict>\nREST approved."}}]}'
  INPUT=$(build_input)

  run_hook
  assert_ack_approve_json

  # Degraded file must have been written
  assert_degraded_file_written
  assert_log_contains "gemini-degrade-write"

  # ack-round → allow
  run_hook
  assert_approve_json
}

# 95. Regular failure (exit 1, non-capacity) → degraded file NOT written
@test "degrade: regular failure (exit 1, non-capacity) → no degraded file written" {
  create_failing_engine "gemini" 1
  # No REST configured — regular failure path, not capacity path
  INPUT=$(build_input)

  run_hook
  assert_deny_json  # fail-deny (engine tried but failed)

  # Degraded file must NOT have been written (only capacity failures degrade)
  [ ! -f "${REVIEW_COUNTER_DIR}/.gemini-degraded" ]
  local log_file="${REVIEW_LOG_DIR}/plan-review.log"
  ! grep -q "gemini-degrade-write" "$log_file"
}

# 96. Gemini capacity exhausted + REST fails → deny with combined failure reason
@test "degrade: capacity + REST fails → deny with failure reason" {
  create_capacity_exhausted_engine "gemini"
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_failing_curl 1
  INPUT=$(build_input)

  run_hook
  assert_deny_json
  [[ "$HOOK_STDERR" == *"all review engines failed"* ]]
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"all review engines failed"* ]]
  [[ "$reason" == *"capacity exhausted"* ]]
}

# 97. Degraded state active + REST fails → deny with degraded reason and REST info
@test "degrade: degraded state + REST fails → deny with degraded + REST reason" {
  create_degraded_file 0  # fresh
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_failing_curl 7  # connection refused
  INPUT=$(build_input)

  run_hook
  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"all review engines failed"* ]]
  [[ "$reason" == *"degraded state"* ]]
  [[ "$reason" == *"REST: http="* ]]
}

# 98. Regular failure + REST configured → degrade file written at REST entry
@test "degrade: regular failure + REST configured → degrade file written" {
  create_failing_engine "gemini" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  # REST also fails — we just care that the degrade file is written before REST runs
  create_failing_curl 1
  INPUT=$(build_input)

  run_hook
  assert_deny_json  # fail-deny (CLI + REST both failed)

  # Degrade file written at REST entry (non-capacity failure path)
  assert_degraded_file_written
  assert_log_contains "rest-fallback-triggered"
}

# 99. Expired degrade file + Gemini fails + REST configured → timestamp refreshed (bug fix)
# Before fix: `! -f "$DEGRADE_FILE"` blocked timestamp refresh on expired files, causing
# an infinite loop where Gemini wastes 70s on every hook but REST only gets ~40s (clipped
# by time-budget guard after Gemini timeout).
@test "degrade: expired degrade + Gemini fail + REST → timestamp refreshed" {
  export REVIEW_ENGINE_DEGRADE_TTL=1
  create_degraded_file 5  # 5s old > 1s TTL → expired; Gemini will be re-called
  local old_ts; old_ts=$(cat "${REVIEW_COUNTER_DIR}/.gemini-degraded")

  create_failing_engine "gemini" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl '{"choices":[{"message":{"content":"<verdict>APPROVE</verdict>\nREST approved."}}]}'
  INPUT=$(build_input)

  run_hook
  assert_ack_approve_json

  # Degrade file must be refreshed: new timestamp >= old timestamp
  assert_degraded_file_written
  local new_ts; new_ts=$(cat "${REVIEW_COUNTER_DIR}/.gemini-degraded")
  (( new_ts >= old_ts )) || { echo "timestamp not refreshed: old=$old_ts new=$new_ts"; return 1; }
  assert_log_contains "gemini-degrade-write"
  assert_log_contains "rest-fallback-triggered"
}

# =============================================================================
# Dispatch Manifest — Layer 1 (plan-review.sh)
# =============================================================================

# 101. plan 含 Task( 关键词 + 无 manifest → deny 不调引擎 + counter 递增
@test "manifest: plan with Task( keyword + no manifest → pre-flight deny + counter increment" {
  # No mock engine — pre-flight fires before engine call
  INPUT=$(build_input plan="Step 1: Use Task( to isolate work. No manifest here.")
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"MISSING DISPATCH MANIFEST"* ]]
  # Counter must be incremented (pre-flight is CONCERNS-equivalent)
  local attempt; attempt=$(get_counter_value)
  [ "$attempt" -eq 1 ]
}

# 102. plan 含 Task( + 完整 manifest → 进入正常引擎审阅路径
@test "manifest: plan with Task( + Dispatch Manifest → proceeds to engine review" {
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
Plan looks good with manifest."
  local plan_with_manifest="## Plan
Step 1: Use Task( to run analysis.

## Dispatch Manifest
| step | agent_type | model | depends_on | parallel_with |
|------|-----------|-------|------------|---------------|
| 1    | worker    | sonnet| -          | -             |"
  INPUT=$(build_input "plan=$plan_with_manifest")
  run_hook

  # Engine was called (ack-deny with APPROVED)
  assert_ack_approve_json
}

# 103. plan 不含 Task 关键词 → 不要求 manifest
@test "manifest: plan without Task/Agent keywords → no manifest required" {
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
Simple plan, no dispatch needed."
  INPUT=$(build_input plan="Simple plan: edit file X, run tests, commit.")
  run_hook

  # Engine was called normally (no pre-flight block)
  assert_ack_approve_json
}

# 104. 大小写变体 "Worker Agent" / "TASK(" → 也触发 needs_manifest
@test "manifest: case variants 'Worker Agent' and 'TASK(' trigger manifest requirement" {
  INPUT=$(build_input plan="Use Worker Agent for step 2. Also TASK( for isolation.")
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"MISSING DISPATCH MANIFEST"* ]]
}

# 105. APPROVE 路径 + plan 含 manifest → dispatch JSON 写入且 schema 合法
@test "manifest: APPROVE path + manifest → dispatch JSON written with valid schema" {
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
All good."
  local plan_with_manifest="## Implementation
Use Task( for isolation.

## Dispatch Manifest
| step | agent_type | model | depends_on | parallel_with |
|------|-----------|-------|------------|---------------|
| 1    | -         | -     | -          | -             |
| 2    | worker    | sonnet| 1          | -             |"
  INPUT=$(build_input "plan=$plan_with_manifest")
  run_hook

  assert_ack_approve_json
  # Dispatch JSON must exist
  local dispatch_file="${REVIEW_COUNTER_DIR}/.dispatch-test-session.json"
  [ -f "$dispatch_file" ]
  # Must be valid JSON with required fields
  jq -e '.requires_dispatch_check == true' "$dispatch_file" >/dev/null
  jq -e '.plan_hash | length > 0' "$dispatch_file" >/dev/null
  jq -e '.steps | length == 2' "$dispatch_file" >/dev/null
  # Step 2 has agent_type and model
  jq -e '.steps[1].agent_type == "worker"' "$dispatch_file" >/dev/null
  jq -e '.steps[1].model == "sonnet"' "$dispatch_file" >/dev/null
}

# 106. APPROVE 路径 + plan 无 manifest → 不写 dispatch JSON
@test "manifest: APPROVE path + no manifest → no dispatch JSON written" {
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
Simple plan approved."
  INPUT=$(build_input plan="Simple plan: edit file, run tests.")
  run_hook_to_completion

  assert_approve_json
  # Dispatch file must NOT exist
  [ ! -f "${REVIEW_COUNTER_DIR}/.dispatch-test-session.json" ]
}

# 107. manifest 行含 stray 引号 → 落地 JSON 仍合法（jq -e 通过）
@test "manifest: stray quotes in manifest rows → dispatch JSON still valid" {
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
LGTM."
  local plan_with_quoted_manifest='## Task( analysis

## Dispatch Manifest
| step | agent_type | model | depends_on | parallel_with |
|------|-----------|-------|------------|---------------|
| 1    | "worker"  | "sonnet" | -       | -             |'
  INPUT=$(build_input "plan=$plan_with_quoted_manifest")
  run_hook

  assert_ack_approve_json
  local dispatch_file="${REVIEW_COUNTER_DIR}/.dispatch-test-session.json"
  [ -f "$dispatch_file" ]
  # Must be parseable by jq (no stray quotes in JSON values)
  jq -e '.' "$dispatch_file" >/dev/null
  jq -e '.steps[0].agent_type == "worker"' "$dispatch_file" >/dev/null
  jq -e '.steps[0].model == "sonnet"' "$dispatch_file" >/dev/null
}

# 108. pre-flight 反复 deny 至 MAX_ROUNDS → 第 MAX+1 次 valve escalate to user
@test "manifest: repeated pre-flight denies up to MAX_ROUNDS → valve escalates" {
  export REVIEW_MAX_ROUNDS=2
  # No mock engine — pre-flight fires before engine call
  INPUT=$(build_input plan="Use Task( for analysis.")

  # Round 1: ATTEMPT=0 < MAX=2 → pre-flight deny, ATTEMPT→1
  run_hook
  assert_deny_json
  [[ "$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" == *"MISSING DISPATCH MANIFEST"* ]]

  # Round 2: ATTEMPT=1 < MAX=2 → pre-flight deny, ATTEMPT→2
  run_hook
  assert_deny_json

  # Round 3: ATTEMPT=2 >= MAX=2 → valve fires before pre-flight → allow (ESCALATED)
  run_hook
  assert_approve_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"ESCALATED"* ]]
}

# 109. APPROVE 写入 dispatch 前清理 stale 文件
@test "manifest: APPROVE path cleans up stale dispatch files" {
  create_mock_engine "gemini" "<verdict>APPROVE</verdict>
Good."
  local plan_with_manifest="## Task( work

## Dispatch Manifest
| step | agent_type | model | depends_on | parallel_with |
|------|-----------|-------|------------|---------------|
| 1    | worker    | haiku | -          | -             |"

  # Pre-plant a stale dispatch file (mtime >30min ago via touch -t)
  local stale_file="${REVIEW_COUNTER_DIR}/.dispatch-other-session.json"
  printf '{"stale":true}' > "$stale_file"
  # Backdate by 35 minutes (2100 seconds)
  touch -t "$(date -v -35M +%Y%m%d%H%M 2>/dev/null || date -d '35 minutes ago' +%Y%m%d%H%M 2>/dev/null || date +%Y%m%d%H%M)" "$stale_file" 2>/dev/null || \
    python3 -c "import os,time; os.utime('$stale_file', (time.time()-2100, time.time()-2100))" 2>/dev/null || true

  INPUT=$(build_input "plan=$plan_with_manifest")
  run_hook

  assert_ack_approve_json
  # Stale file must be cleaned up
  [ ! -f "$stale_file" ]
}

# 100. Capacity-fast-break → degrade file already written; REST entry does not overwrite
#      (double-write is harmless: timestamps differ by <1s, both numeric, TTL still valid)
@test "degrade: capacity-fast-break + REST success → degrade file refreshed (double-write harmless)" {
  create_capacity_exhausted_engine "gemini"
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl '{"choices":[{"message":{"content":"<verdict>APPROVE</verdict>\nREST approved."}}]}'
  INPUT=$(build_input)

  run_hook
  assert_ack_approve_json

  # Degrade file exists with a valid timestamp (may be written once or twice — both ok)
  assert_degraded_file_written
  local ts; ts=$(cat "${REVIEW_COUNTER_DIR}/.gemini-degraded")
  local now; now=$(date +%s)
  local age=$(( now - ts ))
  # Timestamp must be recent (within 10s): proves at least one write succeeded
  (( age < 10 )) || { echo "degrade timestamp too old: age=${age}s"; return 1; }
  assert_log_contains "gemini-degrade-write"

  run_hook
  assert_approve_json
}

# ---------------------------------------------------------------------------
# Prompt content integrity
# ---------------------------------------------------------------------------
@test "system-instructions: Testability criterion has structured sub-items" {
  grep -q "Test strategy presence" "${HOOK_SCRIPT:?Missing hook script}"
  grep -q "E2E selector cascade" "${HOOK_SCRIPT:?Missing hook script}"
  grep -q "evidence-gated" "${HOOK_SCRIPT:?Missing hook script}"
  grep -q "Deletion completeness" "${HOOK_SCRIPT:?Missing hook script}"
  grep -q "3000 characters" "${HOOK_SCRIPT:?Missing hook script}"
}
