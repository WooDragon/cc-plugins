#!/usr/bin/env bats
# Composition test: does the set of outroutes claimed for dispatch actually
# clear EVERY PreToolUse(Agent) guard this plugin registers, not just the
# one guard whose own test file happens to cover it?
#
# Motivating failure (claude-config 仓 issue 173): pre-dispatch-channel-guard.sh's
# header once asserted, in prose only, that dropping `name` to escape THIS
# gate would not walk straight into dispatch-sync-guard.sh's BLOCK (missing
# run_in_background:false). That assertion was false in the fork world and
# stayed false for months, because dispatch-channel-guard.bats only ever
# invoked pre-dispatch-channel-guard.sh in isolation — no test ever fed the
# same payload to both gates in sequence, so nothing could catch the prose
# going stale. This file turns that prose claim into code: build the payload
# for each claimed outroute once, run it through every gate in GATE_SCRIPTS,
# and assert every one of them returns exit 0.
#
# Gate discovery (see discover_agent_gates in test_helper/common-setup.bash)
# reads hooks.json's PreToolUse section at test time instead of hardcoding
# script names — a third PreToolUse(Agent) guard added to this plugin later
# is automatically included in every test below without touching this file.
#
# Negative-control discipline (Design requirement C): asserting "the two
# claimed outroutes pass everywhere" is not sufficient on its own — if some
# future change degraded every gate into an unconditional `exit 0`, that
# assertion alone would keep passing. So this file also asserts the inverse:
# payloads that are NOT any claimed outroute must be rejected by at least
# one gate in the set. Those negative-control tests are the load-bearing
# check that the composition assertions above mean anything; mutation test
# #4 in the accompanying report exists specifically to verify this file
# itself would catch a gate collapsing to `exit 0`.

setup() {
  load 'test_helper/common-setup'
  common_setup
  unset ALLOW_UNMANAGED_TEAMMATE
  unset ALLOW_BACKGROUND_DISPATCH
  unset CLAUDE_CODE_DISABLE_BACKGROUND_TASKS
  unset CLAUDE_AUTO_BACKGROUND_TASKS
  discover_agent_gates
}

teardown() {
  common_teardown
}

# ============================================================
# Fixture self-check: the dynamic discovery itself must be trustworthy
# before any composition assertion built on top of it can be.
# ============================================================

@test "composition #0: hooks.json PreToolUse(Agent) discovery is complete, on-disk, and covers every known guard" {
  # Check 1: discovered count must match an INDEPENDENTLY-parsed count from
  # hooks.json — a different jq traversal (recursive descent via `..` instead
  # of discover_agent_gates' explicit `.hooks.PreToolUse[]` field walk) so
  # this check cannot pass by construction just because both expressions
  # share the same bug. This is what makes the assertion resilient to a
  # fourth guard being added later: the expected number is computed from the
  # same file discover_agent_gates reads, not hardcoded here.
  local independent_count
  independent_count=$(jq '
    [.. | objects | select(has("matcher") and .matcher == "Agent") | .hooks[]?] | length
  ' "$HOOKS_JSON_PATH")
  [ "${#GATE_SCRIPTS[@]}" -eq "$independent_count" ] || {
    echo "discover_agent_gates found ${#GATE_SCRIPTS[@]} gates, but independent jq recount of hooks.json found $independent_count: ${GATE_SCRIPTS[*]}"
    return 1
  }

  # Check 2: every discovered path must actually exist on disk.
  local s
  for s in "${GATE_SCRIPTS[@]}"; do
    [ -f "$s" ] || { echo "Discovered gate path does not exist on disk: $s"; return 1; }
  done

  # Check 3: all three known guards must be present in the discovered set.
  local found_sync=0 found_capability=0 found_channel=0
  for s in "${GATE_SCRIPTS[@]}"; do
    [[ "$s" == *"/hooks/dispatch-sync-guard.sh" ]] && found_sync=1
    [[ "$s" == *"/hooks/dispatch-capability-guard.sh" ]] && found_capability=1
    [[ "$s" == *"/hooks/pre-dispatch-channel-guard.sh" ]] && found_channel=1
  done
  [ "$found_sync" -eq 1 ] || { echo "dispatch-sync-guard.sh not in discovered set: ${GATE_SCRIPTS[*]}"; return 1; }
  [ "$found_capability" -eq 1 ] || { echo "dispatch-capability-guard.sh not in discovered set: ${GATE_SCRIPTS[*]}"; return 1; }
  [ "$found_channel" -eq 1 ] || { echo "pre-dispatch-channel-guard.sh not in discovered set: ${GATE_SCRIPTS[*]}"; return 1; }
}

# ============================================================
# Outroute ①: lightweight one-shot dispatch — no name,
# run_in_background:false. Must clear every gate in GATE_SCRIPTS.
# ============================================================

@test "composition #1: outroute ① (no name, run_in_background:false) clears every discovered gate" {
  local payload
  payload=$(mk_composed_payload "Agent" "false" "omit" "omit" "omit")
  local s rc
  for s in "${GATE_SCRIPTS[@]}"; do
    run_one_gate "$s" "$payload"
    rc="$ONE_GATE_EXIT"
    [ "$rc" -eq 0 ] || {
      echo "Outroute ① payload was BLOCKed by $(basename "$s") (exit $rc)"
      echo "stderr: $ONE_GATE_STDERR"
      return 1
    }
  done
}

# ============================================================
# Outroute ②: managed teammate dispatch — name + subagent_type
# resolving against the roster. run_in_background omitted (name presence
# is what exempts sync-guard, per its step 8 "team-ops lifeline"; this
# outroute must not depend on ALSO supplying run_in_background:false).
# Must clear every gate in GATE_SCRIPTS.
# ============================================================

@test "composition #2: outroute ② (name + roster-hit subagent_type) clears every discovered gate" {
  local cwd="$TEST_TEMP_DIR/roster2"
  mkdir -p "$cwd/.claude/agents"
  printf 'dev role\n' > "$cwd/.claude/agents/dev.md"
  local payload
  payload=$(mk_composed_payload "Agent" "omit" "lead" "dev" "$cwd")
  # fixture self-check
  [[ "$(jq -r '.tool_input.name' <<< "$payload")" == "lead" ]]
  [[ "$(jq -r '.tool_input.subagent_type' <<< "$payload")" == "dev" ]]
  run jq -e '.tool_input | has("run_in_background")' <<< "$payload"
  [ "$status" -eq 1 ]
  local s rc
  for s in "${GATE_SCRIPTS[@]}"; do
    run_one_gate "$s" "$payload"
    rc="$ONE_GATE_EXIT"
    [ "$rc" -eq 0 ] || {
      echo "Outroute ② payload was BLOCKed by $(basename "$s") (exit $rc)"
      echo "stderr: $ONE_GATE_STDERR"
      return 1
    }
  done
}

# ============================================================
# Negative controls (Design requirement C — the load-bearing check).
# ============================================================

@test "composition #3: neither outroute (no name, run_in_background omitted) is BLOCKed by at least one gate" {
  local payload
  payload=$(mk_composed_payload "Agent" "omit" "omit" "omit" "omit")
  local s rc any_block=0
  for s in "${GATE_SCRIPTS[@]}"; do
    run_one_gate "$s" "$payload"
    rc="$ONE_GATE_EXIT"
    [ "$rc" -eq 2 ] && any_block=1
  done
  [ "$any_block" -eq 1 ] || {
    echo "Expected at least one gate to BLOCK a payload matching neither claimed outroute, but every gate in ${GATE_SCRIPTS[*]} passed it"
    return 1
  }
}

@test "composition #4: name present but subagent_type off-roster is BLOCKed by at least one gate" {
  local cwd="$TEST_TEMP_DIR/noroster4"
  mkdir -p "$cwd"
  local fakehome="$TEST_TEMP_DIR/fakehome4"
  mkdir -p "$fakehome"
  local payload
  payload=$(mk_composed_payload "Agent" "omit" "lead" "not-a-real-role" "$cwd")
  local s rc any_block=0
  for s in "${GATE_SCRIPTS[@]}"; do
    run_one_gate "$s" "$payload" "HOME=$fakehome"
    rc="$ONE_GATE_EXIT"
    [ "$rc" -eq 2 ] && any_block=1
  done
  [ "$any_block" -eq 1 ] || {
    echo "Expected at least one gate to BLOCK an off-roster teammate payload, but every gate in ${GATE_SCRIPTS[*]} passed it"
    return 1
  }
}

# ============================================================
# Each escape hatch is scoped to its own gate only (Design requirement D).
# Not asserted: a hatch making some OTHER gate pass — that is out of its
# domain by design, so there is nothing to test there.
# ============================================================

@test "composition #5: ALLOW_BACKGROUND_DISPATCH=1 clears dispatch-sync-guard.sh's own BLOCK payload" {
  local sync_script="${PLUGIN_ROOT_DIR}/hooks/dispatch-sync-guard.sh"
  [ -f "$sync_script" ]
  local payload
  payload=$(mk_composed_payload "Agent" "omit" "omit" "omit" "omit")
  run_one_gate "$sync_script" "$payload" "ALLOW_BACKGROUND_DISPATCH=1"
  [ "$ONE_GATE_EXIT" -eq 0 ] || {
    echo "Expected ALLOW_BACKGROUND_DISPATCH=1 to clear dispatch-sync-guard.sh, got exit $ONE_GATE_EXIT"
    echo "stderr: $ONE_GATE_STDERR"
    return 1
  }
}

@test "composition #6: ALLOW_UNMANAGED_TEAMMATE=1 clears pre-dispatch-channel-guard.sh's own BLOCK payload" {
  local channel_script="${PLUGIN_ROOT_DIR}/hooks/pre-dispatch-channel-guard.sh"
  [ -f "$channel_script" ]
  local cwd="$TEST_TEMP_DIR/hatch6"
  mkdir -p "$cwd"
  local fakehome="$TEST_TEMP_DIR/fakehome6"
  mkdir -p "$fakehome"
  local payload
  payload=$(mk_composed_payload "Agent" "omit" "lead" "not-a-real-role" "$cwd")
  run_one_gate "$channel_script" "$payload" "HOME=$fakehome" "ALLOW_UNMANAGED_TEAMMATE=1"
  [ "$ONE_GATE_EXIT" -eq 0 ] || {
    echo "Expected ALLOW_UNMANAGED_TEAMMATE=1 to clear pre-dispatch-channel-guard.sh, got exit $ONE_GATE_EXIT"
    echo "stderr: $ONE_GATE_STDERR"
    return 1
  }
}
