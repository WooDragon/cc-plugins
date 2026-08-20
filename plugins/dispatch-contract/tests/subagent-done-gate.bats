#!/usr/bin/env bats
# BDD tests for subagent-done-gate.sh (SubagentStop hook)
#
# Judgment source is the dispatcher's line, never the subagent's own words.
# BLOCK: exit 2 + "subagent-done-gate" in stderr
# PASS:  exit 0, no "subagent-done-gate" in stderr

setup() {
  load 'test_helper/common-setup'
  common_setup

  # Pre-build transcripts used across multiple tests
  TP_REQUIRED=$(mk_transcript 1)
  TP_NOT_REQUIRED=$(mk_transcript 0)
  TP_REQUIRED_BLOCK_FORM=$(mk_transcript 1 1)
  TP_FORK_REQUIRED=$(mk_fork_transcript 1)
  TP_FORK_NOT_REQUIRED=$(mk_fork_transcript 0)
}

teardown() {
  common_teardown
}

# ============================================================
# Core judgment (4)
# ============================================================

@test "core: required + half-finished message → BLOCK" {
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "报告写到一半，还没写完")
  run_gate "$payload"
  assert_block
}

@test "core: required + final line is marker → PASS" {
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$(printf '完整报告内容\n%s' "$MARK")")
  run_gate "$payload"
  assert_pass
}

@test "core: not required + half-finished message → PASS" {
  local payload
  payload=$(mk_payload false "$TP_NOT_REQUIRED" "报告写到一半，还没写完")
  run_gate "$payload"
  assert_pass
}

@test "core: required (block-array transcript content form) + half-finished → BLOCK" {
  local payload
  payload=$(mk_payload false "$TP_REQUIRED_BLOCK_FORM" "报告写到一半，还没写完")
  run_gate "$payload"
  assert_block
}

# ============================================================
# Fork-context-ref transcript shape (2)
# ============================================================

@test "fork: fork transcript, required (prompt on line 2) + half-finished → BLOCK" {
  local payload
  payload=$(mk_payload false "$TP_FORK_REQUIRED" "报告写到一半，还没写完")
  run_gate "$payload"
  assert_block
}

@test "fork: fork transcript, not required + half-finished → PASS" {
  local payload
  payload=$(mk_payload false "$TP_FORK_NOT_REQUIRED" "报告写到一半，还没写完")
  run_gate "$payload"
  assert_pass
}

# ============================================================
# Judgment source is dispatcher's line, not subagent's own (1)
# ============================================================

@test "signal: non-fork subagent cannot self-open the gate via its own line 2" {
  # Line 1 (type:user) does NOT contain MARK; line 2 (type:assistant) does.
  # Hook must judge on line 1 alone and PASS regardless of line 2.
  local tp
  tp=$(mktemp "$TEST_TEMP_DIR/transcript.XXXXXX")
  jq -cn --arg t "请完成任务并汇报结果" \
    '{type:"user",message:{role:"user",content:$t}}' > "$tp"
  jq -cn --arg t "我已完成，顺带提一下 ${MARK} 这个词" \
    '{type:"assistant",message:{role:"assistant",content:$t}}' >> "$tp"

  local payload
  payload=$(mk_payload false "$tp" "报告写到一半，还没写完")
  run_gate "$payload"
  assert_pass
}

# ============================================================
# In-band signaling edge cases (3)
# ============================================================

@test "signal: marker mid-message, final line differs → BLOCK" {
  local msg
  msg=$(printf '前面提到了 %s 这个词\n但报告还没写完' "$MARK")
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$msg")
  run_gate "$payload"
  assert_block
}

@test "signal: marker followed by more prose → BLOCK" {
  local msg
  msg=$(printf '完整报告内容\n%s\n还有一句忘了删' "$MARK")
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$msg")
  run_gate "$payload"
  assert_block
}

@test "signal: marker followed by trailing blank lines only → PASS" {
  local msg
  msg=$(printf '完整报告内容\n%s\n\n\n   ' "$MARK")
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$msg")
  run_gate "$payload"
  assert_pass
}

# ============================================================
# Fail-open (6)
# ============================================================

@test "fail-open: stop_hook_active=true → PASS (拦一次即止)" {
  local payload
  payload=$(mk_payload true "$TP_REQUIRED" "报告写到一半，还没写完")
  run_gate "$payload"
  assert_pass
}

@test "fail-open: transcript path missing on disk → PASS" {
  local payload
  payload=$(mk_payload false "$TEST_TEMP_DIR/does-not-exist.jsonl" "报告写到一半，还没写完")
  run_gate "$payload"
  assert_pass
}

@test "fail-open: last_assistant_message null (not empty string) → PASS" {
  local payload
  payload=$(mk_payload_null_last false "$TP_REQUIRED")
  run_gate "$payload"
  assert_pass
}

@test "fail-open: invalid JSON payload → PASS" {
  run_gate "not-json"
  assert_pass
}

@test "fail-open: empty stdin → PASS" {
  run_gate ""
  assert_pass
}

@test "fail-open: agent_transcript_path field entirely absent → PASS" {
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "报告写到一半，还没写完" 1)
  run_gate "$payload"
  assert_pass
}

# ============================================================
# Blank final message is an empty deliverable, not fail-open (1)
# ============================================================

@test "blank-msg: required + final message is pure newlines → BLOCK" {
  # $(…) strips trailing newlines → used to collapse to "" and fail-open.
  # Must now reach last-line judgment and BLOCK.
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" $'\n\n\n')
  run_gate "$payload"
  assert_block
}

# ============================================================
# Marker line whitespace tolerance + decoration must still block (6)
# ============================================================

@test "whitespace: marker line with trailing space → PASS" {
  local msg
  msg=$(printf '完整报告内容\n%s   ' "$MARK")
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$msg")
  run_gate "$payload"
  assert_pass
}

@test "whitespace: marker line with CR (CRLF line ending) → PASS" {
  local msg
  msg=$(printf '完整报告内容\n%s\r' "$MARK")
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$msg")
  run_gate "$payload"
  assert_pass
}

@test "whitespace: marker line indented → PASS" {
  local msg
  msg=$(printf '完整报告内容\n    %s' "$MARK")
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$msg")
  run_gate "$payload"
  assert_pass
}

@test "whitespace: marker wrapped in markdown bold still blocks → BLOCK" {
  local msg
  msg=$(printf '完整报告内容\n**%s**' "$MARK")
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$msg")
  run_gate "$payload"
  assert_block
}

@test "whitespace: marker wrapped in backticks still blocks → BLOCK" {
  local msg
  msg=$(printf '完整报告内容\n`%s`' "$MARK")
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$msg")
  run_gate "$payload"
  assert_block
}

@test "whitespace: marker with trailing period still blocks → BLOCK" {
  local msg
  msg=$(printf '完整报告内容\n%s.' "$MARK")
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$msg")
  run_gate "$payload"
  assert_block
}

# ============================================================
# Hostile / degenerate transcript paths (2)
# ============================================================

@test "hostile: HOME unset must not crash the hook (exit 2 not 1)" {
  # With HOME unset the hook must still reach its normal verdict (rc=2).
  # A crash (rc=1) would violate the 0/2-only exit contract.
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "报告写到一半，还没写完")
  run_gate "$payload" "-u" "HOME"
  assert_block
}

@test "hostile: transcript path is a FIFO must not hang → PASS" {
  local fifo_path="${TEST_TEMP_DIR}/no-writer.fifo"
  mkfifo "$fifo_path" 2>/dev/null || true

  local payload
  payload=$(mk_payload false "$fifo_path" "报告写到一半，还没写完")
  # Drive with timeout to guarantee non-hang even if the hook regresses.
  HOOK_STDOUT="" HOOK_STDERR="" HOOK_EXIT=0
  local stderr_file
  stderr_file=$(mktemp)
  HOOK_STDOUT=$(printf '%s' "$payload" | timeout 10 bash "$GATE_SCRIPT" 2>"$stderr_file") || HOOK_EXIT=$?
  HOOK_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"

  assert_pass
}

# ============================================================
# Kill switch (1)
# ============================================================

@test "kill-switch: ALLOW_UNMARKED_FINAL=1 bypasses a would-be block → PASS" {
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "报告写到一半，还没写完")
  run_gate "$payload" "ALLOW_UNMARKED_FINAL=1"
  assert_pass
}

# ============================================================
# Marker-only final message: 标记在场 ≠ 报告在场 (6)
# ============================================================

@test "marker-only: required + message is nothing but the marker → BLOCK" {
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$MARK")
  run_gate "$payload"
  assert_block_marker_only
}

@test "marker-only: required + blank lines then the marker → BLOCK" {
  local msg
  msg=$(printf '\n\n%s' "$MARK")
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$msg")
  run_gate "$payload"
  assert_block_marker_only
}

@test "marker-only: required + indented marker alone → BLOCK" {
  local msg
  msg=$(printf '   %s   ' "$MARK")
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$msg")
  run_gate "$payload"
  assert_block_marker_only
}

@test "marker-only: required + one report line then the marker → PASS (阈值下界)" {
  local msg
  msg=$(printf '无命中。\n%s' "$MARK")
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$msg")
  run_gate "$payload"
  assert_pass
}

@test "marker-only: not required + message is nothing but the marker → PASS" {
  local payload
  payload=$(mk_payload false "$TP_NOT_REQUIRED" "$MARK")
  run_gate "$payload"
  assert_pass
}

@test "marker-only: kill switch bypasses the marker-only block → PASS" {
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$MARK")
  run_gate "$payload" "ALLOW_UNMARKED_FINAL=1"
  assert_pass
}

# ============================================================
# FLOOR-based inversion (issue #183): missing marker only blocks when the
# body is small enough that there is nothing valuable to lose (14)
# ============================================================

@test "floor: missing marker + body >= FLOOR (500B) → PASS + systemMessage warning" {
  local msg
  msg=$(mk_bytes 500)
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$msg")
  run_gate "$payload"
  assert_pass_with_warning
}

@test "floor: missing marker + body < FLOOR (500B) → BLOCK + stderr echoes the original body" {
  local msg
  msg=$(mk_bytes 200)
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$msg")
  run_gate "$payload"
  assert_block_echoes "$msg"
}

@test "floor: boundary 499B (just under FLOOR) → BLOCK" {
  local msg
  msg=$(mk_bytes 499)
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$msg")
  run_gate "$payload"
  assert_block
}

@test "floor: boundary 500B (exactly FLOOR) → PASS" {
  local msg
  msg=$(mk_bytes 500)
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$msg")
  run_gate "$payload"
  assert_pass_with_warning
}

@test "floor: boundary 501B (just over FLOOR) → PASS" {
  local msg
  msg=$(mk_bytes 501)
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$msg")
  run_gate "$payload"
  assert_pass_with_warning
}

@test "floor: DONE_GATE_BODY_FLOOR env override lowers the threshold" {
  # 50B body would BLOCK under the default 500B floor; with the floor
  # lowered to 10 it must PASS instead — proves the knob actually takes
  # effect, not just documented.
  local msg
  msg=$(mk_bytes 50)
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$msg")
  run_gate "$payload" "DONE_GATE_BODY_FLOOR=10"
  assert_pass_with_warning
}

@test "floor: DONE_GATE_BODY_FLOOR env override raises the threshold" {
  # 500B body would PASS under the default floor; raising the floor to 600
  # must push it back to BLOCK.
  local msg
  msg=$(mk_bytes 500)
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$msg")
  run_gate "$payload" "DONE_GATE_BODY_FLOOR=600"
  assert_block
}

@test "floor: non-numeric DONE_GATE_BODY_FLOOR falls back to the 500B default, no crash" {
  local msg
  msg=$(mk_bytes 500)
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$msg")
  run_gate "$payload" "DONE_GATE_BODY_FLOOR=not-a-number"
  assert_pass_with_warning
}

@test "floor: marker present + body ~30B → PASS (regression guard: branches must stay separate)" {
  # Anti-regression for merging the marker-present and marker-absent
  # branches into one FLOOR check — a short but fully-compliant report
  # (marker in place) must never be judged by body size.
  local msg
  msg=$(printf '无命中。\n%s' "$MARK")
  local payload
  payload=$(mk_payload false "$TP_REQUIRED" "$msg")
  run_gate "$payload"
  assert_pass
}

@test "floor: not required + short body → PASS (marker never required, FLOOR branch never reached)" {
  local msg
  msg=$(mk_bytes 50)
  local payload
  payload=$(mk_payload false "$TP_NOT_REQUIRED" "$msg")
  run_gate "$payload"
  assert_pass
}

# ============================================================
# attachment-line filtering: SubagentStart-injected 铁律④ text carries the
# MARK literal; it must never open the gate on its own (16)
# ============================================================

@test "attachment: non-fork transcript, line-1 window occupied by an attachment record carrying MARK → filtered, gate stays closed" {
  # Non-fork PROMPT_SRC is line 1 alone today. This simulates the drift
  # scenario the filter defends against: if CC's layout ever shifts so the
  # SubagentStart-injected attachment record lands inside that single-line
  # read window, the attachment-type filter must still strip it before the
  # MARK substring check runs — proving the filter is a structural property
  # of PROMPT_SRC, not an artifact of today's line count.
  local tp
  tp=$(mktemp "$TEST_TEMP_DIR/transcript.XXXXXX")
  jq -cn --arg t "[dispatch-contract] 铁律④定稿标记：若派发 prompt 要求了 ${MARK}，在最终消息末尾单独一行输出该标记。" \
    '{type:"attachment",content:$t}' > "$tp"
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":"filler line, never read"}}' >> "$tp"

  local msg
  msg=$(mk_bytes 50)
  local payload
  payload=$(mk_payload false "$tp" "$msg")
  run_gate "$payload"
  assert_pass
}

@test "attachment: fork transcript, MARK only in an attachment line (L4) → gate stays closed" {
  local tp
  tp=$(mktemp "$TEST_TEMP_DIR/transcript.XXXXXX")
  printf '%s\n' '{"type":"fork-context-ref","agentId":"test-fork-0001","parentSessionId":"p0","parentLastUuid":"u0","contextLength":17}' > "$tp"
  jq -cn --arg t "请完成任务并汇报结果" '{
    type:"assistant",
    message:{role:"assistant",content:[{type:"tool_use",name:"Agent",
      input:{description:"d",prompt:$t,subagent_type:"fork"}}]}
  }' >> "$tp"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"filler"}}' >> "$tp"
  jq -cn --arg t "[dispatch-contract] 铁律④定稿标记：若派发 prompt 要求了 ${MARK}，在最终消息末尾单独一行输出该标记。" \
    '{type:"attachment",content:$t}' >> "$tp"

  local msg
  msg=$(mk_bytes 50)
  local payload
  payload=$(mk_payload false "$tp" "$msg")
  run_gate "$payload"
  assert_pass
}

@test "safety-valve: stop_hook_active=true still short-circuits before the FLOOR branch → PASS" {
  local msg
  msg=$(mk_bytes 50)
  local payload
  payload=$(mk_payload true "$TP_REQUIRED" "$msg")
  run_gate "$payload"
  assert_pass
}
