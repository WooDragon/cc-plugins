#!/usr/bin/env bats
# BDD tests for dispatch-capability-guard.sh (PreToolUse hook, matcher:
# Agent/Task): blocks ad-hoc dispatch calls whose subagent_type/model cannot
# deliver what the prompt itself asks for.
#
# Three independent judgments, single trailing `exit 2`:
#   A: !EXEC && (RO||NEG) && TYPE in {general-purpose, claude}  (read-only
#      declaration sent to a full-privilege agent)
#   B: NEEDS_CAP && TYPE in {explore, plan}  (write/exec need sent to a
#      read-only-capability agent)
#   C: NEEDS_CAP && model contains "haiku"  (write/exec need sent to haiku)
#
# BLOCK is exit 2 + "命中判据 <letter>" in stderr (see assert_cap_block, which
# anchors on which judgment fired, not exit code alone — a stray path that
# also exits 2 for an unrelated reason must not pass).
# PASS is exit 0, no "dispatch-capability-guard" in stderr.
#
# Fixture self-check discipline: this suite has previously been bitten by a
# fixture bug disguising itself as a passing fail-open gate (printf eating a
# marker's percent sign — see feedback-printf-eats-percent-marker memory).
# Payload-builder-driven tests below re-read the built payload with jq before
# running the gate, to confirm the fixture carries the field shape claimed.

setup() {
  load 'test_helper/common-setup'
  common_setup
}

teardown() {
  common_teardown
}

# ============================================================
# Four-quadrant matrix on Explore: (EXEC||WRITE) x (RO||NEG)
# ============================================================

@test "cap #1: Explore, WRITE hit + no RO/NEG -> BLOCK judgment B" {
  local payload
  payload=$(mk_cap_payload "explore" "修复 main.py" "omit")
  [[ "$(jq -r '.tool_input.subagent_type' <<< "$payload")" == "explore" ]]
  run_cap_guard "$payload"
  assert_cap_block "B"
}

@test "cap #2: Explore, EXEC hit + no RO/NEG -> BLOCK judgment B" {
  local payload
  payload=$(mk_cap_payload "explore" "跑测试" "omit")
  run_cap_guard "$payload"
  assert_cap_block "B"
}

@test "cap #3: Explore, WRITE hit + RO hit (mixed prompt, e.g. 调研根因并修复) -> PASS (accepted under-block)" {
  local payload
  payload=$(mk_cap_payload "explore" "调研根因并修复" "omit")
  run_cap_guard "$payload"
  assert_cap_pass
}

@test "cap #4: Explore, neither EXEC/WRITE nor RO/NEG -> PASS" {
  local payload
  payload=$(mk_cap_payload "explore" "请完成任务并汇报结果" "omit")
  run_cap_guard "$payload"
  assert_cap_pass
}

# ============================================================
# Judgment A: !EXEC && (RO||NEG) && TYPE in {general-purpose, claude}
# ============================================================

@test "cap #5: general-purpose + RO declaration -> BLOCK judgment A" {
  local payload
  payload=$(mk_cap_payload "general-purpose" "只读调研，查看代码逻辑" "omit")
  run_cap_guard "$payload"
  assert_cap_block "A"
}

@test "cap #6: claude + RO declaration -> BLOCK judgment A" {
  local payload
  payload=$(mk_cap_payload "claude" "只读调研，查看代码逻辑" "omit")
  run_cap_guard "$payload"
  assert_cap_block "A"
}

@test "cap #7: Explore + RO declaration -> PASS (this is the correct dispatch, not a miss)" {
  local payload
  payload=$(mk_cap_payload "explore" "只读调研，查看代码逻辑" "omit")
  run_cap_guard "$payload"
  assert_cap_pass
}

# ============================================================
# Judgment B: NEEDS_CAP && TYPE in {explore, plan}
# ============================================================

@test "cap #8: Explore + write prompt (修复 main.py) -> BLOCK judgment B" {
  local payload
  payload=$(mk_cap_payload "explore" "修复 main.py" "omit")
  run_cap_guard "$payload"
  assert_cap_block "B"
}

@test "cap #9: Plan + exec prompt (跑测试确认通过) -> BLOCK judgment B" {
  local payload
  payload=$(mk_cap_payload "plan" "跑测试确认通过" "omit")
  run_cap_guard "$payload"
  assert_cap_block "B"
}

@test "cap #10: general-purpose + write prompt (修复 main.py) -> PASS (full-privilege agent can do this)" {
  local payload
  payload=$(mk_cap_payload "general-purpose" "修复 main.py" "omit")
  run_cap_guard "$payload"
  assert_cap_pass
}

# ============================================================
# Judgment C: NEEDS_CAP && model contains "haiku"
# ============================================================

@test "cap #11: general-purpose + write prompt + model=haiku (bare) -> BLOCK judgment C" {
  local payload
  payload=$(mk_cap_payload "general-purpose" "修复 main.py" "haiku")
  [[ "$(jq -r '.tool_input.model' <<< "$payload")" == "haiku" ]]
  run_cap_guard "$payload"
  assert_cap_block "C"
}

@test "cap #12: general-purpose + write prompt + model=claude-haiku-4-5-20251001 (full ID) -> BLOCK judgment C" {
  local payload
  payload=$(mk_cap_payload "general-purpose" "修复 main.py" "claude-haiku-4-5-20251001")
  run_cap_guard "$payload"
  assert_cap_block "C"
}

@test "cap #13: general-purpose + write prompt + model=HAIKU (uppercase) -> BLOCK judgment C" {
  local payload
  payload=$(mk_cap_payload "general-purpose" "修复 main.py" "HAIKU")
  run_cap_guard "$payload"
  assert_cap_block "C"
}

@test "cap #14: general-purpose + write prompt + model=sonnet -> PASS" {
  local payload
  payload=$(mk_cap_payload "general-purpose" "修复 main.py" "sonnet")
  run_cap_guard "$payload"
  assert_cap_pass
}

@test "cap #15: general-purpose + write prompt + model field absent -> PASS" {
  local payload
  payload=$(mk_cap_payload "general-purpose" "修复 main.py" "omit")
  # fixture self-check: model key genuinely absent from tool_input
  [[ "$(jq -e '.tool_input | has("model") | not' <<< "$payload")" == "true" ]]
  run_cap_guard "$payload"
  assert_cap_pass
}

# ============================================================
# WRITE anchoring: syntactic shape, not bare keyword
# ============================================================

@test "cap #16: Explore + 修复 main.py (verb + path token) -> BLOCK judgment B" {
  local payload
  payload=$(mk_cap_payload "explore" "修复 main.py" "omit")
  run_cap_guard "$payload"
  assert_cap_block "B"
}

@test "cap #17: Explore + 重构 auth 模块 (verb + object noun) -> BLOCK judgment B" {
  local payload
  payload=$(mk_cap_payload "explore" "重构 auth 模块" "omit")
  run_cap_guard "$payload"
  assert_cap_block "B"
}

@test "cap #18: Explore + implement the function (EN verb + object noun) -> BLOCK judgment B" {
  local payload
  payload=$(mk_cap_payload "explore" "implement the function" "omit")
  run_cap_guard "$payload"
  assert_cap_block "B"
}

@test "cap #19: Explore + 创建一份调研报告 (bare verb, non-code object) -> PASS (report is not code)" {
  local payload
  payload=$(mk_cap_payload "explore" "创建一份调研报告" "omit")
  run_cap_guard "$payload"
  assert_cap_pass
}

@test "cap #20: Explore + 写一篇讨论只读门禁的文档 (bare verb, doc object) -> PASS" {
  local payload
  payload=$(mk_cap_payload "explore" "写一篇讨论只读门禁的文档" "omit")
  run_cap_guard "$payload"
  assert_cap_pass
}

# ============================================================
# Mixed-task deliberate miss (pin the accepted boundary)
# ============================================================

@test "cap #21: Explore + 调研根因并修复 (mixed RO+WRITE) -> PASS (deliberately accepted under-block, do not 'fix' this later)" {
  local payload
  payload=$(mk_cap_payload "explore" "调研根因并修复" "omit")
  run_cap_guard "$payload"
  assert_cap_pass
}

# ============================================================
# False-positive defense
# ============================================================

@test "cap #22: Explore + 查一下跑测试的脚本在哪，只读调研 -> PASS" {
  local payload
  payload=$(mk_cap_payload "explore" "查一下跑测试的脚本在哪，只读调研" "omit")
  run_cap_guard "$payload"
  assert_cap_pass
}

# ============================================================
# Double negation scrub
# ============================================================

@test "cap #23: 不得不改代码 must not be read as RO declaration (general-purpose -> PASS, no judgment A)" {
  local payload
  payload=$(mk_cap_payload "general-purpose" "不得不改代码" "omit")
  run_cap_guard "$payload"
  assert_cap_pass
}

@test "cap #24: 不得不修改代码 (double-negation write) on Explore -> BLOCK judgment B (it IS a write task, not RO)" {
  local payload
  payload=$(mk_cap_payload "explore" "不得不修改代码" "omit")
  run_cap_guard "$payload"
  assert_cap_block "B"
}

@test "cap #25: 不得不改测试，仍需继续跑 (double-negation, comma-separated clause with no independent NEG object) -> PASS on general-purpose (no judgment A)" {
  local payload
  payload=$(mk_cap_payload "general-purpose" "不得不改测试，仍需继续跑" "omit")
  run_cap_guard "$payload"
  assert_cap_pass
}

@test "cap #25b: 不得不改测试，不修改任何文件 -> BLOCK judgment A on general-purpose (the second clause is its OWN independent absolute negation, not part of the double-negation span — traced: RE_DOUBLE_NEG only consumes 不得不改, leaving 不修改任何文件 intact for RE_NEG to match; this is correct, not a false positive)" {
  local payload
  payload=$(mk_cap_payload "general-purpose" "不得不改测试，不修改任何文件" "omit")
  run_cap_guard "$payload"
  assert_cap_block "A"
}

# ============================================================
# Exclusive write-scope exemption (dispatch-contract rule 2 wording)
# ============================================================

@test "cap #26: 只改测试，不改代码 on general-purpose -> PASS (scope fencing, not an RO declaration)" {
  local payload
  payload=$(mk_cap_payload "general-purpose" "只改测试，不改代码" "omit")
  run_cap_guard "$payload"
  assert_cap_pass
}

@test "cap #27: 不要只改测试 (left-boundary: negated-scope prefix must not fake the exemption) -> PASS on general-purpose (no WRITE/EXEC object -> NEEDS_CAP=0, no judgment fires)" {
  local payload
  payload=$(mk_cap_payload "general-purpose" "不要只改测试" "omit")
  run_cap_guard "$payload"
  assert_cap_pass
}

@test "cap #27b: 不要只改测试，不改代码 (left-boundary with absolute-negation object present) -> BLOCK judgment A (真否定声明，非排他豁免)" {
  local payload
  payload=$(mk_cap_payload "general-purpose" "不要只改测试，不改代码" "omit")
  run_cap_guard "$payload"
  assert_cap_block "A"
}

# ============================================================
# B + C combined
# ============================================================

@test "cap #28: Explore + haiku + 跑测试 -> exit 2 with BOTH judgment B and C messages present" {
  local payload
  payload=$(mk_cap_payload "explore" "跑测试" "haiku")
  run_cap_guard "$payload"
  [ "$CAP_EXIT" -eq 2 ] || {
    echo "Expected exit 2, got $CAP_EXIT"
    echo "stderr: $CAP_STDERR"
    return 1
  }
  [[ "$CAP_STDERR" == *"命中判据 B"* ]] || {
    echo "Expected '命中判据 B' in stderr, got: $CAP_STDERR"
    return 1
  }
  [[ "$CAP_STDERR" == *"命中判据 C"* ]] || {
    echo "Expected '命中判据 C' in stderr, got: $CAP_STDERR"
    return 1
  }
}

# ============================================================
# Escape hatch
# ============================================================

@test "cap #29: judgment-B payload + ALLOW_DISPATCH_CAPABILITY_MISMATCH=1 -> exit 0 with [GATE-BYPASS]" {
  local payload
  payload=$(mk_cap_payload "explore" "修复 main.py" "omit")
  run_cap_guard "$payload" "ALLOW_DISPATCH_CAPABILITY_MISMATCH=1"
  [ "$CAP_EXIT" -eq 0 ] || {
    echo "Expected exit 0, got $CAP_EXIT"
    echo "stderr: $CAP_STDERR"
    return 1
  }
  [[ "$CAP_STDERR" == *"[GATE-BYPASS]"* ]] || {
    echo "Expected '[GATE-BYPASS]' in stderr, got: $CAP_STDERR"
    return 1
  }
}

# ============================================================
# Malformed input fail-open
# ============================================================

@test "cap #30a: empty stdin -> PASS" {
  run_cap_guard_stdin ""
  assert_cap_pass
}

@test "cap #30b: non-JSON string stdin -> exit 0 (fail-open via [GATE-DEGRADE], not assert_cap_pass — that helper's stderr check is for the no-signal case, but jq extraction failure legitimately logs [GATE-DEGRADE] with the hook's own name while still exiting 0)" {
  run_cap_guard_stdin "not json at all"
  [ "$CAP_EXIT" -eq 0 ] || {
    echo "Expected exit 0, got $CAP_EXIT"
    echo "stderr: $CAP_STDERR"
    return 1
  }
  [[ "$CAP_STDERR" == *"[GATE-DEGRADE]"* ]] || {
    echo "Expected '[GATE-DEGRADE]' in stderr, got: $CAP_STDERR"
    return 1
  }
}

@test "cap #30c: tool_input:null -> PASS" {
  local payload
  payload=$(mk_cap_payload_null_input)
  [[ "$(jq -r '.tool_input' <<< "$payload")" == "null" ]]
  run_cap_guard "$payload"
  assert_cap_pass
}

@test "cap #30d: prompt field missing entirely -> PASS" {
  local payload
  payload=$(mk_cap_payload "explore" "" "omit" "omit")
  # fixture self-check: prompt key genuinely absent
  [[ "$(jq -e '.tool_input | has("prompt") | not' <<< "$payload")" == "true" ]]
  run_cap_guard "$payload"
  assert_cap_pass
}

@test "cap #30e: prompt field present but empty string -> PASS" {
  local payload
  payload=$(mk_cap_payload "explore" "" "omit")
  [[ "$(jq -e '.tool_input | has("prompt")' <<< "$payload")" == "true" ]]
  [[ "$(jq -r '.tool_input.prompt' <<< "$payload")" == "" ]]
  run_cap_guard "$payload"
  assert_cap_pass
}

# ============================================================
# subagent_type default (absent -> general-purpose)
# ============================================================

@test "cap #31: subagent_type absent + RO declaration -> BLOCK judgment A (defaults to general-purpose)" {
  local payload
  payload=$(mk_cap_payload "omit" "只读调研，查看代码逻辑" "omit")
  # fixture self-check: subagent_type key genuinely absent
  [[ "$(jq -e '.tool_input | has("subagent_type") | not' <<< "$payload")" == "true" ]]
  run_cap_guard "$payload"
  assert_cap_block "A"
}

# ============================================================
# Case folding on subagent_type (judgment B)
# ============================================================

@test "cap #32a: subagent_type=EXPLORE (uppercase) + write prompt -> BLOCK judgment B" {
  local payload
  payload=$(mk_cap_payload "EXPLORE" "修复 main.py" "omit")
  run_cap_guard "$payload"
  assert_cap_block "B"
}

@test "cap #32b: subagent_type=Explore (mixed case) + write prompt -> BLOCK judgment B" {
  local payload
  payload=$(mk_cap_payload "Explore" "修复 main.py" "omit")
  run_cap_guard "$payload"
  assert_cap_block "B"
}

@test "cap #32c: subagent_type=explore (lowercase) + write prompt -> BLOCK judgment B" {
  local payload
  payload=$(mk_cap_payload "explore" "修复 main.py" "omit")
  run_cap_guard "$payload"
  assert_cap_block "B"
}
