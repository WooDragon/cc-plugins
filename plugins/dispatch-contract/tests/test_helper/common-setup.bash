#!/bin/bash
# Test infrastructure for subagent-done-gate hook BDD tests.

GATE_SCRIPT="${BATS_TEST_DIRNAME}/../hooks/subagent-done-gate.sh"

MARK='%%DONE%%'

# --- Setup / Teardown ---

cleanup_test_temp_dir() {
  rm -rf "${TEST_TEMP_DIR:-}"
}

restore_common_setup_traps() {
  trap - EXIT INT TERM
  [ -n "${COMMON_SETUP_PREVIOUS_EXIT_TRAP:-}" ] && eval "$COMMON_SETUP_PREVIOUS_EXIT_TRAP"
  [ -n "${COMMON_SETUP_PREVIOUS_INT_TRAP:-}" ] && eval "$COMMON_SETUP_PREVIOUS_INT_TRAP"
  [ -n "${COMMON_SETUP_PREVIOUS_TERM_TRAP:-}" ] && eval "$COMMON_SETUP_PREVIOUS_TERM_TRAP"
  return 0
}

cleanup_and_terminate() {
  local signal="$1"
  cleanup_test_temp_dir
  trap - EXIT INT TERM
  kill -s "$signal" "$$"
}

common_setup() {
  COMMON_SETUP_PREVIOUS_EXIT_TRAP=$(trap -p EXIT)
  COMMON_SETUP_PREVIOUS_INT_TRAP=$(trap -p INT)
  COMMON_SETUP_PREVIOUS_TERM_TRAP=$(trap -p TERM)
  TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dispatch-contract.XXXXXX") || return 1
  trap cleanup_test_temp_dir EXIT
  trap 'cleanup_and_terminate INT' INT
  trap 'cleanup_and_terminate TERM' TERM
}

common_teardown() {
  cleanup_test_temp_dir
  restore_common_setup_traps
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

# mk_bytes N — a single-line, N-byte ASCII string ('x' repeated). Used to
# build fixtures that land exactly on/around the FLOOR byte threshold —
# English 'x' is guaranteed 1 byte/char, unlike the Chinese filler text used
# elsewhere in this suite, so the caller controls the exact byte count.
mk_bytes() {
  local n="$1"
  printf 'x%.0s' $(seq 1 "$n")
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
  stderr_file=$(mktemp "$TEST_TEMP_DIR/stderr.XXXXXX") || return 1

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
  stderr_file=$(mktemp "$TEST_TEMP_DIR/stderr.XXXXXX") || return 1

  # 夹具必须隔离调用者环境：若跑测试的 shell 里设了 ALLOW_BACKGROUND_DISPATCH=1、
  # CLAUDE_CODE_DISABLE_BACKGROUND_TASKS 或 CLAUDE_AUTO_BACKGROUND_TASKS,门禁
  # 会全部 fail-open(或改判 BLOCK),导致用例假通过/假失败。测试结果不该取决于
  # 谁在什么 shell 里跑。注意 -u 必须排在显式 override 之前,这样用例仍能主动
  # 传这三个变量做正向测试。
  if [[ "${2:-}" != "" ]]; then
    SYNC_STDOUT=$(printf '%s' "$payload" | env -u ALLOW_BACKGROUND_DISPATCH -u CLAUDE_CODE_DISABLE_BACKGROUND_TASKS -u CLAUDE_AUTO_BACKGROUND_TASKS "${@:2}" bash "$SYNC_GUARD_SCRIPT" 2>"$stderr_file") || SYNC_EXIT=$?
  else
    SYNC_STDOUT=$(printf '%s' "$payload" | env -u ALLOW_BACKGROUND_DISPATCH -u CLAUDE_CODE_DISABLE_BACKGROUND_TASKS -u CLAUDE_AUTO_BACKGROUND_TASKS bash "$SYNC_GUARD_SCRIPT" 2>"$stderr_file") || SYNC_EXIT=$?
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
  stderr_file=$(mktemp "$TEST_TEMP_DIR/stderr.XXXXXX") || return 1

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

# ============================================================
# Additions below support dispatch-channel-guard.bats
# (PreToolUse channel/protocol-match guard, pre-dispatch-channel-guard.sh).
# Existing functions above are untouched.
# ============================================================

CHANNEL_GUARD_SCRIPT="${BATS_TEST_DIRNAME}/../hooks/pre-dispatch-channel-guard.sh"

# --- Payload Builders (dispatch-channel-guard) ---

# mk_channel_payload TOOL_NAME NAME SUBAGENT_TYPE CWD
# Any of NAME / SUBAGENT_TYPE / CWD passed as the literal string "__OMIT__"
# omits that field from the payload entirely (distinct from an empty string,
# which is a present-but-blank value). NAME/SUBAGENT_TYPE go under
# tool_input; CWD is a top-level payload field (matches the script's `.cwd`
# read, not $PWD).
mk_channel_payload() {
  local tool="$1" name_val="$2" subtype_val="$3" cwd_val="$4"
  local tool_input='{}'
  if [[ "$name_val" != "__OMIT__" ]]; then
    tool_input=$(jq -cn --argjson base "$tool_input" --arg n "$name_val" '$base + {name:$n}')
  fi
  if [[ "$subtype_val" != "__OMIT__" ]]; then
    tool_input=$(jq -cn --argjson base "$tool_input" --arg s "$subtype_val" '$base + {subagent_type:$s}')
  fi
  local payload
  payload=$(jq -cn --arg tool "$tool" --argjson ti "$tool_input" '{tool_name:$tool, tool_input:$ti}')
  if [[ "$cwd_val" != "__OMIT__" ]]; then
    payload=$(jq -cn --argjson base "$payload" --arg c "$cwd_val" '$base + {cwd:$c}')
  fi
  echo "$payload"
}

# --- Run Helper (dispatch-channel-guard) ---

# run_channel_guard PAYLOAD [env_overrides...]
# Sets: CHANNEL_STDOUT, CHANNEL_STDERR, CHANNEL_EXIT
#
# Isolates all six escape-hatch/fail-open env vars any of this plugin's
# PreToolUse(Agent|Task) guards read, not just this gate's own
# ALLOW_UNMANAGED_TEAMMATE — a BLOCK test here must not silently PASS because
# the calling shell happens to have ALLOW_BACKGROUND_DISPATCH,
# CLAUDE_CODE_DISABLE_BACKGROUND_TASKS, CLAUDE_AUTO_BACKGROUND_TASKS, or
# ALLOW_DISPATCH_CAPABILITY_MISMATCH set for an unrelated sibling guard's
# tests. -u is placed before any explicit override, so a test can still pass
# one of them positively.
run_channel_guard() {
  local payload="$1"
  CHANNEL_STDOUT=""
  CHANNEL_STDERR=""
  CHANNEL_EXIT=0

  local stderr_file
  stderr_file=$(mktemp "$TEST_TEMP_DIR/stderr.XXXXXX") || return 1

  if [[ "${2:-}" != "" ]]; then
    CHANNEL_STDOUT=$(printf '%s' "$payload" | env -u ALLOW_UNMANAGED_TEAMMATE -u ALLOW_BACKGROUND_DISPATCH -u CLAUDE_CODE_DISABLE_BACKGROUND_TASKS -u CLAUDE_AUTO_BACKGROUND_TASKS -u ALLOW_DISPATCH_CAPABILITY_MISMATCH -u ALLOW_AGENT_MODEL_INHERIT "${@:2}" bash "$CHANNEL_GUARD_SCRIPT" 2>"$stderr_file") || CHANNEL_EXIT=$?
  else
    CHANNEL_STDOUT=$(printf '%s' "$payload" | env -u ALLOW_UNMANAGED_TEAMMATE -u ALLOW_BACKGROUND_DISPATCH -u CLAUDE_CODE_DISABLE_BACKGROUND_TASKS -u CLAUDE_AUTO_BACKGROUND_TASKS -u ALLOW_DISPATCH_CAPABILITY_MISMATCH -u ALLOW_AGENT_MODEL_INHERIT bash "$CHANNEL_GUARD_SCRIPT" 2>"$stderr_file") || CHANNEL_EXIT=$?
  fi
  CHANNEL_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

# --- Assertion Helpers (dispatch-channel-guard) ---

# assert_channel_pass — exit 0 and no BLOCK-shaped "[dispatch-channel-guard]"
# marker in stderr. NOTE this is narrower than the sibling sync-guard
# assertion's bare-substring check: this gate is built on lib/gate.sh's
# gate_preamble, whose fail-open/escape-hatch paths legitimately write
# "[GATE-DEGRADE] dispatch-channel-guard: ..." / "[GATE-BYPASS]
# dispatch-channel-guard: ..." on PASS itself (see channel #15/#16/#17) — those
# contain the bare gate name too, so a bare-substring check would wrongly fail
# every one of those legitimate PASS cases. The bracket-wrapped
# "[dispatch-channel-guard]" form is only ever emitted by this script's own
# terminal BLOCK message (see the two `printf` calls before `exit 2` in
# pre-dispatch-channel-guard.sh) — that literal is what distinguishes "this
# gate actually blocked" from "this gate's preamble merely logged a
# degrade/bypass note on its way to passing".
assert_channel_pass() {
  [ "$CHANNEL_EXIT" -eq 0 ] || {
    echo "Expected exit 0, got $CHANNEL_EXIT"
    echo "stderr: $CHANNEL_STDERR"
    return 1
  }
  [[ "$CHANNEL_STDERR" != *"[dispatch-channel-guard]"* ]] || {
    echo "Expected no BLOCK marker '[dispatch-channel-guard]' in stderr, got: $CHANNEL_STDERR"
    return 1
  }
}

# assert_channel_block — exit 2 and the "[dispatch-channel-guard]" BLOCK
# marker in stderr (see assert_channel_pass above for why this is the
# bracket-wrapped form, not the bare gate name).
assert_channel_block() {
  [ "$CHANNEL_EXIT" -eq 2 ] || {
    echo "Expected exit 2, got $CHANNEL_EXIT"
    echo "stderr: $CHANNEL_STDERR"
    return 1
  }
  [[ "$CHANNEL_STDERR" == *"[dispatch-channel-guard]"* ]] || {
    echo "Expected BLOCK marker '[dispatch-channel-guard]' in stderr, got: $CHANNEL_STDERR"
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

# assert_block_marker_only — assert_block, plus the directive that names the
# marker-only path. Both reject paths exit 2, so exit code alone cannot tell
# them apart: a regression that loses the marker-only judgment would fall
# through to "末尾未检测到" and still satisfy assert_block.
assert_block_marker_only() {
  assert_block || return 1
  [[ "$HOOK_STDERR" == *"报告是空的"* ]] || {
    echo "Expected the marker-only directive ('报告是空的') in stderr, got: $HOOK_STDERR"
    return 1
  }
}

# assert_pass_with_warning — exit 0, no BLOCK marker in stderr (assert_pass),
# and stdout carries a systemMessage JSON payload (the ≥FLOOR warn-not-block
# path). Distinct from bare assert_pass so a regression that silently drops
# the warning (falls through to plain fail-open) still fails this assertion
# even though exit code alone would look identical.
assert_pass_with_warning() {
  assert_pass || return 1
  jq -e '.systemMessage | length > 0' <<< "$HOOK_STDOUT" >/dev/null 2>&1 || {
    echo "Expected stdout to carry a non-empty systemMessage, got: $HOOK_STDOUT"
    return 1
  }
}

# assert_block_echoes ORIGINAL_BODY — assert_block, plus the exact original
# body text must appear verbatim in stderr (the <FLOOR echo-back path).
assert_block_echoes() {
  local body="$1"
  assert_block || return 1
  [[ "$HOOK_STDERR" == *"$body"* ]] || {
    echo "Expected the original body echoed back in stderr, got: $HOOK_STDERR"
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
# SUBAGENT_TYPE_MODE: omit | null | any other string (used verbatim as subagent_type value)
# PROMPT: prompt text. Pass "" for an explicit empty string (field present but
#         blank); use PROMPT_MODE=omit (4th positional, see below) to omit the
#         field entirely instead.
# MODEL_MODE: omit | any other string (used verbatim as model value)
# 4th optional arg PROMPT_FIELD_MODE: omit | present(default) — when "omit",
#   the prompt key itself is absent from tool_input (distinct from prompt:"").
mk_cap_payload() {
  local type_mode="$1" prompt="$2" model_mode="${3:-omit}" prompt_field_mode="${4:-present}"
  local ti='{}'
  case "$type_mode" in
    omit) ;;
    null) ti=$(jq -cn --argjson base "$ti" '$base + {subagent_type:null}') ;;
    *) ti=$(jq -cn --argjson base "$ti" --arg v "$type_mode" '$base + {subagent_type:$v}') ;;
  esac
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
  stderr_file=$(mktemp "$TEST_TEMP_DIR/stderr.XXXXXX") || return 1

  # 夹具必须隔离调用者环境：若跑测试的 shell 里设了
  # ALLOW_DISPATCH_CAPABILITY_MISMATCH=1 (本 hook 的逃生舱),门禁会全局失效,
  # 导致每个 BLOCK 用例假通过。-u 排在显式 override 之前,用例仍能主动传该
  # 变量做正向测试（见 GATE-BYPASS 用例）。
  if [[ "${2:-}" != "" ]]; then
    CAP_STDOUT=$(printf '%s' "$payload" | env -u ALLOW_DISPATCH_CAPABILITY_MISMATCH -u ALLOW_AGENT_MODEL_INHERIT "${@:2}" bash "$CAP_GUARD_SCRIPT" 2>"$stderr_file") || CAP_EXIT=$?
  else
    CAP_STDOUT=$(printf '%s' "$payload" | env -u ALLOW_DISPATCH_CAPABILITY_MISMATCH -u ALLOW_AGENT_MODEL_INHERIT bash "$CAP_GUARD_SCRIPT" 2>"$stderr_file") || CAP_EXIT=$?
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
  stderr_file=$(mktemp "$TEST_TEMP_DIR/stderr.XXXXXX") || return 1

  if [[ "${2:-}" != "" ]]; then
    CAP_STDOUT=$(printf '%s' "$raw" | env -u ALLOW_DISPATCH_CAPABILITY_MISMATCH -u ALLOW_AGENT_MODEL_INHERIT "${@:2}" bash "$CAP_GUARD_SCRIPT" 2>"$stderr_file") || CAP_EXIT=$?
  else
    CAP_STDOUT=$(printf '%s' "$raw" | env -u ALLOW_DISPATCH_CAPABILITY_MISMATCH -u ALLOW_AGENT_MODEL_INHERIT bash "$CAP_GUARD_SCRIPT" 2>"$stderr_file") || CAP_EXIT=$?
  fi
  CAP_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

# mk_no_jq_path
# Builds a temp dir containing symlinks to only the commands
# dispatch-capability-guard.sh itself invokes (bash, cat, tr — printf/command
# are builtins) MINUS jq, so `command -v jq` genuinely fails inside the
# hook's subprocess without also breaking bash's own startup (a bare
# PATH=/nonexistent would make bash itself unresolvable under `env`, giving
# exit 127 before the script's own jq check ever runs — that is a fixture
# bug, not a positive test of the jq-unavailable branch). Written into
# TEST_TEMP_DIR so common_teardown's `rm -rf` reclaims it; the mktemp/ln
# calls below run in the test's own shell (already on the real PATH), not
# inside the isolated PATH being constructed.
mk_no_jq_path() {
  local dir
  dir=$(mktemp -d "$TEST_TEMP_DIR/no-jq-path.XXXXXX")
  ln -s "$(command -v bash)" "$dir/bash"
  ln -s "$(command -v cat)" "$dir/cat"
  ln -s "$(command -v tr)" "$dir/tr"
  echo "$dir"
}

# run_cap_guard_no_jq PAYLOAD
# Like run_cap_guard, but runs the hook with PATH pointed at mk_no_jq_path's
# jq-less directory (via `env -i`, a clean environment, so no ambient PATH
# leaks jq back in) instead of the real PATH. Sets CAP_STDOUT/CAP_STDERR/CAP_EXIT.
run_cap_guard_no_jq() {
  local payload="$1"
  local no_jq_dir
  no_jq_dir=$(mk_no_jq_path)

  CAP_STDOUT=""
  CAP_STDERR=""
  CAP_EXIT=0

  local stderr_file
  stderr_file=$(mktemp "$TEST_TEMP_DIR/stderr.XXXXXX") || return 1

  CAP_STDOUT=$(printf '%s' "$payload" | env -i PATH="$no_jq_dir" bash "$CAP_GUARD_SCRIPT" 2>"$stderr_file") || CAP_EXIT=$?
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

# ============================================================
# Additions below support gate-composition.bats
# (composition test: every PreToolUse(Agent) guard this plugin declares in
# hooks.json, run against the same payload, checking the outroutes claimed
# in pre-dispatch-channel-guard.sh's header actually clear every gate — not
# just the one gate whose own test file was written with that outroute in
# mind. See gate-composition.bats header for the issue-173-shaped failure
# mode this exists to catch mechanically instead of by header comment.)
# ============================================================

HOOKS_JSON_PATH="${BATS_TEST_DIRNAME}/../hooks/hooks.json"
PLUGIN_ROOT_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

# _discover_gates_by_matcher MATCHER
# Reads hooks.json's PreToolUse section, keeps only hook entries whose
# matcher is exactly MATCHER, and resolves each hook's `command` string
# (shape: "bash ${CLAUDE_PLUGIN_ROOT}/hooks/xxx.sh") into a real script path
# under this checkout. Sets global array GATE_SCRIPTS. De-dupes so a script
# listed twice under the same matcher (should not happen, but nothing
# enforces it) is only invoked once per payload.
#
# This is the mechanism that keeps the composition test honest as the plugin
# grows: a third PreToolUse guard added to hooks.json tomorrow is picked up
# here automatically, with no edit to this file or to gate-composition.bats
# required. A hardcoded GATE_SCRIPTS=(a.sh b.sh) list would not have that
# property — it is exactly the shape of drift that let the channel-guard
# header's "does not collide with the other gate" claim go unverified for
# months (see gate-composition.bats header).
_discover_gates_by_matcher() {
  local matcher="$1"
  local raw
  raw=$(jq -r --arg m "$matcher" '
    .hooks.PreToolUse[]
    | select(.matcher == $m)
    | .hooks[].command
  ' "$HOOKS_JSON_PATH")

  local line resolved
  local -a resolved_all=()
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    resolved="${line#bash }"
    resolved="${resolved//\$\{CLAUDE_PLUGIN_ROOT\}/$PLUGIN_ROOT_DIR}"
    resolved_all+=("$resolved")
  done <<< "$raw"

  GATE_SCRIPTS=()
  local s seen_s dup
  for s in "${resolved_all[@]}"; do
    dup=0
    for seen_s in "${GATE_SCRIPTS[@]:-}"; do
      [[ "$seen_s" == "$s" ]] && { dup=1; break; }
    done
    [ "$dup" -eq 0 ] && GATE_SCRIPTS+=("$s")
  done
}

# discover_agent_gates — matcher "Agent". Sets GATE_SCRIPTS. See
# _discover_gates_by_matcher above for the mechanism.
discover_agent_gates() {
  _discover_gates_by_matcher "Agent"
}

# discover_task_gates — matcher "Task". Sets GATE_SCRIPTS. hooks.json
# mirrors the same four PreToolUse guards under both the "Agent" and
# "Task" matchers (Lead/PM dispatch via the Task tool as well as Agent), so
# any composition assertion built only from discover_agent_gates would stay
# green even if someone stripped a guard from the "Task" side only — the
# exact failure mode this function exists to make mechanically checkable
# instead of relying on the two matcher blocks in hooks.json staying in sync
# by eyeball (see gate-composition.bats "Task matcher mirrors Agent matcher").
discover_task_gates() {
  _discover_gates_by_matcher "Task"
}

# mk_composed_payload TOOL_NAME RIB_MODE NAME_MODE SUBTYPE_MODE CWD_MODE [PROMPT_MODE] [DESC_MODE] [MODEL_MODE]
#
# Single payload builder shared across all gates in GATE_SCRIPTS — the two
# existing per-gate builders (mk_dispatch_payload / mk_channel_payload) each
# omit a field the *other* gate reads (mk_dispatch_payload has no cwd;
# mk_channel_payload has no run_in_background), so neither can build a
# payload a composition test can feed to both without silently starving one
# gate's judgment data.
#
# RIB_MODE:      omit | false | true
# NAME_MODE:     omit | <literal string>   (tool_input.name)
# SUBTYPE_MODE:  omit | __NULL__ | <literal string>   (tool_input.subagent_type)
# CWD_MODE:      omit | <literal path>     (top-level .cwd)
# PROMPT_MODE:   omit | <literal string>   (tool_input.prompt, default omit)
# DESC_MODE:     omit | <literal string>   (tool_input.description, default omit)
# MODEL_MODE:    omit | <literal string>   (tool_input.model, default omit)
#
# PROMPT_MODE/DESC_MODE/MODEL_MODE default to "omit" so every existing call
# site (built before dispatch-capability-guard.sh joined GATE_SCRIPTS'
# composition coverage) keeps building the same payload shape it always did.
mk_composed_payload() {
  local tool="$1" rib="$2" name="$3" subtype="$4" cwd="$5"
  local prompt="${6:-omit}" desc="${7:-omit}" model="${8:-omit}"
  local ti='{}'
  case "$rib" in
    false) ti=$(jq -cn --argjson b "$ti" '$b + {run_in_background:false}') ;;
    true)  ti=$(jq -cn --argjson b "$ti" '$b + {run_in_background:true}') ;;
    omit)  ;;
  esac
  if [[ "$name" != "omit" ]]; then
    ti=$(jq -cn --argjson b "$ti" --arg n "$name" '$b + {name:$n}')
  fi
  case "$subtype" in
    omit) ;;
    __NULL__) ti=$(jq -cn --argjson b "$ti" '$b + {subagent_type:null}') ;;
    *) ti=$(jq -cn --argjson b "$ti" --arg s "$subtype" '$b + {subagent_type:$s}') ;;
  esac
  if [[ "$prompt" != "omit" ]]; then
    ti=$(jq -cn --argjson b "$ti" --arg p "$prompt" '$b + {prompt:$p}')
  fi
  if [[ "$desc" != "omit" ]]; then
    ti=$(jq -cn --argjson b "$ti" --arg d "$desc" '$b + {description:$d}')
  fi
  if [[ "$model" != "omit" ]]; then
    ti=$(jq -cn --argjson b "$ti" --arg m "$model" '$b + {model:$m}')
  fi
  local payload
  payload=$(jq -cn --arg tool "$tool" --argjson ti "$ti" '{tool_name:$tool, tool_input:$ti}')
  if [[ "$cwd" != "omit" ]]; then
    payload=$(jq -cn --argjson b "$payload" --arg c "$cwd" '$b + {cwd:$c}')
  fi
  echo "$payload"
}

# run_one_gate SCRIPT PAYLOAD [env_overrides...]
# Sets: ONE_GATE_EXIT, ONE_GATE_STDERR
#
# Same escape-hatch/fail-open isolation discipline as the sibling
# run_*_guard helpers above: a BLOCK case here must not silently PASS
# because the invoking shell happens to carry one of these six vars for an
# unrelated reason. This runner is shared across every gate discovered by
# discover_agent_gates/discover_task_gates (dispatch-sync-guard.sh,
# dispatch-capability-guard.sh, pre-dispatch-channel-guard.sh) — it must
# clear the union of all their escape hatches, not just the ones the gate
# under test in a given call happens to read, since a caller composing a
# payload for one gate may still route it through this same helper for
# another gate in the set.
run_one_gate() {
  local script="$1" payload="$2"
  shift 2
  ONE_GATE_EXIT=0
  local stderr_file
  stderr_file=$(mktemp "$TEST_TEMP_DIR/stderr.XXXXXX") || return 1
  if [[ "${1:-}" != "" ]]; then
    printf '%s' "$payload" | env -u ALLOW_UNMANAGED_TEAMMATE -u ALLOW_BACKGROUND_DISPATCH -u CLAUDE_CODE_DISABLE_BACKGROUND_TASKS -u CLAUDE_AUTO_BACKGROUND_TASKS -u ALLOW_DISPATCH_CAPABILITY_MISMATCH -u ALLOW_AGENT_MODEL_INHERIT "$@" bash "$script" >/dev/null 2>"$stderr_file" || ONE_GATE_EXIT=$?
  else
    printf '%s' "$payload" | env -u ALLOW_UNMANAGED_TEAMMATE -u ALLOW_BACKGROUND_DISPATCH -u CLAUDE_CODE_DISABLE_BACKGROUND_TASKS -u CLAUDE_AUTO_BACKGROUND_TASKS -u ALLOW_DISPATCH_CAPABILITY_MISMATCH -u ALLOW_AGENT_MODEL_INHERIT bash "$script" >/dev/null 2>"$stderr_file" || ONE_GATE_EXIT=$?
  fi
  ONE_GATE_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

# ============================================================
# Additions below support dispatch-agent-ownership-guard.bats.
# ============================================================

OWNERSHIP_GUARD_SCRIPT="${BATS_TEST_DIRNAME}/../hooks/dispatch-agent-ownership-guard.sh"

# mk_ownership_payload TOOL_NAME TYPE_MODE MODEL_MODE [MODEL_VALUE]
# TYPE_MODE: omit | null | any literal type. MODEL_MODE: omit | null | string.
mk_ownership_payload() {
  local tool="$1" type_mode="$2" model_mode="$3" model_value="${4:-}"
  local ti='{}'

  case "$type_mode" in
    omit) ;;
    null) ti=$(jq -cn --argjson base "$ti" '$base + {subagent_type:null}') ;;
    *) ti=$(jq -cn --argjson base "$ti" --arg value "$type_mode" '$base + {subagent_type:$value}') ;;
  esac
  case "$model_mode" in
    null) ti=$(jq -cn --argjson base "$ti" '$base + {model:null}') ;;
    string) ti=$(jq -cn --argjson base "$ti" --arg value "$model_value" '$base + {model:$value}') ;;
    omit) ;;
    *) return 2 ;;
  esac
  jq -cn --arg tool "$tool" --argjson ti "$ti" '{tool_name:$tool, tool_input:$ti}'
}

# run_ownership_guard PAYLOAD [env_overrides...]
# Sets: OWNERSHIP_STDOUT, OWNERSHIP_STDERR, OWNERSHIP_EXIT. The runner clears
# the ownership hatch before applying a test's explicit override.
run_ownership_guard() {
  run_ownership_script "$OWNERSHIP_GUARD_SCRIPT" "$@"
}

# run_ownership_script SCRIPT PAYLOAD [env_overrides...]
# Like run_ownership_guard, but accepts a temp-copy script for mutation tests.
run_ownership_script() {
  local script="$1" payload="$2"
  shift 2
  OWNERSHIP_STDOUT=""
  OWNERSHIP_STDERR=""
  OWNERSHIP_EXIT=0

  local stderr_file
  stderr_file=$(mktemp "$TEST_TEMP_DIR/stderr.XXXXXX") || return 1
  if [[ "${1:-}" != "" ]]; then
    OWNERSHIP_STDOUT=$(printf '%s' "$payload" | env -u ALLOW_AGENT_MODEL_INHERIT "$@" bash "$script" 2>"$stderr_file") || OWNERSHIP_EXIT=$?
  else
    OWNERSHIP_STDOUT=$(printf '%s' "$payload" | env -u ALLOW_AGENT_MODEL_INHERIT bash "$script" 2>"$stderr_file") || OWNERSHIP_EXIT=$?
  fi
  OWNERSHIP_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

run_ownership_guard_no_jq() {
  local payload="$1" no_jq_dir
  no_jq_dir=$(mk_no_jq_path)
  OWNERSHIP_STDOUT=""
  OWNERSHIP_STDERR=""
  OWNERSHIP_EXIT=0

  local stderr_file
  stderr_file=$(mktemp "$TEST_TEMP_DIR/stderr.XXXXXX") || return 1
  OWNERSHIP_STDOUT=$(printf '%s' "$payload" | env -i PATH="$no_jq_dir" bash "$OWNERSHIP_GUARD_SCRIPT" 2>"$stderr_file") || OWNERSHIP_EXIT=$?
  OWNERSHIP_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

assert_ownership_pass() {
  [ "$OWNERSHIP_EXIT" -eq 0 ] || {
    echo "Expected exit 0, got $OWNERSHIP_EXIT"
    echo "stderr: $OWNERSHIP_STDERR"
    return 1
  }
  [[ "$OWNERSHIP_STDERR" != *"[dispatch-agent-ownership-guard]"* ]] || {
    echo "Expected no ownership BLOCK marker, got: $OWNERSHIP_STDERR"
    return 1
  }
}

assert_ownership_block() {
  [ "$OWNERSHIP_EXIT" -eq 2 ] || {
    echo "Expected exit 2, got $OWNERSHIP_EXIT"
    echo "stderr: $OWNERSHIP_STDERR"
    return 1
  }
  [[ "$OWNERSHIP_STDERR" == *"[dispatch-agent-ownership-guard]"* ]] || {
    echo "Expected ownership BLOCK marker, got: $OWNERSHIP_STDERR"
    return 1
  }
}
