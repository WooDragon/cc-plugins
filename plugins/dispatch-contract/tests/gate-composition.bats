#!/usr/bin/env bats
# Composition test: does the set of outroutes claimed for dispatch actually
# clear EVERY PreToolUse(Agent|Task) guard this plugin registers, not just
# the one guard whose own test file happens to cover it?
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
# Gate discovery (see discover_agent_gates/discover_task_gates in
# test_helper/common-setup.bash) reads hooks.json's PreToolUse section at
# test time instead of hardcoding script names — any additional PreToolUse
# guard added to this plugin later is automatically included in every test below
# without touching this file. hooks.json registers the same four guards
# under BOTH the "Agent" and "Task" matchers (Lead/PM can dispatch via
# either tool), so this file checks both matchers independently (composition
# #7/#8/#9 below) — the Agent-only checks alone would stay green even if a
# guard were stripped from only the "Task" side, reproducing the exact
# same-shape blind spot issue 173 already burned this plugin once for.
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
#
# Non-empty-prompt discipline (Design requirement F): mk_composed_payload
# never set tool_input.prompt until this patch, and
# dispatch-capability-guard.sh's very first branch after field extraction is
# `[ -z "$PROMPT" ] && exit 0` — so every "clears every gate" assertion here
# was, for that one guard, true for a reason unrelated to its judgment logic
# (a real Agent/Task dispatch always carries a prompt, so the old payload
# shape was not even a realistic fixture). Composition #1/#2 now carry a
# neutral, judgment-safe prompt (see setup's NEUTRAL_PROMPT comment) so that
# guard's participation in the composition assertion is no longer vacuous;
# composition #11 supplies the matching positive control (a payload built
# from the same mk_composed_payload shape that must BLOCK) so the vacuity
# concern is closed on both sides, not just asserted away by adding a
# prompt.

setup() {
  load 'test_helper/common-setup'
  common_setup
  unset ALLOW_UNMANAGED_TEAMMATE
  unset ALLOW_BACKGROUND_DISPATCH
  unset CLAUDE_CODE_DISABLE_BACKGROUND_TASKS
  unset CLAUDE_AUTO_BACKGROUND_TASKS
  unset ALLOW_DISPATCH_CAPABILITY_MISMATCH
  unset ALLOW_AGENT_MODEL_INHERIT
  discover_agent_gates
  # A neutral prompt/description pair carrying no EXEC/WRITE/RO/NEG signal
  # dispatch-capability-guard.sh's regex set recognizes (verified directly
  # against the script: NEEDS_CAP folds to 0 whenever neither EXEC_HIT nor
  # WRITE_HIT fires, and this text contains none of RE_EXEC_BARE_CN/EN's or
  # RE_WRITE_CN/EN's keywords). Composition #1/#2 below use it to give
  # dispatch-capability-guard.sh real judgment data — mk_composed_payload
  # previously never set tool_input.prompt at all, and the guard's very
  # first line after field extraction is `[ -z "$PROMPT" ] && exit 0`, so
  # "clears every discovered gate" was true of that guard for a reason that
  # had nothing to do with its judgment logic. A prompt string is required
  # by construction, not merely present-but-blank.
  NEUTRAL_PROMPT="请确认现有派发流程的说明是否完整，并把结论汇报给我。"
  NEUTRAL_DESC="确认派发流程文档完整性"
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
  # share the same bug. This is what makes the assertion resilient to an
  # additional guard being added later: the expected number is computed from
  # the same file discover_agent_gates reads, not hardcoded here.
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

  # Check 3: all four known guards must be present in the discovered set.
  local found_sync=0 found_ownership=0 found_capability=0 found_channel=0
  for s in "${GATE_SCRIPTS[@]}"; do
    [[ "$s" == *"/hooks/dispatch-sync-guard.sh" ]] && found_sync=1
    [[ "$s" == *"/hooks/dispatch-agent-ownership-guard.sh" ]] && found_ownership=1
    [[ "$s" == *"/hooks/dispatch-capability-guard.sh" ]] && found_capability=1
    [[ "$s" == *"/hooks/pre-dispatch-channel-guard.sh" ]] && found_channel=1
  done
  [ "$found_sync" -eq 1 ] || { echo "dispatch-sync-guard.sh not in discovered set: ${GATE_SCRIPTS[*]}"; return 1; }
  [ "$found_ownership" -eq 1 ] || { echo "dispatch-agent-ownership-guard.sh not in discovered set: ${GATE_SCRIPTS[*]}"; return 1; }
  [ "$found_capability" -eq 1 ] || { echo "dispatch-capability-guard.sh not in discovered set: ${GATE_SCRIPTS[*]}"; return 1; }
  [ "$found_channel" -eq 1 ] || { echo "pre-dispatch-channel-guard.sh not in discovered set: ${GATE_SCRIPTS[*]}"; return 1; }
}

# ============================================================
# Outroute ①: lightweight one-shot dispatch — no name,
# run_in_background:false. Must clear every gate in GATE_SCRIPTS.
# ============================================================

@test "composition #1: outroute ① (no name, run_in_background:false) clears every discovered gate" {
  local payload
  payload=$(mk_composed_payload "Agent" "false" "omit" "omit" "omit" "$NEUTRAL_PROMPT" "$NEUTRAL_DESC" "sonnet")
  # fixture self-check: a real Agent dispatch always carries a prompt — a
  # payload with no prompt field makes dispatch-capability-guard.sh's
  # participation in this test a no-op (see setup's NEUTRAL_PROMPT comment).
  [[ "$(jq -r '.tool_input.prompt' <<< "$payload")" == "$NEUTRAL_PROMPT" ]]
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
  # Registered teammates own their model in frontmatter, so callers must omit
  # model. PROMPT/DESC are supplied per setup's NEUTRAL_PROMPT comment.
  payload=$(mk_composed_payload "Agent" "omit" "lead" "dev" "$cwd" "$NEUTRAL_PROMPT" "$NEUTRAL_DESC")
  # fixture self-check
  [[ "$(jq -r '.tool_input.name' <<< "$payload")" == "lead" ]]
  [[ "$(jq -r '.tool_input.subagent_type' <<< "$payload")" == "dev" ]]
  [[ "$(jq -r '.tool_input.prompt' <<< "$payload")" == "$NEUTRAL_PROMPT" ]]
  [[ "$(jq -e '.tool_input | has("model") | not' <<< "$payload")" == "true" ]]
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

# ============================================================
# Task matcher mirrors Agent matcher (Design requirement E — see task hint
# in this file's header update, issue-173-shaped mode: if someone strips a
# guard from ONLY the "Task" matcher block in hooks.json, composition #1/#2
# above would stay green forever, because they only ever look at
# discover_agent_gates' output. Two independent checks close that: a
# structural set-equality assertion against hooks.json itself, plus running
# both outroutes' payloads through the Task-side discovered gates too (not
# merely trusting that "Task" and "Agent" resolve to the same script paths
# because the equality check above says so — the two checks catch different
# regressions: one catches hooks.json drifting, the other catches a
# Task-dispatched payload actually behaving differently than an
# Agent-dispatched one at any of those same scripts, e.g. a stray tool_name
# branch introduced later that only fires for "Task").
# ============================================================

@test "composition #7: hooks.json Task matcher's PreToolUse command set equals Agent matcher's" {
  local agent_cmds task_cmds
  agent_cmds=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Agent") | .hooks[].command' "$HOOKS_JSON_PATH" | sort)
  task_cmds=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Task") | .hooks[].command' "$HOOKS_JSON_PATH" | sort)
  [[ "$agent_cmds" == "$task_cmds" ]] || {
    echo "Agent matcher and Task matcher PreToolUse command sets differ."
    echo "Agent-only (or reordered away from Task):"
    comm -23 <(echo "$agent_cmds") <(echo "$task_cmds")
    echo "Task-only (or reordered away from Agent):"
    comm -13 <(echo "$agent_cmds") <(echo "$task_cmds")
    return 1
  }
}

@test "composition #8: outroute ① via Task matcher clears every discovered Task-side gate" {
  discover_task_gates
  local payload
  payload=$(mk_composed_payload "Task" "false" "omit" "omit" "omit" "$NEUTRAL_PROMPT" "$NEUTRAL_DESC" "sonnet")
  local s rc
  for s in "${GATE_SCRIPTS[@]}"; do
    run_one_gate "$s" "$payload"
    rc="$ONE_GATE_EXIT"
    [ "$rc" -eq 0 ] || {
      echo "Task-side outroute ① payload was BLOCKed by $(basename "$s") (exit $rc)"
      echo "stderr: $ONE_GATE_STDERR"
      return 1
    }
  done
}

@test "composition #9: outroute ② via Task matcher clears every discovered Task-side gate" {
  discover_task_gates
  local cwd="$TEST_TEMP_DIR/roster9"
  mkdir -p "$cwd/.claude/agents"
  printf 'dev role\n' > "$cwd/.claude/agents/dev.md"
  local payload
  payload=$(mk_composed_payload "Task" "omit" "lead" "dev" "$cwd" "$NEUTRAL_PROMPT" "$NEUTRAL_DESC")
  local s rc
  for s in "${GATE_SCRIPTS[@]}"; do
    run_one_gate "$s" "$payload"
    rc="$ONE_GATE_EXIT"
    [ "$rc" -eq 0 ] || {
      echo "Task-side outroute ② payload was BLOCKed by $(basename "$s") (exit $rc)"
      echo "stderr: $ONE_GATE_STDERR"
      return 1
    }
  done
}

# ============================================================
# run_one_gate's own escape-hatch isolation (mirrors the sibling sync #21
# ambient-leak test, applied to the variable run_one_gate was missing until
# this patch: ALLOW_DISPATCH_CAPABILITY_MISMATCH). Without this test, a
# regression that drops the `-u ALLOW_DISPATCH_CAPABILITY_MISMATCH` added to
# run_one_gate in this patch would go uncaught by every other test in this
# file, because none of them run in a shell that has the variable exported
# ambiently — this is the only test that deliberately pollutes the calling
# shell first.
# ============================================================

@test "composition #10: ambient ALLOW_DISPATCH_CAPABILITY_MISMATCH=1 in the calling shell must not leak into run_one_gate" {
  local cap_script="${PLUGIN_ROOT_DIR}/hooks/dispatch-capability-guard.sh"
  [ -f "$cap_script" ]
  local payload
  # A capability-guard BLOCK payload (judgment B: write-intent prompt routed
  # to a read-only subagent_type) so the assertion is "still BLOCKs despite
  # the ambient hatch", not merely "still exits something".
  payload=$(jq -cn '{tool_name:"Agent", tool_input:{run_in_background:false, subagent_type:"explore", prompt:"修复 main.py 里的 bug"}}')
  export ALLOW_DISPATCH_CAPABILITY_MISMATCH=1
  # No override passed to run_one_gate: the ambient export above must be
  # stripped by run_one_gate's `env -u`, so this must still BLOCK as if
  # unpolluted.
  run_one_gate "$cap_script" "$payload"
  unset ALLOW_DISPATCH_CAPABILITY_MISMATCH
  [ "$ONE_GATE_EXIT" -eq 2 ] || {
    echo "Expected ambient ALLOW_DISPATCH_CAPABILITY_MISMATCH=1 to be stripped by run_one_gate (still BLOCK), got exit $ONE_GATE_EXIT"
    echo "stderr: $ONE_GATE_STDERR"
    return 1
  }
  [[ "$ONE_GATE_STDERR" == *"命中判据 B"* ]] || {
    echo "Expected '命中判据 B' in stderr (real judgment, not a leaked bypass), got: $ONE_GATE_STDERR"
    return 1
  }
}

# ============================================================
# Non-empty-prompt positive control (Design requirement F): composition
# #1/#2 asserting "dispatch-capability-guard.sh passes every claimed
# outroute" only means something if the same payload shape can also make it
# BLOCK. Before this patch mk_composed_payload never set tool_input.prompt,
# and dispatch-capability-guard.sh's very first branch after field
# extraction is `[ -z "$PROMPT" ] && exit 0` — so every prior "clears every
# gate" assertion was vacuously true for this gate specifically. This test
# proves the gate is not a permanent no-op in the composed-payload shape by
# constructing a payload that must BLOCK: write-intent prompt + a read-only
# subagent_type (Explore, judgment B's domain).
# ============================================================

@test "composition #11: write-intent prompt + read-only subagent_type is BLOCKed by dispatch-capability-guard.sh (non-empty-prompt positive control)" {
  local cap_script="${PLUGIN_ROOT_DIR}/hooks/dispatch-capability-guard.sh"
  [ -f "$cap_script" ]
  local payload
  payload=$(mk_composed_payload "Agent" "false" "omit" "explore" "omit" "修复 main.py 里的 bug" "omit")
  # fixture self-check: sync-guard and channel-guard must both PASS this
  # exact payload, so a failure below is unambiguously attributable to
  # dispatch-capability-guard.sh, not to some other gate in the set.
  local sync_script="${PLUGIN_ROOT_DIR}/hooks/dispatch-sync-guard.sh"
  local channel_script="${PLUGIN_ROOT_DIR}/hooks/pre-dispatch-channel-guard.sh"
  run_one_gate "$sync_script" "$payload"
  [ "$ONE_GATE_EXIT" -eq 0 ] || {
    echo "Fixture self-check failed: dispatch-sync-guard.sh unexpectedly BLOCKed the positive-control payload (exit $ONE_GATE_EXIT)"
    echo "stderr: $ONE_GATE_STDERR"
    return 1
  }
  run_one_gate "$channel_script" "$payload"
  [ "$ONE_GATE_EXIT" -eq 0 ] || {
    echo "Fixture self-check failed: pre-dispatch-channel-guard.sh unexpectedly BLOCKed the positive-control payload (exit $ONE_GATE_EXIT)"
    echo "stderr: $ONE_GATE_STDERR"
    return 1
  }
  run_one_gate "$cap_script" "$payload"
  [ "$ONE_GATE_EXIT" -eq 2 ] || {
    echo "Expected dispatch-capability-guard.sh to BLOCK write-intent-to-explore, got exit $ONE_GATE_EXIT"
    echo "stderr: $ONE_GATE_STDERR"
    return 1
  }
  [[ "$ONE_GATE_STDERR" == *"命中判据 B"* ]] || {
    echo "Expected '命中判据 B' in stderr, got: $ONE_GATE_STDERR"
    return 1
  }
}

@test "composition #12: ownership guard blocks an Agent and Task runtime default without model" {
  local ownership_script="${PLUGIN_ROOT_DIR}/hooks/dispatch-agent-ownership-guard.sh"
  local tool payload
  for tool in Agent Task; do
    payload=$(mk_composed_payload "$tool" "false" "omit" "omit" "omit" "$NEUTRAL_PROMPT" "$NEUTRAL_DESC")
    run_one_gate "$ownership_script" "$payload"
    [ "$ONE_GATE_EXIT" -eq 2 ] || {
      echo "Expected ownership guard to block $tool without model, got exit $ONE_GATE_EXIT"
      echo "stderr: $ONE_GATE_STDERR"
      return 1
    }
    [[ "$ONE_GATE_STDERR" == *"runtime-owned"* ]] || {
      echo "Expected runtime-owned ownership message, got: $ONE_GATE_STDERR"
      return 1
    }
  done
}

@test "composition #13: dev-econ write dispatch without model clears all Agent and Task gates" {
  local tool payload s
  for tool in Agent Task; do
    discover_agent_gates
    [[ "$tool" == "Task" ]] && discover_task_gates
    payload=$(mk_composed_payload "$tool" "false" "omit" "dev-econ" "omit" "修复 main.py 里的 bug" "$NEUTRAL_DESC")
    [[ "$(jq -e '.tool_input | has("model") | not' <<<"$payload")" == "true" ]]
    for s in "${GATE_SCRIPTS[@]}"; do
      run_one_gate "$s" "$payload"
      [ "$ONE_GATE_EXIT" -eq 0 ] || {
        echo "Expected dev-econ write dispatch to pass $(basename "$s") for $tool, got exit $ONE_GATE_EXIT"
        echo "stderr: $ONE_GATE_STDERR"
        return 1
      }
    done
  done
}

@test "composition #14: missing or null type normalizes to general-purpose before C for both Agent and Task" {
  local tool type_mode payload s
  for tool in Agent Task; do
    discover_agent_gates
    [[ "$tool" == "Task" ]] && discover_task_gates
    for type_mode in omit __NULL__; do
      payload=$(mk_composed_payload "$tool" "false" "omit" "$type_mode" "omit" "修复 main.py 里的 bug" "$NEUTRAL_DESC" "haiku")
      for s in "${GATE_SCRIPTS[@]}"; do
        run_one_gate "$s" "$payload"
        if [[ "$s" == *"/dispatch-capability-guard.sh" ]]; then
          [ "$ONE_GATE_EXIT" -eq 2 ] || {
            echo "Expected capability C to block $tool/$type_mode, got exit $ONE_GATE_EXIT"
            echo "stderr: $ONE_GATE_STDERR"
            return 1
          }
          [[ "$ONE_GATE_STDERR" == *"命中判据 C"* ]] || {
            echo "Expected judgment C for $tool/$type_mode, got: $ONE_GATE_STDERR"
            return 1
          }
        else
          [ "$ONE_GATE_EXIT" -eq 0 ] || {
            echo "Expected sibling gate $(basename "$s") to pass $tool/$type_mode, got exit $ONE_GATE_EXIT"
            echo "stderr: $ONE_GATE_STDERR"
            return 1
          }
        fi
      done
    done
  done
}

@test "composition #15: missing or null type plus sonnet write dispatch clears all Agent and Task gates" {
  local tool type_mode payload s
  for tool in Agent Task; do
    discover_agent_gates
    [[ "$tool" == "Task" ]] && discover_task_gates
    for type_mode in omit __NULL__; do
      payload=$(mk_composed_payload "$tool" "false" "omit" "$type_mode" "omit" "修复 main.py 里的 bug" "$NEUTRAL_DESC" "sonnet")
      for s in "${GATE_SCRIPTS[@]}"; do
        run_one_gate "$s" "$payload"
        [ "$ONE_GATE_EXIT" -eq 0 ] || {
          echo "Expected sonnet dispatch $tool/$type_mode to pass $(basename "$s"), got exit $ONE_GATE_EXIT"
          echo "stderr: $ONE_GATE_STDERR"
          return 1
        }
      done
    done
  done
}
