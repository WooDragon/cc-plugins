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

@test "cap #15d: missing or null subagent_type defaults to general-purpose, so explicit haiku write dispatch blocks C for Agent and Task" {
  local tool type_mode payload
  for tool in Agent Task; do
    for type_mode in omit null; do
      payload=$(mk_cap_payload "$type_mode" "修复 main.py" "haiku")
      payload=$(jq -c --arg tool "$tool" '. + {tool_name:$tool}' <<<"$payload")
      if [[ "$type_mode" == "omit" ]]; then
        [[ "$(jq -e '.tool_input | has("subagent_type") | not' <<<"$payload")" == "true" ]]
      else
        [[ "$(jq -r '.tool_input.subagent_type' <<<"$payload")" == "null" ]]
      fi
      run_cap_guard "$payload"
      assert_cap_block "C"
    done
  done
}

@test "cap #15a: dev-econ + write prompt + model=haiku -> PASS (registered agents are outside judgment C)" {
  local payload
  payload=$(mk_cap_payload "dev-econ" "修复 main.py" "haiku")
  run_cap_guard "$payload"
  assert_cap_pass
}

@test "cap #15b: dev-econ + write prompt + model=sonnet -> PASS (registered agents are outside judgment C)" {
  local payload
  payload=$(mk_cap_payload "dev-econ" "修复 main.py" "sonnet")
  run_cap_guard "$payload"
  assert_cap_pass
}

@test "cap #15c: dev-econ + write prompt + model absent -> PASS (registered agents are outside judgment C)" {
  local payload
  payload=$(mk_cap_payload "dev-econ" "修复 main.py" "omit")
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

@test "cap #30a: empty stdin -> exit 0 with [GATE-DEGRADE] (empty stdin is a degrade path, not a silent no-signal pass)" {
  run_cap_guard_stdin ""
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

# ============================================================
# Regression: four fixed dispatch-capability defects
# (WRITE_HIT_A dead-end close, EXEC exec-intent anchor, GATE-DEGRADE for
# empty stdin / missing jq, WRITE_OBJ bug|issue|error). See preamble in
# hooks/dispatch-capability-guard.sh ("A's exemption" block comment) for
# the full trace of what each fix closes.
# ============================================================

# --- Group 1: Critical dead-end regression (judgment A + !WRITE_A) ---
# Before the fix, a mixed RO+WRITE prompt on general-purpose/claude hit
# judgment A on !EXEC alone and was told to re-dispatch to Explore — whose
# Edit/Write is physically disabled, a dead end the gate manufactured. The
# fix adds !WRITE_A to A's condition so a prompt carrying write intent no
# longer matches A at all. Exit code alone does not pin this: a future
# regression could still exit 0 while the stderr dead-end text is back
# (e.g. some other change makes A fire but stops short of exit 2), so the
# assertion below anchors on both exit AND the absence of A's specific
# re-dispatch-to-Explore wording, not just assert_cap_pass's exit check.

@test "cap #33: general-purpose + 只读查看现有实现，然后修复 main.py -> PASS, no dead-end re-dispatch-to-Explore text in stderr" {
  local payload
  payload=$(mk_cap_payload "general-purpose" "只读查看现有实现，然后修复 main.py" "omit")
  run_cap_guard "$payload"
  assert_cap_pass
  [[ "$CAP_STDERR" != *"改派内置 Explore"* ]] || {
    echo "Expected no dead-end re-dispatch-to-Explore text, got: $CAP_STDERR"
    return 1
  }
  [[ "$CAP_STDERR" != *"命中判据 A"* ]] || {
    echo "Expected judgment A to not fire, got: $CAP_STDERR"
    return 1
  }
}

@test "cap #34: general-purpose + 先只读通读一遍，再重构 auth 模块 (rephrased dead-end regression, different verb/object) -> PASS, no dead-end re-dispatch-to-Explore text" {
  local payload
  payload=$(mk_cap_payload "general-purpose" "先只读通读一遍，再重构 auth 模块" "omit")
  run_cap_guard "$payload"
  assert_cap_pass
  [[ "$CAP_STDERR" != *"改派内置 Explore"* ]] || {
    echo "Expected no dead-end re-dispatch-to-Explore text, got: $CAP_STDERR"
    return 1
  }
  [[ "$CAP_STDERR" != *"命中判据 A"* ]] || {
    echo "Expected judgment A to not fire, got: $CAP_STDERR"
    return 1
  }
}

# --- Group 2: EXEC false-positive regression (clause-anchored EXEC_HIT) ---
# Bare-keyword EXEC match must sit in an imperative/delegation clause, not a
# research-frame or negated clause, before counting as EXEC_HIT.

@test "cap #35: Explore + 查一下跑测试的脚本在哪 (research-frame CN, distinct from cap #22's comma-joined variant) -> PASS" {
  local payload
  payload=$(mk_cap_payload "explore" "查一下跑测试的脚本在哪" "omit")
  run_cap_guard "$payload"
  assert_cap_pass
}

@test "cap #36: Explore + 分析为什么不要跑测试 (negation/research-frame CN) -> PASS" {
  local payload
  payload=$(mk_cap_payload "explore" "分析为什么不要跑测试" "omit")
  run_cap_guard "$payload"
  assert_cap_pass
}

@test "cap #37: Explore + find where we document how to run the tests (research-frame EN) -> PASS" {
  local payload
  payload=$(mk_cap_payload "explore" "find where we document how to run the tests" "omit")
  run_cap_guard "$payload"
  assert_cap_pass
}

# --- Group 3: EXEC true-positive retained (guard against group 2 over-fix) ---

@test "cap #38: Explore + 请跑测试看结果 (imperative exec, no research-frame) -> BLOCK judgment B" {
  local payload
  payload=$(mk_cap_payload "explore" "请跑测试看结果" "omit")
  run_cap_guard "$payload"
  assert_cap_block "B"
}

@test "cap #39: Explore + 跑一遍测试并确认全绿 (imperative exec, no research-frame) -> BLOCK judgment B" {
  local payload
  payload=$(mk_cap_payload "explore" "跑一遍测试并确认全绿" "omit")
  run_cap_guard "$payload"
  assert_cap_block "B"
}

# --- Group 4: judgment A narrowing (!WRITE_A) stays scoped to write intent ---
# A must not have gone from "reject !EXEC" to "never reject" — pure
# read-only declarations with no write object must still block.

@test "cap #40: general-purpose + 只读调研这个模块，然后请跑测试看结果 (RO + EXEC, no WRITE object) -> PASS (EXEC_HIT suppresses A same as before, and suppresses NEEDS_CAP's RO-gated B on this TYPE)" {
  local payload
  payload=$(mk_cap_payload "general-purpose" "只读调研这个模块，然后请跑测试看结果" "omit")
  run_cap_guard "$payload"
  assert_cap_pass
}

@test "cap #41: general-purpose + 只读调研一下这个模块 (pure RO, no WRITE/EXEC at all) -> BLOCK judgment A (A is narrowed, not disabled)" {
  local payload
  payload=$(mk_cap_payload "general-purpose" "只读调研一下这个模块" "omit")
  run_cap_guard "$payload"
  assert_cap_block "A"
}

# --- Group 5: WRITE_OBJ bug|issue|error addition ---

@test "cap #42: Explore + fix the bug in auth (defect noun only, no file/code/test noun) -> BLOCK judgment B" {
  local payload
  payload=$(mk_cap_payload "explore" "fix the bug in auth" "omit")
  run_cap_guard "$payload"
  assert_cap_block "B"
}

# 中文侧 bug 的专属锚点：cap #42 走的是 RE_WRITE_EN 自己的宾语表，不经过
# WRITE_OBJ,所以删掉 WRITE_OBJ 里的 bug 时 cap #42 照样绿——中英两侧的 bug
# token 各有独立落点,只测一侧会让另一侧的删除静默通过。本例钉住 CN 侧。
# 句中刻意不含「模块」「代码」「文件」等其它 WRITE_OBJ 词：WRITE_OBJ 是并集
# 匹配,任一词表内词共现都会掩盖 bug 单独被删的效果,那样本用例就名存实亡。
@test "cap #45: Explore + 修复 auth 的 bug (CN verb + EN defect noun as the ONLY WRITE_OBJ hit) -> BLOCK judgment B" {
  local payload
  payload=$(mk_cap_payload "explore" "修复 auth 的 bug" "omit")
  run_cap_guard "$payload"
  assert_cap_block "B"
}

# --- Group 6: new GATE-DEGRADE paths (empty stdin / missing jq) ---

@test "cap #43: empty stdin -> exit 0 with [GATE-DEGRADE] and 'empty stdin' text (distinct message from cap #30a's generic check — pins the specific wording this fix introduced)" {
  run_cap_guard_stdin ""
  [ "$CAP_EXIT" -eq 0 ] || {
    echo "Expected exit 0, got $CAP_EXIT"
    echo "stderr: $CAP_STDERR"
    return 1
  }
  [[ "$CAP_STDERR" == *"[GATE-DEGRADE]"* ]] || {
    echo "Expected '[GATE-DEGRADE]' in stderr, got: $CAP_STDERR"
    return 1
  }
  [[ "$CAP_STDERR" == *"empty stdin"* ]] || {
    echo "Expected 'empty stdin' in stderr, got: $CAP_STDERR"
    return 1
  }
}

@test "cap #44: jq unavailable (isolated PATH with bash/cat/tr symlinked but no jq) -> exit 0 with [GATE-DEGRADE] and 'jq unavailable' text" {
  local payload
  payload=$(mk_cap_payload "general-purpose" "修复 main.py" "omit")
  run_cap_guard_no_jq "$payload"
  [ "$CAP_EXIT" -eq 0 ] || {
    echo "Expected exit 0, got $CAP_EXIT"
    echo "stderr: $CAP_STDERR"
    return 1
  }
  [[ "$CAP_STDERR" == *"[GATE-DEGRADE]"* ]] || {
    echo "Expected '[GATE-DEGRADE]' in stderr, got: $CAP_STDERR"
    return 1
  }
  [[ "$CAP_STDERR" == *"jq unavailable"* ]] || {
    echo "Expected 'jq unavailable' in stderr, got: $CAP_STDERR"
    return 1
  }
}

@test "cap #46: copied hook without agent-kind.sh fails open with [GATE-DEGRADE]" {
  local copied_guard payload
  copied_guard="$TEST_TEMP_DIR/dependency-missing/dispatch-capability-guard.sh"
  mkdir -p "${copied_guard%/*}"
  cp "$CAP_GUARD_SCRIPT" "$copied_guard"

  payload=$(mk_cap_payload "explore" "修复 main.py" "omit")
  run_cap_guard_script "$copied_guard" "$payload"
  [ "$CAP_EXIT" -eq 0 ] || {
    echo "Expected dependency-missing copied hook to fail open, got $CAP_EXIT: $CAP_STDERR"
    return 1
  }
  [[ "$CAP_STDERR" == *"[GATE-DEGRADE]"* && "$CAP_STDERR" == *"agent-kind.sh unavailable"* ]] || {
    echo "Expected agent-kind dependency degrade, got: $CAP_STDERR"
    return 1
  }
}

@test "cap #47: A and B rejection exits provide complete executable dispatch fields" {
  local payload
  payload=$(mk_cap_payload "general-purpose" "只读调研，查看代码逻辑" "sonnet")
  run_cap_guard "$payload"
  assert_cap_block "A"
  [[ "$CAP_STDERR" == *'Agent(subagent_type="Explore", model="sonnet", ...)'* ]] || {
    echo "Expected complete Explore re-dispatch fields, got: $CAP_STDERR"
    return 1
  }

  payload=$(mk_cap_payload "explore" "修复 main.py" "omit")
  run_cap_guard "$payload"
  assert_cap_block "B"
  [[ "$CAP_STDERR" == *'Agent(subagent_type="general-purpose", model="sonnet", ...)'* ]] || {
    echo "Expected complete general-purpose re-dispatch fields, got: $CAP_STDERR"
    return 1
  }
  [[ "$CAP_STDERR" == *'Agent(subagent_type="dev", ...)'* && "$CAP_STDERR" == *"省略 model"* ]] || {
    echo "Expected registered-agent model ownership guidance, got: $CAP_STDERR"
    return 1
  }
}
