#!/usr/bin/env bats
# BDD tests for brain-route-gate.sh — routing reminder for local memory writes.

load 'test_helper/common-setup'

setup() {
  common_setup
}

teardown() {
  common_teardown
}

# --- Path filter ---

@test "non-memory .md path → allow" {
  INPUT=$(build_write_input file_path=/project/docs/guide.md content="worktree hook fail-open") \
    run_gate
  assert_allowed
}

@test "memory path but MEMORY.md itself → allow" {
  INPUT=$(build_write_input file_path=/project/projects/x/memory/MEMORY.md content="worktree hook fail-open") \
    run_gate
  assert_allowed
}

@test "memory path but memory.md (lowercase) → allow (case-insensitive basename)" {
  INPUT=$(build_write_input file_path=/project/projects/x/memory/memory.md content="worktree 门禁 fail-open") \
    run_gate
  assert_allowed
}

@test "memory path but Memory.md (mixed case) → allow (case-insensitive basename)" {
  INPUT=$(build_write_input file_path=/project/projects/x/memory/Memory.md content="worktree 门禁 fail-open") \
    run_gate
  assert_allowed
}

# --- Content threshold ---

@test "memory path + content signal words below threshold → allow" {
  INPUT=$(build_write_input file_path=/project/projects/x/memory/lesson.md content="just a note about worktree setup") \
    run_gate
  assert_allowed
}

@test "memory path + content signal words reach threshold → deny" {
  INPUT=$(build_write_input file_path=/project/projects/x/memory/lesson.md content="在 worktree 里改了 hook 的 fail-open 逻辑") \
    run_gate
  assert_deny_json
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"brain-recall"* ]]
}

@test "BRAIN_ROUTE_MIN_HITS is configurable: lowering threshold to 1 turns a single-signal-word write into deny" {
  INPUT=$(build_write_input file_path=/project/projects/x/memory/lesson.md content="just a note about worktree setup") \
    BRAIN_ROUTE_MIN_HITS=1 run_gate
  assert_deny_json
}

# --- Word-boundary false positives (generic ASCII words dropped from signal list) ---

@test "false positive guard: 'digital github commitment' (git/commit substrings) → allow" {
  INPUT=$(build_write_input file_path=/project/projects/x/memory/lesson.md content="digital github commitment 的产品规划文档") \
    run_gate
  assert_allowed
}

@test "false positive guard: 'timeout 30s, index built on user_id' → allow" {
  INPUT=$(build_write_input file_path=/project/projects/x/memory/lesson.md content="这个 API 的 timeout 设成 30s，index 建在 user_id 上") \
    run_gate
  assert_allowed
}

@test "false positive guard: 'git branch/commit naming convention note' → allow" {
  INPUT=$(build_write_input file_path=/project/projects/x/memory/lesson.md content="git 分支命名约定：feature/xxx，commit 用中文") \
    run_gate
  assert_allowed
}

# --- Genuine cross-project lessons still deny after signal-word list narrowing ---

@test "genuine lesson: worktree stale main branch causes fake green → deny" {
  INPUT=$(build_write_input file_path=/project/projects/x/memory/lesson.md content="worktree 里跑测试打到主仓旧码，全绿是假绿") \
    run_gate
  assert_deny_json
}

@test "genuine lesson: printf eats percent sign in gate fixtures → deny" {
  INPUT=$(build_write_input file_path=/project/projects/x/memory/lesson.md content="造门禁夹具时 printf 会吃掉百分号，须用 heredoc") \
    run_gate
  assert_deny_json
}

@test "genuine lesson: parallel subagents share .git state, commit dangles → deny" {
  INPUT=$(build_write_input file_path=/project/projects/x/memory/lesson.md content="并行派 subagent 时 .git 是共享状态，commit 会悬空") \
    run_gate
  assert_deny_json
}

# --- Per-file marker ---

@test "first call denies and writes marker; same session same file second call → allow" {
  local file_path="/project/projects/x/memory/lesson.md"
  local session="test-session"

  # First call: real deny, must actually write the marker file itself.
  INPUT=$(build_write_input file_path="$file_path" session_id="$session" content="在 worktree 里改了 hook 的 fail-open 逻辑") \
    run_gate
  assert_deny_json

  local hash marker_path
  hash=$(printf '%s' "$file_path" | shasum -a 256 | cut -c1-16)
  marker_path="$BRAIN_ROUTE_GATE_DIR/.brain-route-${session}-${hash}"
  [ -f "$marker_path" ] || {
    echo "Expected marker file to exist after first call: $marker_path"
    return 1
  }

  # Second call, same session + same file: marker suppresses the prompt.
  INPUT=$(build_write_input file_path="$file_path" session_id="$session" content="在 worktree 里改了 hook 的 fail-open 逻辑") \
    run_gate
  assert_allowed
}

# --- Kill switch ---

@test "kill switch BRAIN_ROUTE_DISABLED=1 → allow" {
  BRAIN_ROUTE_DISABLED=1 \
    INPUT=$(build_write_input file_path=/project/projects/x/memory/lesson.md content="在 worktree 里改了 hook 的 fail-open 逻辑") \
    run_gate
  assert_allowed
}

# --- Dependency check ---

# NOTE (mutation-testing scope, verified by hand): this test asserts an
# observable behavior — jq missing → silent allow, exit 0, empty stdout.
# It does NOT prove that Phase 2's explicit `command -v jq` check exists.
# Mutation test performed: deleting that check line and re-running with jq
# absent from PATH produces the *same* observable outcome (silent allow),
# because the script's outermost guard — `_main 2>/dev/null || true` — also
# swallows the failure that a missing jq would otherwise cause downstream.
# So the explicit jq check is not distinguishable from its absence by any
# assertion on this script's output: it is redundant given the outer
# fail-open, a consequence of the two-layer fail-open design, not a test
# gap. This test still has value — it locks in the correct *behavior* — but
# it cannot be read as coverage of the explicit check itself.
@test "fail-open: jq missing → silent allow" {
  local mock_bin="${TEST_TEMP_DIR}/nojq"
  mkdir -p "$mock_bin"
  # Real jq lives at /usr/bin/jq on macOS, so a mock-first PATH alone doesn't
  # remove it — isolate PATH to only the mock dir. Every binary the script
  # touches BEFORE the jq check (Phase 2: cat via `$(cat)`, plus bash itself)
  # must still be reachable, or the script fails earlier than the jq check
  # and the test would pass for the wrong reason (i.e. it would look like a
  # jq-missing test while actually just testing an almost-empty PATH). jq
  # itself is deliberately NOT symlinked here — that absence is what this
  # test asserts on.
  for bin in bash cat; do
    local real_bin
    real_bin=$(command -v "$bin")
    ln -sf "$real_bin" "$mock_bin/$bin"
  done
  local raw_input='{"tool_name":"Write","session_id":"test-session","tool_input":{"file_path":"/project/projects/x/memory/lesson.md","content":"worktree hook fail-open"}}'
  HOOK_STDOUT="" HOOK_STDERR="" HOOK_EXIT=0
  local stderr_file
  stderr_file=$(mktemp)
  HOOK_STDOUT=$(PATH="$mock_bin" printf '%s' "$raw_input" | PATH="$mock_bin" bash "$GATE_SCRIPT" 2>"$stderr_file") || HOOK_EXIT=$?
  HOOK_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

# --- Malformed input ---

@test "fail-open: empty stdin → silent allow" {
  run_gate_raw_stdin ""
  assert_allowed
}

@test "fail-open: corrupt JSON → silent allow" {
  run_gate_raw_stdin "not-json{{"
  assert_allowed
}

# --- Edit tool path ---

@test "Edit tool new_string field also triggers deny" {
  INPUT=$(build_edit_input file_path=/project/projects/x/memory/lesson.md new_string="在 worktree 里改了 hook 的 fail-open 逻辑") \
    run_gate
  assert_deny_json
}

# --- Missing session_id ---

@test "missing session_id → allow" {
  INPUT=$(jq -n '{tool_name:"Write",tool_input:{file_path:"/project/projects/x/memory/lesson.md",content:"在 worktree 里改了 hook 的 fail-open 逻辑"}}') \
    run_gate
  assert_allowed
}
