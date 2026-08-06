#!/usr/bin/env bats
# BDD tests for dispatch-sync-guard.sh (PreToolUse hook) and
# dispatch-rules-inject.sh (SubagentStart hook).
#
# dispatch-sync-guard: BLOCK is exit 2 + "dispatch-sync-guard" in stderr.
#                       PASS is exit 0, no "dispatch-sync-guard" in stderr.
# dispatch-rules-inject: PASS always exits 0; assertions check stdout shape.
#
# Fixture self-check discipline: this suite has previously been bitten by a
# fixture bug disguising itself as a passing fail-open gate (printf eating
# the %%DONE%% marker's percent sign). Every payload-builder-driven test
# below re-reads the built payload with jq before running the gate, to
# confirm the fixture itself carries the field shape the test claims it does.

setup() {
  load 'test_helper/common-setup'
  common_setup
}

teardown() {
  common_teardown
}

# ============================================================
# dispatch-sync-guard: pass/block matrix (1-3, 11)
# ============================================================

@test "sync #1: run_in_background:false -> PASS" {
  local payload
  payload=$(mk_dispatch_payload "Task" "false")
  # fixture self-check
  [[ "$(jq -r '.tool_input.run_in_background' <<< "$payload")" == "false" ]]
  run_sync_guard "$payload"
  assert_sync_pass
}

@test "sync #2: run_in_background omitted -> BLOCK" {
  local payload
  payload=$(mk_dispatch_payload "Task" "omit")
  # fixture self-check: field genuinely absent
  [[ "$(jq -e 'has("tool_input") and (.tool_input | has("run_in_background") | not)' <<< "$payload")" == "true" ]]
  # 省略路径的 stderr 形态断言见 sync #16（field-absent 分支）——本用例只钉 BLOCK。
  run_sync_guard "$payload"
  assert_sync_block
}

@test "sync #3: run_in_background:true (explicit) -> BLOCK" {
  local payload
  payload=$(mk_dispatch_payload "Task" "true")
  [[ "$(jq -r '.tool_input.run_in_background' <<< "$payload")" == "true" ]]
  run_sync_guard "$payload"
  assert_sync_block
}

@test "sync #11: run_in_background:\"false\" (string) -> BLOCK" {
  local payload
  payload=$(mk_dispatch_payload "Task" "string_false")
  # fixture self-check: value is a JSON string, not a boolean
  [[ "$(jq -r '.tool_input.run_in_background | type' <<< "$payload")" == "string" ]]
  [[ "$(jq -r '.tool_input.run_in_background' <<< "$payload")" == "false" ]]
  run_sync_guard "$payload"
  assert_sync_block
}

# ============================================================
# dispatch-sync-guard: name / agent_id exemptions (4-6)
# ============================================================

@test "sync #4: tool_input.name present + omitted RIB (Lead starting a teammate) -> PASS" {
  local payload
  payload=$(mk_dispatch_payload "Agent" "omit" "omit" "present")
  [[ "$(jq -r '.tool_input.name' <<< "$payload")" == "lead" ]]
  [[ "$(jq -e '.tool_input | has("run_in_background") | not' <<< "$payload")" == "true" ]]
  run_sync_guard "$payload"
  assert_sync_pass
}

@test "sync #5: tool_input.name present + run_in_background:false (observed real shape) -> PASS" {
  local payload
  payload=$(mk_dispatch_payload "Agent" "false" "omit" "present")
  [[ "$(jq -r '.tool_input.name' <<< "$payload")" == "lead" ]]
  [[ "$(jq -r '.tool_input.run_in_background' <<< "$payload")" == "false" ]]
  run_sync_guard "$payload"
  assert_sync_pass
}

@test "sync #6: agent_id present + omitted RIB (teammate internal dispatch) -> PASS" {
  local payload
  payload=$(mk_dispatch_payload "Task" "omit" "present")
  [[ "$(jq -r '.agent_id' <<< "$payload")" == "test-agent-0000" ]]
  run_sync_guard "$payload"
  assert_sync_pass
}

@test "sync #6b: agent_id present but empty string + omitted RIB -> BLOCK (blank must not fake the exemption)" {
  local payload
  payload=$(mk_dispatch_payload "Task" "omit" "empty")
  # fixture self-check: field present, value is an empty string, not absent
  [[ "$(jq -e 'has("agent_id")' <<< "$payload")" == "true" ]]
  [[ "$(jq -r '.agent_id' <<< "$payload")" == "" ]]
  run_sync_guard "$payload"
  assert_sync_block
}

@test "sync #6c: agent_id present but tab-only + omitted RIB -> BLOCK (blank test must cover tabs, not just spaces)" {
  local payload
  payload=$(mk_dispatch_payload "Task" "omit" "tab")
  # fixture self-check: field present, value is exactly one tab (not absent, not empty)
  [[ "$(jq -e 'has("agent_id")' <<< "$payload")" == "true" ]]
  [[ "$(jq -r '.agent_id' <<< "$payload")" == $'\t' ]]
  run_sync_guard "$payload"
  assert_sync_block
}

@test "sync #6d: agent_id present but newline-only + omitted RIB -> BLOCK" {
  local payload
  payload=$(mk_dispatch_payload "Task" "omit" "newline")
  [[ "$(jq -e 'has("agent_id")' <<< "$payload")" == "true" ]]
  run_sync_guard "$payload"
  assert_sync_block
}

@test "sync #4b: tool_input.name tab-only + omitted RIB -> BLOCK (blank name must not fake the team-ops exemption)" {
  local payload
  payload=$(mk_dispatch_payload "Agent" "omit" "omit" "tab")
  # fixture self-check: name key present, value is exactly one tab
  [[ "$(jq -e '.tool_input | has("name")' <<< "$payload")" == "true" ]]
  [[ "$(jq -r '.tool_input.name' <<< "$payload")" == $'\t' ]]
  run_sync_guard "$payload"
  assert_sync_block
}

# ============================================================
# dispatch-sync-guard: env-var fail-open + escape hatch (7-8)
# ============================================================

@test "sync #7: CLAUDE_CODE_DISABLE_BACKGROUND_TASKS set + omitted RIB -> PASS" {
  local payload
  payload=$(mk_dispatch_payload "Task" "omit")
  run_sync_guard "$payload" "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1"
  assert_sync_pass
}

@test "sync #8: ALLOW_BACKGROUND_DISPATCH=1 + omitted RIB -> PASS" {
  local payload
  payload=$(mk_dispatch_payload "Task" "omit")
  run_sync_guard "$payload" "ALLOW_BACKGROUND_DISPATCH=1"
  assert_sync_pass
}

# ============================================================
# dispatch-sync-guard: tool_name outside {Agent, Task} (9)
# ============================================================

@test "sync #9: tool_name=Bash -> PASS (not a dispatch call)" {
  local payload
  payload=$(mk_dispatch_payload "Bash" "omit")
  [[ "$(jq -r '.tool_name' <<< "$payload")" == "Bash" ]]
  run_sync_guard "$payload"
  assert_sync_pass
}

# ============================================================
# dispatch-sync-guard: malformed stdin fail-open (10)
# ============================================================

@test "sync #10a: empty stdin -> PASS" {
  run_sync_guard ""
  assert_sync_pass
}

@test "sync #10b: truncated JSON '{' -> PASS" {
  run_sync_guard "{"
  assert_sync_pass
}

@test "sync #10c: whitespace-only stdin -> PASS" {
  run_sync_guard $'   \n  \n'
  assert_sync_pass
}

# ============================================================
# dispatch-rules-inject: normal injection shape (12)
# ============================================================

@test "inject #12: normal agent_type -> stdout is valid JSON with additionalContext" {
  local payload
  payload=$(mk_start_payload "worker")
  [[ "$(jq -r '.agent_type' <<< "$payload")" == "worker" ]]
  run_rules_inject "$payload"
  [ "$INJECT_EXIT" -eq 0 ]
  # stdout must parse as JSON
  jq -e '.hookSpecificOutput.hookEventName == "SubagentStart"' <<< "$INJECT_STDOUT" >/dev/null
  jq -e '.hookSpecificOutput.additionalContext | length > 0' <<< "$INJECT_STDOUT" >/dev/null
  local ctx
  ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<< "$INJECT_STDOUT")
  [[ "$ctx" == *"只改指定文件"* ]]
}

# ============================================================
# dispatch-rules-inject: read-only agent_type tiering (13)
# ============================================================

@test "inject #13: agent_type=Explore -> omits scope-fence wording" {
  local payload
  payload=$(mk_start_payload "Explore")
  [[ "$(jq -r '.agent_type' <<< "$payload")" == "Explore" ]]
  run_rules_inject "$payload"
  [ "$INJECT_EXIT" -eq 0 ]
  local ctx
  ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<< "$INJECT_STDOUT")
  [[ "$ctx" != *"只改指定文件"* ]]
  [[ "$ctx" == *"输出即产物"* ]]
  [[ "$ctx" == *"渐进产出"* ]]
}

@test "inject #13b: agent_type=Plan -> same read-only tier as Explore (omits scope-fence wording)" {
  local payload
  payload=$(mk_start_payload "Plan")
  [[ "$(jq -r '.agent_type' <<< "$payload")" == "Plan" ]]
  run_rules_inject "$payload"
  [ "$INJECT_EXIT" -eq 0 ]
  local ctx
  ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<< "$INJECT_STDOUT")
  [[ "$ctx" != *"只改指定文件"* ]]
  [[ "$ctx" == *"输出即产物"* ]]
  [[ "$ctx" == *"渐进产出"* ]]
}

# ============================================================
# dispatch-rules-inject: fail-open with empty stdout (14-15)
# ============================================================

@test "inject #14: empty stdin -> stdout completely empty, exit 0" {
  run_rules_inject ""
  assert_inject_empty_stdout
}

@test "inject #15: ALLOW_NO_RULES_INJECT=1 -> stdout empty, exit 0" {
  local payload
  payload=$(mk_start_payload "worker")
  run_rules_inject "$payload" "ALLOW_NO_RULES_INJECT=1"
  assert_inject_empty_stdout
}

# --- fork world (schema dropped run_in_background) ---

@test "sync #16: RIB field absent + no DISABLE env -> BLOCK with fork-specific message" {
  local payload
  payload=$(mk_dispatch_payload "Agent" "omit")
  # 夹具自检：确认 tool_input 里真的没有该键(防夹具错导致假绿)
  run jq -e '.tool_input | has("run_in_background") | not' <<< "$payload"
  [ "$status" -eq 0 ]

  run_sync_guard "$payload"
  assert_sync_block
  [[ "$SYNC_STDERR" == *"CLAUDE_CODE_FORK_SUBAGENT"* ]] || {
    echo "Expected fork-specific advice in stderr, got: $SYNC_STDERR"
    return 1
  }
  # fork 世界必须给出可执行解法。判据锚定"有没有指向 FORK_SUBAGENT 这个正解",
  # 而不是"有没有出现 ALLOW_BACKGROUND_DISPATCH 这个词"——消息里本就有一句
  # "不要改用 ALLOW_BACKGROUND_DISPATCH=1 绕过"的劝阻,按词判会与自家措辞撞车。
  # 因此这里断言:该词若出现,必须是以劝阻形态出现(带"不要")。
  [[ "$SYNC_STDERR" == *"需重启"* ]] || {
    echo "Fork-world message must state the fix requires a CC restart, got: $SYNC_STDERR"
    return 1
  }
  if [[ "$SYNC_STDERR" == *"ALLOW_BACKGROUND_DISPATCH"* ]]; then
    [[ "$SYNC_STDERR" == *"不要改用 ALLOW_BACKGROUND_DISPATCH"* ]] || {
      echo "If ALLOW_BACKGROUND_DISPATCH appears in fork-world message it must be as a warning, got: $SYNC_STDERR"
      return 1
    }
  fi
}

@test "sync #17: RIB explicitly true -> generic message, NOT the fork one" {
  local payload
  payload=$(mk_dispatch_payload "Agent" "true")
  run jq -e '.tool_input | has("run_in_background")' <<< "$payload"
  [ "$status" -eq 0 ]

  run_sync_guard "$payload"
  assert_sync_block
  [[ "$SYNC_STDERR" != *"CLAUDE_CODE_FORK_SUBAGENT"* ]] || {
    echo "Field-present block must not use the fork message, got: $SYNC_STDERR"
    return 1
  }
}

@test "sync #18: RIB string \"false\" -> generic message, NOT the fork one" {
  local payload
  payload=$(mk_dispatch_payload "Agent" "string_false")
  run_sync_guard "$payload"
  assert_sync_block
  [[ "$SYNC_STDERR" != *"CLAUDE_CODE_FORK_SUBAGENT"* ]] || {
    echo "Field-present block must not use the fork message, got: $SYNC_STDERR"
    return 1
  }
}

# ============================================================
# CLAUDE_AUTO_BACKGROUND_TASKS: even run_in_background:false is defeated
# by the runtime's own 120s auto-background flip (19-21)
# ============================================================

@test "sync #19: CLAUDE_AUTO_BACKGROUND_TASKS=1 + run_in_background:false -> BLOCK (auto-flip defeats the field)" {
  local payload
  payload=$(mk_dispatch_payload "Agent" "false")
  # fixture self-check: this payload alone would PASS absent the env var
  [[ "$(jq -r '.tool_input.run_in_background' <<< "$payload")" == "false" ]]
  run_sync_guard "$payload" "CLAUDE_AUTO_BACKGROUND_TASKS=1"
  assert_sync_block
  [[ "$SYNC_STDERR" == *"CLAUDE_AUTO_BACKGROUND_TASKS"* ]] || {
    echo "Expected CLAUDE_AUTO_BACKGROUND_TASKS wording in stderr, got: $SYNC_STDERR"
    return 1
  }
}

@test "sync #20: CLAUDE_AUTO_BACKGROUND_TASKS=0 + run_in_background:false -> PASS (tr()-falsy, not merely non-empty)" {
  local payload
  payload=$(mk_dispatch_payload "Agent" "false")
  run_sync_guard "$payload" "CLAUDE_AUTO_BACKGROUND_TASKS=0"
  assert_sync_pass
}

@test "sync #21: ambient CLAUDE_AUTO_BACKGROUND_TASKS=1 in the calling shell must not leak into the gate" {
  local payload
  payload=$(mk_dispatch_payload "Agent" "false")
  export CLAUDE_AUTO_BACKGROUND_TASKS=1
  # No override passed to run_sync_guard: the ambient export above must be
  # stripped by run_sync_guard's `env -u`, so this must still PASS as if
  # unpolluted (same isolation discipline as sync #8's sibling guards).
  run_sync_guard "$payload"
  unset CLAUDE_AUTO_BACKGROUND_TASKS
  assert_sync_pass
}
