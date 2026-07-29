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
  create_mock_engine "agy" "<verdict>APPROVE</verdict>\nAll good."
  INPUT=$(build_input)
  run_hook_to_completion

  assert_approve_json
}

# =============================================================================
# Plan Extraction
# =============================================================================

# 8. Plan from tool_input.plan
@test "plan: extract from tool_input.plan" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>\nLGTM."
  INPUT=$(build_input plan="My specific plan content")
  run_hook_to_completion

  assert_approve_json
}

# 9. Plan from fallback file
@test "plan: fallback to planFilePath when tool_input has no plan" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>\nLGTM."
  local plan_file="${TEST_TEMP_DIR}/session-plan.md"
  printf '%s' "Plan from planFilePath" > "$plan_file"
  INPUT=$(build_input_no_plan "planFilePath=${plan_file}")
  run_hook_to_completion

  assert_approve_json
}

# 10. No plan anywhere → deny (fail-closed)
@test "plan: no plan content → deny with ERROR" {
  INPUT=$(build_input_no_plan)
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"[ERROR]"* ]]
}

# 10b. planFilePath points to non-existent file → deny with path in reason
@test "plan: planFilePath file missing → deny with path info" {
  INPUT=$(build_input_no_plan "planFilePath=/tmp/nonexistent-plan-file.md")
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"[ERROR]"* ]]
  [[ "$reason" == *"/tmp/nonexistent-plan-file.md"* ]]
}

# 10c. planFilePath file exists but plan field empty → reads from file
@test "plan: planFilePath file exists → reads plan from file" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>\nLGTM."
  local plan_file="${TEST_TEMP_DIR}/my-plan.md"
  printf '%s' "Plan content from file" > "$plan_file"
  INPUT=$(build_input_no_plan "planFilePath=${plan_file}")
  run_hook_to_completion

  assert_approve_json
}

# =============================================================================
# Transcript-based plan recovery (CC 2.1.x out-of-band plan-file contract)
# =============================================================================

# T1. Whitelisted plan file exists → recover content → normal review (APPROVE)
@test "transcript: recovers plan from whitelisted file → review proceeds" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>\nLGTM."
  printf '# Recovered plan\nStep 1: do X\n' > "${REVIEW_PLAN_DIR}/recovered.md"
  local transcript
  transcript=$(create_transcript_with_plan_file "${REVIEW_PLAN_DIR}/recovered.md")
  INPUT=$(build_input_no_plan "transcript_path=${transcript}")
  run_hook_to_completion

  assert_approve_json
  assert_log_contains "recovered-from-transcript"
}

# T2. Resolved path outside whitelist (/etc/passwd) → reject → fail-closed
@test "transcript: path outside whitelist → deny (outside-whitelist)" {
  local transcript
  transcript=$(create_transcript_with_plan_file "/etc/passwd")
  INPUT=$(build_input_no_plan "transcript_path=${transcript}")
  run_hook

  assert_deny_json
  assert_log_contains "resolve=outside-whitelist"
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"非法"* ]]
  # Message must name the offending path so the user knows what was rejected.
  [[ "$reason" == *"passwd"* ]]
}

# T3. Whitelisted path but file never written → fail-closed (resolved-but-missing)
@test "transcript: whitelisted file missing → deny (resolved-but-missing)" {
  local transcript
  transcript=$(create_transcript_with_plan_file "${REVIEW_PLAN_DIR}/never-written.md")
  INPUT=$(build_input_no_plan "transcript_path=${transcript}")
  run_hook

  assert_deny_json
  assert_log_contains "resolve=resolved-but-missing"
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"尚未写入"* ]]
  # Regression: the message MUST name the plan file path (the whole point — tell
  # the user which file to write). A bare "指定了 plan 文件" with no path is useless.
  [[ "$reason" == *"never-written.md"* ]]
}

# T4. transcript_path empty / file absent → fail-closed (no crash, no hang)
@test "transcript: missing transcript_path → deny (no-transcript)" {
  INPUT=$(build_input_no_plan)
  run_hook

  assert_deny_json
  assert_log_contains "resolve=no-transcript"
}

# T5. Transcript has no plan_mode attachment → fail-closed
@test "transcript: no plan_mode attachment → deny (no-plan-attachment)" {
  local transcript="${TEST_TEMP_DIR}/empty.jsonl"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}' > "$transcript"
  INPUT=$(build_input_no_plan "transcript_path=${transcript}")
  run_hook

  assert_deny_json
  assert_log_contains "resolve=no-plan-attachment"
}

# T6. Path traversal in plan path → reject (path-traversal)
@test "transcript: path traversal → deny (path-traversal)" {
  local transcript
  transcript=$(create_transcript_with_plan_file "${REVIEW_PLAN_DIR}/../../../etc/passwd")
  INPUT=$(build_input_no_plan "transcript_path=${transcript}")
  run_hook

  assert_deny_json
  assert_log_contains "resolve=path-traversal"
}

# T7. SECURITY: symlink inside whitelist → /etc/passwd → reject (symlink-rejected)
@test "transcript: symlink escape rejected (symlink-rejected)" {
  ln -sf /etc/passwd "${REVIEW_PLAN_DIR}/evil-link.md"
  local transcript
  transcript=$(create_transcript_with_plan_file "${REVIEW_PLAN_DIR}/evil-link.md")
  INPUT=$(build_input_no_plan "transcript_path=${transcript}")
  run_hook

  assert_deny_json
  assert_log_contains "resolve=symlink-rejected"
}

# T8. SECURITY: transcript is a FIFO → [ -f ] gate prevents blocking read (no hang)
@test "transcript: FIFO transcript → deny without hanging" {
  local fifo="${TEST_TEMP_DIR}/fifo-transcript"
  mkfifo "$fifo"
  INPUT=$(build_input_no_plan "transcript_path=${fifo}")
  # Must return promptly (the [ -f ] gate rejects non-regular files before any read).
  run_hook

  assert_deny_json
  assert_log_contains "resolve=no-transcript"
  rm -f "$fifo"
}

# T9. Regression: tool_input.plan still works (legacy contract unbroken)
@test "transcript: inline tool_input.plan still reviewed (legacy contract)" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>\nLGTM."
  INPUT=$(build_input plan="Inline legacy plan")
  run_hook_to_completion

  assert_approve_json
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
  # Don't create any mock — agy (default engine binary) won't exist in MOCK_BIN
  INPUT=$(build_input)

  # Temporarily override command lookup: hide real agy if installed
  local clean_path="${MOCK_BIN}"
  local orig_path="$PATH"

  # Build PATH without any directory containing agy
  while IFS=: read -r -d: dir || [ -n "$dir" ]; do
    if [ -d "$dir" ] && [ ! -x "${dir}/agy" ]; then
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
  create_failing_engine "agy" 1
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
  create_mock_engine "agy" ""
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
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
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
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
Missing error handling."
  INPUT=$(build_input)
  run_hook

  assert_deny_json
}

# 17. Standard REJECT tag
@test "verdict: standard REJECT → deny JSON" {
  create_mock_engine "agy" "<verdict>REJECT</verdict>
Fundamentally flawed approach."
  INPUT=$(build_input)
  run_hook

  assert_deny_json
}

# 18. Mixed case → normalized
@test "verdict: mixed case <Verdict>approve</Verdict> → APPROVE" {
  create_mock_engine "agy" "<Verdict>approve</Verdict>
Looks fine."
  INPUT=$(build_input)
  run_hook_to_completion

  assert_approve_json
}

# 19. BUG FIX: No verdict tag → fail-closed as CONCERNS (no crash)
@test "verdict: no verdict tag (BUG FIX) → CONCERNS, deny JSON, no crash" {
  create_mock_engine "agy" "This plan has some issues but overall looks decent.
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
  create_mock_engine "agy" "<verdict> CONCERNS </verdict>
Needs work."
  INPUT=$(build_input)
  run_hook

  assert_deny_json
}

# 21. Verdict typo → fail-closed
@test "verdict: misspelled verdict → CONCERNS (fail-closed)" {
  create_mock_engine "agy" "<verdict>APPROV</verdict>
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
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
All good."
  INPUT=$(build_input)
  run_hook_to_completion

  assert_approve_json
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-count-test-session" ]
  [ ! -f "${REVIEW_COUNTER_DIR}/.review-approved-test-session" ]
}

# 23. CONCERNS → increment counter (both ATTEMPT and TOTAL)
@test "branch: CONCERNS → counter incremented" {
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
Issues found."
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  [ "$(get_counter_value)" -eq 1 ]
  [ "$(get_total_rounds)" -eq 1 ]
}

# 24a. Ack-deny JSON structure validation
@test "branch: APPROVE ack-deny JSON has correct structure" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
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

# 24a-2. Ack-deny message must state APPROVE != authorization to start work,
# and must direct Claude to re-call ExitPlanMode for the user's native go/no-go.
@test "branch: APPROVE ack-deny message forbids starting work before user arbitration" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Plan looks solid."
  INPUT=$(build_input)
  run_hook

  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')

  # Must explicitly decouple approval from authorization to start work
  [[ "$reason" == *"审阅通过 ≠ 可以开工"* ]]
  # Must direct Claude to re-call ExitPlanMode for the user's native decision
  [[ "$reason" == *"ExitPlanMode"* ]]
  # Must instruct not to modify the plan before re-submitting
  [[ "$reason" == *"不修改 plan"* ]]
  # Must forbid starting any implementation action at this point
  [[ "$reason" == *"禁止"* ]]
  [[ "$reason" == *"落地"* ]]
}

# 24b. Ack-deny with round info (multi-round APPROVE)
@test "branch: APPROVE ack-deny after prior rounds includes round info" {
  set_counter_value 2 test-session 4
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
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
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
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
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
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
  create_flaky_engine "agy" "<verdict>APPROVE</verdict>
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
  create_flaky_engine "agy" "<verdict>CONCERNS</verdict>
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
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
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
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
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
  create_failing_engine "agy" 1
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
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
Issues found."
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 1 ]
  [ "$(get_total_rounds)" -eq 1 ]

  # Round 2: engine crashes → fail-deny, counter must stay at 1:1
  create_failing_engine "agy" 1
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 1 ]
  [ "$(get_total_rounds)" -eq 1 ]

  # Round 3: engine recovers → CONCERNS, attempt=2, total=2
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
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
  create_mock_engine "agy" "<verdict>REJECT</verdict>
[Critical] Security vulnerability found."
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  [ "$(get_counter_value)" -eq 0 ]
  [ "$(get_total_rounds)" -eq 1 ]
}

# 35. Multiple REJECT → ATTEMPT stays 0
@test "severity: multiple REJECT → ATTEMPT stays 0" {
  create_mock_engine "agy" "<verdict>REJECT</verdict>
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
  create_mock_engine "agy" "<verdict>REJECT</verdict>
[Critical] Flaw found."
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 0 ]
  [ "$(get_total_rounds)" -eq 1 ]

  # Round 2: CONCERNS → attempt=1, total=2
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
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
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
[Major] Needs work."
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 1 ]
  [ "$(get_total_rounds)" -eq 1 ]

  # Round 2: REJECT → attempt resets to 0, total=2
  create_mock_engine "agy" "<verdict>REJECT</verdict>
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
  create_mock_engine "agy" "<verdict>REJECT</verdict>
[Critical] Broken."
  run_hook; assert_deny_json  # total=1, attempt=0
  run_hook; assert_deny_json  # total=2, attempt=0

  # 2 rounds CONCERNS → attempt goes 1, 2
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
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
  create_mock_engine "agy" "<verdict>REJECT</verdict>
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
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
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
  create_mock_engine "agy" "<verdict>REJECT</verdict>
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
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
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
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
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
  create_mock_engine "agy" "<verdict>REJECT</verdict>
[Critical] New critical flaw introduced."
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 0 ]
  [ "$(get_total_rounds)" -eq 3 ]

  # Round 4: CONCERNS → attempt=1, total=4
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
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
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
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
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
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
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
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

# 45. No plan content → deny (fail-closed, no blind fallback)
@test "skip: no plan content → deny with ERROR reason" {
  INPUT=$(build_input_no_plan)
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"[ERROR]"* ]]
  # Regression: this fail-closed deny path must carry hookEventName, else the
  # framework rejects it with "Hook JSON output validation failed".
  local event_name
  event_name=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.hookEventName')
  [ "$event_name" = "PreToolUse" ]
}

# 45b. No plan content → diagnostic capture: raw payload dumped + key schema logged
@test "skip: no plan content → dumps raw payload and logs field schema" {
  INPUT=$(build_input_no_plan "session_id=diag-sess" "cwd=/work/proj")
  run_hook

  assert_deny_json
  # Decision log records the field schema (top-level keys, tool_input keys, cwd)
  # so the actual CC payload layout can be diagnosed without re-instrumenting.
  assert_log_contains "top_keys="
  assert_log_contains "tool_input_keys="
  assert_log_contains "cwd=/work/proj"
  # A PAYLOAD-DUMP pointer line is written and the raw payload file exists.
  assert_log_contains "PAYLOAD-DUMP"
  local dump_count
  dump_count=$(find "${REVIEW_LOG_DIR}/payloads" -name 'exitplanmode-diag-sess-*.json' 2>/dev/null | wc -l | tr -d ' ')
  [ "$dump_count" -ge 1 ]
}

# 46. Engine CLI not found → allow JSON with WARNING reason
@test "skip: engine CLI not found → allow JSON with WARNING reason" {
  INPUT=$(build_input)

  local clean_path="${MOCK_BIN}"
  local orig_path="$PATH"
  while IFS=: read -r -d: dir || [ -n "$dir" ]; do
    if [ -d "$dir" ] && [ ! -x "${dir}/agy" ]; then
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
  create_failing_engine "agy" 1
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
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
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
  create_mock_engine "agy" "<verdict>APPROVE</verdict> New plan looks good."
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
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
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
  create_failing_engine "agy" 124
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
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
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
  create_failing_engine "agy" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl_sse '<verdict>APPROVE</verdict>\nLooks good via REST.'
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
  create_failing_engine "agy" 1
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
  create_failing_engine "agy" 1
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
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
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
  create_failing_engine "agy" 1
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
  create_failing_engine "agy" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl_sse '<verdict>CONCERNS</verdict>\n[Major] Missing error handling.'
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
  create_capacity_exhausted_engine "agy"
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl_sse '<verdict>APPROVE</verdict>\nLooks good via REST.'
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
  create_capacity_then_success_engine "agy" "<verdict>APPROVE</verdict>LGTM on retry."
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
  create_failing_engine "agy" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl_sse '<verdict>APPROVE</verdict>\nLooks good.'
  INPUT=$(build_input)

  run_hook
  assert_ack_approve_json
  assert_log_contains "rest-result http=200"
}

# 84. ENGINE_OUT non-empty with API error body → rest-debug api_error logged
@test "rest-fallback: api error body → rest-debug api_error logged" {
  create_failing_engine "agy" 1
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
  create_failing_engine "agy" 1
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
  create_failing_engine "agy" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  # Hand-write mock: outputs non-JSON binary content (no .error.message) + status "500".
  # Post-SSE-migration the body_prefix diagnostic lives in the error bypass, reached
  # via a non-2xx status (or a '{'-leading JSON error body); a bare 200 + non-SSE body
  # would instead fall through to the SSE parser. 500 routes it to the bypass as intended.
  cat > "${MOCK_BIN}/curl" << 'SCRIPT_EOF'
#!/bin/bash
out_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out_file="$2"; shift 2 ;;
    --speed-limit|--speed-time) shift 2 ;;
    --no-buffer) shift ;;
    *)  shift ;;
  esac
done
[ -n "$out_file" ] && printf 'Hello\x01\x02World\x03' > "$out_file"
printf '500'
SCRIPT_EOF
  chmod +x "${MOCK_BIN}/curl"
  INPUT=$(build_input)

  run_hook
  assert_deny_json  # fail-deny: engines tried but all failed (CLI + REST)
  # Control chars \x01\x02\x03 must be stripped; printable text preserved
  assert_log_contains "rest-debug body_prefix=HelloWorld"
}

# =============================================================================
# REST SSE Streaming (agy migration — v1.1.0)
# =============================================================================

# 86a. Multi-frame SSE stream → delta.content joined across chunks
@test "rest-sse: multi-frame stream → delta.content joined" {
  create_failing_engine "agy" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  # Two content frames ("A" + "BC") + [DONE]; parser must join to "ABC".
  cat > "${MOCK_BIN}/curl" << 'SCRIPT_EOF'
#!/bin/bash
out_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out_file="$2"; shift 2 ;;
    --speed-limit|--speed-time) shift 2 ;;
    --no-buffer) shift ;;
    *)  shift ;;
  esac
done
[ -n "$out_file" ] && cat > "$out_file" << 'BODY'
data: {"choices":[{"delta":{"role":"assistant"}}]}

data: {"choices":[{"delta":{"content":"<verdict>APPROVE"}}]}

data: {"choices":[{"delta":{"content":"</verdict>\nJoined OK"}}]}

data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

data: [DONE]
BODY
printf '200'
SCRIPT_EOF
  chmod +x "${MOCK_BIN}/curl"
  INPUT=$(build_input)

  # Joined content = "<verdict>APPROVE</verdict>\nJoined OK" → APPROVE → ack-deny
  run_hook
  assert_ack_approve_json
  [[ "$HOOK_STDERR" == *"REST API fallback succeeded"* ]]

  run_hook
  assert_approve_json
}

# 86b. [DONE] terminator does not abort jq parse (content survives)
@test "rest-sse: [DONE] terminator does not break jq parse" {
  create_failing_engine "agy" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  # create_mock_curl_sse emits exactly: data:{delta} + blank + data:[DONE].
  # The [DONE] line is non-JSON; if it reached jq raw the parse would abort and
  # drop the content. grep -v '^\[DONE\]' must strip it so CONCERNS survives.
  create_mock_curl_sse '<verdict>CONCERNS</verdict>
[Major] Survived the DONE terminator.'
  INPUT=$(build_input)

  run_hook
  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"Survived the DONE terminator"* ]]
}

# 86b-2. Malformed mid-stream frame → isolated (fromjson?), later frames survive
@test "rest-sse: malformed mid-stream frame does not truncate the review" {
  create_failing_engine "agy" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  # A truncated/garbled JSON frame sits BETWEEN two good frames. The old whole-
  # stream `jq -rj '.choices...'` would abort at the bad frame and silently drop
  # every chunk after it — here that would lose the [Critical] content following
  # the verdict, risking a stale/misleading review. `jq -R 'fromjson?'` must skip
  # only the bad frame and keep both good frames intact.
  cat > "${MOCK_BIN}/curl" << 'SCRIPT_EOF'
#!/bin/bash
out_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out_file="$2"; shift 2 ;;
    --speed-limit|--speed-time) shift 2 ;;
    --no-buffer) shift ;;
    *)  shift ;;
  esac
done
[ -n "$out_file" ] && cat > "$out_file" << 'BODY'
data: {"choices":[{"delta":{"content":"<verdict>CONCERNS</verdict>"}}]}

data: {"choices":[{"delta":{"content":"truncated frame

data: {"choices":[{"delta":{"content":"\n[Critical] survived the bad frame"}}]}

data: [DONE]
BODY
printf '200'
SCRIPT_EOF
  chmod +x "${MOCK_BIN}/curl"
  INPUT=$(build_input)

  run_hook
  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  # Both the verdict AND the post-bad-frame content must survive.
  [[ "$reason" == *"CONCERNS"* ]]
  [[ "$reason" == *"survived the bad frame"* ]]
}

# 86c. curl exit 28 (stall watchdog) → not parsed, fail-deny with stall reason
@test "rest-sse: curl exit 28 (stall) → fail-deny, not fed to parser" {
  create_failing_engine "agy" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_stalling_curl
  INPUT=$(build_input)

  run_hook
  assert_deny_json  # fail-deny: CLI + REST both failed
  assert_log_contains "rest-stall-timeout curl_exit=28"
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"all review engines failed"* ]]
}

# 86d. Non-2xx JSON error body → error bypass, .error.message logged (not SSE-parsed)
@test "rest-sse: non-2xx JSON error body → error bypass, not SSE-parsed" {
  create_failing_engine "agy" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  # 500 + JSON error object (first char '{') → must hit the error bypass, extract
  # .error.message, and NOT flow through the "data: " SSE cleaning pipeline.
  create_mock_curl '{"error":{"message":"boom upstream"}}' "500"
  INPUT=$(build_input)

  run_hook
  assert_deny_json
  assert_log_contains "rest-result http=500"
  assert_log_contains "rest-debug api_error=boom upstream"
}

# 86d-2. Large SSE body → first_char probe must not SIGPIPE-kill the hook
@test "rest-sse: large body does not SIGPIPE-crash the first-char probe" {
  create_failing_engine "agy" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  # A big (~200KB) valid SSE body. The first_char probe `tr <file | head -c 1`
  # would let head close the pipe after 1 byte while tr streams the whole body →
  # tr dies with SIGPIPE (141); under set -o pipefail + set -e that killed the
  # hook mid-fallback, emitting NO decision JSON. The bounded `head -c 100 | tr`
  # form must survive and still parse the stream to a verdict.
  local big_content
  big_content="<verdict>APPROVE</verdict> $(printf 'y%.0s' $(seq 1 200000))"
  create_mock_curl_sse "$big_content"
  INPUT=$(build_input)

  # Must NOT crash: a valid JSON decision must be emitted (assert_*_json checks
  # exit 0 + parseable JSON — a SIGPIPE crash would fail both).
  run_hook
  assert_ack_approve_json

  run_hook
  assert_approve_json
}

# 86e. Oversized prompt (> 256KB) → skip agy, log agy-skip, fall to REST
@test "rest-sse: oversized prompt → skip agy, REST fallback used" {
  # A plan body north of 256KB trips the ARG_MAX guard: agy is skipped (its prompt
  # can only ride the command line) and REST takes over.
  local big_plan
  big_plan="<verdict>marker</verdict> $(printf 'x%.0s' $(seq 1 300000))"
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl_sse '<verdict>APPROVE</verdict>
Approved via REST after agy skip.'
  INPUT=$(build_input plan="$big_plan")

  run_hook
  assert_ack_approve_json
  assert_log_contains "agy-skip reason=prompt-too-large"
  [[ "$HOOK_STDERR" == *"REST API fallback succeeded"* ]]

  run_hook
  assert_approve_json
}

# =============================================================================
# Time-Budget Guard + REST Timeout Clamping (v1.0.23)
# =============================================================================

# 87. Budget exhausted + REST configured → break retry loop → REST fires
@test "budget-guard: budget exhausted + REST configured → skip retry → REST fires" {
  # HOOK_BUDGET=1 makes remaining ≈ 1 < ENGINE_TIMEOUT(90) on retry check
  export REVIEW_HOOK_BUDGET=1
  create_flaky_engine "agy" "<verdict>APPROVE</verdict>
Would succeed on retry but budget prevents it."
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl_sse '<verdict>APPROVE</verdict>\nLooks good via REST.'
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
  create_flaky_engine "agy" "<verdict>APPROVE</verdict>
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
  create_flaky_engine "agy" "<verdict>APPROVE</verdict>
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
  create_failing_engine "agy" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  # SSE success mock (consumes curl's --speed-limit/--speed-time/--no-buffer flags)
  create_mock_curl_sse '<verdict>APPROVE</verdict>
OK'
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
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
[Major] This should not be seen."
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl_sse '<verdict>APPROVE</verdict>\nREST approved.'
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
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
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
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
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
  create_capacity_exhausted_engine "agy"
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl_sse '<verdict>APPROVE</verdict>\nREST approved.'
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
  create_failing_engine "agy" 1
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
  create_capacity_exhausted_engine "agy"
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
  create_failing_engine "agy" 1
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

  create_failing_engine "agy" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl_sse '<verdict>APPROVE</verdict>\nREST approved.'
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
  # Deny message must embed a self-contained format example (not just "see CLAUDE.md").
  # Assert tokens that ONLY appear in the embedded example, so the old code can't pass.
  [[ "$reason" == *"parallel_with"* ]]
  [[ "$reason" == *"填写规则"* ]]
  # Counter must be incremented (TOTAL_ROUNDS only, ATTEMPT stays 0)
  local attempt; attempt=$(get_counter_value)
  [ "$attempt" -eq 0 ]
  [ "$(get_total_rounds)" -eq 1 ]
}

# 102. plan 含 Task( + 完整 manifest → 进入正常引擎审阅路径
@test "manifest: plan with Task( + Dispatch Manifest → proceeds to engine review" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
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
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
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
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
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
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Simple plan approved."
  INPUT=$(build_input plan="Simple plan: edit file, run tests.")
  run_hook_to_completion

  assert_approve_json
  # Dispatch file must NOT exist
  [ ! -f "${REVIEW_COUNTER_DIR}/.dispatch-test-session.json" ]
}

# 107. manifest 行含 stray 引号 → 落地 JSON 仍合法（jq -e 通过）
@test "manifest: stray quotes in manifest rows → dispatch JSON still valid" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
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

# 108. pre-flight 反复 deny → ATTEMPT 始终 0，不触发非 Critical 安全阀
@test "manifest: repeated pre-flight denies → ATTEMPT stays 0, only TOTAL increments" {
  export REVIEW_MAX_ROUNDS=2
  # No mock engine — pre-flight fires before engine call
  INPUT=$(build_input plan="Use Task( for analysis.")

  # Round 1: ATTEMPT stays 0, TOTAL→1
  run_hook
  assert_deny_json
  [[ "$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" == *"MISSING DISPATCH MANIFEST"* ]]
  [ "$(get_counter_value)" -eq 0 ]
  [ "$(get_total_rounds)" -eq 1 ]

  # Round 2: ATTEMPT stays 0, TOTAL→2
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 0 ]
  [ "$(get_total_rounds)" -eq 2 ]

  # Round 3: ATTEMPT=0 < MAX=2 → valve does NOT fire, pre-flight deny again
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 0 ]
  [ "$(get_total_rounds)" -eq 3 ]
}

# 109. APPROVE 写入 dispatch 前清理 stale 文件
@test "manifest: APPROVE path cleans up stale dispatch files" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
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

# 110. plan 含 dispatch 关键词 + manifest 全 "-" → degenerate deny + counter increment
@test "manifest: all-dash manifest → pre-flight degenerate deny + counter increment" {
  local plan_all_dash="## Plan
Step 1: Use Task( for analysis.

## Dispatch Manifest
| step | agent_type | model | depends_on | parallel_with |
|------|-----------|-------|------------|---------------|
| 1    | -         | -     | -          | -             |
| 2    | -         | -     | 1          | -             |"
  INPUT=$(build_input "plan=$plan_all_dash")
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"DEGENERATE DISPATCH MANIFEST"* ]]
  # Deny message must embed the self-contained format example.
  [[ "$reason" == *"parallel_with"* ]]
  [[ "$reason" == *"填写规则"* ]]
  local attempt; attempt=$(get_counter_value)
  [ "$attempt" -eq 0 ]
  [ "$(get_total_rounds)" -eq 1 ]
}

# 111. mixed manifest (dash + real agent) → passes pre-flight (non-regression)
@test "manifest: mixed manifest with real agent_type → passes pre-flight to engine" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
All good."
  local plan_mixed="## Plan
Step 1: Prepare context. Step 2: Use Task( for heavy lifting.

## Dispatch Manifest
| step | agent_type | model | depends_on | parallel_with |
|------|-----------|-------|------------|---------------|
| 1    | -         | -     | -          | -             |
| 2    | worker    | sonnet| 1          | -             |"
  INPUT=$(build_input "plan=$plan_mixed")
  run_hook

  assert_ack_approve_json
}

# 112. all-dash repeated → ATTEMPT stays 0, only TOTAL increments
@test "manifest: repeated degenerate denies → ATTEMPT stays 0, only TOTAL increments" {
  export REVIEW_MAX_ROUNDS=2
  local plan_all_dash="## Plan
Use Task( for work.

## Dispatch Manifest
| step | agent_type | model | depends_on | parallel_with |
|------|-----------|-------|------------|---------------|
| 1    | -         | -     | -          | -             |"
  INPUT=$(build_input "plan=$plan_all_dash")

  # Round 1: degenerate deny, ATTEMPT stays 0, TOTAL→1
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 0 ]
  [ "$(get_total_rounds)" -eq 1 ]

  # Round 2: degenerate deny, ATTEMPT stays 0, TOTAL→2
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 0 ]
  [ "$(get_total_rounds)" -eq 2 ]

  # Round 3: ATTEMPT=0 < MAX=2 → valve does NOT fire, degenerate deny again
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 0 ]
  [ "$(get_total_rounds)" -eq 3 ]
}

# 113. empty manifest (header + separator only, 0 data rows) → degenerate deny
@test "manifest: empty manifest section (no data rows) → degenerate deny" {
  local plan_empty_manifest="## Plan
Step 1: Use Task( for isolation.

## Dispatch Manifest
| step | agent_type | model | depends_on | parallel_with |
|------|-----------|-------|------------|---------------|

## Next Section"
  INPUT=$(build_input "plan=$plan_empty_manifest")
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"DEGENERATE DISPATCH MANIFEST"* ]]
}

# 114. agent_type="worker" + model="-" → NOT blocked (only agent_type checked)
@test "manifest: real agent_type with dash model → passes pre-flight" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
OK."
  local plan_agent_no_model="## Plan
Use Task( for analysis.

## Dispatch Manifest
| step | agent_type | model | depends_on | parallel_with |
|------|-----------|-------|------------|---------------|
| 1    | worker    | -     | -          | -             |"
  INPUT=$(build_input "plan=$plan_agent_no_model")
  run_hook

  assert_ack_approve_json
}

# 100. Capacity-fast-break → degrade file already written; REST entry does not overwrite
#      (double-write is harmless: timestamps differ by <1s, both numeric, TTL still valid)
@test "degrade: capacity-fast-break + REST success → degrade file refreshed (double-write harmless)" {
  create_capacity_exhausted_engine "agy"
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl_sse '<verdict>APPROVE</verdict>\nREST approved.'
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

@test "system-instructions: Scope Boundary has training-cutoff / version-identifier ground-truth directive" {
  grep -q "GROUND TRUTH" "${HOOK_SCRIPT:?Missing hook script}"
  grep -q "verify against your memory" "${HOOK_SCRIPT:?Missing hook script}"
  grep -q "training knowledge has a cutoff" "${HOOK_SCRIPT:?Missing hook script}"
  grep -q "NOT common knowledge" "${HOOK_SCRIPT:?Missing hook script}"
  grep -q "never Critical" "${HOOK_SCRIPT:?Missing hook script}"
}

# ---------------------------------------------------------------------------
# Finding Quality Gate (issue #30) — prompt-layer denoising directives.
# These are static prompt-content assertions: the gate operates inside the
# review engine (LLM self-check), so it cannot be exercised at runtime here.
# We assert the four gap-closing directives are present in SYSTEM_INSTRUCTIONS.
# ---------------------------------------------------------------------------
@test "system-instructions: Finding Quality Gate section present" {
  grep -q "Finding Quality Gate" "${HOOK_SCRIPT:?Missing hook script}"
}

@test "quality-gate: gap1 confidence threshold + drop-low-confidence directive" {
  grep -q "Confidence" "${HOOK_SCRIPT:?Missing hook script}"
  grep -q "DROP" "${HOOK_SCRIPT:?Missing hook script}"
}

@test "quality-gate: gap1 gradient exit — low-confidence Critical kept as UNVERIFIED, not dropped" {
  grep -q "UNVERIFIED" "${HOOK_SCRIPT:?Missing hook script}"
  grep -q "not REJECT" "${HOOK_SCRIPT:?Missing hook script}"
}

@test "quality-gate: gap2 false-positive registry present" {
  grep -q "False-positive registry" "${HOOK_SCRIPT:?Missing hook script}"
  grep -qi "never raise" "${HOOK_SCRIPT:?Missing hook script}"
}

@test "quality-gate: gap3 verdict-severity pre-flight self-check (prompt-layer, not body-scan)" {
  grep -q "Verdict↔severity" "${HOOK_SCRIPT:?Missing hook script}"
  # Routing must remain verdict-only: the hook must NOT grep the body for severity tags
  ! grep -qE "grep[^|]*'\[Critical\]'" "${HOOK_SCRIPT:?Missing hook script}"
}

@test "quality-gate: gap4 severity calibration anti-drift" {
  grep -q "Severity calibration" "${HOOK_SCRIPT:?Missing hook script}"
  grep -q "never Major" "${HOOK_SCRIPT:?Missing hook script}"
}

@test "quality-gate: UNVERIFIED routes to CONCERNS in verdict rules + output format" {
  # CONCERNS bucket explicitly includes UNVERIFIED suspicions
  grep -q "UNVERIFIED.*suspicion.*but no confirmed Critical\|including any .UNVERIFIED" "${HOOK_SCRIPT:?Missing hook script}"
  # output format documents the [Major] [UNVERIFIED] emission shape
  grep -q '\[Major\] \[UNVERIFIED\]' "${HOOK_SCRIPT:?Missing hook script}"
}

# =============================================================================
# Dispatch Economy — Criterion 7 regression (v1.0.44 → v1.0.45)
# Asserts: (1) bash syntax still valid after heredoc refactor,
#          (2) new Criterion 7 token set is present in SYSTEM_INSTRUCTIONS,
#          (3) manifest detection path still passes through to engine (non-regression).
# =============================================================================

# 115. bash syntax check — quoted heredoc must have matching delimiters
@test "dispatch-economy: bash -n reports no syntax errors after heredoc refactor" {
  run bash -n "${HOOK_SCRIPT:?Missing hook script}"
  [ "$status" -eq 0 ]
}

# 116. Criterion 7 token presence — new prompt content has not been reverted
@test "dispatch-economy: Criterion 7 tokens present in SYSTEM_INSTRUCTIONS" {
  grep -q "Dispatch Economy"      "${HOOK_SCRIPT:?Missing hook script}"
  grep -q "Full hoarding"         "${HOOK_SCRIPT:?Missing hook script}"
  grep -q "Partial hoarding"      "${HOOK_SCRIPT:?Missing hook script}"
  grep -q "Retrieval work"        "${HOOK_SCRIPT:?Missing hook script}"
  grep -q "split-brain"           "${HOOK_SCRIPT:?Missing hook script}"
  grep -q "Decision work"         "${HOOK_SCRIPT:?Missing hook script}"
  grep -q "Implementation work"   "${HOOK_SCRIPT:?Missing hook script}"
}

# 117. manifest detection survives prompt refactor — Task( + manifest reaches engine
# Non-regression: same scenario as test 102, re-asserted post-heredoc-refactor.
@test "dispatch-economy: Task( + Dispatch Manifest still proceeds to engine review after refactor" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Dispatch Economy verified."
  local plan_with_manifest="## Plan
Step 1: Use Task( for isolation.

## Dispatch Manifest
| step | agent_type | model | depends_on | parallel_with |
|------|-----------|-------|------------|---------------|
| 1    | worker    | sonnet| -          | -             |"
  INPUT=$(build_input "plan=$plan_with_manifest")
  run_hook

  assert_ack_approve_json
}

# --- Bug #44: blank-line tolerance in manifest parsing ---

# 118. blank line between heading and table → manifest still parsed
@test "manifest: blank line between heading and table → passes pre-flight" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
All good."
  local plan_blank="## Plan
Step 1: Use Task( for isolation.

## Dispatch Manifest

| step | agent_type | model | depends_on | parallel_with |
|------|-----------|-------|------------|---------------|
| 1    | worker    | sonnet| -          | -             |"
  INPUT=$(build_input "plan=$plan_blank")
  run_hook

  assert_ack_approve_json
}

# 119. blank line before all-dash table → degenerate deny (not false pass)
@test "manifest: blank line before all-dash table → degenerate deny" {
  local plan_blank_dash="## Plan
Step 1: Use Task( for work.

## Dispatch Manifest

| step | agent_type | model | depends_on | parallel_with |
|------|-----------|-------|------------|---------------|
| 1    | -         | -     | -          | -             |"
  INPUT=$(build_input "plan=$plan_blank_dash")
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"DEGENERATE DISPATCH MANIFEST"* ]]
}

# 120. multiple blank lines between heading and table → still parsed
@test "manifest: multiple blank lines between heading and table → passes pre-flight" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
OK."
  local plan_multi="## Plan
Use Task( for work.

## Dispatch Manifest


| step | agent_type | model | depends_on | parallel_with |
|------|-----------|-------|------------|---------------|
| 1    | worker    | haiku | -          | -             |"
  INPUT=$(build_input "plan=$plan_multi")
  run_hook

  assert_ack_approve_json
}

# 121. blank line AFTER table terminates parsing (existing behavior preserved)
@test "manifest: blank line after table terminates block" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Good."
  local plan_trail="## Plan
Use Task( for isolation.

## Dispatch Manifest
| step | agent_type | model | depends_on | parallel_with |
|------|-----------|-------|------------|---------------|
| 1    | worker    | sonnet| -          | -             |

Some trailing content."
  INPUT=$(build_input "plan=$plan_trail")
  run_hook

  assert_ack_approve_json
}

# 122. manifest heading with no table + next section has table → no bleeding
@test "manifest: heading with no table + next section has table → chapter boundary stops parsing" {
  local plan_no_table="## Plan
Use Task( for analysis.

## Dispatch Manifest

## Other Section
| step | agent_type | model | depends_on | parallel_with |
|------|-----------|-------|------------|---------------|
| 1    | worker    | sonnet| -          | -             |"
  INPUT=$(build_input "plan=$plan_no_table")
  run_hook

  # Must deny as MISSING (manifest heading present but no table before next ##)
  # Actually has_manifest matches heading, manifest_has_real_agent finds nothing → DEGENERATE
  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"DEGENERATE DISPATCH MANIFEST"* ]]
}

# --- Bug #71: pre-flight deny NOT consuming ATTEMPT budget ---

# 123. pre-flight deny then fix → engine review starts ATTEMPT from 0
@test "manifest: pre-flight deny then fix → engine review starts ATTEMPT from 0" {
  export REVIEW_MAX_ROUNDS=2
  INPUT=$(build_input plan="Use Task( for analysis.")

  # Pre-flight deny: ATTEMPT stays 0, TOTAL→1
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 0 ]
  [ "$(get_total_rounds)" -eq 1 ]

  # User fixes manifest, engine gives CONCERNS
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
Issues found."
  local fixed_plan="## Plan
Use Task( for analysis.

## Dispatch Manifest
| step | agent_type | model | depends_on | parallel_with |
|------|-----------|-------|------------|---------------|
| 1    | worker    | sonnet| -          | -             |"
  INPUT=$(build_input "plan=$fixed_plan")
  run_hook

  # Engine CONCERNS: ATTEMPT→1, TOTAL→2
  assert_deny_json
  [ "$(get_counter_value)" -eq 1 ]
  [ "$(get_total_rounds)" -eq 2 ]
}

# 124. pre-flight denies hit global safety valve at TOTAL_ROUNDS limit
@test "manifest: pre-flight denies hit global safety valve at TOTAL_ROUNDS limit" {
  export REVIEW_MAX_TOTAL_ROUNDS=3
  INPUT=$(build_input plan="Use Task( for analysis.")

  # 3 pre-flight denies → TOTAL reaches 3
  run_hook; assert_deny_json; [ "$(get_total_rounds)" -eq 1 ]
  run_hook; assert_deny_json; [ "$(get_total_rounds)" -eq 2 ]
  run_hook; assert_deny_json; [ "$(get_total_rounds)" -eq 3 ]

  # Next call: TOTAL=3 >= MAX_TOTAL=3 → global safety valve (HARD STOP deny)
  run_hook
  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"HARD STOP"* ]]
}

# =============================================================================
# agy conversation reuse + JSON output + degrade TTL (v1.2.0)
# =============================================================================

# conv: first round — no CONV_FILE → agy called WITHOUT --conversation, id captured
@test "conv: first round → agy invoked without --conversation, CONV_FILE created" {
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
[Major] Something to fix."
  INPUT=$(build_input)
  run_hook
  assert_deny_json
  # agy was called without a --conversation flag on the first round
  [[ "$(agy_args agy)" != *"--conversation"* ]]
  # agy was called with JSON output mode
  [[ "$(agy_args agy)" == *"--output-format json"* ]]
  # conversation_id was captured and persisted
  local convfile="${REVIEW_COUNTER_DIR}/.conversation-test-session"
  [ -f "$convfile" ]
  [[ "$(cat "$convfile")" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
  assert_log_contains "agy-conversation id=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee reuse=no"
}

# conv: reuse round — CONV_FILE present → agy called WITH --conversation <id>
@test "conv: reuse round → agy invoked with --conversation <captured id>" {
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
[Major] Round issue."
  INPUT=$(build_input)
  # Round 1: creates CONV_FILE
  run_hook
  assert_deny_json
  [ -f "${REVIEW_COUNTER_DIR}/.conversation-test-session" ]
  # Round 2: should resume the captured conversation
  run_hook
  assert_deny_json
  [[ "$(agy_args agy)" == *"--conversation aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"* ]]
  assert_log_contains "reuse=yes"
}

# conv: cleanup on ack-round approved → CONV_FILE removed
@test "conv: ack-round approved → CONV_FILE removed" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Looks good."
  INPUT=$(build_input)
  run_hook              # APPROVE → ack-deny, writes APPROVE_MARKER
  assert_ack_approve_json
  run_hook              # ack-round → allow, cleans counter + CONV_FILE
  assert_approve_json
  [ ! -f "${REVIEW_COUNTER_DIR}/.conversation-test-session" ]
}

# conv: cleanup on non-critical safety valve → CONV_FILE removed
@test "conv: non-critical safety valve → CONV_FILE removed" {
  export REVIEW_MAX_ROUNDS=1
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
[Major] Persistent."
  INPUT=$(build_input)
  run_hook              # ATTEMPT 0→1, CONCERNS deny, CONV_FILE written
  assert_deny_json
  run_hook              # ATTEMPT 1 >= MAX 1 → valve allow, cleans CONV_FILE
  assert_approve_json
  [[ "$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" == *"ESCALATED"* ]]
  [ ! -f "${REVIEW_COUNTER_DIR}/.conversation-test-session" ]
}

# conv: no-plan fail-closed → CONV_FILE removed
@test "conv: no-plan fail-closed → CONV_FILE removed" {
  # Seed a stale CONV_FILE
  printf '%s' "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" > "${REVIEW_COUNTER_DIR}/.conversation-test-session"
  INPUT=$(build_input_no_plan)
  run_hook
  assert_deny_json
  [ ! -f "${REVIEW_COUNTER_DIR}/.conversation-test-session" ]
}

# conv: capacity fast-break → cached CONV_FILE cleared
@test "conv: capacity fast-break → CONV_FILE cleared" {
  printf '%s' "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" > "${REVIEW_COUNTER_DIR}/.conversation-test-session"
  create_capacity_exhausted_engine "agy"
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl_sse '<verdict>APPROVE</verdict>\nREST approved.'
  INPUT=$(build_input)
  run_hook
  # capacity → fast-break → REST fallback; the cached conversation must be dropped
  [ ! -f "${REVIEW_COUNTER_DIR}/.conversation-test-session" ]
}

# json: multi-line response with escaped chars → verdict correctly extracted
@test "json: multi-line response body → verdict parsed, review unwrapped" {
  create_mock_engine "agy" "<verdict>REJECT</verdict>
[Critical] Line one.
[Critical] Line two with \"quotes\".
End."
  INPUT=$(build_input)
  run_hook
  assert_deny_json
  # REJECT verdict was extracted from the JSON response despite raw newlines
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"REJECT"* ]]
  [[ "$reason" == *"Line one."* ]]
  [[ "$reason" == *"Line two"* ]]
}

# json: response extraction failure → no false verdict from envelope, engine treated as failed
@test "json: malformed envelope with fake verdict tag → not mis-parsed as REJECT" {
  # Mock emits JSON WITHOUT a response field, but the envelope text contains a
  # <verdict>REJECT</verdict> literal (e.g. echoed prompt). The unwrap must fail
  # and the raw shell must NOT be fed to the verdict extractor.
  cat > "${MOCK_BIN}/agy" <<'MOCK_INNER'
#!/bin/bash
printf '%s\n' "$*" > "$(dirname "$0")/../.agy-args-agy"
printf '{"conversation_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","status":"SUCCESS","echoed_prompt":"<verdict>REJECT</verdict>","usage":{"input_tokens":1,"total_tokens":2}}\n'
MOCK_INNER
  chmod +x "${MOCK_BIN}/agy"
  INPUT=$(build_input)
  run_hook
  # response extraction failed → REVIEW empty → logged, no engine success
  assert_log_contains "agy-response-extract-failed"
  # The fake REJECT in the envelope must NOT drive the decision.
  # With no REST configured, all engines fail → deny with engines-failed reason.
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
  [[ "$reason" != *"REJECT"* ]]
}

# json: agy's real backend HTML-safe-escapes the "response" string value's
# angle brackets and ampersand (Go encoding/json default, verified against
# production output). Regression for a bug where these were NOT among the awk
# unescaper's handled cases, silently corrupting the first-line verdict tag
# into mangled literal text and forcing every agy call to fall back to
# CONCERNS regardless of the engine's real verdict. create_mock_engine itself
# now performs this same HTML-safe escaping (test_helper/common-setup.bash),
# so a plain fixture string round-trips through the real production shape
# automatically -- no bespoke mock needed here.
@test "json: HTML-safe-escaped verdict tag (agy's real JSON shape) -> APPROVE, not corrupted-to-CONCERNS" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
A & B look fine."
  INPUT=$(build_input)
  run_hook
  assert_ack_approve_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  # The unescaped review body must reach the user cleanly -- no leftover
  # "u003c"-style mangling, and the escaped "&" must decode too.
  [[ "$reason" == *"A & B look fine."* ]]
  [[ "$reason" != *"u003c"* ]]
}

# json: same HTML-safe-escaped shape, but a REJECT verdict -- the
# higher-stakes half of this bug. Before the fix, ANY verdict (not just
# APPROVE) silently fell back to CONCERNS on agy, since the first-line tag
# structure itself was corrupted regardless of which keyword it wrapped. A
# confirmed-Critical REJECT getting silently downgraded to CONCERNS is worse
# than a missed APPROVE: REJECT resets the negotiation-round counter and
# forces Critical framing in front of the user; CONCERNS just burns a round
# and can eventually auto-allow via the non-critical safety valve -- letting
# a plan with a real Critical defect slip through.
@test "json: HTML-safe-escaped verdict tag (agy's real JSON shape) -> REJECT, not silently downgraded to CONCERNS" {
  create_mock_engine "agy" "<verdict>REJECT</verdict>
[Critical] Data loss path & no rollback."
  INPUT=$(build_input)
  run_hook
  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"REJECT"* ]]
  [[ "$reason" != *"CONCERNS"* ]]
  [[ "$reason" == *"Data loss path & no rollback."* ]]
  [[ "$reason" != *"u003c"* ]]
}

# ttl: new default 600 — degraded file aged 700s (> 600) → expired, agy called
@test "ttl: default 600 — 700s-old degrade file treated as expired (agy invoked)" {
  create_degraded_file 700   # older than new 600 default
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Fresh call."
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  INPUT=$(build_input)
  run_hook
  # Not skipped: agy actually ran (args captured), no skip-cli log
  [ -f "${MOCK_BIN}/../.agy-args-agy" ]
  ! grep -q "gemini-degraded skip-cli" "${REVIEW_LOG_DIR}/plan-review.log"
}

# ttl: new default 600 — degraded file aged 500s (< 600) → still degraded, skip CLI
@test "ttl: default 600 — 500s-old degrade file still active (skip CLI)" {
  create_degraded_file 500   # within new 600 default
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
Should not run."
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl_sse '<verdict>APPROVE</verdict>\nREST approved.'
  INPUT=$(build_input)
  run_hook
  assert_log_contains "gemini-degraded skip-cli"
}

# ttl: explicit override — TTL=1200, 700s-old file → still degraded (env beats default)
@test "ttl: explicit REVIEW_ENGINE_DEGRADE_TTL=1200 overrides default (700s still active)" {
  export REVIEW_ENGINE_DEGRADE_TTL=1200
  create_degraded_file 700   # < 1200 override, would be > 600 default
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
Should not run."
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl_sse '<verdict>APPROVE</verdict>\nREST approved.'
  INPUT=$(build_input)
  run_hook
  assert_log_contains "gemini-degraded skip-cli"
}

# =============================================================================
# grok review hardening (v1.2.0, PR #111): CONV cleanup on failure/plan-change,
# whitespace-tolerant response extraction, reuse-round framing
# =============================================================================

# conv: extract failure → stale CONV_FILE cleared (not resumed next round)
@test "conv: response extract failure → CONV_FILE cleared" {
  # Seed a stale CONV_FILE, then have agy return an envelope with NO response
  # field (extraction fails). No REST configured → engines fail → deny.
  printf '%s' "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" > "${REVIEW_COUNTER_DIR}/.conversation-test-session"
  cat > "${MOCK_BIN}/agy" <<'MOCK_INNER'
#!/bin/bash
printf '%s\n' "$*" > "$(dirname "$0")/../.agy-args-agy"
printf '{"conversation_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","status":"SUCCESS","no_response_here":"x"}\n'
MOCK_INNER
  chmod +x "${MOCK_BIN}/agy"
  INPUT=$(build_input)
  run_hook
  assert_log_contains "agy-response-extract-failed"
  [ ! -f "${REVIEW_COUNTER_DIR}/.conversation-test-session" ]
}

# conv: empty review → CONV_FILE NOT persisted (deferred-persist policy)
@test "conv: empty extracted review → CONV_FILE not written" {
  # agy exit 0 but response unwraps to empty → must not persist a conversation
  # we cannot consume. No prior CONV_FILE, no REST → deny.
  cat > "${MOCK_BIN}/agy" <<'MOCK_INNER'
#!/bin/bash
printf '%s\n' "$*" > "$(dirname "$0")/../.agy-args-agy"
printf '{"conversation_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","response":"","usage":{}}\n'
MOCK_INNER
  chmod +x "${MOCK_BIN}/agy"
  INPUT=$(build_input)
  run_hook
  [ ! -f "${REVIEW_COUNTER_DIR}/.conversation-test-session" ]
}

# conv: plan changed after approve → falls through to re-review, CONV cleared
@test "conv: plan-changed-after-approve → old session dropped, re-review is fresh first round" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Good."
  INPUT=$(build_input plan="Original plan")
  run_hook                    # APPROVE → ack-deny, APPROVE_MARKER + CONV_FILE written
  assert_ack_approve_json
  [ -f "${REVIEW_COUNTER_DIR}/.conversation-test-session" ]
  # Plan changes before the ack-round → hash mismatch → plan-changed branch must
  # drop the old conversation handle so the re-review does NOT resume the OLD
  # plan's session to review a DIFFERENT plan.
  INPUT=$(build_input plan="Completely different plan")
  run_hook
  assert_log_contains "reason=plan-changed-after-approve conv-cleared"
  # The re-review round called agy WITHOUT --conversation (fresh first round),
  # proving the stale handle was dropped rather than resumed onto the new plan.
  [[ "$(agy_args agy)" != *"--conversation"* ]]
}

# conv: global safety valve → CONV_FILE cleared (no orphan)
@test "conv: global safety valve → CONV_FILE cleared" {
  set_counter_value 0 test-session 3
  export REVIEW_MAX_TOTAL_ROUNDS=3
  printf '%s' "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" > "${REVIEW_COUNTER_DIR}/.conversation-test-session"
  INPUT=$(build_input)
  run_hook
  assert_deny_json
  [[ "$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" == *"HARD STOP"* ]]
  [ ! -f "${REVIEW_COUNTER_DIR}/.conversation-test-session" ]
}

# json: response with surrounding whitespace around key colon → still extracted
@test "json: whitespace around response key colon → verdict still extracted" {
  cat > "${MOCK_BIN}/agy" <<'MOCK_INNER'
#!/bin/bash
printf '%s\n' "$*" > "$(dirname "$0")/../.agy-args-agy"
printf '{"conversation_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","response" : "<verdict>APPROVE</verdict>\nspaced key colon","usage":{}}\n'
MOCK_INNER
  chmod +x "${MOCK_BIN}/agy"
  INPUT=$(build_input)
  run_hook
  assert_ack_approve_json
}

# conv: reuse-round prompt carries Consultation Context (round framing)
@test "conv: reuse round prompt includes Consultation Context framing" {
  # Capture the full prompt agy receives on the reuse round via a mock that
  # dumps its -p argument. Round 1 seeds CONV_FILE; round 2 is the reuse round.
  cat > "${MOCK_BIN}/agy" <<'MOCK_INNER'
#!/bin/bash
# Find the -p value and dump it
prev=""
for a in "$@"; do
  if [ "$prev" = "-p" ]; then printf '%s' "$a" > "$(dirname "$0")/../.agy-prompt-agy"; fi
  prev="$a"
done
printf '%s\n' "$*" > "$(dirname "$0")/../.agy-args-agy"
printf '{"conversation_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","response":"<verdict>CONCERNS</verdict>\n[Major] x","usage":{}}\n'
MOCK_INNER
  chmod +x "${MOCK_BIN}/agy"
  INPUT=$(build_input)
  run_hook   # round 1 → CONCERNS, seeds CONV_FILE
  assert_deny_json
  run_hook   # round 2 → reuse round
  local prompt
  prompt=$(cat "${MOCK_BIN}/../.agy-prompt-agy")
  [[ "$prompt" == *"Consultation Context"* ]]
  [[ "$prompt" == *"Plan to Review"* ]]
}

# conv: non-capacity CLI failure (exit≠0) → resume handle dropped
@test "conv: agy exit≠0 (non-capacity) → CONV_FILE cleared" {
  # Seed a stale CONV_FILE, then agy fails with a plain non-zero exit (not
  # capacity). No REST configured. The resume handle must be dropped so the
  # next round won't re-send --conversation onto a session that just failed.
  printf '%s' "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" > "${REVIEW_COUNTER_DIR}/.conversation-test-session"
  create_failing_engine "agy" 1
  INPUT=$(build_input)
  run_hook
  [ ! -f "${REVIEW_COUNTER_DIR}/.conversation-test-session" ]
}

# =============================================================================
# codex engine (REVIEW_ENGINE=codex)
# =============================================================================

# codex: 1. APPROVE verdict → ack-deny, approve marker written
@test "codex: APPROVE verdict → ack-deny, approve marker written" {
  export REVIEW_ENGINE="codex"
  create_mock_codex "<verdict>APPROVE</verdict>
Looks solid."
  INPUT=$(build_input)
  run_hook

  assert_ack_approve_json
  [ -f "${REVIEW_COUNTER_DIR}/.review-approved-test-session" ]
}

# codex: 2. CONCERNS verdict → deny, ATTEMPT/TOTAL counters correct
@test "codex: CONCERNS verdict → deny, ATTEMPT/TOTAL incremented" {
  export REVIEW_ENGINE="codex"
  create_mock_codex "<verdict>CONCERNS</verdict>
[Major] Missing error handling."
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  [ "$(get_counter_value)" -eq 1 ]
  [ "$(get_total_rounds)" -eq 1 ]
}

# codex: 3. REJECT verdict → deny, ATTEMPT reset to 0 (TOTAL still increments)
@test "codex: REJECT verdict → deny, ATTEMPT reset to 0" {
  export REVIEW_ENGINE="codex"
  set_counter_value 2 test-session 2
  create_mock_codex "<verdict>REJECT</verdict>
[Critical] Fundamentally flawed approach."
  INPUT=$(build_input)
  run_hook

  assert_deny_json
  [ "$(get_counter_value)" -eq 0 ]
  [ "$(get_total_rounds)" -eq 3 ]
}

# codex: 4. codex binary missing → fail-open allow + stderr/reason WARNING
@test "codex: binary missing → fail-open allow with WARNING" {
  export REVIEW_ENGINE="codex"
  INPUT=$(build_input)

  # Mirror the "engine: CLI not found" guard test: rebuild PATH excluding any
  # directory that happens to have a real `codex` installed (this plugin repo
  # ships a codex companion, so a real binary may well be on the dev PATH).
  local clean_path="${MOCK_BIN}"
  local orig_path="$PATH"
  while IFS=: read -r -d: dir || [ -n "$dir" ]; do
    if [ -d "$dir" ] && [ ! -x "${dir}/codex" ]; then
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

# codex: 5. CODEX_BIN pointing at a binary OUTSIDE PATH → is actually used
@test "codex: CODEX_BIN outside PATH → used directly" {
  export REVIEW_ENGINE="codex"
  local outside_dir="${TEST_TEMP_DIR}/outside-path"
  mkdir -p "$outside_dir"
  local saved_mock_bin="$MOCK_BIN"
  MOCK_BIN="$outside_dir"
  create_mock_codex "<verdict>APPROVE</verdict>
Used the CODEX_BIN override."
  MOCK_BIN="$saved_mock_bin"
  export CODEX_BIN="${outside_dir}/codex"

  # Sanity: the override binary must NOT be reachable via bare PATH lookup.
  ! command -v codex >/dev/null 2>&1 || [ "$(command -v codex)" != "${outside_dir}/codex" ]

  INPUT=$(build_input)
  run_hook

  assert_ack_approve_json
}

# codex: 6. CODEX_MODEL empty → no -m flag; CODEX_MODEL set → -m <value> present
@test "codex: CODEX_MODEL empty → no -m; CODEX_MODEL set → -m <value> present" {
  export REVIEW_ENGINE="codex"
  create_mock_codex "<verdict>APPROVE</verdict>
ok"
  INPUT=$(build_input)
  run_hook
  assert_ack_approve_json
  [[ "$(agy_args codex)" != *"-m "* ]]

  # New session_id: reusing test-session would just hit the ack-round guard
  # (unchanged plan hash → allow without calling codex again).
  export CODEX_MODEL="gpt-5.1-codex-max"
  INPUT=$(build_input session_id=session-with-model)
  run_hook
  assert_ack_approve_json
  [[ "$(agy_args codex)" == *"-m gpt-5.1-codex-max"* ]]
}

# codex: 7. non-zero exit → retry exhausted → REST fallback takes over
@test "codex: non-zero exit → retry exhausted → REST fallback takes over" {
  export REVIEW_ENGINE="codex"
  create_failing_codex 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl_sse '<verdict>APPROVE</verdict>\nApproved via REST.'
  INPUT=$(build_input)
  run_hook

  assert_ack_approve_json
  [[ "$HOOK_STDERR" == *"REST API fallback succeeded"* ]]
}

# codex: 8. empty response → retry then allow JSON with WARNING
@test "codex: empty response → retry then allow JSON with WARNING" {
  export REVIEW_ENGINE="codex"
  create_mock_codex ""
  INPUT=$(build_input)
  run_hook

  assert_approve_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"[WARNING]"* ]]
}

# codex: 9. invocation args carry the isolation flags; -C is NOT the project cwd
@test "codex: invocation args include isolation flags; -C differs from project cwd" {
  export REVIEW_ENGINE="codex"
  create_mock_codex "<verdict>APPROVE</verdict>
ok"
  INPUT=$(build_input cwd=/project/dir)
  run_hook
  assert_ack_approve_json

  local args cwd_arg
  args=$(agy_args codex)
  [[ "$args" == *"-s read-only"* ]]
  [[ "$args" == *"--ephemeral"* ]]
  [[ "$args" == *"-C "* ]]

  cwd_arg=$(printf '%s' "$args" | awk '{for(i=1;i<=NF;i++) if($i=="-C"){print $(i+1); exit}}')
  [ -n "$cwd_arg" ]
  [ "$cwd_arg" != "/project/dir" ]
}

# codex: 10. failure path → LOG_FILE has ERROR diagnostics, no prompt body leak
@test "codex: failure path → LOG_FILE has ERROR diagnostics, no prompt body leak" {
  export REVIEW_ENGINE="codex"
  create_failing_codex 1
  # SYSTEM_INSTRUCTIONS itself contains the literal phrase "missing error
  # handling" — this falsifies a naive keyword-based ("contains 'error'")
  # filter, since the real diagnostic ("ERROR: mock codex failure") also
  # contains "error" and must survive while the prompt phrase must not.
  INPUT=$(build_input plan="Plan with an error handling gap to review.")
  run_hook

  assert_deny_json
  assert_log_contains "ERROR: mock codex failure"
  run grep -F "missing error handling" "${REVIEW_LOG_DIR}/plan-review.log"
  [ "$status" -ne 0 ]
  run grep -F "Plan with an error handling gap to review." "${REVIEW_LOG_DIR}/plan-review.log"
  [ "$status" -ne 0 ]
}

# codex: 11. banner drift (missing second --------) → fail-closed branch still filters prompt
@test "codex: banner drift (no second dashes) → fail-closed branch, still no prompt leak" {
  export REVIEW_ENGINE="codex"
  export MOCK_CODEX_NO_SECOND_DASHES=1
  create_failing_codex 1
  INPUT=$(build_input plan="Plan with an error handling gap to review.")
  run_hook

  assert_deny_json
  assert_log_contains "ERROR: mock codex failure"
  run grep -F "missing error handling" "${REVIEW_LOG_DIR}/plan-review.log"
  [ "$status" -ne 0 ]
  run grep -F "Plan with an error handling gap to review." "${REVIEW_LOG_DIR}/plan-review.log"
  [ "$status" -ne 0 ]
}

# codex: 12. line-count drift (extra blank line) → Layer B content filter saves it
@test "codex: line-count drift (extra blank) → Layer B still strips prompt content" {
  export REVIEW_ENGINE="codex"
  export MOCK_CODEX_EXTRA_BLANK=1
  create_failing_codex 1
  INPUT=$(build_input plan="Plan with an error handling gap to review.")
  run_hook

  assert_deny_json
  assert_log_contains "ERROR: mock codex failure"
  run grep -F "missing error handling" "${REVIEW_LOG_DIR}/plan-review.log"
  [ "$status" -ne 0 ]
  run grep -F "Plan with an error handling gap to review." "${REVIEW_LOG_DIR}/plan-review.log"
  [ "$status" -ne 0 ]
}

# codex: 13. retry cycle (fail then succeed) → temp resources reclaimed, no leftover prompt content
@test "codex: retry cycle (fail then succeed) → no leftover temp file with prompt content" {
  export REVIEW_ENGINE="codex"
  # Ad-hoc flaky mock (create_flaky_engine's stdout-based contract doesn't
  # fit codex's -o-file contract): fails attempt 1 (reproducing the real
  # stderr shape), succeeds attempt 2 by writing to the -o file.
  local state_file="${TEST_TEMP_DIR}/.codex-flaky-state"
  local args_file="${MOCK_BIN}/../.agy-args-codex"
  cat > "${MOCK_BIN}/codex" << MOCK_EOF
#!/bin/bash
printf '%s\n' "\$*" > '${args_file}'
out_file=""
prev=""
for arg in "\$@"; do
  if [ "\$prev" = "-o" ]; then out_file="\$arg"; fi
  prev="\$arg"
done
if [ ! -f "${state_file}" ]; then
  touch "${state_file}"
  {
    echo "codex-cli 0.0.0-mock"
    echo "--------"
    echo "workdir: /tmp/mock"
    echo "model: mock-model"
    echo "provider: mock"
    echo "approval: never"
    echo "sandbox: read-only"
    echo "reasoning effort: mock"
    echo "reasoning summaries: mock"
    echo "session: mock-session"
    echo "--------"
    echo "user"
    cat
    echo ""
    echo "warning: mock warning line"
    echo "ERROR: mock codex failure"
  } >&2
  exit 1
fi
if [ -n "\$out_file" ]; then
  cat > "\$out_file" << 'OUTPUT_EOF'
<verdict>APPROVE</verdict>
Recovered on retry.
OUTPUT_EOF
fi
exit 0
MOCK_EOF
  chmod +x "${MOCK_BIN}/codex"

  INPUT=$(build_input plan="Unique-Marker-Plan-Content-For-Leak-Check")
  run_hook
  assert_ack_approve_json

  # ENGINE_OUT and CODEX_WORKDIR are created once, OUTSIDE the retry loop —
  # both attempts share them, so the (successful) second invocation's
  # captured args still name the paths used throughout the whole cycle.
  local args engine_out codex_workdir
  args=$(agy_args codex)
  engine_out=$(printf '%s' "$args" | awk '{for(i=1;i<=NF;i++) if($i=="-o"){print $(i+1); exit}}')
  codex_workdir=$(printf '%s' "$args" | awk '{for(i=1;i<=NF;i++) if($i=="-C"){print $(i+1); exit}}')
  [ -n "$engine_out" ]
  [ -n "$codex_workdir" ]
  [ ! -e "$engine_out" ]
  [ ! -e "${engine_out}.err" ]
  [ ! -d "$codex_workdir" ]

  # Best-effort sweep of the shared mktemp parent dir (where CODEX_PROMPT_FILE
  # — not derivable from captured args — also lived) for the plan's unique
  # marker, bounded to files touched during this test to avoid false hits
  # from unrelated concurrent temp files.
  local tmp_parent
  tmp_parent=$(dirname "$engine_out")
  if [ -d "$tmp_parent" ]; then
    run bash -c "find '$tmp_parent' -maxdepth 1 -type f -newer '$state_file' -exec grep -l 'Unique-Marker-Plan-Content-For-Leak-Check' {} + 2>/dev/null"
    [ -z "$output" ]
  fi
}

@test "codex: byte-truncated non-ASCII CLAUDE.md → prompt sanitized to valid UTF-8" {
  export REVIEW_ENGINE="codex"
  # Reproduce the real-world break: PROJECT_MD is read with `head -c 8000`,
  # a BYTE cut. A CLAUDE.md whose 8000th byte lands inside a multi-byte
  # character yields an orphaned lead byte in the merged prompt, and codex
  # hard-rejects such stdin ("input is not valid UTF-8") rather than degrading.
  # Without the iconv sanitation this test fails with engines-failed.
  local proj_dir="${TEST_TEMP_DIR}/proj"
  mkdir -p "$proj_dir"
  # 7999 ASCII bytes, then a 3-byte CJK char → head -c 8000 keeps only its
  # first byte (0xE4), producing an invalid sequence at the cut.
  {
    printf 'a%.0s' $(seq 1 7999)
    printf '中文内容\n'
  } > "${proj_dir}/CLAUDE.md"

  # Sanity-check the fixture itself: the truncated slice MUST be invalid UTF-8,
  # otherwise this test would pass vacuously.
  run bash -c "head -c 8000 '${proj_dir}/CLAUDE.md' | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1"
  [ "$status" -ne 0 ]

  MOCK_CODEX_STRICT_UTF8=1 create_mock_codex "<verdict>APPROVE</verdict>
Sanitized fine."
  export MOCK_CODEX_STRICT_UTF8=1

  INPUT=$(build_input cwd="$proj_dir" plan="Test plan content")
  run_hook

  # The mock rejects invalid stdin with exit 1 → hook would deny with
  # engines-failed. Reaching the APPROVE ack-deny proves sanitation happened.
  assert_ack_approve_json
  [[ "$HOOK_STDOUT" != *"engines-failed"* ]]
  [[ "$HOOK_STDERR" != *"not valid UTF-8"* ]]
}

# fixture: reset_leaky_env must clear every env var a developer shell might
# export. Regression guard — the codex vars were missed when the codex engine
# landed, and with CODEX_MODEL exported the "codex: CODEX_MODEL empty → no -m"
# case failed outright. Asserting `-z` on the vars as they stand after
# common_setup would prove nothing (a clean shell passes either way), so this
# pollutes first and calls reset_leaky_env directly.
@test "fixture: reset_leaky_env clears developer-shell env leakage" {
  export CODEX_BIN="/nonexistent/codex"
  export CODEX_MODEL="leaked-model"
  export MOCK_CODEX_STRICT_UTF8=1
  export MOCK_CODEX_NO_SECOND_DASHES=1
  export MOCK_CODEX_EXTRA_BLANK=1
  export REVIEW_API_URL="http://leaked.invalid"
  export REVIEW_API_KEY="leaked-key"
  export REVIEW_HOOK_BUDGET=1
  export REVIEW_ENGINE_DEGRADE_TTL=1
  export GEMINI_REVIEW_OFF=1
  export GEMINI_DRY_RUN=1
  export GEMINI_MAX_REVIEWS=1
  export PLAN_REVIEW_RUNNING=1

  reset_leaky_env

  [ -z "${CODEX_BIN:-}" ]
  [ -z "${CODEX_MODEL:-}" ]
  [ -z "${MOCK_CODEX_STRICT_UTF8:-}" ]
  [ -z "${MOCK_CODEX_NO_SECOND_DASHES:-}" ]
  [ -z "${MOCK_CODEX_EXTRA_BLANK:-}" ]
  [ -z "${REVIEW_API_URL:-}" ]
  [ -z "${REVIEW_API_KEY:-}" ]
  [ -z "${REVIEW_HOOK_BUDGET:-}" ]
  [ -z "${REVIEW_ENGINE_DEGRADE_TTL:-}" ]
  [ -z "${GEMINI_REVIEW_OFF:-}" ]
  [ -z "${GEMINI_DRY_RUN:-}" ]
  [ -z "${GEMINI_MAX_REVIEWS:-}" ]
  [ -z "${PLAN_REVIEW_RUNNING:-}" ]
}

# fixture: the call site, not just the helper. The case above stays green even
# if common_setup stops calling reset_leaky_env — it invokes the helper
# directly. This one pollutes, re-enters common_setup, and asserts the vars
# were cleared, so severing the call site turns it red.
#
# common_setup is not re-entrant for free: it runs `mktemp -d` and reassigns
# TEST_TEMP_DIR, orphaning the previous one (common_teardown only removes
# whatever TEST_TEMP_DIR points at last). The stale path is captured and
# removed explicitly rather than left in /tmp.
@test "fixture: common_setup calls reset_leaky_env" {
  export CODEX_MODEL="leaked-model"
  export CODEX_BIN="/nonexistent/codex"

  local stale_temp_dir="$TEST_TEMP_DIR"
  common_setup
  rm -rf "$stale_temp_dir"

  [ -z "${CODEX_MODEL:-}" ]
  [ -z "${CODEX_BIN:-}" ]
}
