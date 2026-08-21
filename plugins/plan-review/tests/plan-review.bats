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
  [[ "$reason" == *"框架许可的 plan 目录"* ]]
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



# 100. Capacity-fast-break plus REST success refreshes the degraded state.
@test "degrade: capacity-fast-break + REST success → degrade file refreshed" {
  create_capacity_exhausted_engine "agy"
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl_sse '<verdict>APPROVE</verdict>\nREST approved.'
  INPUT=$(build_input)

  run_hook
  assert_ack_approve_json
  assert_degraded_file_written
  local timestamp now age
  timestamp=$(cat "${REVIEW_COUNTER_DIR}/.gemini-degraded")
  now=$(date +%s)
  age=$(( now - timestamp ))
  (( age < 10 )) || { echo "degrade timestamp too old: age=${age}s"; return 1; }
  assert_log_contains "gemini-degrade-write"

  run_hook
  assert_approve_json
}

# =============================================================================
# Dispatch Manifest v2 — Layer 1 (plan-review.sh)
# =============================================================================

manifest_v2_plan() {
  local rows="$1"
  printf '%s\n' "## Plan
Use Task( for isolated work.

## Dispatch Manifest
| step | location | subagent_type | model_source | model | depends_on | parallel_with |
|------|----------|---------------|--------------|-------|------------|---------------|
${rows}"
}

@test "manifest v2: Main, preset, and runtime rows pass pre-flight" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Approved."
  local plan
  plan=$(manifest_v2_plan '| 1 | main  | -        | -       | -     | - | - |
| 2 | agent | dev-econ | preset  | -     | 1 | - |
| 3 | agent | Explore  | runtime | haiku | 1 | 2 |')
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_ack_approve_json
}

@test "manifest v2: Main-only rows deny when dispatch keywords are present" {
  local plan
  plan=$(manifest_v2_plan '| 1 | main | - | - | - | - | - |')
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"DISPATCH HOARDING"* ]]
  [[ "$reason" == *"必须同时移除 Manifest 与全部调度关键词"* ]]
  [[ "$reason" == *"显式声明至少一个 Agent step"* ]]
}

@test "manifest v2: preset-only row is structurally valid" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Approved."
  local plan
  plan=$(manifest_v2_plan '| 1 | agent | dev-econ | preset | - | - | - |')
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_ack_approve_json
}

@test "manifest v2: runtime-only row is structurally valid" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Approved."
  local plan
  plan=$(manifest_v2_plan '| 1 | agent | Explore | runtime | haiku | - | - |')
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_ack_approve_json
}

@test "manifest v2: Main row rejects subagent fields" {
  local plan
  plan=$(manifest_v2_plan '| 1 | main | dev-econ | - | - | - | - |')
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  [[ "$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" == *"INVALID DISPATCH MANIFEST"* ]]
}

@test "manifest v2: preset row requires type and forbids model" {
  local plan
  plan=$(manifest_v2_plan '| 1 | agent | - | preset | - | - | - |')
  INPUT=$(build_input "plan=$plan")
  run_hook
  assert_deny_json

  plan=$(manifest_v2_plan '| 1 | agent | dev-econ | preset | haiku | - | - |')
  INPUT=$(build_input "plan=$plan")
  run_hook
  assert_deny_json
}

@test "manifest v2: runtime row requires type and model" {
  local plan
  plan=$(manifest_v2_plan '| 1 | agent | Explore | runtime | - | - | - |')
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  [[ "$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" == *"INVALID DISPATCH MANIFEST"* ]]
}

@test "manifest v2: agent row rejects an unknown model_source" {
  local plan
  plan=$(manifest_v2_plan '| 1 | agent | Explore | inherited | - | - | - |')
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  [[ "$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" == *"INVALID DISPATCH MANIFEST"* ]]
}

@test "manifest v2: wrong or missing columns reject before review" {
  local plan='## Plan
Use Task( for isolation.

## Dispatch Manifest
| step | location | subagent_type | model_source | model | depends_on |
|------|----------|---------------|--------------|-------|------------|
| 1 | main | - | - | - | - |'
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  [[ "$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" == *"INVALID DISPATCH MANIFEST"* ]]
}

@test "manifest v2: APPROVE writes schema v2 signatures and dependency columns" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Approved."
  local plan
  plan=$(manifest_v2_plan '| 1 | main  | -        | -       | -     | - | - |
| 2 | agent | dev-econ | preset  | -     | 1 | - |
| 3 | agent | Explore  | runtime | haiku | 1 | 2 |')
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_ack_approve_json
  local dispatch_file="${REVIEW_COUNTER_DIR}/.dispatch-test-session.json"
  [ -f "$dispatch_file" ]
  jq -e '.schema_version == 2' "$dispatch_file" >/dev/null
  jq -e '.allowed_signatures == [{"subagent_type":"dev-econ","model_source":"preset"},{"subagent_type":"Explore","model_source":"runtime","model":"haiku"}]' "$dispatch_file" >/dev/null
  jq -e '.steps[2].depends_on == "1" and .steps[2].parallel_with == "2"' "$dispatch_file" >/dev/null
}



@test "manifest v2: quote and backslash cells serialize to valid JSON" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Approved."
  local plan
  plan=$(manifest_v2_plan '| 1 | agent | dev"econ\preset | preset | - | - | - |
| 2 | agent | Explore | runtime | haiku"tier\2 | - | - |')
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_ack_approve_json
  local dispatch_file="${REVIEW_COUNTER_DIR}/.dispatch-test-session.json"
  jq -e . "$dispatch_file" >/dev/null
  jq -e '.steps[0].subagent_type == "dev\"econ\\preset"' "$dispatch_file" >/dev/null
  jq -e '.steps[1].model == "haiku\"tier\\2"' "$dispatch_file" >/dev/null
}



@test "manifest v2: literal TAB in subagent_type rejects before state creation" {
  local tab=$'\t'
  local plan
  plan=$(manifest_v2_plan "| 1 | agent | Explore${tab}smuggled | runtime | haiku | - | - |")
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  [[ "$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" == *"tab or carriage-return"* ]]
  [ ! -e "${REVIEW_COUNTER_DIR}/.dispatch-test-session.json" ]
}

@test "manifest v2: literal TAB in model rejects before state creation" {
  local tab=$'\t'
  local plan
  plan=$(manifest_v2_plan "| 1 | agent | Explore | runtime | hai${tab}ku | - | - |")
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  [[ "$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" == *"tab or carriage-return"* ]]
  [ ! -e "${REVIEW_COUNTER_DIR}/.dispatch-test-session.json" ]
}


@test "manifest v2: literal carriage-return in dependency rejects before state creation" {
  local carriage_return=$'\r'
  local plan
  plan=$(manifest_v2_plan "| 1 | agent | Explore | runtime | haiku | dependency${carriage_return}tail | - |")
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  [[ "$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" == *"tab or carriage-return"* ]]
  [ ! -e "${REVIEW_COUNTER_DIR}/.dispatch-test-session.json" ]
}

@test "manifest v2: failed serializer leaves no temporary or destination state" {
  setup_script_copy
  local copied_manifest="${COPY_SCRIPT_DIR}/lib/manifest.sh"
  python3 - "$copied_manifest" <<'PYTHON'
from pathlib import Path
path = Path(__import__('sys').argv[1])
text = path.read_text()
needle = '  validate_manifest_v2 "$plan" || return 1\n'
assert text.count(needle) == 1
path.write_text(text.replace(needle, '  return 1\n', 1))
PYTHON

  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Approved."
  local plan
  plan=$(manifest_v2_plan '| 1 | agent | Explore | runtime | haiku | - | - |')
  INPUT=$(build_input "plan=$plan")
  run_hook_copy

  assert_ack_approve_json
  [ ! -e "${REVIEW_COUNTER_DIR}/.dispatch-test-session.json" ]
  ! find "$REVIEW_COUNTER_DIR" -maxdepth 1 -name '.dispatch-test-session.*' -print -quit | grep -q .
}

@test "mutation: shared blank-line boundary has one executable hit" {
  local plan
  plan=$(manifest_v2_plan '| 1 | main | - | - | - | - | - |

| 2 | agent | Explore | runtime | haiku | - | - |')

  run bash -c '. "$1"; manifest_has_agent_signature "$2"' bash "${BATS_TEST_DIRNAME}/../scripts/lib/manifest.sh" "$plan"
  [ "$status" -ne 0 ]

  setup_script_copy
  local copied_manifest="${COPY_SCRIPT_DIR}/lib/manifest.sh"
  python3 - "$copied_manifest" <<'PYTHON'
from pathlib import Path
path = Path(__import__('sys').argv[1])
text = path.read_text()
needle = '''if [ "$table_started" -eq 1 ] && [[ "$line" =~ ^[[:space:]]*$ ]]; then
      break
    fi'''
assert text.count(needle) == 1, text.count(needle)
path.write_text(text.replace(needle, '''if [ "$table_started" -eq 1 ] && [[ "$line" =~ ^[[:space:]]*$ ]]; then
      : # MUTATION
    fi''', 1))
PYTHON
  run grep -F ': # MUTATION' "$copied_manifest"
  [ "$status" -eq 0 ]

  # Red proof: without the shared boundary the later agent row satisfies the
  # exact signature expectation that the production implementation rejects.
  run bash -c '. "$1"; manifest_has_agent_signature "$2"' bash "$copied_manifest" "$plan"
  [ "$status" -eq 0 ]
}

@test "manifest v2: no manifest remains optional without dispatch keywords" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Approved."
  INPUT=$(build_input plan="Edit one file and run its test.")
  run_hook_to_completion

  assert_approve_json
  [ ! -f "${REVIEW_COUNTER_DIR}/.dispatch-test-session.json" ]
}

@test "dispatch cleanup: Tier0 approval removes stale global dispatch state" {
  local stale_dispatch="${REVIEW_COUNTER_DIR}/.dispatch-abandoned-session.json"
  printf '%s' '{}' > "$stale_dispatch"
  touch -t 200001010000 "$stale_dispatch"
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Approved."
  INPUT=$(build_input plan="Edit one file and run its test.")
  run_hook

  assert_ack_approve_json
  [ ! -e "$stale_dispatch" ]
}

@test "manifest v2: missing manifest still rejects dispatch keywords" {
  INPUT=$(build_input plan="Use Task( for isolation.")
  run_hook

  assert_deny_json
  [[ "$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" == *"MISSING DISPATCH MANIFEST"* ]]
}



# Pre-flight corrections consume only TOTAL_ROUNDS, never the non-Critical
# ATTEMPT budget. These are control-flow regressions independent of v1 schema.
@test "manifest v2: repeated pre-flight denies keep ATTEMPT at zero" {
  export REVIEW_MAX_ROUNDS=2
  INPUT=$(build_input plan="Use Task( for analysis.")

  run_hook; assert_deny_json; [ "$(get_counter_value)" -eq 0 ]; [ "$(get_total_rounds)" -eq 1 ]
  run_hook; assert_deny_json; [ "$(get_counter_value)" -eq 0 ]; [ "$(get_total_rounds)" -eq 2 ]
  run_hook; assert_deny_json; [ "$(get_counter_value)" -eq 0 ]; [ "$(get_total_rounds)" -eq 3 ]
}

@test "manifest v2: correcting pre-flight error starts engine from prior ATTEMPT" {
  INPUT=$(build_input plan="Use Task( for analysis.")
  run_hook
  assert_deny_json
  [ "$(get_counter_value)" -eq 0 ]
  [ "$(get_total_rounds)" -eq 1 ]

  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
Needs work."
  local plan
  plan=$(manifest_v2_plan '| 1 | agent | Explore | runtime | haiku | - | - |')
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  [ "$(get_counter_value)" -eq 1 ]
  [ "$(get_total_rounds)" -eq 2 ]
}

@test "manifest v2: repeated pre-flight denies reach the TOTAL hard stop" {
  export REVIEW_MAX_TOTAL_ROUNDS=3
  INPUT=$(build_input plan="Use Task( for analysis.")

  run_hook; assert_deny_json; [ "$(get_total_rounds)" -eq 1 ]
  run_hook; assert_deny_json; [ "$(get_total_rounds)" -eq 2 ]
  run_hook; assert_deny_json; [ "$(get_total_rounds)" -eq 3 ]
  run_hook
  assert_deny_json
  [[ "$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" == *"HARD STOP"* ]]
}

# Static contracts in the generic prompt must remain present even though the
# Manifest v2 criteria live in the plan-specific prompt.
@test "system-instructions: Version Identifiers Are Ground Truth remains explicit" {
  grep -q "GROUND TRUTH" "${SYSTEM_PROMPT_COMMON_FILE:?Missing system prompt asset}"
  grep -q "verify against your memory" "${SYSTEM_PROMPT_COMMON_FILE:?Missing system prompt asset}"
  grep -q "training knowledge has a cutoff" "${SYSTEM_PROMPT_COMMON_FILE:?Missing system prompt asset}"
  grep -q "NOT common knowledge" "${SYSTEM_PROMPT_COMMON_FILE:?Missing system prompt asset}"
  grep -q "never Critical" "${SYSTEM_PROMPT_COMMON_FILE:?Missing system prompt asset}"
}

@test "system-instructions: Finding Quality Gate contract remains complete" {
  grep -q "Finding Quality Gate" "${SYSTEM_PROMPT_COMMON_FILE:?Missing system prompt asset}"
  grep -q "Confidence" "${SYSTEM_PROMPT_COMMON_FILE:?Missing system prompt asset}"
  grep -q "DROP" "${SYSTEM_PROMPT_COMMON_FILE:?Missing system prompt asset}"
  grep -q "UNVERIFIED" "${SYSTEM_PROMPT_COMMON_FILE:?Missing system prompt asset}"
  grep -q "not REJECT" "${SYSTEM_PROMPT_COMMON_FILE:?Missing system prompt asset}"
  grep -q "False-positive registry" "${SYSTEM_PROMPT_COMMON_FILE:?Missing system prompt asset}"
  grep -qi "never raise" "${SYSTEM_PROMPT_COMMON_FILE:?Missing system prompt asset}"
  grep -q "Verdict↔severity" "${SYSTEM_PROMPT_COMMON_FILE:?Missing system prompt asset}"
  grep -q "Severity calibration" "${SYSTEM_PROMPT_COMMON_FILE:?Missing system prompt asset}"
  grep -q "never Major" "${SYSTEM_PROMPT_COMMON_FILE:?Missing system prompt asset}"
  grep -q 'UNVERIFIED.*suspicion.*but no confirmed Critical\|including any .UNVERIFIED' "${SYSTEM_PROMPT_COMMON_FILE:?Missing system prompt asset}"
  grep -q '\[Major\] \[UNVERIFIED\]' "${SYSTEM_PROMPT_COMMON_FILE:?Missing system prompt asset}"
  ! grep -qE "grep[^|]*'\[Critical\]'" "${HOOK_SCRIPT:?Missing hook script}"
}

# =============================================================================
# Dispatch Economy — Criterion 7 regression
# =============================================================================

@test "dispatch-economy: bash -n reports no syntax errors" {
  while IFS= read -r -d '' f; do
    run bash -n "$f"
    [ "$status" -eq 0 ] || { echo "syntax error in $f: $output"; return 1; }
  done < <(find "${BATS_TEST_DIRNAME}/../scripts" -name '*.sh' -print0)
}

@test "dispatch-economy: Criterion 7 states ownership and source rules" {
  grep -q "Decision and review judgment" "${SYSTEM_PROMPT_PLAN_FILE:?Missing system prompt asset}"
  grep -q "registered agent" "${SYSTEM_PROMPT_PLAN_FILE:?Missing system prompt asset}"
  grep -q "dev-econ" "${SYSTEM_PROMPT_PLAN_FILE:?Missing system prompt asset}"
  grep -q "worker-econ" "${SYSTEM_PROMPT_PLAN_FILE:?Missing system prompt asset}"
  grep -qF "full hoarding [Critical]" "${SYSTEM_PROMPT_PLAN_FILE:?Missing system prompt asset}"
  grep -qF "partial hoarding [Major]" "${SYSTEM_PROMPT_PLAN_FILE:?Missing system prompt asset}"
  ! grep -q "Implementation work.*sonnet" "${SYSTEM_PROMPT_PLAN_FILE:?Missing system prompt asset}"
}



# Manifest parser boundaries: blanks before the table are tolerated; a blank
# after it and a following section are both hard boundaries.
@test "manifest v2 parser: one blank line before table is tolerated" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Approved."
  local plan="## Plan
Use Task( for isolation.

## Dispatch Manifest

| step | location | subagent_type | model_source | model | depends_on | parallel_with |
|------|----------|---------------|--------------|-------|------------|---------------|
| 1 | agent | Explore | runtime | haiku | - | - |"
  INPUT=$(build_input "plan=$plan")
  run_hook
  assert_ack_approve_json
}

@test "manifest v2 parser: multiple blank lines before an Agent table are tolerated" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Approved."
  local plan="## Plan
Use Task( for isolated work.

## Dispatch Manifest


| step | location | subagent_type | model_source | model | depends_on | parallel_with |
|------|----------|---------------|--------------|-------|------------|---------------|
| 1 | agent | Explore | runtime | haiku | - | - |"
  INPUT=$(build_input "plan=$plan")
  run_hook
  assert_ack_approve_json
}

@test "manifest v2 parser: blank line after table terminates parsing" {
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Approved."
  local plan="## Plan
Use Task( for isolation.

## Dispatch Manifest
| step | location | subagent_type | model_source | model | depends_on | parallel_with |
|------|----------|---------------|--------------|-------|------------|---------------|
| 1 | agent | Explore | runtime | haiku | - | - |

| this trailing table is not manifest content |"
  INPUT=$(build_input "plan=$plan")
  run_hook
  assert_ack_approve_json
}

@test "manifest v2 parser: blank line blocks a later seven-column agent signature" {
  local plan="## Plan
Use Task( for isolation.

## Dispatch Manifest
| step | location | subagent_type | model_source | model | depends_on | parallel_with |
|------|----------|---------------|--------------|-------|------------|---------------|
| 1 | main | - | - | - | - | - |

| 2 | agent | Explore | runtime | haiku | - | - |"
  run bash -c '. "$1"; manifest_has_agent_signature "$2"' bash "${BATS_TEST_DIRNAME}/../scripts/lib/manifest.sh" "$plan"
  [ "$status" -ne 0 ]
  run bash -c '. "$1"; parse_manifest_to_json "$2" test-hash' bash "${BATS_TEST_DIRNAME}/../scripts/lib/manifest.sh" "$plan"
  [ "$status" -eq 0 ]
  [[ "$(jq -c '.allowed_signatures' <<<"$output")" == '[]' ]]
  [[ "$(jq -c '.steps' <<<"$output")" == '[{"id":"1","location":"main","subagent_type":null,"model_source":null,"model":null,"depends_on":null,"parallel_with":null}]' ]]

  INPUT=$(build_input "plan=$plan")
  run_hook
  assert_deny_json
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$HOOK_STDOUT")" == *"DISPATCH HOARDING"* ]]
  [ ! -e "${REVIEW_COUNTER_DIR}/.dispatch-test-session.json" ]
}

@test "manifest v2 parser: blank line blocks a later TAB-based agent signature" {
  local tab=$'\t'
  local plan="## Plan
Use Task( for isolation.

## Dispatch Manifest
| step | location | subagent_type | model_source | model | depends_on | parallel_with |
|------|----------|---------------|--------------|-------|------------|---------------|
| 1 | main | - | - | - | - | - |

| 2 | agent | Explore${tab}smuggled | runtime | haiku | - | - |"
  run bash -c '. "$1"; manifest_has_agent_signature "$2"' bash "${BATS_TEST_DIRNAME}/../scripts/lib/manifest.sh" "$plan"
  [ "$status" -ne 0 ]
  run bash -c '. "$1"; parse_manifest_to_json "$2" test-hash' bash "${BATS_TEST_DIRNAME}/../scripts/lib/manifest.sh" "$plan"
  [ "$status" -eq 0 ]
  [[ "$(jq -c '.allowed_signatures' <<<"$output")" == '[]' ]]

  INPUT=$(build_input "plan=$plan")
  run_hook
  assert_deny_json
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$HOOK_STDOUT")" == *"DISPATCH HOARDING"* ]]
  [ ! -e "${REVIEW_COUNTER_DIR}/.dispatch-test-session.json" ]
}

@test "manifest v2 parser: terminal CRLF suffix is normalized before table semantics" {
  local cr=$'\r'
  local plan="## Plan
Use Task( for isolation.

## Dispatch Manifest
| step | location | subagent_type | model_source | model | depends_on | parallel_with |${cr}
|------|----------|---------------|--------------|-------|------------|---------------|${cr}
| 1 | agent | Explore | runtime | haiku | - | - |${cr}"
  run bash -c '. "$1"; parse_manifest_to_json "$2" test-hash' bash "${BATS_TEST_DIRNAME}/../scripts/lib/manifest.sh" "$plan"
  [ "$status" -eq 0 ]
  [[ "$(jq -c '.allowed_signatures' <<<"$output")" == '[{"subagent_type":"Explore","model_source":"runtime","model":"haiku"}]' ]]
}

@test "manifest v2 parser: Markdown alignment separator variants validate" {
  local plan="## Plan
Use Task( for isolation.

## Dispatch Manifest
| step | location | subagent_type | model_source | model | depends_on | parallel_with |
| :--- | :---: | ---: | :--- | :---: | ---: | :--- |
| 1 | agent | Explore | runtime | haiku | - | - |"
  run bash -c '. "$1"; validate_manifest_v2 "$2" && manifest_has_agent_signature "$2" && parse_manifest_to_json "$2" test-hash' bash "${BATS_TEST_DIRNAME}/../scripts/lib/manifest.sh" "$plan"

  [ "$status" -eq 0 ]
  [[ "$(jq -c '.allowed_signatures' <<<"$output")" == '[{"subagent_type":"Explore","model_source":"runtime","model":"haiku"}]' ]]
}

@test "manifest v2 parser: malformed later separator cell rejects" {
  local plan="## Plan
Use Task( for isolation.

## Dispatch Manifest
| step | location | subagent_type | model_source | model | depends_on | parallel_with |
|------|garbage|---------------|--------------|-------|------------|---------------|
| 1 | agent | Explore | runtime | haiku | - | - |"
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$HOOK_STDOUT")" == *"table separator must have seven Markdown separator cells"* ]]
}

@test "manifest v2 parser: over-64KB valid plan validates, detects signature, and serializes" {
  local padding padding_lines padding_bytes
  padding=$(awk 'BEGIN { for (i = 1; i <= 3000; i++) printf "padding-%04d-abcdefghijklmnopqrstuvwxyz-0123456789-ordinary-ascii-line\n", i }')
  padding_lines=$(printf '%s\n' "$padding" | wc -l | tr -d ' ')
  padding_bytes=$(printf '%s' "$padding" | wc -c | tr -d ' ')
  [ "$padding_lines" -ge 2000 ] || { echo "large plan padding has only $padding_lines lines"; return 1; }
  [ "$padding_bytes" -gt 65536 ] || { echo "large plan padding has only $padding_bytes bytes"; return 1; }

  local plan manifest_script
  manifest_script="${BATS_TEST_DIRNAME}/../scripts/lib/manifest.sh"
  plan="## Plan
Use Task( for isolation.

## Dispatch Manifest
| step | location | subagent_type | model_source | model | depends_on | parallel_with |
|------|----------|---------------|--------------|-------|------------|---------------|
| 1 | agent | Explore | runtime | haiku | - | - |

## Detail
${padding}"

  run bash -c '. "$1"; validate_manifest_v2 "$2"' bash "$manifest_script" "$plan"
  [ "$status" -eq 0 ]

  run bash -c '. "$1"; manifest_has_agent_signature "$2"' bash "$manifest_script" "$plan"
  [ "$status" -eq 0 ]

  run bash -c '. "$1"; parse_manifest_to_json "$2" test-hash' bash "$manifest_script" "$plan"
  [ "$status" -eq 0 ]
  [[ "$(jq -c '.allowed_signatures' <<<"$output")" == '[{"subagent_type":"Explore","model_source":"runtime","model":"haiku"}]' ]]
}

@test "manifest v2 parser: next section table does not satisfy missing manifest table" {
  local plan="## Plan
Use Task( for isolation.

## Dispatch Manifest

## Other Section
| step | location | subagent_type | model_source | model | depends_on | parallel_with |
|------|----------|---------------|--------------|-------|------------|---------------|
| 1 | agent | Explore | runtime | haiku | - | - |"
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  [[ "$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" == *"INVALID DISPATCH MANIFEST"* ]]
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
  [[ "$prompt" == *"Artifact to Review"* ]]
}

# assembly: SYSTEM_INSTRUCTIONS internal ordering — review-plan.md's framing
# layer must lead, review-common.md's shared discipline/format layer must
# trail. Grepping for substring presence alone (as the other system-
# instructions / quality-gate tests do) cannot catch an assembly-order
# regression where plan-review.sh:493 accidentally swapped the two
# `tr -d '\r' < ...` operands — both substrings would still be present, just
# in the wrong order. This test captures the agy FIRST-round -p argument
# (round 1 always sends the full AGY_PROMPT = SYSTEM_INSTRUCTIONS + '\n\n' +
# PROMPT_FILE — see agy.sh's engine_invoke, CONV_ID empty branch), which is
# the one point where the raw assembled SYSTEM_INSTRUCTIONS bytes are
# observable end-to-end. Byte-position comparison (not a golden file) so the
# test survives unrelated wording edits to either asset.
@test "assembly: SYSTEM_INSTRUCTIONS orders review-plan.md ahead of review-common.md" {
  cat > "${MOCK_BIN}/agy" <<'MOCK_INNER'
#!/bin/bash
prev=""
for a in "$@"; do
  if [ "$prev" = "-p" ]; then printf '%s' "$a" > "$(dirname "$0")/../.agy-prompt-agy"; fi
  prev="$a"
done
printf '%s\n' "$*" > "$(dirname "$0")/../.agy-args-agy"
printf '{"conversation_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","response":"<verdict>APPROVE</verdict>","usage":{}}\n'
MOCK_INNER
  chmod +x "${MOCK_BIN}/agy"
  INPUT=$(build_input)
  run_hook   # round 1 — first round, sends the full static+dynamic prompt
  assert_ack_approve_json

  local prompt_file="${MOCK_BIN}/../.agy-prompt-agy"
  [ -s "$prompt_file" ]

  local pos_criteria pos_ground_truth pos_scope pos_gate
  pos_criteria=$(grep -boF 'Review Criteria' "$prompt_file" | head -1 | cut -d: -f1)
  pos_ground_truth=$(grep -boF 'Version Identifiers Are Ground Truth' "$prompt_file" | head -1 | cut -d: -f1)
  pos_scope=$(grep -boF '## Scope Boundary' "$prompt_file" | head -1 | cut -d: -f1)
  pos_gate=$(grep -boF '## Finding Quality Gate' "$prompt_file" | head -1 | cut -d: -f1)

  [ -n "$pos_criteria" ]
  [ -n "$pos_ground_truth" ]
  [ -n "$pos_scope" ]
  [ -n "$pos_gate" ]

  [ "$pos_criteria" -lt "$pos_ground_truth" ]
  [ "$pos_scope" -lt "$pos_gate" ]
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
  # Reproduce the real-world break: PROJECT_MD is read via clamp_head_bytes
  # 24000 (lib/common.sh), which itself only guarantees clean UTF-8 when a
  # complete line exists before the cut (see that function's branch 2/3
  # split). This fixture has NO newline anywhere in its first 24000 bytes —
  # one long ASCII run — so clamp_head_bytes falls through to its branch-3
  # raw fallback (`head -c 24000`) and the cut still lands mid-character,
  # exactly like the pre-clamp `head -c` bug this test was written against.
  # codex hard-rejects such stdin ("input is not valid UTF-8") rather than
  # degrading. Without codex.sh's own iconv sanitation this test fails with
  # engines-failed — that is what this test actually verifies now that the
  # clamp handles the common (has-a-newline) case at the source.
  local proj_dir="${TEST_TEMP_DIR}/proj"
  mkdir -p "$proj_dir"
  # 23999 ASCII bytes (no newline among them), then a 3-byte CJK char →
  # head -c 24000 keeps only its first byte (0xE4), producing an invalid
  # sequence at the cut.
  {
    printf 'a%.0s' $(seq 1 23999)
    printf '中文内容\n'
  } > "${proj_dir}/CLAUDE.md"

  # Sanity-check the fixture itself: the truncated slice MUST be invalid UTF-8,
  # otherwise this test would pass vacuously.
  run bash -c "head -c 24000 '${proj_dir}/CLAUDE.md' | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1"
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

# codex: 14. capacity exhausted + REST configured → fast break, same as agy/claude
# (Issue #144 fix): codex's stderr never reached LOG_FILE wholesale (privacy
# filter), so the old "grep LOG_FILE for RESOURCE_EXHAUSTED" capacity check only
# caught codex by coincidence — whatever the 500-byte filtered codex-diag
# excerpt happened to retain. Capacity detection now scans the raw $ENGINE_ERR
# directly (see plan-review.sh), so codex behaves identically to agy/claude
# regardless of what the privacy filter keeps or drops.
# NOTE: this mock's capacity text is short enough to also survive inside the
# filtered codex-diag excerpt — it exercises the "lucky" case (raw $ENGINE_ERR
# and filtered LOG_FILE agree). See the "buried" test below for the case that
# actually distinguishes the two.
@test "codex: capacity exhausted + REST configured → fast break + REST used" {
  export REVIEW_ENGINE="codex"
  create_capacity_exhausted_codex
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl_sse '<verdict>APPROVE</verdict>\nApproved via REST.'
  INPUT=$(build_input)

  run_hook
  assert_ack_approve_json
  [[ "$HOOK_STDERR" == *"skipping retry (REST fallback available)"* ]]
  [[ "$HOOK_STDERR" == *"REST API fallback succeeded"* ]]
  assert_log_contains "rest-skip=capacity-fast-break engine=codex"
}

# codex: 15. capacity exhausted (buried past the 500-byte privacy-filter
# window) + REST configured → fast break still fires. Unlike test 14, the
# capacity text here is truncated away by engine_err_filter()'s `head -c 500`
# before it reaches LOG_FILE's codex-diag line — so this only passes if
# capacity detection scans the RAW $ENGINE_ERR directly (the Issue #144 fix).
# A pre-fix "grep LOG_FILE for RESOURCE_EXHAUSTED" check would find nothing
# and fall through to the ordinary retry path instead of fast-breaking.
@test "codex: capacity exhausted buried past privacy-filter window → fast break + REST used" {
  export REVIEW_ENGINE="codex"
  create_capacity_exhausted_codex_buried
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl_sse '<verdict>APPROVE</verdict>\nApproved via REST.'
  INPUT=$(build_input)

  run_hook
  assert_ack_approve_json
  [[ "$HOOK_STDERR" == *"skipping retry (REST fallback available)"* ]]
  [[ "$HOOK_STDERR" == *"REST API fallback succeeded"* ]]
  assert_log_contains "rest-skip=capacity-fast-break engine=codex"
  # Prove the buried capacity text really did NOT survive the privacy filter:
  # codex-diag's logged excerpt must not contain the capacity marker. This
  # assertion is only meaningful if the codex-diag line was actually written
  # — without the `-n` check, a regressed backfill (or a broken filter that
  # emits nothing) would leave $output empty and the `!= *"..."*` assertion
  # would pass vacuously, "proving" nothing.
  run grep -F "codex-diag" "${REVIEW_LOG_DIR}/plan-review.log"
  [ -n "$output" ]
  [[ "$output" != *"RESOURCE_EXHAUSTED"* ]]
}

# --- Fix (PR #146 review, Major): hook killed mid-invoke must not lose
# this round's stderr. Pre-fix, _cleanup() only did `rm -f "$ENGINE_ERR"` on
# every exit path (normal or signal) — a hook-timeout SIGTERM landing while
# an engine call is in flight discarded that round's raw stderr entirely,
# with zero trace ever reaching LOG_FILE. That is exactly the diagnostic a
# maintainer needs most (the round that got killed, not the one that
# finished). Runs the real hook script as a background process, waits for
# the mock engine to actually start (ready-file handshake — no fixed sleep
# guessing), sends SIGTERM to the hook itself (mirroring the framework's
# 600s hook-timeout kill), and asserts _cleanup's defensive
# `backfill_engine_err 143` call landed this round's stderr into LOG_FILE
# before reaping the temp files.
@test "cleanup: hook killed mid-invoke → this round's stderr still reaches LOG_FILE" {
  local ready_file="${TEST_TEMP_DIR}/mock-agy-ready"
  rm -f "$ready_file"
  # Deliberately NOT the shared create_mock_engine helper: this mock must
  # touch a ready-file and then block (sleep), which no existing generator
  # supports. Unquoted heredoc so ${ready_file} interpolates at creation time.
  cat > "${MOCK_BIN}/agy" << MOCK_EOF
#!/bin/bash
touch '${ready_file}'
echo "MIDKILL-STDERR-MARKER: engine was killed mid-flight" >&2
sleep 30
MOCK_EOF
  chmod +x "${MOCK_BIN}/agy"

  INPUT=$(build_input)
  local out_file="${TEST_TEMP_DIR}/midkill.stdout"
  local err_file="${TEST_TEMP_DIR}/midkill.stderr"

  bash "$HOOK_SCRIPT" <<< "$INPUT" > "$out_file" 2> "$err_file" &
  local hook_pid=$!

  # Handshake: block until the mock has actually started (touched
  # ready_file) instead of guessing a fixed startup delay — avoids a flake
  # where SIGTERM arrives before engine_invoke even begins.
  local waited=0
  while [ ! -f "$ready_file" ] && [ "$waited" -lt 100 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  [ -f "$ready_file" ]

  # The mock writes its stderr line immediately after touching ready_file,
  # before its `sleep 30` — a small margin covers the write actually landing
  # on disk (OS-buffered fd write, not an async race with the ready-file
  # signal itself).
  sleep 0.2

  kill -TERM "$hook_pid" 2>/dev/null || true

  # Wait for the hook process (and its trap-driven _cleanup) to actually
  # exit, bounded so a stuck run fails fast instead of hanging the suite.
  waited=0
  while kill -0 "$hook_pid" 2>/dev/null && [ "$waited" -lt 100 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  if kill -0 "$hook_pid" 2>/dev/null; then
    kill -KILL "$hook_pid" 2>/dev/null || true
  fi
  wait "$hook_pid" 2>/dev/null || true

  assert_log_contains "MIDKILL-STDERR-MARKER: engine was killed mid-flight"
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
  export AGY_MODEL="leaked-agy-model"
  export CLAUDE_MODEL="leaked-claude-model"
  export GEMINI_MODEL="leaked-gemini-model"

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
  [ -z "${AGY_MODEL:-}" ]
  [ -z "${CLAUDE_MODEL:-}" ]
  [ -z "${GEMINI_MODEL:-}" ]
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

# =============================================================================
# Bootstrap fail-open coverage (PR #145 review fixes)
#
# These exercise plan-review.sh's own bootstrap guards — lib-file existence
# AND non-emptiness (single `-s` test), lib-file sourceability, and
# prompt-asset presence/content — which resolve paths relative to the
# script's own location (SCRIPT_DIR via BASH_SOURCE) and are therefore NOT
# reachable by env-var overrides. `setup_script_copy` / `run_hook_copy`
# (test_helper/common-setup.bash) copy the whole scripts/ tree into an
# isolated TEST_TEMP_DIR so these files can be deleted/corrupted without
# ever touching the real repo tree; common_teardown's `rm -rf
# "$TEST_TEMP_DIR"` cleans the copy up automatically.
#
# Every test in this block sets REVIEW_DRY_RUN=1 as a safety belt (see the
# comment above the first test for why) and asserts with assert_approve_json
# rather than the weaker assert_allowed, so a regression that lets execution
# fall through past the bootstrap guard is caught by a hookEventName/
# permissionDecision mismatch instead of silently invoking a real engine CLI.
# =============================================================================

# bootstrap: missing lib/*.sh file → allow + [WARNING], never a silent hang
# or fail-closed deny.
#
# REVIEW_DRY_RUN=1 is a safety belt, not the mechanism under test: the
# bootstrap guard below fires and exits long before the script would ever
# reach the engine-invocation section, so dry-run has no way to influence
# this test's actual assertions. It exists purely so that if the guard ever
# regresses (stops firing), this test fails on a wrong JSON/exit-code
# assertion instead of silently placing a real call to agy/claude/codex.
@test "bootstrap: missing lib file → allow JSON with WARNING" {
  export REVIEW_DRY_RUN=1
  setup_script_copy
  rm -f "${COPY_SCRIPT_DIR}/lib/manifest.sh"

  run_hook_copy

  assert_approve_json
  [[ "$HOOK_STDOUT" == *"[WARNING]"* ]]
  [[ "$HOOK_STDOUT" == *"lib file missing"* ]]
}

# bootstrap: a lib file EXISTS and is non-empty (passes `[ -s ]`) but has a
# real bash syntax error — `source` itself fails even though the
# existence/non-emptiness check does not. This is the gap Fix 2 (of the PR
# #145 first round) closes: previously the script would abort mid-parse
# with no allow JSON emitted at all (silent hook failure).
# See REVIEW_DRY_RUN note above the previous test — same rationale applies.
@test "bootstrap: syntax-broken lib file → allow JSON with WARNING (source fails, not missing)" {
  export REVIEW_DRY_RUN=1
  setup_script_copy
  # Unbalanced quote + stray paren: guaranteed bash syntax error, file still
  # exists and is readable.
  printf '%s\n' 'this is " not valid bash (' >> "${COPY_SCRIPT_DIR}/lib/manifest.sh"

  run_hook_copy

  assert_approve_json
  [[ "$HOOK_STDOUT" == *"[WARNING]"* ]]
  [[ "$HOOK_STDOUT" == *"failed to load"* ]]
}

# bootstrap: lib file exists but is empty (zero bytes) — passes the old
# `[ -f ]` existence check clean, `source` of an empty file "succeeds"
# (exit 0, sourcing zero bytes is valid bash), and the very next call to a
# helper defined in it dies with "command not found" (exit 127), no allow
# JSON ever printed — a silent fail-closed, the opposite of this script's
# contract. This is the gap the second-round PR #145 review found and
# `[ ! -s ]` (existence AND non-emptiness in one test) closes.
# See REVIEW_DRY_RUN note above the first bootstrap test — same rationale.
@test "bootstrap: empty lib file → allow JSON with WARNING" {
  export REVIEW_DRY_RUN=1
  setup_script_copy
  : > "${COPY_SCRIPT_DIR}/lib/manifest.sh"

  run_hook_copy

  assert_approve_json
  [[ "$HOOK_STDOUT" == *"[WARNING]"* ]]
  [[ "$HOOK_STDOUT" == *"lib file missing"* ]]
}

# bootstrap: prompt asset file missing entirely → allow + [WARNING].
# The prompt asset guard (plan-review.sh:476-482) loops over BOTH
# review-plan.md and review-common.md, so each half needs its own coverage —
# a regression that only checks one file would otherwise slip past.
# See REVIEW_DRY_RUN note above the first bootstrap test — same rationale.
@test "bootstrap: missing prompt asset (review-plan.md) → allow JSON with WARNING" {
  export REVIEW_DRY_RUN=1
  setup_script_copy
  rm -f "${COPY_SCRIPT_DIR}/assets/review-plan.md"

  run_hook_copy

  assert_approve_json
  [[ "$HOOK_STDOUT" == *"[WARNING]"* ]]
  [[ "$HOOK_STDOUT" == *"prompt asset missing/empty"* ]]
}

@test "bootstrap: missing prompt asset (review-common.md) → allow JSON with WARNING" {
  export REVIEW_DRY_RUN=1
  setup_script_copy
  rm -f "${COPY_SCRIPT_DIR}/assets/review-common.md"

  run_hook_copy

  assert_approve_json
  [[ "$HOOK_STDOUT" == *"[WARNING]"* ]]
  [[ "$HOOK_STDOUT" == *"prompt asset missing/empty"* ]]
}

# bootstrap: prompt asset present but zero bytes → allow + [WARNING].
# Same per-file split rationale as the missing-asset pair above.
# See REVIEW_DRY_RUN note above the first bootstrap test — same rationale.
@test "bootstrap: empty prompt asset (review-plan.md) → allow JSON with WARNING" {
  export REVIEW_DRY_RUN=1
  setup_script_copy
  : > "${COPY_SCRIPT_DIR}/assets/review-plan.md"

  run_hook_copy

  assert_approve_json
  [[ "$HOOK_STDOUT" == *"[WARNING]"* ]]
  [[ "$HOOK_STDOUT" == *"prompt asset missing/empty"* ]]
}

@test "bootstrap: empty prompt asset (review-common.md) → allow JSON with WARNING" {
  export REVIEW_DRY_RUN=1
  setup_script_copy
  : > "${COPY_SCRIPT_DIR}/assets/review-common.md"

  run_hook_copy

  assert_approve_json
  [[ "$HOOK_STDOUT" == *"[WARNING]"* ]]
  [[ "$HOOK_STDOUT" == *"prompt asset missing/empty"* ]]
}

# bootstrap: prompt asset truncated to a single whitespace byte — passes the
# `-s` (non-empty) check but has no real reviewing instructions. This is
# exactly the gap Fix 5's <verdict> anchor check closes: without it, a
# truncated-to-whitespace asset would silently proceed to review with an
# empty instruction set instead of failing open visibly.
# Post-split, the <verdict> anchor literal lives in review-common.md (see
# assets/review-common.md's Output Format section), so truncating THAT file
# is what must trip the anchor check — truncating review-plan.md alone
# leaves review-common.md's `<verdict>` tag intact in the concatenated
# SYSTEM_INSTRUCTIONS, so the anchor check must NOT fire in that case
# (verified manually: truncating review-plan.md alone still produces a
# normal dry-run APPROVE flow, not a truncated-asset WARNING).
# See REVIEW_DRY_RUN note above the first bootstrap test — same rationale.
@test "bootstrap: prompt asset truncated to whitespace-only (review-common.md) → allow JSON with WARNING (anchor check)" {
  export REVIEW_DRY_RUN=1
  setup_script_copy
  printf ' ' > "${COPY_SCRIPT_DIR}/assets/review-common.md"

  run_hook_copy

  assert_approve_json
  [[ "$HOOK_STDOUT" == *"[WARNING]"* ]]
  [[ "$HOOK_STDOUT" == *"prompt asset truncated"* ]]
}

# --- Engine-lib bootstrap (second bootstrap block: lib/engines/*.sh) ---
#
# The first bootstrap block above (lib/common.sh, lib/plan-source.sh,
# lib/manifest.sh, lib/verdict.sh) went through the `[ -s ]` + `_source_lib`
# hardening in PR #145. The engine libs (lib/engines/rest.sh + the
# REVIEW_ENGINE-selected lib, e.g. agy.sh) are sourced in a SECOND, separate
# bootstrap block further down in the script and had NOT been hardened the
# same way — REVIEW_ENGINE is unset in these tests, which the case statement
# resolves to the `*` fallback (agy.sh), so these tests corrupt
# lib/engines/agy.sh to hit that path.
#
# Same REVIEW_DRY_RUN=1 safety-belt rationale as the first bootstrap block:
# this guard fires and exits before the script ever reaches the
# engine-invocation section, so dry-run cannot influence these assertions —
# it only prevents a real engine CLI call if the guard ever regresses.

# bootstrap: engine lib file exists but is empty (zero bytes) — passes the
# old `[ -f ]` existence check clean, `source` of an empty file "succeeds"
# (sourcing zero bytes is valid bash, exit 0), and the very next call to a
# helper the lib was supposed to define (e.g. engine_probe) dies with
# "command not found" (exit 127), no allow JSON ever printed — silent
# fail-closed. This is the same gap class PR #145 closed for the first
# bootstrap block; this test proves the second block (engine libs) is
# hardened identically.
@test "bootstrap: empty engine lib file → allow JSON with WARNING" {
  export REVIEW_DRY_RUN=1
  setup_script_copy
  : > "${COPY_SCRIPT_DIR}/lib/engines/agy.sh"

  run_hook_copy

  assert_approve_json
  [[ "$HOOK_STDOUT" == *"[WARNING]"* ]]
  [[ "$HOOK_STDOUT" == *"lib file missing"* ]]
}

# bootstrap: engine lib file EXISTS and is non-empty (passes `[ -s ]`) but has
# a real bash syntax error — `source` itself fails even though the
# existence/non-emptiness check does not. Proves the engine-lib bootstrap
# block routes through `_source_lib` (fail-open on source failure) instead of
# a bare `source "$LIB_ENGINE_SELECTED"` that would let `set -e` kill the
# script with no allow JSON ever emitted.
@test "bootstrap: syntax-broken engine lib file → allow JSON with WARNING (source fails, not missing)" {
  export REVIEW_DRY_RUN=1
  setup_script_copy
  # Unbalanced quote + stray paren: guaranteed bash syntax error, file still
  # exists and is readable.
  printf '%s\n' 'this is " not valid bash (' >> "${COPY_SCRIPT_DIR}/lib/engines/agy.sh"

  run_hook_copy

  assert_approve_json
  [[ "$HOOK_STDOUT" == *"[WARNING]"* ]]
  [[ "$HOOK_STDOUT" == *"failed to load"* ]]
}

# bootstrap: engine lib file missing entirely → allow + [WARNING]. The first
# bootstrap block's missing-lib test (above) only exercises
# lib/manifest.sh, which lives in the FIRST loop — it never proves the
# SECOND loop (lib/engines/rest.sh + the selected engine lib) still guards
# non-existence too, so this is not redundant with it.
@test "bootstrap: missing engine lib file → allow JSON with WARNING" {
  export REVIEW_DRY_RUN=1
  setup_script_copy
  rm -f "${COPY_SCRIPT_DIR}/lib/engines/agy.sh"

  run_hook_copy

  assert_approve_json
  [[ "$HOOK_STDOUT" == *"[WARNING]"* ]]
  [[ "$HOOK_STDOUT" == *"lib file missing"* ]]
}

# bootstrap: rest.sh (the OTHER lib in the engine-lib loop, sourced
# unconditionally regardless of REVIEW_ENGINE) empty → allow + [WARNING].
# Covers the loop iterating over $LIB_REST specifically, not just the
# REVIEW_ENGINE-selected lib.
@test "bootstrap: empty rest.sh lib file → allow JSON with WARNING" {
  export REVIEW_DRY_RUN=1
  setup_script_copy
  : > "${COPY_SCRIPT_DIR}/lib/engines/rest.sh"

  run_hook_copy

  assert_approve_json
  [[ "$HOOK_STDOUT" == *"[WARNING]"* ]]
  [[ "$HOOK_STDOUT" == *"lib file missing"* ]]
}

# bootstrap: lib/consult.sh (the third member of the second bootstrap block's
# loop, alongside rest.sh + the REVIEW_ENGINE-selected engine lib — see
# plan-review.sh:193's `for _lib in "$LIB_REST" "$LIB_ENGINE_SELECTED"
# "$LIB_CONSULT"` and its `_source_lib` call at :212) missing entirely →
# allow + [WARNING]. Same rationale as the other lib-file bootstrap tests:
# proves the loop's existence/non-emptiness check covers this newly
# extracted file too, not just rest.sh and the engine lib.
@test "bootstrap: missing consult.sh lib file → allow JSON with WARNING" {
  export REVIEW_DRY_RUN=1
  setup_script_copy
  rm -f "${COPY_SCRIPT_DIR}/lib/consult.sh"

  run_hook_copy

  assert_approve_json
  [[ "$HOOK_STDOUT" == *"[WARNING]"* ]]
  [[ "$HOOK_STDOUT" == *"lib file missing"* ]]
}

# bootstrap: consult.sh exists but is empty (zero bytes) — passes `[ -f ]`
# clean, `source` of zero bytes "succeeds", and the first call into a helper
# it was supposed to define (run_consultation) would die with "command not
# found" (exit 127) absent the `[ -s ]` guard — silent fail-closed.
@test "bootstrap: empty consult.sh lib file → allow JSON with WARNING" {
  export REVIEW_DRY_RUN=1
  setup_script_copy
  : > "${COPY_SCRIPT_DIR}/lib/consult.sh"

  run_hook_copy

  assert_approve_json
  [[ "$HOOK_STDOUT" == *"[WARNING]"* ]]
  [[ "$HOOK_STDOUT" == *"lib file missing"* ]]
}

# bootstrap: consult.sh exists and is non-empty (passes `[ -s ]`) but has a
# real bash syntax error — `source` itself fails even though the
# existence/non-emptiness check does not. Proves consult.sh routes through
# `_source_lib`'s fail-open-on-source-failure path like the other libs.
@test "bootstrap: syntax-broken consult.sh lib file → allow JSON with WARNING (source fails, not missing)" {
  export REVIEW_DRY_RUN=1
  setup_script_copy
  # Unbalanced quote + stray paren: guaranteed bash syntax error, file still
  # exists and is readable.
  printf '%s\n' 'this is " not valid bash (' >> "${COPY_SCRIPT_DIR}/lib/consult.sh"

  run_hook_copy

  assert_approve_json
  [[ "$HOOK_STDOUT" == *"[WARNING]"* ]]
  [[ "$HOOK_STDOUT" == *"failed to load"* ]]
}

# =============================================================================
# Round Memory (A): HISTORY_FILE injection, recording, and lifecycle
# =============================================================================

# history: codex — second round injects the thread built from round 1
@test "history: codex second round injects Prior Review Thread with first round's review" {
  export REVIEW_ENGINE="codex"
  create_mock_codex_capture "<verdict>CONCERNS</verdict>
[Major] round1 finding about caching."
  INPUT=$(build_input)
  run_hook
  assert_deny_json

  local history_file
  history_file=$(get_history_file)
  [ -s "$history_file" ]
  grep -q "round1 finding about caching" "$history_file"

  create_mock_codex_capture "<verdict>APPROVE</verdict>
Looks good now."
  run_hook
  assert_ack_approve_json

  local captured
  captured=$(cat "${MOCK_BIN}/../.codex-stdin")
  [[ "$captured" == *"## Prior Review Thread"* ]]
  [[ "$captured" == *"round1 finding about caching"* ]]
}

# history: claude — second round injects the thread built from round 1 (the
# path PR #153 missed: it only fixed codex).
@test "history: claude second round injects Prior Review Thread with first round's review" {
  export REVIEW_ENGINE="claude"
  create_mock_engine "claude" "<verdict>CONCERNS</verdict>
[Major] round1 claude finding."
  INPUT=$(build_input)
  run_hook
  assert_deny_json

  local history_file
  history_file=$(get_history_file)
  [ -s "$history_file" ]
  grep -q "round1 claude finding" "$history_file"

  create_mock_engine "claude" "<verdict>APPROVE</verdict>
Approved on round 2."
  run_hook
  assert_ack_approve_json

  local captured
  captured=$(mock_stdin "claude")
  [[ "$captured" == *"## Prior Review Thread"* ]]
  [[ "$captured" == *"round1 claude finding"* ]]
}

# history: agy with a live CONV_FILE does NOT inject the thread (native
# session memory already carries it — injecting too would duplicate findings).
@test "history: agy with live CONV_FILE does not inject Prior Review Thread" {
  printf '%s' "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" > "${REVIEW_COUNTER_DIR}/.conversation-test-session"
  printf '### Round 1 — CONCERNS\n\n[Major] stale finding.\n\n' > "$(get_history_file)"
  set_counter_value 1 test-session 1
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
[Major] round2 finding."
  INPUT=$(build_input)
  run_hook
  assert_deny_json
  [[ "$(agy_args agy)" == *"--conversation aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"* ]]
  [[ "$(agy_args agy)" != *"Prior Review Thread"* ]]
}

# history: agy CONV_FILE missing/cleared → falls back to thread injection
# (first-round-shaped call reads PROMPT_FILE, which now carries the thread).
@test "history: agy CONV_FILE cleared falls back to Prior Review Thread injection" {
  printf '### Round 1 — CONCERNS\n\n[Major] earlier finding needing re-check.\n\n' > "$(get_history_file)"
  set_counter_value 1 test-session 1
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
[Major] round2 finding."
  INPUT=$(build_input)
  run_hook
  assert_deny_json
  [[ "$(agy_args agy)" != *"--conversation"* ]]
  [[ "$(agy_args agy)" == *"## Prior Review Thread"* ]]
  [[ "$(agy_args agy)" == *"earlier finding needing re-check"* ]]
}

# history: agy CLI failure mid-round → CONV_FILE cleared → REST fallback
# still receives the thread (A4's SECOND call site, right before rest_invoke;
# the review's own root-cause scenario: composition-time judged "agy has
# native memory" so call site 1 skipped injection, then the CLI call itself
# failed and dropped that memory before REST ever saw the prompt).
@test "history: agy CLI failure → REST fallback receives Prior Review Thread (second injection call site)" {
  printf '%s' "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" > "${REVIEW_COUNTER_DIR}/.conversation-test-session"
  printf '### Round 1 — CONCERNS\n\n[Major] finding that must survive to REST.\n\n' > "$(get_history_file)"
  set_counter_value 1 test-session 1
  create_failing_engine "agy" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  local captured_req="${TEST_TEMP_DIR}/rest-request-body.json"
  create_mock_curl_sse_capture '<verdict>APPROVE</verdict>\nApproved via REST with thread.' "$captured_req"

  INPUT=$(build_input)
  run_hook
  assert_ack_approve_json

  [ -f "$captured_req" ]
  local prompt_content
  prompt_content=$(jq -r '.messages[1].content' "$captured_req")
  [[ "$prompt_content" == *"## Prior Review Thread"* ]]
  [[ "$prompt_content" == *"finding that must survive to REST"* ]]
}

# history: both A4 call sites can legitimately fire in the same round (agy's
# CONV_FILE already absent at composition time, THEN the CLI call also
# fails) — the HISTORY_INJECTED guard, not the condition, must be what stops
# a second, duplicate injection.
@test "history: thread is injected only once per round despite two call sites (HISTORY_INJECTED guard)" {
  printf '### Round 1 — CONCERNS\n\n[Major] guard-check finding.\n\n' > "$(get_history_file)"
  set_counter_value 1 test-session 1
  create_failing_engine "agy" 1
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  local captured_req="${TEST_TEMP_DIR}/rest-request-body-guard.json"
  create_mock_curl_sse_capture '<verdict>APPROVE</verdict>\nApproved.' "$captured_req"

  INPUT=$(build_input)
  run_hook
  assert_ack_approve_json

  [ -f "$captured_req" ]
  local prompt_content occurrences
  prompt_content=$(jq -r '.messages[1].content' "$captured_req")
  # Match the injected SECTION HEADING as its own line, not any substring —
  # the delta review rules (B) legitimately reference "## Prior Review
  # Thread" by name in prose ('see any "## Prior Review Thread" section
  # above'), which would double-count against a plain substring grep.
  occurrences=$(printf '%s' "$prompt_content" | grep -c '^## Prior Review Thread$')
  [ "$occurrences" -eq 1 ]
}

# history: first round (TOTAL_ROUNDS=0) never carries a thread section — there
# are no prior rounds to summarize yet.
@test "history: first round prompt has no Prior Review Thread section" {
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
[Major] first round only."
  INPUT=$(build_input)
  run_hook
  assert_deny_json
  [[ "$(agy_args agy)" != *"Prior Review Thread"* ]]
}

# history: dry-run's synthetic APPROVE never reaches the CONCERNS/REJECT
# recording branch — no engine call happened, nothing to record.
@test "history: dry-run never writes to HISTORY_FILE" {
  export REVIEW_DRY_RUN=1
  INPUT=$(build_input)
  run_hook
  assert_ack_approve_json
  [ ! -f "$(get_history_file)" ]
}

# history: cycle-ending exits clear HISTORY_FILE, one test per exit path.
@test "history: ack-round approved clears HISTORY_FILE" {
  printf '### Round 1 — APPROVE\n\nstale.\n\n' > "$(get_history_file)"
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Looks good."
  INPUT=$(build_input)
  run_hook
  assert_ack_approve_json
  run_hook
  assert_approve_json
  [ ! -f "$(get_history_file)" ]
}

@test "history: non-critical safety valve clears HISTORY_FILE" {
  export REVIEW_MAX_ROUNDS=1
  printf '### Round 1 — CONCERNS\n\nstale.\n\n' > "$(get_history_file)"
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
[Major] persistent."
  INPUT=$(build_input)
  run_hook
  assert_deny_json
  run_hook
  assert_approve_json
  [ ! -f "$(get_history_file)" ]
}

@test "history: no-plan fail-closed clears HISTORY_FILE" {
  printf '### Round 1 — CONCERNS\n\nstale.\n\n' > "$(get_history_file)"
  INPUT=$(build_input_no_plan)
  run_hook
  assert_deny_json
  [ ! -f "$(get_history_file)" ]
}

@test "history: global safety valve clears HISTORY_FILE" {
  set_counter_value 0 test-session 3
  export REVIEW_MAX_TOTAL_ROUNDS=3
  printf '### Round 3 — CONCERNS\n\nstale.\n\n' > "$(get_history_file)"
  INPUT=$(build_input)
  run_hook
  assert_deny_json
  [[ "$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" == *"HARD STOP"* ]]
  [ ! -f "$(get_history_file)" ]
}

# history: plan-changed-after-approve is NOT a cycle end — HISTORY_FILE is
# kept (only appended a revision marker), unlike every other exit above.
@test "history: plan-changed-after-approve retains HISTORY_FILE and appends revision marker" {
  printf '### Round 1 — CONCERNS\n\n[Major] earlier finding.\n\n' > "$(get_history_file)"
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Good."
  INPUT=$(build_input plan="Original plan")
  run_hook
  assert_ack_approve_json

  INPUT=$(build_input plan="Completely different plan")
  run_hook
  assert_log_contains "reason=plan-changed-after-approve conv-cleared"

  local history_file
  history_file=$(get_history_file)
  [ -f "$history_file" ]
  grep -q "earlier finding" "$history_file"
  grep -q "plan revised after approve" "$history_file"
}

# history: an in-loop CLI failure (:626/:646 — this round's own retry, not a
# cycle end) must NOT clear HISTORY_FILE — only the resume handle is stale.
@test "history: engine failure within the retry loop does not clear HISTORY_FILE" {
  printf '### Round 1 — CONCERNS\n\n[Major] must survive retry.\n\n' > "$(get_history_file)"
  set_counter_value 1 test-session 1
  create_flaky_engine "agy" "<verdict>CONCERNS</verdict>
[Major] round2 finding." "exit"
  INPUT=$(build_input)
  run_hook
  assert_deny_json
  local history_file
  history_file=$(get_history_file)
  [ -s "$history_file" ]
  grep -q "must survive retry" "$history_file"
}

# history: grok-flagged gap — a live CONV_FILE at composition time makes
# call site 1 skip injection (agy's own session memory looked sufficient).
# The CLI's OWN retry then fails attempt 1, clears CONV_FILE, and agy's
# attempt 2 reads an empty CONV_ID — falling back to its first-round path,
# which re-reads PROMPT_FILE from scratch. Without a retry-path injection
# right after CONV_FILE is cleared, that re-read PROMPT_FILE still has no
# thread and attempt 2 silently loses all prior-round context — this path
# is MORE common than the REST-fallback gap (call site 2) since it fires
# with no REST fallback configured at all.
@test "history: agy CLI failure clears a LIVE CONV_FILE mid-retry → attempt 2's first-round path carries Prior Review Thread" {
  printf '%s' "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" > "${REVIEW_COUNTER_DIR}/.conversation-test-session"
  printf '### Round 1 — CONCERNS\n\n[Major] stale finding needing re-check.\n\n' > "$(get_history_file)"
  set_counter_value 1 test-session 1
  create_flaky_engine "agy" "<verdict>CONCERNS</verdict>
[Major] round2 finding." "exit"
  INPUT=$(build_input)
  run_hook
  assert_deny_json

  local captured
  captured=$(agy_args agy)
  # attempt 2 must NOT resume the (now-cleared) old conversation...
  [[ "$captured" != *"--conversation"* ]]
  # ...and must carry the thread call site 1 skipped, via call site 2
  # (unified: right after engine_extract(), before any branching).
  [[ "$captured" == *"## Prior Review Thread"* ]]
  [[ "$captured" == *"stale finding needing re-check"* ]]
}

# history: grok re-review round 2 finding — a 0-exit agy CLI call whose JSON
# envelope has no parseable "response" field never trips the orchestrator's
# `engine_exit != 0` invalidation (exit IS 0); the ONLY thing that clears
# CONV_FILE here is agy.sh's own internal rm inside engine_extract() (see
# lib/engines/agy.sh, the "else: rm -f CONV_FILE" branch under REVIEW empty).
# Before the unified call site 2, the orchestrator had no way to observe that
# internal rm, so attempt 2 (which reads the now-empty CONV_ID and falls back
# to agy's first-round path, re-reading PROMPT_FILE) never got the thread.
@test "history: agy CLI exit 0 but malformed envelope (no response field) → attempt 2's first-round path carries Prior Review Thread" {
  printf '%s' "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" > "${REVIEW_COUNTER_DIR}/.conversation-test-session"
  printf '### Round 1 — CONCERNS\n\n[Major] stale finding survives malformed envelope.\n\n' > "$(get_history_file)"
  set_counter_value 1 test-session 1

  local state_file="${TEST_TEMP_DIR}/.agy-malformed-state"
  local args_file="${MOCK_BIN}/../.agy-args-agy"
  cat > "${MOCK_BIN}/agy" << MOCK_EOF
#!/bin/bash
printf '%s\n' "\$*" > '${args_file}'
if [ ! -f "${state_file}" ]; then
  touch "${state_file}"
  # attempt 1: exit 0, JSON parses, but there is no "response" key at all —
  # engine_extract's forward scan finds no match, REVIEW stays empty, and
  # agy.sh's OWN internal rm (not the orchestrator) clears CONV_FILE.
  echo '{"conversation_id":"bbbbbbbb-cccc-dddd-eeee-ffffffffffff","status":"SUCCESS","usage":{"input_tokens":1,"total_tokens":1}}'
  exit 0
fi
# attempt 2: well-formed envelope, real verdict.
echo '{"conversation_id":"cccccccc-dddd-eeee-ffff-000000000000","status":"SUCCESS","response":"<verdict>CONCERNS</verdict> round2 finding.","usage":{"input_tokens":1,"total_tokens":1}}'
MOCK_EOF
  chmod +x "${MOCK_BIN}/agy"

  INPUT=$(build_input)
  run_hook
  assert_deny_json

  local captured
  captured=$(agy_args agy)
  # attempt 2 must NOT resume the (internally-cleared) old conversation...
  [[ "$captured" != *"--conversation"* ]]
  # ...and must carry the thread call site 1 skipped (agy looked live at
  # composition time), picked up here via call site 2 seeing agy's own
  # internal rm having already run inside engine_extract().
  [[ "$captured" == *"## Prior Review Thread"* ]]
  [[ "$captured" == *"stale finding survives malformed envelope"* ]]
}

# history: grok re-review round 2 finding — agy's ARG_MAX guard
# (_ENGINE_ABORT_RETRY=1, oversized prompt) aborts BEFORE engine_extract()
# ever runs this round, so CONV_FILE is left completely untouched — it can
# still look perfectly "live" even though this round produced no agy call at
# all and is about to fall through to REST, which never has session memory
# of its own. Gating REST's injection on agy's CONV_FILE liveness was the
# category error call site 3's `force` parameter exists to close.
@test "history: agy ARG_MAX abort (_ENGINE_ABORT_RETRY, oversized prompt) with a LIVE CONV_FILE → REST fallback still receives Prior Review Thread (force)" {
  printf '%s' "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" > "${REVIEW_COUNTER_DIR}/.conversation-test-session"
  printf '### Round 1 — CONCERNS\n\n[Major] finding that must survive an ARG_MAX abort.\n\n' > "$(get_history_file)"
  set_counter_value 1 test-session 1

  # A plan body north of 256KB trips agy's ARG_MAX guard (mirrors "rest-sse:
  # oversized prompt → skip agy, REST fallback used" above) — CONV_FILE stays
  # live/untouched through this whole path.
  local big_plan
  big_plan="<verdict>marker</verdict> $(printf 'x%.0s' $(seq 1 300000))"
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  local captured_req="${TEST_TEMP_DIR}/rest-request-body-argmax.json"
  create_mock_curl_sse_capture '<verdict>APPROVE</verdict>\nApproved via REST after ARG_MAX abort.' "$captured_req"

  INPUT=$(build_input plan="$big_plan")
  run_hook
  assert_ack_approve_json
  assert_log_contains "agy-skip reason=prompt-too-large"

  [ -f "$captured_req" ]
  local prompt_content
  prompt_content=$(jq -r '.messages[1].content' "$captured_req")
  [[ "$prompt_content" == *"## Prior Review Thread"* ]]
  [[ "$prompt_content" == *"finding that must survive an ARG_MAX abort"* ]]
}

# history: grok re-review round 3 finding — CROSS-round, a different
# dimension from the three same-round injection call sites tested above.
# Round 1's ARG_MAX abort leaves CONV_FILE completely untouched, and REST —
# not agy — produces this round's authoritative REVIEW. Without invalidating
# CONV_FILE afterward, round 2's composition-time check would see a
# non-empty CONV_FILE, conclude agy has native memory, and skip thread
# injection entirely — but agy's own server-side session never saw round
# 1's REST-produced finding (it never ran), so round 2 would get neither the
# thread nor real native memory of it. This is what `[ -z "$REVIEW" ] ||
# rm -f "${CONV_FILE:-}"` right after rest_extract fixes.
@test "history: REST-produced REVIEW after an ARG_MAX abort invalidates CONV_FILE cross-round → next round has no --conversation and carries REST's finding" {
  # Precondition: CONV_FILE already live, as if established by an earlier
  # successful agy round outside this test's visibility — this is what makes
  # the assertions below non-trivial (without a live CONV_FILE to begin
  # with, "no --conversation next round" would hold even without the fix).
  printf '%s' "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" > "${REVIEW_COUNTER_DIR}/.conversation-test-session"

  # Round 1: oversized plan trips agy's ARG_MAX guard — CONV_FILE is never
  # touched by that path — and REST is the only producer of a result this
  # round. Verdict CONCERNS so A3 records the finding into HISTORY_FILE and
  # the cycle continues (a round 2 happens at all).
  local big_plan
  big_plan="<verdict>marker</verdict> $(printf 'x%.0s' $(seq 1 300000))"
  export REVIEW_API_URL="http://localhost:9999"
  export REVIEW_API_KEY="test-key"
  create_mock_curl_sse '<verdict>CONCERNS</verdict>
[Major] REST-produced finding from the ARG_MAX round.'
  INPUT=$(build_input plan="$big_plan")
  run_hook
  assert_deny_json
  assert_log_contains "agy-skip reason=prompt-too-large"

  local history_file
  history_file=$(get_history_file)
  [ -s "$history_file" ]
  grep -q "REST-produced finding from the ARG_MAX round" "$history_file"

  # Round 1 exhausting CLI and falling to REST unconditionally refreshes the
  # gemini degrade-file (unrelated to this fix — same behavior pre-dates it),
  # which would otherwise make round 2 ALSO skip straight to REST (reusing
  # round 1's REST mock output) instead of actually invoking agy. Clear it
  # so round 2 genuinely exercises the agy CLI path this test is about.
  rm -f "${REVIEW_COUNTER_DIR}/.gemini-degraded"

  # Round 2: same session, a normal (non-oversized) plan — agy's CLI
  # actually gets invoked this time. If CONV_FILE were still live from round
  # 1 (the bug this test pins), this round would resume it with
  # --conversation and never receive the injected thread.
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Acknowledged, finding resolved."
  INPUT=$(build_input)
  run_hook
  assert_ack_approve_json

  local captured
  captured=$(agy_args agy)
  [[ "$captured" != *"--conversation"* ]]
  [[ "$captured" == *"## Prior Review Thread"* ]]
  [[ "$captured" == *"REST-produced finding from the ARG_MAX round"* ]]
}

# history: engine-not-found is an orphan exit (no engine call will ever
# happen this cycle) — HISTORY_FILE is dropped to block cross-plan
# contamination, but COUNTER_FILE deliberately survives (unchanged contract).
@test "history: engine-not-found clears HISTORY_FILE but keeps COUNTER_FILE" {
  export REVIEW_ENGINE="codex"
  printf '### Round 1 — CONCERNS\n\n[Major] should not leak to next plan.\n\n' > "$(get_history_file)"
  set_counter_value 1 test-session 1
  INPUT=$(build_input)

  # Rebuild PATH excluding any directory that happens to have a real `codex`
  # installed (mirrors the existing "codex: binary missing" test).
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
  [ ! -f "$(get_history_file)" ]
  [ -f "${REVIEW_COUNTER_DIR}/.review-count-test-session" ]
}

# history: engine-not-attempted (CLI ran, returned empty, no REST configured
# to try next) is the other orphan exit — same cleanup contract as above.
@test "history: engine-not-attempted clears HISTORY_FILE but keeps COUNTER_FILE" {
  create_mock_engine "agy" ""
  printf '### Round 1 — CONCERNS\n\n[Major] should not leak to next plan.\n\n' > "$(get_history_file)"
  set_counter_value 1 test-session 1
  INPUT=$(build_input)
  run_hook
  assert_approve_json
  [[ "$HOOK_STDOUT" == *"[WARNING]"* ]]
  [ ! -f "$(get_history_file)" ]
  [ -f "${REVIEW_COUNTER_DIR}/.review-count-test-session" ]
}

# history: HISTORY_FILE write failure must not kill the hook under `set -e`,
# and must not fail silently either.
@test "history: HISTORY_FILE unwritable → hook still emits decision JSON, logs history-write-failed" {
  mkdir -p "$(get_history_file)"
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
[Major] finding despite write failure."
  INPUT=$(build_input)
  run_hook
  assert_deny_json
  assert_log_contains "history-write-failed"
}

# =============================================================================
# Delta Review Rules (B): "## Consultation Context" expansion, all engines
# =============================================================================

# context: codex — delta rules present on round > 0
@test "context: delta review rules appear in codex prompt when TOTAL_ROUNDS>0" {
  export REVIEW_ENGINE="codex"
  set_counter_value 1 test-session 1
  create_mock_codex_capture "<verdict>APPROVE</verdict>
Fine."
  INPUT=$(build_input)
  run_hook
  assert_ack_approve_json
  local captured
  captured=$(cat "${MOCK_BIN}/../.codex-stdin")
  [[ "$captured" == *"Evidence burden is symmetric"* ]]
  [[ "$captured" == *"forfeited relitigation"* ]]
}

# context: claude — delta rules present on round > 0
@test "context: delta review rules appear in claude prompt when TOTAL_ROUNDS>0" {
  export REVIEW_ENGINE="claude"
  set_counter_value 1 test-session 1
  create_mock_engine "claude" "<verdict>APPROVE</verdict>
Fine."
  INPUT=$(build_input)
  run_hook
  assert_ack_approve_json
  local captured
  captured=$(mock_stdin "claude")
  [[ "$captured" == *"Evidence burden is symmetric"* ]]
  [[ "$captured" == *"forfeited relitigation"* ]]
}

# context: agy first-round-shaped call (no CONV_FILE yet, reads PROMPT_FILE)
# — delta rules present on round > 0
@test "context: delta review rules appear in agy PROMPT_FILE-based prompt when TOTAL_ROUNDS>0" {
  set_counter_value 1 test-session 1
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Fine."
  INPUT=$(build_input)
  run_hook
  assert_ack_approve_json
  local captured
  captured=$(agy_args agy)
  [[ "$captured" == *"Evidence burden is symmetric"* ]]
  [[ "$captured" == *"forfeited relitigation"* ]]
}

# context: agy resume-round inline prompt (bypasses PROMPT_FILE entirely) —
# delta rules must ALSO be present here, since this duplicate text is the
# MOST COMMON multi-round path with the default engine.
@test "context: delta review rules appear in agy resume-round inline prompt when TOTAL_ROUNDS>0" {
  printf '%s' "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" > "${REVIEW_COUNTER_DIR}/.conversation-test-session"
  set_counter_value 1 test-session 1
  create_mock_engine "agy" "<verdict>APPROVE</verdict>
Fine."
  INPUT=$(build_input)
  run_hook
  assert_ack_approve_json
  local captured
  captured=$(agy_args agy)
  [[ "$captured" == *"--conversation aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"* ]]
  [[ "$captured" == *"Evidence burden is symmetric"* ]]
  [[ "$captured" == *"forfeited relitigation"* ]]
}

# context: first round (TOTAL_ROUNDS=0) has no delta review rules — there is
# no prior round to build a delta against yet.
@test "context: first round prompt has no delta review rules" {
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
[Major] first round."
  INPUT=$(build_input)
  run_hook
  assert_deny_json
  [[ "$(agy_args agy)" != *"Evidence burden is symmetric"* ]]
}

# =============================================================================
# Byte Clamps (D): clamp_head_bytes / clamp_tail_bytes — lib/common.sh
# =============================================================================

# prompt: clamp_head_bytes branch 1 (under limit) — full round-trip, no
# edge line dropped from either boundary. Title says "content preserved",
# NOT "unchanged": this fixture's $input has no trailing newline, so this
# case happens to round-trip byte-for-byte, but the function's own
# content=$(cat) strips ALL trailing stdin newlines regardless — see the
# dedicated trailing-newline test below, which pins that behavior for input
# that DOES have one.
@test "prompt: clamp_head_bytes under limit preserves content, no edge line dropped" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/common.sh"
  local input="line1
line2
line3"
  local out
  out=$(printf '%s' "$input" | clamp_head_bytes 1000)
  [ "$out" = "$input" ]
}

# prompt: clamp_head_bytes's content=$(cat) strips ALL trailing stdin
# newlines before the byte-count comparison even when under the limit — the
# same command-substitution semantics already used elsewhere in this
# codebase (e.g. the original GLOBAL_MD=$(head -c ... ) idiom). This is
# acceptable, not a regression: it only ever shortens output, never exceeds
# the byte budget, and the under-limit branch is a pure pass-through of
# already-truncated content otherwise. Pinned here so a future refactor
# doesn't accidentally "fix" this into inconsistent behavior with the rest
# of the codebase.
@test "prompt: clamp_head_bytes strips trailing newlines from stdin even when under limit (known, acceptable)" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/common.sh"
  local out
  out=$(printf 'aaaaaaaaaa\n\n\n' | clamp_head_bytes 12 | wc -c | tr -d ' ')
  [ "$out" -eq 10 ]
}

# prompt: clamp_head_bytes branch 2 (over limit, cut lands mid-CJK-character
# on a line that has a complete predecessor) — the truncated line is dropped
# whole, result stays valid UTF-8.
@test "prompt: clamp_head_bytes over limit at a line boundary drops the truncated line, stays valid UTF-8" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/common.sh"
  local infile outfile
  infile="${TEST_TEMP_DIR}/head-over.txt"
  outfile="${TEST_TEMP_DIR}/head-over.out"
  {
    printf 'aaaaaaaaaa\n'
    printf 'b%.0s' $(seq 1 20)
    printf '中文内容\n'
    printf 'c%.0s' $(seq 1 20)
  } > "$infile"
  clamp_head_bytes 33 < "$infile" > "$outfile"
  run bash -c "iconv -f UTF-8 -t UTF-8 < '$outfile' >/dev/null 2>&1"
  [ "$status" -eq 0 ]
  [ "$(cat "$outfile")" = "aaaaaaaaaa" ]
}

# prompt: clamp_head_bytes branch 3 (over limit, no newline before the cut —
# a single long line) — falls back to a raw byte cut rather than returning
# empty.
@test "prompt: clamp_head_bytes over limit with no newline before the cut falls back to raw head -c, not empty" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/common.sh"
  local infile outfile
  infile="${TEST_TEMP_DIR}/head-single.txt"
  outfile="${TEST_TEMP_DIR}/head-single.out"
  printf 'a%.0s' $(seq 1 50) > "$infile"
  clamp_head_bytes 10 < "$infile" > "$outfile"
  [ -s "$outfile" ]
  [ "$(wc -c < "$outfile" | tr -d ' ')" -eq 10 ]
}

# prompt: clamp_tail_bytes branch 1 (under limit) — full round-trip, no edge
# line dropped. Title says "content preserved", NOT "unchanged": see the
# clamp_head_bytes trailing-newline note above — the same content=$(cat)
# stripping applies here too, this fixture's $input just has no trailing
# newline so it round-trips byte-for-byte.
@test "prompt: clamp_tail_bytes under limit preserves content, no edge line dropped" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/common.sh"
  local input="line1
line2
line3"
  local out
  out=$(printf '%s' "$input" | clamp_tail_bytes 1000)
  [ "$out" = "$input" ]
}

# prompt: clamp_tail_bytes branch 2 (over limit, cut lands mid-CJK-character)
# — the truncated line is dropped whole, result stays valid UTF-8.
@test "prompt: clamp_tail_bytes over limit at a line boundary drops the truncated line, stays valid UTF-8" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/common.sh"
  local infile outfile
  infile="${TEST_TEMP_DIR}/tail-over.txt"
  outfile="${TEST_TEMP_DIR}/tail-over.out"
  {
    printf 'AAAAAAAAAA\n'
    printf '中文内容\n'
    printf 'CCCC\n'
    printf 'DDDD\n'
  } > "$infile"
  clamp_tail_bytes 15 < "$infile" > "$outfile"
  run bash -c "iconv -f UTF-8 -t UTF-8 < '$outfile' >/dev/null 2>&1"
  [ "$status" -eq 0 ]
  local content
  content=$(cat "$outfile")
  [[ "$content" == *"CCCC"* ]]
  [[ "$content" == *"DDDD"* ]]
  [[ "$content" != *"内容"* ]]
}

# prompt: clamp_tail_bytes branch 3 (over limit, no newline before the cut) —
# falls back to a raw byte cut rather than returning empty.
@test "prompt: clamp_tail_bytes over limit with no newline before the cut falls back to raw tail -c, not empty" {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/common.sh"
  local infile outfile
  infile="${TEST_TEMP_DIR}/tail-single.txt"
  outfile="${TEST_TEMP_DIR}/tail-single.out"
  printf 'a%.0s' $(seq 1 50) > "$infile"
  clamp_tail_bytes 10 < "$infile" > "$outfile"
  [ -s "$outfile" ]
  [ "$(wc -c < "$outfile" | tr -d ' ')" -eq 10 ]
}

# prompt: A3 + D integration — a single overlong Chinese review is clamped
# by clamp_head_bytes before landing in HISTORY_FILE, and the clamped record
# stays valid UTF-8.
@test "prompt: single-round overlong Chinese review is clamped into HISTORY_FILE, stays valid UTF-8" {
  local body i
  body="<verdict>CONCERNS</verdict>"$'\n'
  for i in $(seq 1 200); do
    body="${body}[Major] 第${i}条中文发现内容，用于撑大审阅正文长度以测试单轮记录截断行为是否安全可靠。"$'\n'
  done
  create_mock_engine "agy" "$body"
  INPUT=$(build_input)
  run_hook
  assert_deny_json

  local history_file
  history_file=$(get_history_file)
  [ -s "$history_file" ]
  run bash -c "iconv -f UTF-8 -t UTF-8 < '$history_file' >/dev/null 2>&1"
  [ "$status" -eq 0 ]
  grep -q "第1条中文发现" "$history_file"
  ! grep -q "第200条中文发现" "$history_file"
  local hist_bytes
  hist_bytes=$(wc -c < "$history_file" | tr -d ' ')
  # HISTORY_ROUND_BYTES is 9000 (lib/common.sh); 9200 leaves the same ~200-byte
  # margin the original 6200/6000 pairing did, for the "### Round N — VERDICT"
  # header + trailing blank line this clamp doesn't count against the budget.
  [ "$hist_bytes" -lt 9200 ]
}

# prompt: A4 + D integration — an overlong accumulated thread (many rounds)
# is capped by clamp_tail_bytes on injection, keeping only the most recent
# rounds, and the injected content stays valid UTF-8.
@test "prompt: overlong accumulated thread is capped by clamp_tail_bytes on injection, stays valid UTF-8" {
  local history_file i
  history_file=$(get_history_file)
  : > "$history_file"
  # 400 rounds (not 200): HISTORY_INJECT_BYTES is 48000 (lib/common.sh), up
  # from the old 24000 — this fixture must exceed the CURRENT budget by a
  # comfortable margin, or the clamp under test never actually triggers.
  for i in $(seq 1 400); do
    printf '### Round %d — CONCERNS\n\n[Major] 第%d轮中文审阅意见内容一，用于撑大历史文件体积用于测试截断行为是否安全。第%d轮中文审阅意见内容二，重复一遍确保单条记录本身足够长。\n\n' \
      "$i" "$i" "$i" >> "$history_file"
  done
  local hist_bytes
  hist_bytes=$(wc -c < "$history_file" | tr -d ' ')
  [ "$hist_bytes" -gt 48000 ]

  set_counter_value 1 test-session 5
  create_mock_engine "agy" "<verdict>CONCERNS</verdict>
[Major] latest finding."
  INPUT=$(build_input)
  run_hook
  assert_deny_json

  local args_file="${MOCK_BIN}/../.agy-args-agy"
  [[ "$(cat "$args_file")" == *"## Prior Review Thread"* ]]
  [[ "$(cat "$args_file")" != *"Round 1 —"* ]]
  [[ "$(cat "$args_file")" == *"Round 400 —"* ]]
  run bash -c "iconv -f UTF-8 -t UTF-8 < '$args_file' >/dev/null 2>&1"
  [ "$status" -eq 0 ]
}
