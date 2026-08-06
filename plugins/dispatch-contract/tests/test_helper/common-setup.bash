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

  # 夹具必须隔离调用者环境：若跑测试的 shell 里设了 ALLOW_UNMARKED_FINAL=1
  # (subagent-done-gate 的逃生舱),门禁会全局失效,导致每个 BLOCK 用例假通过。
  # -u 排在显式 override 之前,用例仍能主动传该变量做正向测试。
  if [[ "${2:-}" != "" ]]; then
    HOOK_STDOUT=$(printf '%s' "$payload" | env -u ALLOW_UNMARKED_FINAL "${@:2}" bash "$GATE_SCRIPT" 2>"$stderr_file") || HOOK_EXIT=$?
  else
    HOOK_STDOUT=$(printf '%s' "$payload" | env -u ALLOW_UNMARKED_FINAL bash "$GATE_SCRIPT" 2>"$stderr_file") || HOOK_EXIT=$?
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
  elif [[ "$name_mode" == "tab" ]]; then
    # Tab-only name: must read as blank. Guards against ${var// /}, which
    # strips only U+0020 and would let this fake the team-ops exemption.
    tool_input=$(jq -cn --argjson base "$tool_input" '$base + {name:"\t"}')
  fi
  local payload
  payload=$(jq -cn --arg tool "$tool" --argjson ti "$tool_input" '{tool_name:$tool, tool_input:$ti}')
  case "$agent_id_mode" in
    present) payload=$(jq -cn --argjson base "$payload" '$base + {agent_id:"test-agent-0000"}') ;;
    empty)   payload=$(jq -cn --argjson base "$payload" '$base + {agent_id:""}') ;;
    # Tab-only / newline-only agent_id: same blank-detection trap as name above.
    tab)     payload=$(jq -cn --argjson base "$payload" '$base + {agent_id:"\t"}') ;;
    newline) payload=$(jq -cn --argjson base "$payload" '$base + {agent_id:"\n"}') ;;
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

  # 夹具必须隔离调用者环境：若跑测试的 shell 里设了 ALLOW_BACKGROUND_DISPATCH=1
  # 或 CLAUDE_CODE_DISABLE_BACKGROUND_TASKS,门禁会全部 fail-open,导致每个
  # BLOCK 用例假通过。测试结果不该取决于谁在什么 shell 里跑。
  # 注意 -u 必须排在显式 override 之前,这样用例仍能主动传这两个变量做正向测试。
  if [[ "${2:-}" != "" ]]; then
    SYNC_STDOUT=$(printf '%s' "$payload" | env -u ALLOW_BACKGROUND_DISPATCH -u CLAUDE_CODE_DISABLE_BACKGROUND_TASKS "${@:2}" bash "$SYNC_GUARD_SCRIPT" 2>"$stderr_file") || SYNC_EXIT=$?
  else
    SYNC_STDOUT=$(printf '%s' "$payload" | env -u ALLOW_BACKGROUND_DISPATCH -u CLAUDE_CODE_DISABLE_BACKGROUND_TASKS bash "$SYNC_GUARD_SCRIPT" 2>"$stderr_file") || SYNC_EXIT=$?
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

  # 夹具必须隔离调用者环境：若跑测试的 shell 里设了 ALLOW_NO_RULES_INJECT=1
  # (dispatch-rules-inject 的逃生舱),门禁会静默 exit 0 不注入,导致用例假通过。
  # -u 排在显式 override 之前,用例仍能主动传该变量做正向测试。
  if [[ "${2:-}" != "" ]]; then
    INJECT_STDOUT=$(printf '%s' "$payload" | env -u ALLOW_NO_RULES_INJECT "${@:2}" bash "$INJECT_SCRIPT" 2>"$stderr_file") || INJECT_EXIT=$?
  else
    INJECT_STDOUT=$(printf '%s' "$payload" | env -u ALLOW_NO_RULES_INJECT bash "$INJECT_SCRIPT" 2>"$stderr_file") || INJECT_EXIT=$?
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

# ============================================================
# Additions below support dispatch-capability-guard.bats
# (PreToolUse hook: subagent_type/model capability mismatch guard,
# judgments A/B/C). Existing functions above are untouched —
# subagent-done-gate.bats and dispatch-sync-guard.bats depend on them
# as-is.
# ============================================================

CAP_GUARD_SCRIPT="${BATS_TEST_DIRNAME}/../hooks/dispatch-capability-guard.sh"

# --- Payload Builder (dispatch-capability-guard) ---

# mk_cap_payload SUBAGENT_TYPE_MODE PROMPT [MODEL_MODE]
# SUBAGENT_TYPE_MODE: omit | any other string (used verbatim as subagent_type value)
# PROMPT: prompt text. Pass "" for an explicit empty string (field present but
#         blank); use PROMPT_MODE=omit (4th positional, see below) to omit the
#         field entirely instead.
# MODEL_MODE: omit | any other string (used verbatim as model value)
# 4th optional arg PROMPT_FIELD_MODE: omit | present(default) — when "omit",
#   the prompt key itself is absent from tool_input (distinct from prompt:"").
mk_cap_payload() {
  local type_mode="$1" prompt="$2" model_mode="${3:-omit}" prompt_field_mode="${4:-present}"
  local ti='{}'
  if [[ "$type_mode" != "omit" ]]; then
    ti=$(jq -cn --argjson base "$ti" --arg v "$type_mode" '$base + {subagent_type:$v}')
  fi
  if [[ "$prompt_field_mode" != "omit" ]]; then
    ti=$(jq -cn --argjson base "$ti" --arg v "$prompt" '$base + {prompt:$v}')
  fi
  if [[ "$model_mode" != "omit" ]]; then
    ti=$(jq -cn --argjson base "$ti" --arg v "$model_mode" '$base + {model:$v}')
  fi
  jq -cn --argjson ti "$ti" '{tool_input:$ti}'
}

# mk_cap_payload_null_input
# tool_input is JSON null, not an object — malformed-shape fixture.
mk_cap_payload_null_input() {
  jq -cn '{tool_input:null}'
}

# --- Run Helper (dispatch-capability-guard) ---

# run_cap_guard PAYLOAD [env_overrides...]
# Sets: CAP_STDOUT, CAP_STDERR, CAP_EXIT
run_cap_guard() {
  local payload="$1"
  CAP_STDOUT=""
  CAP_STDERR=""
  CAP_EXIT=0

  local stderr_file
  stderr_file=$(mktemp)

  # 夹具必须隔离调用者环境：若跑测试的 shell 里设了
  # ALLOW_DISPATCH_CAPABILITY_MISMATCH=1 (本 hook 的逃生舱),门禁会全局失效,
  # 导致每个 BLOCK 用例假通过。-u 排在显式 override 之前,用例仍能主动传该
  # 变量做正向测试（见 GATE-BYPASS 用例）。
  if [[ "${2:-}" != "" ]]; then
    CAP_STDOUT=$(printf '%s' "$payload" | env -u ALLOW_DISPATCH_CAPABILITY_MISMATCH "${@:2}" bash "$CAP_GUARD_SCRIPT" 2>"$stderr_file") || CAP_EXIT=$?
  else
    CAP_STDOUT=$(printf '%s' "$payload" | env -u ALLOW_DISPATCH_CAPABILITY_MISMATCH bash "$CAP_GUARD_SCRIPT" 2>"$stderr_file") || CAP_EXIT=$?
  fi
  CAP_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

# run_cap_guard_stdin RAW_STDIN [env_overrides...]
# Like run_cap_guard but takes a raw stdin string instead of building/echoing
# a JSON payload — for malformed-input fixtures (empty, non-JSON, etc.) where
# there is no well-formed payload to build.
run_cap_guard_stdin() {
  local raw="$1"
  CAP_STDOUT=""
  CAP_STDERR=""
  CAP_EXIT=0

  local stderr_file
  stderr_file=$(mktemp)

  if [[ "${2:-}" != "" ]]; then
    CAP_STDOUT=$(printf '%s' "$raw" | env -u ALLOW_DISPATCH_CAPABILITY_MISMATCH "${@:2}" bash "$CAP_GUARD_SCRIPT" 2>"$stderr_file") || CAP_EXIT=$?
  else
    CAP_STDOUT=$(printf '%s' "$raw" | env -u ALLOW_DISPATCH_CAPABILITY_MISMATCH bash "$CAP_GUARD_SCRIPT" 2>"$stderr_file") || CAP_EXIT=$?
  fi
  CAP_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

# --- Assertion Helpers (dispatch-capability-guard) ---

# assert_cap_pass — exit 0 and no "dispatch-capability-guard" in stderr
assert_cap_pass() {
  [ "$CAP_EXIT" -eq 0 ] || {
    echo "Expected exit 0, got $CAP_EXIT"
    echo "stderr: $CAP_STDERR"
    return 1
  }
  [[ "$CAP_STDERR" != *"dispatch-capability-guard"* ]] || {
    echo "Expected no 'dispatch-capability-guard' in stderr, got: $CAP_STDERR"
    return 1
  }
}

# assert_cap_block JUDGMENT(A|B|C) — exit 2 and stderr names the judgment
# ("命中判据 A" / "命中判据 B" / "命中判据 C"), anchoring the assertion to
# WHICH branch fired rather than exit code alone (mutation-testing requirement:
# a stray path that also exits 2 for the wrong reason must not pass this).
assert_cap_block() {
  local judgment="$1"
  [ "$CAP_EXIT" -eq 2 ] || {
    echo "Expected exit 2, got $CAP_EXIT"
    echo "stderr: $CAP_STDERR"
    return 1
  }
  [[ "$CAP_STDERR" == *"命中判据 ${judgment}"* ]] || {
    echo "Expected '命中判据 ${judgment}' in stderr, got: $CAP_STDERR"
    return 1
  }
}
