#!/usr/bin/env bats
# BDD coverage for runtime model ownership on PreToolUse(Agent|Task).
# Runtime-owned built-ins require a nonblank model. Registered named agents
# own their model in frontmatter, so callers may omit the field or pass null
# but may not provide any other value.

setup() {
  load 'test_helper/common-setup'
  common_setup
}

teardown() {
  common_teardown
}

@test "ownership #1: all six runtime-owned agent types accept a nonblank model for Agent and Task" {
  local tool type payload
  for tool in Agent Task; do
    for type in general-purpose claude Explore Plan claude-code-guide statusline-setup; do
      payload=$(mk_ownership_payload "$tool" "$type" string sonnet)
      [[ "$(jq -r '.tool_input.model' <<<"$payload")" == "sonnet" ]]
      run_ownership_guard "$payload"
      assert_ownership_pass
    done
  done
}

@test "ownership #2: missing subagent_type defaults to general-purpose and requires model" {
  local payload
  payload=$(mk_ownership_payload Agent omit omit)
  [[ "$(jq -e '.tool_input | has("subagent_type") | not' <<<"$payload")" == "true" ]]
  run_ownership_guard "$payload"
  assert_ownership_block
  [[ "$OWNERSHIP_STDERR" == *"补 runtime model"* ]]
}

@test "ownership #3: runtime-owned types reject omitted, null, empty, and whitespace model fields" {
  local payload
  payload=$(mk_ownership_payload Agent Explore omit)
  run_ownership_guard "$payload"
  assert_ownership_block

  payload=$(mk_ownership_payload Agent Explore null)
  run_ownership_guard "$payload"
  assert_ownership_block

  payload=$(mk_ownership_payload Agent Explore string '')
  run_ownership_guard "$payload"
  assert_ownership_block

  payload=$(mk_ownership_payload Agent Explore string '  ')
  run_ownership_guard "$payload"
  assert_ownership_block
}

@test "ownership #4: type classification is case-insensitive like capability handling" {
  local payload
  payload=$(mk_ownership_payload Task GENERAL-PURPOSE string haiku)
  run_ownership_guard "$payload"
  assert_ownership_pass
}

@test "ownership #5: registered agents accept only model omission or null" {
  local type model_mode payload
  for type in dev dev-econ; do
    for model_mode in omit null; do
      payload=$(mk_ownership_payload Agent "$type" "$model_mode")
      run_ownership_guard "$payload"
      assert_ownership_pass
    done
  done
}

@test "ownership #6: registered agent rejects model inherit, empty, whitespace, haiku, and sonnet overrides" {
  local value payload
  for value in inherit '' '  ' haiku sonnet; do
    payload=$(mk_ownership_payload Task dev string "$value")
    [[ "$(jq -e '.tool_input | has("model")' <<<"$payload")" == "true" ]]
    run_ownership_guard "$payload"
    assert_ownership_block
    [[ "$OWNERSHIP_STDERR" == *"删除 model"* ]]
  done
}

@test "ownership #7: explicit model override is rejected for dev-econ too" {
  local payload
  payload=$(mk_ownership_payload Agent dev-econ string haiku)
  run_ownership_guard "$payload"
  assert_ownership_block
}

@test "ownership #8: escape hatch emits GATE-BYPASS and passes" {
  local payload
  payload=$(mk_ownership_payload Agent general-purpose omit)
  run_ownership_guard "$payload" "ALLOW_AGENT_MODEL_INHERIT=1"
  [ "$OWNERSHIP_EXIT" -eq 0 ]
  [[ "$OWNERSHIP_STDERR" == *"[GATE-BYPASS]"* ]]
}

@test "ownership #9: empty and malformed JSON fail open with GATE-DEGRADE" {
  run_ownership_guard ""
  [ "$OWNERSHIP_EXIT" -eq 0 ]
  [[ "$OWNERSHIP_STDERR" == *"[GATE-DEGRADE]"* ]]

  run_ownership_guard "not json"
  [ "$OWNERSHIP_EXIT" -eq 0 ]
  [[ "$OWNERSHIP_STDERR" == *"[GATE-DEGRADE]"* ]]
}

@test "ownership #10: jq unavailable fails open with GATE-DEGRADE" {
  local payload
  payload=$(mk_ownership_payload Agent general-purpose omit)
  run_ownership_guard_no_jq "$payload"
  [ "$OWNERSHIP_EXIT" -eq 0 ]
  [[ "$OWNERSHIP_STDERR" == *"[GATE-DEGRADE]"* ]]
  [[ "$OWNERSHIP_STDERR" == *"jq unavailable"* ]]
}

@test "ownership #11: non-Agent/Task payload passes without ownership judgment" {
  local tool payload
  for tool in Bash Read; do
    payload=$(mk_ownership_payload "$tool" general-purpose omit)
    run_ownership_guard "$payload"
    assert_ownership_pass
  done
}

@test "ownership #12: null subagent_type normalizes to general-purpose" {
  local payload
  payload=$(mk_ownership_payload Agent null string sonnet)
  [[ "$(jq -r '.tool_input.subagent_type' <<<"$payload")" == "null" ]]
  run_ownership_guard "$payload"
  assert_ownership_pass

  payload=$(mk_ownership_payload Task null omit)
  run_ownership_guard "$payload"
  assert_ownership_block
}

@test "ownership #13: invalid mk_ownership_payload mode fails loudly" {
  run mk_ownership_payload Agent general-purpose invalid
  [ "$status" -eq 2 ] || {
    echo "Expected invalid model mode to return 2, got $status"
    return 1
  }
}

@test "ownership #14: Bats reports an intentional failure and still executes teardown" {
  local probe marker helper
  probe="$TEST_TEMP_DIR/intentional-failure-probe.bats"
  marker="$TEST_TEMP_DIR/teardown-ran"
  helper="${BATS_TEST_DIRNAME}/test_helper/common-setup.bash"
  cat > "$probe" <<'EOF'
#!/usr/bin/env bats
setup() {
  source "$HELPER"
  common_setup
}
teardown() {
  printf 'teardown-ran' > "$MARKER"
  common_teardown
}
@test "intentional failure" {
  false
}
EOF

  run env HELPER="$helper" MARKER="$marker" bats "$probe"
  [ "$status" -ne 0 ] || {
    echo "Intentional failing probe was reported as passing: $output"
    return 1
  }
  [[ "$output" == *"not ok"* && "$output" == *"intentional failure"* ]] || {
    echo "Bats did not report the intentional failure: $output"
    return 1
  }
  [ "$(<"$marker")" = "teardown-ran" ] || {
    echo "Bats did not execute teardown after the intentional failure"
    return 1
  }
}

@test "ownership #15: runtime rejection mutation makes the focused block assertion red, then restores it" {
  local mutant payload anchor anchor_count
  mkdir -p "$TEST_TEMP_DIR/mutant/hooks"
  mutant="$TEST_TEMP_DIR/mutant/hooks/dispatch-agent-ownership-guard.sh"
  cp "$OWNERSHIP_GUARD_SCRIPT" "$mutant"
  cp -R "${OWNERSHIP_GUARD_SCRIPT%/*}/lib" "$TEST_TEMP_DIR/mutant/hooks/lib"

  anchor='  printf '\''[dispatch-agent-ownership-guard] 内置 runtime-owned agent(subagent_type=%s) 必须显式带非空、非空白 model。\n'\'' "$TYPE" >&2'
  anchor_count=$(grep -Fxc "$anchor" "$mutant")
  [ "$anchor_count" -eq 1 ] || {
    echo "Expected exactly one complete runtime-rejection anchor, found $anchor_count"
    return 1
  }
  perl -0pi -e 's/(内置 runtime-owned agent\(subagent_type=%s\).*?\n.*?\n  exit) 2/$1 0 # MUTATION/s' "$mutant"
  run grep -F 'exit 0 # MUTATION' "$mutant"
  [ "$status" -eq 0 ] || {
    echo "Runtime rejection mutation did not land"
    return 1
  }

  payload=$(mk_ownership_payload Agent general-purpose omit)
  run_ownership_script "$mutant" "$payload"
  if assert_ownership_block; then
    echo "Mutated runtime rejection still satisfied the focused block assertion"
    return 1
  fi

  cp "$OWNERSHIP_GUARD_SCRIPT" "$mutant"
  run_ownership_script "$mutant" "$payload"
  assert_ownership_block
}
