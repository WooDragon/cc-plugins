#!/bin/bash
# Test infrastructure for subagent-done-gate hook BDD tests.

GATE_SCRIPT="${BATS_TEST_DIRNAME}/../hooks/subagent-done-gate.sh"

MARK='%%DONE%%'

# --- Setup / Teardown ---

common_setup() {
  TEST_TEMP_DIR=$(mktemp -d)
}

common_teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

# --- Transcript Fixture Builders ---

# mk_transcript REQUIRE_MARK(0/1) [BLOCK_FORM(0/1)]
# Writes a 2-line JSONL fixture. Line 1 is the "dispatch prompt" line the hook
# inspects. When REQUIRE_MARK=1 the text contains the MARK substring.
# BLOCK_FORM=1 uses content block array form (type:text) for line 1.
mk_transcript() {
  local require="$1" block_form="${2:-0}"
  local file text
  file=$(mktemp "$TEST_TEMP_DIR/transcript.XXXXXX")
  if [[ "$require" == "1" ]]; then
    text="请把完整报告直接输出在最终消息里，并在末尾单独一行输出 ${MARK}"
  else
    text="请完成任务并汇报结果"
  fi
  if [[ "$block_form" == "1" ]]; then
    jq -cn --arg t "$text" \
      '{type:"user",message:{role:"user",content:[{type:"text",text:$t}]}}' > "$file"
  else
    jq -cn --arg t "$text" \
      '{type:"user",message:{role:"user",content:$t}}' > "$file"
  fi
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":"filler line, never read"}}' >> "$file"
  echo "$file"
}

# mk_fork_transcript REQUIRE_MARK(0/1)
# Reproduces the fork shape: line 1 is type:"fork-context-ref" with no prompt;
# the dispatch text lives on line 2 inside the assistant tool_use input.
mk_fork_transcript() {
  local require="$1"
  local file text
  file=$(mktemp "$TEST_TEMP_DIR/transcript.XXXXXX")
  if [[ "$require" == "1" ]]; then
    text="请把完整报告直接输出在最终消息里，并在末尾单独一行输出 ${MARK}"
  else
    text="请完成任务并汇报结果"
  fi
  printf '%s\n' '{"type":"fork-context-ref","agentId":"test-fork-0000","parentSessionId":"p0","parentLastUuid":"u0","contextLength":17}' > "$file"
  jq -cn --arg t "$text" '{
    type:"assistant",
    message:{role:"assistant",content:[{type:"tool_use",name:"Agent",
      input:{description:"d",prompt:$t,subagent_type:"fork"}}]}
  }' >> "$file"
  echo "$file"
}

# --- Payload Builders ---

# mk_payload STOP_HOOK_ACTIVE(true/false) TRANSCRIPT_PATH LAST_MSG [OMIT_TRANSCRIPT(0/1)]
mk_payload() {
  local stop="$1" tp="$2" last="$3" omit="${4:-0}"
  jq -cn \
    --argjson stop "$stop" \
    --arg tp "$tp" \
    --arg last "$last" \
    --argjson omit "$omit" '
    {
      hook_event_name: "SubagentStop",
      stop_hook_active: $stop,
      agent_id: "test-agent-0000",
      agent_type: "worker",
      last_assistant_message: $last
    }
    | if $omit == 1 then . else . + {agent_transcript_path: $tp} end
  '
}

# mk_payload_null_last STOP_HOOK_ACTIVE(true/false) TRANSCRIPT_PATH
# last_assistant_message field is null, not an empty string.
mk_payload_null_last() {
  local stop="$1" tp="$2"
  jq -cn \
    --argjson stop "$stop" \
    --arg tp "$tp" '
    {
      hook_event_name: "SubagentStop",
      stop_hook_active: $stop,
      agent_id: "test-agent-0000",
      agent_type: "worker",
      last_assistant_message: null,
      agent_transcript_path: $tp
    }
  '
}

# --- Run Helper ---

# run_gate PAYLOAD [env_overrides...]
# Sets: HOOK_STDOUT, HOOK_STDERR, HOOK_EXIT
run_gate() {
  local payload="$1"
  HOOK_STDOUT=""
  HOOK_STDERR=""
  HOOK_EXIT=0

  local stderr_file
  stderr_file=$(mktemp)

  if [[ "${2:-}" != "" ]]; then
    HOOK_STDOUT=$(printf '%s' "$payload" | env "${@:2}" bash "$GATE_SCRIPT" 2>"$stderr_file") || HOOK_EXIT=$?
  else
    HOOK_STDOUT=$(printf '%s' "$payload" | bash "$GATE_SCRIPT" 2>"$stderr_file") || HOOK_EXIT=$?
  fi
  HOOK_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

# ============================================================
# Additions below support dispatch-sync-guard.bats
# (PreToolUse sync guard + SubagentStart rules injector).
# Existing functions above are untouched — subagent-done-gate.bats
# depends on them as-is.
# ============================================================

SYNC_GUARD_SCRIPT="${BATS_TEST_DIRNAME}/../hooks/dispatch-sync-guard.sh"
INJECT_SCRIPT="${BATS_TEST_DIRNAME}/../hooks/dispatch-rules-inject.sh"

# --- Payload Builders (dispatch-sync-guard) ---

# mk_dispatch_payload TOOL_NAME RIB_MODE [AGENT_ID_MODE] [NAME_MODE]
# TOOL_NAME: any string (e.g. Agent, Task, Bash)
# RIB_MODE: false | true | string_false | omit  (tool_input.run_in_background)
# AGENT_ID_MODE (optional, default omit): omit | present | empty
# NAME_MODE (optional, default omit): omit | present  (tool_input.name)
mk_dispatch_payload() {
  local tool="$1" rib_mode="$2" agent_id_mode="${3:-omit}" name_mode="${4:-omit}"
  local tool_input
  case "$rib_mode" in
    false)        tool_input=$(jq -cn '{run_in_background:false}') ;;
    true)         tool_input=$(jq -cn '{run_in_background:true}') ;;
    string_false) tool_input=$(jq -cn '{run_in_background:"false"}') ;;
    omit)         tool_input='{}' ;;
    *)            tool_input='{}' ;;
  esac
  if [[ "$name_mode" == "present" ]]; then
    tool_input=$(jq -cn --argjson base "$tool_input" '$base + {name:"lead"}')
  fi
  local payload
  payload=$(jq -cn --arg tool "$tool" --argjson ti "$tool_input" '{tool_name:$tool, tool_input:$ti}')
  case "$agent_id_mode" in
    present) payload=$(jq -cn --argjson base "$payload" '$base + {agent_id:"test-agent-0000"}') ;;
    empty)   payload=$(jq -cn --argjson base "$payload" '$base + {agent_id:""}') ;;
    omit)    ;;
  esac
  echo "$payload"
}

# --- Payload Builders (dispatch-rules-inject) ---

# mk_start_payload [AGENT_TYPE]
# AGENT_TYPE omitted entirely from payload when not passed.
mk_start_payload() {
  local agent_type="${1:-}"
  if [[ -z "$agent_type" ]]; then
    jq -cn '{}'
  else
    jq -cn --arg t "$agent_type" '{agent_type:$t}'
  fi
}

# --- Run Helpers ---

# run_sync_guard PAYLOAD [env_overrides...]
# Sets: SYNC_STDOUT, SYNC_STDERR, SYNC_EXIT
run_sync_guard() {
  local payload="$1"
  SYNC_STDOUT=""
  SYNC_STDERR=""
  SYNC_EXIT=0

  local stderr_file
  stderr_file=$(mktemp)

  if [[ "${2:-}" != "" ]]; then
    SYNC_STDOUT=$(printf '%s' "$payload" | env "${@:2}" bash "$SYNC_GUARD_SCRIPT" 2>"$stderr_file") || SYNC_EXIT=$?
  else
    SYNC_STDOUT=$(printf '%s' "$payload" | bash "$SYNC_GUARD_SCRIPT" 2>"$stderr_file") || SYNC_EXIT=$?
  fi
  SYNC_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

# run_rules_inject PAYLOAD [env_overrides...]
# Sets: INJECT_STDOUT, INJECT_STDERR, INJECT_EXIT
run_rules_inject() {
  local payload="$1"
  INJECT_STDOUT=""
  INJECT_STDERR=""
  INJECT_EXIT=0

  local stderr_file
  stderr_file=$(mktemp)

  if [[ "${2:-}" != "" ]]; then
    INJECT_STDOUT=$(printf '%s' "$payload" | env "${@:2}" bash "$INJECT_SCRIPT" 2>"$stderr_file") || INJECT_EXIT=$?
  else
    INJECT_STDOUT=$(printf '%s' "$payload" | bash "$INJECT_SCRIPT" 2>"$stderr_file") || INJECT_EXIT=$?
  fi
  INJECT_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

# --- Assertion Helpers (dispatch-sync-guard) ---

# assert_sync_pass — exit 0 and no "dispatch-sync-guard" in stderr
assert_sync_pass() {
  [ "$SYNC_EXIT" -eq 0 ] || {
    echo "Expected exit 0, got $SYNC_EXIT"
    echo "stderr: $SYNC_STDERR"
    return 1
  }
  [[ "$SYNC_STDERR" != *"dispatch-sync-guard"* ]] || {
    echo "Expected no 'dispatch-sync-guard' in stderr, got: $SYNC_STDERR"
    return 1
  }
}

# assert_sync_block — exit 2 and "dispatch-sync-guard" in stderr
assert_sync_block() {
  [ "$SYNC_EXIT" -eq 2 ] || {
    echo "Expected exit 2, got $SYNC_EXIT"
    echo "stderr: $SYNC_STDERR"
    return 1
  }
  [[ "$SYNC_STDERR" == *"dispatch-sync-guard"* ]] || {
    echo "Expected 'dispatch-sync-guard' in stderr, got: $SYNC_STDERR"
    return 1
  }
}

# --- Assertion Helpers (dispatch-rules-inject) ---

# assert_inject_empty_stdout — exit 0 and completely empty stdout
assert_inject_empty_stdout() {
  [ "$INJECT_EXIT" -eq 0 ] || {
    echo "Expected exit 0, got $INJECT_EXIT"
    echo "stderr: $INJECT_STDERR"
    return 1
  }
  [ -z "$INJECT_STDOUT" ] || {
    echo "Expected empty stdout, got: $INJECT_STDOUT"
    return 1
  }
}

# --- Assertion Helpers (existing — subagent-done-gate.bats) ---

# assert_pass — exit 0 and no "subagent-done-gate" in stderr
assert_pass() {
  [ "$HOOK_EXIT" -eq 0 ] || {
    echo "Expected exit 0, got $HOOK_EXIT"
    echo "stderr: $HOOK_STDERR"
    return 1
  }
  [[ "$HOOK_STDERR" != *"subagent-done-gate"* ]] || {
    echo "Expected no 'subagent-done-gate' in stderr, got: $HOOK_STDERR"
    return 1
  }
}

# assert_block — exit 2 and "subagent-done-gate" in stderr
assert_block() {
  [ "$HOOK_EXIT" -eq 2 ] || {
    echo "Expected exit 2, got $HOOK_EXIT"
    echo "stderr: $HOOK_STDERR"
    return 1
  }
  [[ "$HOOK_STDERR" == *"subagent-done-gate"* ]] || {
    echo "Expected 'subagent-done-gate' in stderr, got: $HOOK_STDERR"
    return 1
  }
}
