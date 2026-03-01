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

# 13. Engine call fails (non-zero exit) — retried then allow JSON with WARNING
@test "engine: call fails → retry then allow JSON with WARNING" {
  create_failing_engine "gemini" 1
  INPUT=$(build_input)
  run_hook

  assert_approve_json
  [[ "$HOOK_STDERR" == *"retrying"* ]]
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"[WARNING]"* ]]
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

# 31. Both attempts fail → fail-open with explicit WARNING
@test "retry: both attempts fail → fail-open with WARNING" {
  export REVIEW_ENGINE="claude"
  create_failing_engine "claude" 1
  INPUT=$(build_input)
  run_hook

  assert_approve_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"[WARNING]"* ]]
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

# 27. Engine failure does not touch counter (fail-open, counter unchanged)
@test "flow: engine failure does not modify counter" {
  INPUT=$(build_input)

  # No counter file exists initially
  [ "$(get_counter_value)" -eq 0 ]

  # Engine fails → fail-open, counter must remain untouched
  create_failing_engine "gemini" 1
  run_hook
  assert_approve_json

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

  # Round 2: engine crashes → fail-open, counter must stay at 1:1
  create_failing_engine "gemini" 1
  run_hook
  assert_approve_json
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

# 47. Engine exhausted → allow JSON with WARNING reason
@test "skip: engine exhausted → allow JSON with WARNING reason" {
  create_failing_engine "gemini" 1
  INPUT=$(build_input)
  run_hook

  assert_approve_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"[WARNING]"* ]]
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
