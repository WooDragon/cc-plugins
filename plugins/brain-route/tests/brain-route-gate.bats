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

@test "fail-open: jq missing → silent allow" {
  local mock_bin="${TEST_TEMP_DIR}/nojq"
  mkdir -p "$mock_bin"
  # Real jq lives at /usr/bin/jq on macOS, so a mock-first PATH alone doesn't
  # remove it — isolate PATH to only the mock dir (plus a minimal shell/coreutils
  # dir) to truly simulate absence.
  ln -sf /bin/bash "$mock_bin/bash"
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
