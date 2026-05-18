#!/usr/bin/env bats
# BDD test suite for dispatch-check.sh (Layer 2 dispatch enforcement hook).
#
# Verifies: fail-open on all anomaly paths, correct deny on missing params,
# stale file cleanup, kill switch, task/agent naming compatibility.
#
# Dependencies: bats-core, jq

setup() {
  load 'test_helper/common-setup'
  common_setup
  # Minimal defaults for dispatch-check (unset plan-review-specific overrides)
  unset DISPATCH_CHECK_DISABLED
}

teardown() {
  common_teardown
}

# Valid dispatch JSON for use across tests
VALID_DISPATCH='{"plan_hash":"abc123","created_at":1700000000,"requires_dispatch_check":true,"steps":[{"id":"1","agent_type":null,"model":null},{"id":"2","agent_type":"worker","model":"sonnet"}]}'

# =============================================================================
# Fail-Open: No Dispatch File
# =============================================================================

# 1. 无 dispatch 文件 + Agent 调用 → allow (exit 0, no JSON output)
@test "dispatch: no dispatch file + Agent call → allow (fail-open)" {
  INPUT=$(build_agent_input)
  run_dispatch_check

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

# 2. dispatch 文件存在 + 完整 Agent 参数 → allow (silent exit 0)
@test "dispatch: dispatch file + complete Agent params → allow" {
  create_dispatch_file "test-session" "$VALID_DISPATCH"
  INPUT=$(build_agent_input model=sonnet subagent_type=worker)
  run_dispatch_check

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

# =============================================================================
# Deny: Missing Params
# =============================================================================

# 3. dispatch 文件存在 + 缺 model → deny + 提示含 manifest 预览
@test "dispatch: dispatch file + missing model → deny with manifest preview" {
  create_dispatch_file "test-session" "$VALID_DISPATCH"
  INPUT=$(build_agent_input subagent_type=worker)
  run_dispatch_check

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"model"* ]]
  [[ "$reason" == *"Manifest"* ]]
}

# 4. dispatch 文件存在 + 缺 subagent_type → deny
@test "dispatch: dispatch file + missing subagent_type → deny" {
  create_dispatch_file "test-session" "$VALID_DISPATCH"
  INPUT=$(build_agent_input model=sonnet)
  run_dispatch_check

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"subagent_type"* ]]
}

# 5. dispatch 文件存在 + 两者都缺 → deny，提示两者
@test "dispatch: dispatch file + missing both → deny with both listed" {
  create_dispatch_file "test-session" "$VALID_DISPATCH"
  INPUT=$(build_agent_input)
  run_dispatch_check

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"subagent_type"* ]]
  [[ "$reason" == *"model"* ]]
}

# =============================================================================
# Fail-Open: Stale File
# =============================================================================

# 6. dispatch 文件 mtime > 30min → allow + 文件自动删除
@test "dispatch: stale dispatch file (>30min) → allow + file deleted" {
  create_dispatch_file "test-session" "$VALID_DISPATCH"
  local dispatch_file="${REVIEW_COUNTER_DIR}/.dispatch-test-session.json"
  # Backdate by 35 minutes
  touch -t "$(date -v -35M +%Y%m%d%H%M 2>/dev/null || date -d '35 minutes ago' +%Y%m%d%H%M 2>/dev/null || date +%Y%m%d%H%M)" \
    "$dispatch_file" 2>/dev/null || \
    python3 -c "import os,time; os.utime('$dispatch_file', (time.time()-2100, time.time()-2100))" 2>/dev/null || true

  INPUT=$(build_agent_input)
  run_dispatch_check

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
  [ ! -f "$dispatch_file" ]
}

# =============================================================================
# Fail-Open: Corrupt / Missing Fields
# =============================================================================

# 7. dispatch JSON 损坏 → allow + 无副作用
@test "dispatch: corrupt dispatch JSON → allow (fail-open)" {
  create_dispatch_file "test-session" "not-valid-json{{{{"
  INPUT=$(build_agent_input)
  run_dispatch_check

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

# 8. requires_dispatch_check=false → allow
@test "dispatch: requires_dispatch_check=false → allow" {
  create_dispatch_file "test-session" \
    '{"plan_hash":"abc","created_at":1700000000,"requires_dispatch_check":false,"steps":[]}'
  INPUT=$(build_agent_input)
  run_dispatch_check

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

# =============================================================================
# Fail-Open: Kill Switches
# =============================================================================

# 9. DISPATCH_CHECK_DISABLED=1 → allow 即使 dispatch 文件存在 + 参数缺失
@test "dispatch: DISPATCH_CHECK_DISABLED=1 → allow regardless of dispatch file" {
  export DISPATCH_CHECK_DISABLED=1
  create_dispatch_file "test-session" "$VALID_DISPATCH"
  INPUT=$(build_agent_input)  # missing both model and subagent_type
  run_dispatch_check

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

# 10. jq 缺失 → allow (PATH 临时去除 jq 模拟)
@test "dispatch: jq missing → allow (fail-open)" {
  create_dispatch_file "test-session" "$VALID_DISPATCH"
  INPUT=$(build_agent_input)

  local restricted_bin="${TEST_TEMP_DIR}/restricted_bin_dc"
  mkdir -p "$restricted_bin"
  for cmd in bash cat grep head tr printf mkdir rm find stat date python3 mktemp; do
    local cmd_path
    cmd_path=$(command -v "$cmd" 2>/dev/null) || continue
    ln -sf "$cmd_path" "${restricted_bin}/${cmd}"
  done

  local orig_path="$PATH"
  export PATH="$restricted_bin"
  run_dispatch_check
  export PATH="$orig_path"

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

# =============================================================================
# Fail-Open: Wrong Tool / Missing Session
# =============================================================================

# 11. tool_name != Agent/Task → allow (e.g. Read)
@test "dispatch: tool_name=Read → allow (not an Agent call)" {
  create_dispatch_file "test-session" "$VALID_DISPATCH"
  INPUT=$(build_agent_input tool_name=Read)
  run_dispatch_check

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

# 12. session_id 缺失 → allow
@test "dispatch: missing session_id → allow (fail-open)" {
  create_dispatch_file "test-session" "$VALID_DISPATCH"
  INPUT=$(jq -n '{"tool_name":"Agent","tool_input":{}}')  # no session_id
  run_dispatch_check

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

# =============================================================================
# Task Tool Name Compatibility
# =============================================================================

# 13. tool_name="Task" → 与 Agent 同等处理（双命名兼容）
@test "dispatch: tool_name=Task → same enforcement as Agent" {
  create_dispatch_file "test-session" "$VALID_DISPATCH"
  INPUT=$(build_agent_input tool_name=Task)  # missing model + subagent_type
  run_dispatch_check

  assert_deny_json
}

# =============================================================================
# Opportunistic Global Cleanup
# =============================================================================

# 14. Opportunistic 全局清理：预置其它 session 的 stale dispatch 文件，本次调用后被删除
@test "dispatch: opportunistic global cleanup removes other sessions' stale files" {
  # Plant stale files for other sessions
  local stale1="${REVIEW_COUNTER_DIR}/.dispatch-old-session-1.json"
  local stale2="${REVIEW_COUNTER_DIR}/.dispatch-old-session-2.json"
  printf '%s' "$VALID_DISPATCH" > "$stale1"
  printf '%s' "$VALID_DISPATCH" > "$stale2"
  touch -t "$(date -v -35M +%Y%m%d%H%M 2>/dev/null || date -d '35 minutes ago' +%Y%m%d%H%M 2>/dev/null || date +%Y%m%d%H%M)" \
    "$stale1" "$stale2" 2>/dev/null || \
    python3 -c "import os,time; [os.utime(f, (time.time()-2100,)*2) for f in ['$stale1','$stale2']]" 2>/dev/null || true

  # Fresh file for current session (no dispatch file for test-session → allow path)
  INPUT=$(build_agent_input)
  run_dispatch_check

  [ "$HOOK_EXIT" -eq 0 ]
  # Stale files for other sessions must be cleaned up
  [ ! -f "$stale1" ]
  [ ! -f "$stale2" ]
}
