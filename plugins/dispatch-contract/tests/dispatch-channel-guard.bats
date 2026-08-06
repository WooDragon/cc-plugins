#!/usr/bin/env bats
# BDD tests for pre-dispatch-channel-guard.sh (PreToolUse hook).
#
# channel-guard: BLOCK is exit 2 + "dispatch-channel-guard" in stderr.
#                PASS is exit 0, no "dispatch-channel-guard" in stderr.
#
# Fixture isolation discipline: setup() explicitly clears all four env vars
# any sibling PreToolUse(Agent|Task) guard in this plugin reads as an escape
# hatch or fail-open switch (ALLOW_UNMANAGED_TEAMMATE, ALLOW_BACKGROUND_DISPATCH,
# CLAUDE_CODE_DISABLE_BACKGROUND_TASKS, CLAUDE_AUTO_BACKGROUND_TASKS). Shell
# pollution from any of these would make every BLOCK case in this suite pass
# for the wrong reason. Roster fixtures are built under $BATS_TEST_TMPDIR /
# mktemp dirs only — never against the real ~/.claude/agents/ roster, which
# drifts as the repo evolves and would make these tests flaky for reasons
# unrelated to the gate itself.

setup() {
  load 'test_helper/common-setup'
  common_setup
  unset ALLOW_UNMANAGED_TEAMMATE
  unset ALLOW_BACKGROUND_DISPATCH
  unset CLAUDE_CODE_DISABLE_BACKGROUND_TASKS
  unset CLAUDE_AUTO_BACKGROUND_TASKS
}

teardown() {
  common_teardown
}

# ============================================================
# Roster ancestor-chain resolution (1-5)
# ============================================================

@test "channel #1: cwd itself has .claude/agents/<t>.md -> PASS" {
  local d="$TEST_TEMP_DIR/self1"
  mkdir -p "$d/.claude/agents"
  printf 'dev role\n' > "$d/.claude/agents/dev.md"
  local payload
  payload=$(mk_channel_payload "Agent" "lead" "dev" "$d")
  # fixture self-check
  [[ "$(jq -r '.tool_input.subagent_type' <<< "$payload")" == "dev" ]]
  [ -f "$d/.claude/agents/dev.md" ]
  run_channel_guard "$payload"
  assert_channel_pass
}

@test "channel #2: roster hit two levels up the ancestor chain -> PASS" {
  local d="$TEST_TEMP_DIR/mid2"
  mkdir -p "$d/.claude/agents"
  printf 'ops role\n' > "$d/.claude/agents/ops.md"
  mkdir -p "$d/x/y"
  local payload
  payload=$(mk_channel_payload "Agent" "lead" "ops" "$d/x/y")
  run_channel_guard "$payload"
  assert_channel_pass
}

@test "channel #3: cwd off the \$HOME chain, \$HOME/.claude/agents/<t>.md exists -> PASS" {
  local fakehome="$TEST_TEMP_DIR/fakehome3"
  mkdir -p "$fakehome/.claude/agents"
  printf 'pm role\n' > "$fakehome/.claude/agents/pm.md"
  local cwd="$TEST_TEMP_DIR/elsewhere3"
  mkdir -p "$cwd"
  # fixture self-check: cwd must NOT be nested under fakehome
  case "$cwd" in
    "$fakehome"|"$fakehome"/*) echo "fixture bug: cwd nested under fakehome"; return 1 ;;
  esac
  local payload
  payload=$(mk_channel_payload "Agent" "lead" "pm" "$cwd")
  run_channel_guard "$payload" "HOME=$fakehome"
  assert_channel_pass
}

@test "channel #4: neither ancestor chain nor \$HOME has the roster file -> BLOCK" {
  local cwd="$TEST_TEMP_DIR/none4"
  mkdir -p "$cwd"
  local fakehome="$TEST_TEMP_DIR/fakehome4"
  mkdir -p "$fakehome"
  local payload
  payload=$(mk_channel_payload "Agent" "lead" "qa" "$cwd")
  run_channel_guard "$payload" "HOME=$fakehome"
  assert_channel_block
}

@test "channel #5: roster directory does not exist anywhere -> BLOCK (must not degrade to PASS)" {
  local cwd="$TEST_TEMP_DIR/none5/a/b/c"
  mkdir -p "$cwd"
  # deliberately do NOT create $fakehome — the guard must survive a
  # nonexistent HOME directory without treating it as a pass condition.
  local fakehome="$TEST_TEMP_DIR/does-not-exist5"
  local payload
  payload=$(mk_channel_payload "Agent" "lead" "qa" "$cwd")
  run_channel_guard "$payload" "HOME=$fakehome"
  assert_channel_block
}

# ============================================================
# Domain boundary: name empty means not this gate's domain (6-8)
# ============================================================

@test "channel #6: tool_input.name field missing -> PASS" {
  local payload
  payload=$(mk_channel_payload "Agent" "__OMIT__" "__OMIT__" "__OMIT__")
  # fixture self-check
  run jq -e '.tool_input | has("name")' <<< "$payload"
  [ "$status" -eq 1 ]
  run_channel_guard "$payload"
  assert_channel_pass
}

@test "channel #7: tool_input.name is an empty string -> PASS" {
  local payload
  payload=$(mk_channel_payload "Agent" "" "__OMIT__" "__OMIT__")
  [[ "$(jq -r '.tool_input.name' <<< "$payload")" == "" ]]
  run jq -e '.tool_input | has("name")' <<< "$payload"
  [ "$status" -eq 0 ]
  run_channel_guard "$payload"
  assert_channel_pass
}

@test "channel #8a: tool_input.name is space-only -> PASS" {
  local payload
  payload=$(mk_channel_payload "Agent" " " "__OMIT__" "__OMIT__")
  [[ "$(jq -r '.tool_input.name' <<< "$payload")" == " " ]]
  run_channel_guard "$payload"
  assert_channel_pass
}

@test "channel #8b: tool_input.name is tab-only -> PASS" {
  local payload
  payload=$(mk_channel_payload "Agent" $'\t' "__OMIT__" "__OMIT__")
  [[ "$(jq -r '.tool_input.name' <<< "$payload")" == $'\t' ]]
  run_channel_guard "$payload"
  assert_channel_pass
}

@test "channel #8c: tool_input.name is newline-only -> PASS" {
  local payload
  payload=$(mk_channel_payload "Agent" $'\n' "__OMIT__" "__OMIT__")
  # fixture self-check via jq's own comparison — bash's $(...) strips
  # trailing newlines from captured output, so comparing the captured value
  # against $'\n' in bash would always read as empty and pass vacuously.
  [[ "$(jq -r '.tool_input.name == "\n"' <<< "$payload")" == "true" ]]
  run_channel_guard "$payload"
  assert_channel_pass
}

# ============================================================
# Charset guard: must reject before any roster path traversal (9-12)
# ============================================================

@test "channel #9: subagent_type=\"../x\" -> BLOCK" {
  local payload
  payload=$(mk_channel_payload "Agent" "lead" "../x" "__OMIT__")
  run_channel_guard "$payload"
  assert_channel_block
}

@test "channel #10: subagent_type=\"a/b\" -> BLOCK" {
  local payload
  payload=$(mk_channel_payload "Agent" "lead" "a/b" "__OMIT__")
  run_channel_guard "$payload"
  assert_channel_block
}

@test "channel #11: subagent_type starting with '-' -> BLOCK" {
  local payload
  payload=$(mk_channel_payload "Agent" "lead" "-foo" "__OMIT__")
  run_channel_guard "$payload"
  assert_channel_block
}

@test "channel #12: subagent_type over-long (33 chars) -> BLOCK" {
  local long33="abcdefghijklmnopqrstuvwxyz0123456"
  [ "${#long33}" -eq 33 ]
  local payload
  payload=$(mk_channel_payload "Agent" "lead" "$long33" "__OMIT__")
  run_channel_guard "$payload"
  assert_channel_block
}

@test "channel #12b: charset guard actually prevents escaping .claude/agents/ to hit an unrelated real file -> BLOCK" {
  # channel #9-#12 only assert BLOCK on payloads whose traversal target does
  # not exist on disk — with no roster hit either way (charset checked or
  # not), those tests would stay green even if the charset regex were
  # deleted entirely (verified: commenting it out left channel #9-#12 all
  # green). This test builds a fixture where ".." actually resolves to a
  # real, existing file outside .claude/agents/, so disabling the charset
  # check would make ROSTER_HIT="1" (wrongly PASS) while the intact check
  # correctly BLOCKs before that traversal is ever attempted.
  local base="$TEST_TEMP_DIR/traversal12b"
  mkdir -p "$base/.claude/agents"
  # decoy file: NOT a legitimate roster entry, sits two levels above
  # .claude/agents/ (i.e. at $base/pwned.md).
  printf 'not a real role\n' > "$base/pwned.md"
  # fixture self-check: OS-level path resolution collapses the ".." the same
  # way the guard's `[ -f ... ]` would if the charset check let it through.
  [ -f "$base/.claude/agents/../../pwned.md" ]
  local payload
  payload=$(mk_channel_payload "Agent" "lead" "../../pwned" "$base")
  run_channel_guard "$payload"
  assert_channel_block
}

# ============================================================
# payload cwd: .cwd missing falls back to $PWD (13)
# ============================================================

@test "channel #13: .cwd missing falls back to \$PWD with fixture present -> PASS" {
  local d="$TEST_TEMP_DIR/pwdcase13"
  mkdir -p "$d/.claude/agents"
  printf 'dev role\n' > "$d/.claude/agents/dev.md"
  local payload
  payload=$(mk_channel_payload "Agent" "lead" "dev" "__OMIT__")
  # fixture self-check: .cwd genuinely absent
  run jq -e 'has("cwd")' <<< "$payload"
  [ "$status" -eq 1 ]
  pushd "$d" >/dev/null
  run_channel_guard "$payload"
  popd >/dev/null
  assert_channel_pass
}

# ============================================================
# Preamble / fail-open / escape hatch (14-17)
# ============================================================

@test "channel #14: tool_name=Bash -> PASS (not a dispatch call)" {
  local payload
  payload=$(mk_channel_payload "Bash" "lead" "dev" "__OMIT__")
  [[ "$(jq -r '.tool_name' <<< "$payload")" == "Bash" ]]
  run_channel_guard "$payload"
  assert_channel_pass
}

@test "channel #15: empty stdin -> PASS" {
  run_channel_guard ""
  assert_channel_pass
}

@test "channel #16: truncated JSON '{' -> PASS" {
  run_channel_guard "{"
  assert_channel_pass
}

@test "channel #17: ALLOW_UNMANAGED_TEAMMATE=1 + otherwise-BLOCK payload -> PASS with [GATE-BYPASS]" {
  local cwd="$TEST_TEMP_DIR/bypass17"
  mkdir -p "$cwd"
  local fakehome="$TEST_TEMP_DIR/fakehome17"
  mkdir -p "$fakehome"
  local payload
  payload=$(mk_channel_payload "Agent" "lead" "general-purpose" "$cwd")
  run_channel_guard "$payload" "HOME=$fakehome" "ALLOW_UNMANAGED_TEAMMATE=1"
  assert_channel_pass
  [[ "$CHANNEL_STDERR" == *"[GATE-BYPASS]"* ]] || {
    echo "Expected [GATE-BYPASS] in stderr, got: $CHANNEL_STDERR"
    return 1
  }
}

# ============================================================
# Isolation self-check: ambient shell pollution must not leak (extra)
# ============================================================

@test "channel #isolation: ambient ALLOW_UNMANAGED_TEAMMATE=1 in the calling shell must not leak into the gate" {
  local cwd="$TEST_TEMP_DIR/isolation"
  mkdir -p "$cwd"
  local fakehome="$TEST_TEMP_DIR/fakehome-isolation"
  mkdir -p "$fakehome"
  local payload
  payload=$(mk_channel_payload "Agent" "lead" "general-purpose" "$cwd")
  export ALLOW_UNMANAGED_TEAMMATE=1
  # No override passed to run_channel_guard: the ambient export above must be
  # stripped by run_channel_guard's `env -u`, so this must still BLOCK as if
  # unpolluted.
  run_channel_guard "$payload" "HOME=$fakehome"
  unset ALLOW_UNMANAGED_TEAMMATE
  assert_channel_block
}

# ============================================================
# Wording: BLOCK message must offer both real exits (18)
# ============================================================

@test "channel #18: BLOCK message states exit ① (run_in_background) and exit ② (roster/名册) wording" {
  local cwd="$TEST_TEMP_DIR/wording18"
  mkdir -p "$cwd"
  local fakehome="$TEST_TEMP_DIR/fakehome18"
  mkdir -p "$fakehome"
  local payload
  payload=$(mk_channel_payload "Agent" "lead" "general-purpose" "$cwd")
  run_channel_guard "$payload" "HOME=$fakehome"
  assert_channel_block
  [[ "$CHANNEL_STDERR" == *"run_in_background"* ]] || {
    echo "Expected exit ① wording (run_in_background) in stderr, got: $CHANNEL_STDERR"
    return 1
  }
  [[ "$CHANNEL_STDERR" == *"名册"* || "$CHANNEL_STDERR" == *"roster"* ]] || {
    echo "Expected exit ② wording (roster/名册) in stderr, got: $CHANNEL_STDERR"
    return 1
  }
}
