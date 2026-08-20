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
