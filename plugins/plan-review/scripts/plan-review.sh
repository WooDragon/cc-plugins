#!/bin/bash
# PreToolUse hook: Adversarial plan review via cross-model consultation.
#
# Triggered when Plan agent calls ExitPlanMode (via PreToolUse matcher).
# Flow (severity-aware adversarial consultation):
#   ExitPlanMode called → hook intercepts → review engine (Gemini/Claude) reviews:
#     APPROVE  → deny with review feedback (ack-deny); next ExitPlanMode allows (ack-round)
#     CONCERNS → deny with feedback, increment ATTEMPT + TOTAL, Claude revises or rebuts
#     REJECT   → deny with feedback, increment TOTAL only (ATTEMPT frozen), Critical must resolve
#   Termination (dual safety valves):
#     Non-Critical valve: ATTEMPT >= MAX_ROUNDS → allow (escalate to user)
#     Global valve:       TOTAL >= MAX_TOTAL_ROUNDS → deny (hard stop, tombstone counter)
#
# All non-guard exits emit structured JSON (allow or deny). No silent exit 0.
#
# Environment variables:
#   REVIEW_DISABLED=1            — bypass entirely (fallback: GEMINI_REVIEW_OFF)
#   REVIEW_DRY_RUN=1             — skip engine call, synthetic APPROVE (fallback: GEMINI_DRY_RUN)
#   REVIEW_MAX_ROUNDS=N          — max non-Critical consultation rounds, default 3 (fallback: GEMINI_MAX_REVIEWS)
#   REVIEW_MAX_TOTAL_ROUNDS=N    — absolute max total rounds (incl. REJECT), default 20
#   REVIEW_ENGINE=gemini         — review engine: "gemini" (default) or "claude"
#   CLAUDE_MODEL=opus            — Claude engine model (default: opus)
#   AGY_MODEL=<id>               — agy CLI model (default: Gemini 3.1 Pro (High))
#   GEMINI_MODEL=<id>            — REST fallback model id (default: gemini-3.1-pro-preview)
#   REVIEW_ENGINE_TIMEOUT=N      — engine call timeout seconds (default: 595; needs timeout/gtimeout)
#   REVIEW_REST_TIMEOUT=N        — REST API fallback curl timeout, default 115 (equals HOOK_BUDGET; clamp logic caps actual value to remaining-3)
#   REVIEW_REST_STALL_TIMEOUT=N  — REST SSE stall watchdog seconds, default 90 (curl --speed-time)
#   REVIEW_HOOK_BUDGET=N         — hook total time budget, default 595 (600 hook timeout - 5s margin)
#   REVIEW_RETRY_DELAY=N         — seconds between retries on non-capacity failure (default: 2)
#   REVIEW_CAPACITY_DELAY=N      — seconds to wait when MODEL_CAPACITY_EXHAUSTED detected (default: 25)
#   REVIEW_API_URL=<url>         — REST API fallback base URL (OpenAI-compatible, e.g. https://proxy.example.com)
#   REVIEW_API_KEY=<key>         — REST API fallback auth key (Bearer token)
#   REVIEW_ENGINE_DEGRADE_TTL=N  — seconds Gemini stays in degraded state after capacity exhaustion (default: 3600)
set -euo pipefail

INPUT=$(cat)

# --- Pre-requisites ---
command -v jq >/dev/null 2>&1 || {
  echo "plan-review: missing jq, allowing." >&2
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"[WARNING] jq missing, plan-review skipped"}}'
  exit 0
}

# --- Logging (write failure → discard, never let side-channel kill core logic) ---
LOG_DIR="${REVIEW_LOG_DIR:-$HOME/.claude/logs}"
mkdir -p "$LOG_DIR" 2>/dev/null && LOG_FILE="${LOG_DIR}/plan-review.log" || LOG_FILE="/dev/null"

# --- Structured decision log (one line per exit, machine-parseable) ---
log_decision() {
  printf '[%s] session=%s attempt=%s/%s total=%s/%s %s\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    "${SESSION_ID:-unknown}" "${ATTEMPT:-?}" "${REVIEW_MAX_ROUNDS:-?}" \
    "${TOTAL_ROUNDS:-?}" "${REVIEW_MAX_TOTAL_ROUNDS:-?}" \
    "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# --- Entry-point diagnostic log (before guards, does not require ATTEMPT/TOTAL) ---
log_entry() {
  printf '[%s] ENTRY tool=%s session=%s %s\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    "${1:-unknown}" "${2:-unknown}" "${3:-}" >> "$LOG_FILE" 2>/dev/null || true
}

# --- Raw payload capture (diagnostic-only; never let IO failure kill core logic) ---
# CC 2.1.x moved plan content out of tool_input into an out-of-band plan file whose
# path is NOT in the hook stdin. When plan extraction fails we dump the complete raw
# payload + a key-schema summary so the true field layout can be inspected post-hoc.
dump_payload() {
  local raw="$1" session="$2"
  local dump_dir="${LOG_DIR}/payloads"
  mkdir -p "$dump_dir" 2>/dev/null || return 0
  local stamp; stamp=$(date -u +"%Y%m%dT%H%M%SZ")
  local dump_file="${dump_dir}/exitplanmode-${session:-nosession}-${stamp}-$$.json"
  printf '%s' "$raw" > "$dump_file" 2>/dev/null || return 0
  # Echo the dump path into the main log so it can be located later.
  printf '[%s] PAYLOAD-DUMP session=%s file=%s\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "${session:-unknown}" "$dump_file" \
    >> "$LOG_FILE" 2>/dev/null || true
}

# --- Visible allow helper (eliminates silent exit 0 for non-guard paths) ---
allow_with_reason() {
  local reason="$1"
  local reason_json
  reason_json=$(printf '%s' "$reason" | jq -Rs . 2>/dev/null) || reason_json="\"$reason\""
  cat << EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":${reason_json}}}
EOF
  exit 0
}

# --- Plan content hasher (portable: sha256sum > shasum > cksum POSIX fallback) ---
# All branches pipe through awk '{print $1}' to strip filename/extra fields.
plan_hash() {
  local content="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$content" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$content" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$content" | cksum | awk '{print $1}'
  fi
}

# --- Transcript-based plan recovery (CC 2.1.x contract: plan lives in an
#     out-of-band file referenced by the plan_mode attachment, which is NOT in
#     the hook stdin; only transcript_path is). Resolve the latest plan file
#     path from the transcript and, if — and only if — it clears three security
#     gates, set RECOVERED_PATH to its physical absolute path. On any rejection,
#     leave RECOVERED_PATH empty and set RESOLVE_REASON for the caller's error
#     messaging.
#
#     IMPORTANT: sets globals directly (no echo + $(...)), because command
#     substitution runs in a subshell and would discard RESOLVE_REASON.
#
#     Threat model (defense in depth):
#       - FIFO / device file → blocking read hangs jq/cat, drains the 600s hook
#         budget, wedges the whole CLI. Gate: [ -f ] (regular file only).
#       - Symlink in plans dir → string-prefix whitelist is bypassable; a link to
#         ~/.ssh/id_rsa or /etc/passwd would be cat'd into the review engine.
#         Gate: reject [ -h ], then realpath to the physical path before the check.
#       - Path traversal → reject any '..' in the raw path.
# ---
RESOLVE_REASON=""
RECOVERED_PATH=""
RESOLVE_PATH=""
resolve_plan_from_transcript() {
  RESOLVE_REASON=""
  RECOVERED_PATH=""
  RESOLVE_PATH=""
  local transcript="$1"
  # Gate 0: transcript must be a regular file (not FIFO/device → no blocking read).
  [ -n "$transcript" ] && [ -f "$transcript" ] || { RESOLVE_REASON="no-transcript"; return; }

  # Whitelist root for plan files (REVIEW_PLAN_DIR reused; prod fallback ~/.claude/plans).
  local whitelist_root="${REVIEW_PLAN_DIR:-$HOME/.claude/plans}"

  # Streaming extraction (line-by-line, no slurp): newest plan_mode planFilePath.
  local raw_path
  raw_path=$(jq -r 'select(.attachment?.type == "plan_mode" and .attachment?.planFilePath != null) | .attachment.planFilePath' "$transcript" 2>/dev/null | tail -1 || true)
  [ -n "$raw_path" ] && [ "$raw_path" != "null" ] || { RESOLVE_REASON="no-plan-attachment"; return; }
  # Expose the path under evaluation so error messages stay actionable on every reject path.
  RESOLVE_PATH="$raw_path"

  # Gate 1: reject path traversal in the raw path.
  case "$raw_path" in
    *..*) RESOLVE_REASON="path-traversal"; return ;;
  esac

  # Gate 2: reject symlinks outright (don't follow links out of the sandbox).
  if [ -h "$raw_path" ]; then
    RESOLVE_REASON="symlink-rejected"
    return
  fi

  # Resolve to the physical path before the whitelist check. Resolve the PARENT
  # directory physically (cd -P collapses symlinked path components) and re-append
  # the basename — this works whether or not the target file exists yet, and is
  # portable (no realpath-on-missing-file dependency, which fails on macOS/BSD).
  local dir base dir_resolved resolved
  dir=$(dirname "$raw_path"); base=$(basename "$raw_path")
  if [ ! -d "$dir" ]; then
    # Parent dir absent → framework named a file under a nonexistent dir; treat as missing.
    RESOLVE_REASON="resolved-but-missing"
    return
  fi
  dir_resolved=$(cd "$dir" 2>/dev/null && pwd -P) || { RESOLVE_REASON="unresolvable"; return; }
  [ -n "$dir_resolved" ] || { RESOLVE_REASON="unresolvable"; return; }
  resolved="${dir_resolved}/${base}"
  RESOLVE_PATH="$resolved"

  # Resolve the whitelist root the same way so the prefix compare is apples-to-apples.
  local root_resolved
  if [ -d "$whitelist_root" ]; then
    root_resolved=$(cd "$whitelist_root" 2>/dev/null && pwd -P) || root_resolved="$whitelist_root"
  else
    root_resolved="$whitelist_root"
  fi

  # Gate 3: physical path must live under the whitelist root.
  case "$resolved" in
    "$root_resolved"/*) : ;;
    *) RESOLVE_REASON="outside-whitelist"; return ;;
  esac

  # Final: must be an existing regular file (covers "framework named it but never wrote it").
  if [ ! -f "$resolved" ]; then
    RESOLVE_REASON="resolved-but-missing"
    return
  fi

  RESOLVE_REASON="ok"
  RECOVERED_PATH="$resolved"
}

# --- Manifest detection helpers (case-insensitive: LLM may write "Worker Agent"/"TASK(") ---
needs_manifest() { printf '%s' "$1" | grep -qiE '(Task\(|subagent_type|agent_type|Plan agent|Explore agent|worker agent|dev agent)'; }
has_manifest()   { printf '%s' "$1" | grep -qi '^## Dispatch Manifest'; }

# Returns 0 if at least one manifest data row has a non-dash agent_type.
manifest_has_real_agent() {
  printf '%s\n' "$1" | awk '
    /^## Dispatch Manifest/ {in_m=1; seen_table=0; next}
    in_m && /^## / {in_m=0}
    in_m && /^ *\|/ {seen_table=1}
    in_m && seen_table && /^ *$/ {in_m=0}
    in_m && /^\|/ && !/^\|---/ && !/^\| *[Ss][Tt][Ee][Pp]/ {
      gsub(/^\| *| *\| *$/, ""); n = split($0, f, / *\| */)
      if (n >= 2) { at=f[2]; gsub(/^ +| +$|"/, "", at); if (at != "-" && at != "") found=1 }
    }
    END { exit (found ? 0 : 1) }
  '
}

# --- Canonical manifest example (single source of truth for both deny messages) ---
# Single-quoted heredoc: backticks, $ and <placeholders> stay literal (no command
# substitution, no expansion). Embedded verbatim into deny reasons so a blocked LLM
# sees the exact format inline instead of guessing column names from CLAUDE.md.
# Agent-row values are <placeholders>, not a copy-pastable real step, so the LLM
# can't paste the example wholesale and inject a phantom dispatch step.
MANIFEST_EXAMPLE=$(cat <<'MANIFEST_EOF'
格式示例（占位值 <...> 替换为你 plan 的真实步骤，勿原样复制本表）：

## Dispatch Manifest
| step | agent_type    | model   | depends_on | parallel_with |
|------|---------------|---------|------------|---------------|
| 1    | -             | -       | -          | -             |
| 2    | <agent_type>  | <model> | 1          | -             |

填写规则：
- 主上下文执行的 step：agent_type 与 model 两列均填 `-`。
- 委派给 Agent 的 step：两列必填，model 用全名（sonnet / opus / haiku）。
- depends_on / parallel_with：填依赖/并行的 step 号，无则填 `-`。
MANIFEST_EOF
)

# --- Manifest JSON serializer (called only from APPROVE branch; failures are silent) ---
# Parses the ## Dispatch Manifest markdown table and outputs a dispatch JSON blob.
# JSON injection defense: strips stray double-quotes LLM may write in manifest rows.
parse_manifest_to_json() {
  local plan="$1" hash="$2"
  printf '%s\n' "$plan" | awk -v hash="$hash" -v now="$(date +%s)" '
    /^## Dispatch Manifest/ {in_manifest=1; seen_table=0; next}
    in_manifest && /^## / {in_manifest=0}
    in_manifest && /^ *\|/ {seen_table=1}
    in_manifest && seen_table && /^ *$/ {in_manifest=0}
    in_manifest && /^\|/ && !/^\|---/ && !/^\| *[Ss][Tt][Ee][Pp]/ {
      gsub(/^\| *| *\| *$/, ""); n = split($0, f, / *\| */)
      if (n >= 3) {
        id=f[1]; at=f[2]; md=f[3]
        gsub(/^ +| +$/, "", id); gsub(/^ +| +$/, "", at); gsub(/^ +| +$/, "", md)
        gsub(/"/, "", id); gsub(/"/, "", at); gsub(/"/, "", md)
        rows[++count] = sprintf("{\"id\":\"%s\",\"agent_type\":%s,\"model\":%s}",
          id,
          (at == "-" ? "null" : "\"" at "\""),
          (md == "-" ? "null" : "\"" md "\""))
      }
    }
    END {
      printf "{\"plan_hash\":\"%s\",\"created_at\":%s,\"requires_dispatch_check\":true,\"steps\":[", hash, now
      for (i=1; i<=count; i++) printf "%s%s", (i>1?",":""), rows[i]
      printf "]}\n"
    }
  '
}

# --- Namespace unification (legacy GEMINI_* fallback — never break userspace) ---
REVIEW_DISABLED="${REVIEW_DISABLED:-${GEMINI_REVIEW_OFF:-0}}"
REVIEW_DRY_RUN="${REVIEW_DRY_RUN:-${GEMINI_DRY_RUN:-0}}"
REVIEW_MAX_ROUNDS="${REVIEW_MAX_ROUNDS:-${GEMINI_MAX_REVIEWS:-3}}"
REVIEW_MAX_TOTAL_ROUNDS="${REVIEW_MAX_TOTAL_ROUNDS:-20}"
REVIEW_ENGINE="${REVIEW_ENGINE:-gemini}"

# --- Unified field extraction (single jq fork, reused by guards + logging) ---
# Pre-initialize so set -u won't fire if read fails (e.g. empty/malformed INPUT).
# || true absorbs read's exit 1 on EOF, preventing set -e from killing the process
# before log_entry() can write the ENTRY diagnostic line.
TOOL_NAME="" SESSION_ID=""
read -r TOOL_NAME SESSION_ID < <(echo "$INPUT" | jq -r '[.tool_name // "", .session_id // ""] | @tsv') || true

# --- Entry-point diagnostic (unconditional, before all guards) ---
log_entry "$TOOL_NAME" "$SESSION_ID" "pid=$$"

# --- Recursive guard: claude -p subprocess inherits this, bail immediately ---
[ "${PLAN_REVIEW_RUNNING:-}" != "1" ] || {
  log_entry "$TOOL_NAME" "$SESSION_ID" "guard=recursive-bail"
  exit 0
}

# --- Kill switch ---
[ "$REVIEW_DISABLED" != "1" ] || {
  log_entry "$TOOL_NAME" "$SESSION_ID" "guard=disabled"
  exit 0
}

# --- Guard: only ExitPlanMode (belt-and-suspenders with matcher) ---
[ "$TOOL_NAME" = "ExitPlanMode" ] || {
  log_entry "$TOOL_NAME" "$SESSION_ID" "guard=wrong-tool"
  exit 0
}

# --- Session ID for counter isolation ---
if [ -z "$SESSION_ID" ]; then
  log_entry "$TOOL_NAME" "" "guard=missing-session-id"
  exit 0
fi

# --- Attempt counter (tmpfs-backed, system handles cleanup) ---
COUNTER_DIR="${REVIEW_COUNTER_DIR:-/tmp/claude-reviews}"
mkdir -p "$COUNTER_DIR"
COUNTER_FILE="$COUNTER_DIR/.review-count-${SESSION_ID}"
APPROVE_MARKER="$COUNTER_DIR/.review-approved-${SESSION_ID}"
# Gemini degraded state file (global, no session suffix — persists across hooks)
DEGRADE_FILE="$COUNTER_DIR/.gemini-degraded"

# --- Read counter (new format ATTEMPT:TOTAL, backward-compat with old single-number) ---
IFS=: read -r ATTEMPT TOTAL_ROUNDS <<< "$(cat "$COUNTER_FILE" 2>/dev/null || echo "0:0")"
# Three-layer defense: empty fallback → old format compat → dirty data sanitization
ATTEMPT=${ATTEMPT:-0}
TOTAL_ROUNDS=${TOTAL_ROUNDS:-$ATTEMPT}  # old format "3" → ATTEMPT=3, TOTAL_ROUNDS="" → 3
[[ "$ATTEMPT" =~ ^[0-9]+$ ]] || ATTEMPT=0
[[ "$TOTAL_ROUNDS" =~ ^[0-9]+$ ]] || TOTAL_ROUNDS=0

# --- 1. Extract plan content (must precede ack-round guard for hash comparison) ---
PLAN=$(echo "$INPUT" | jq -r '.tool_input.plan // ""')

if [ -z "$PLAN" ] || [ "$PLAN" = "null" ]; then
  # Fallback: read from planFilePath (framework-assigned, session-scoped)
  PLAN_FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.planFilePath // ""')
  if [ -n "$PLAN_FILE_PATH" ] && [ "$PLAN_FILE_PATH" != "null" ] && [ -f "$PLAN_FILE_PATH" ]; then
    PLAN=$(cat "$PLAN_FILE_PATH" 2>/dev/null)
  fi
fi

# CC 2.1.x recovery: plan content is in an out-of-band file referenced only by
# the transcript's plan_mode attachment. Resolve it via transcript_path (the one
# locator the hook stdin does carry) through the three security gates. The
# resolver sets RECOVERED_PATH / RESOLVE_REASON globals directly (not via $(...)),
# so RESOLVE_REASON survives for the fail-closed error routing below.
if [ -z "$PLAN" ] || [ "$PLAN" = "null" ]; then
  TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')
  resolve_plan_from_transcript "$TRANSCRIPT_PATH"
  if [ -n "$RECOVERED_PATH" ] && [ -f "$RECOVERED_PATH" ]; then
    PLAN=$(cat "$RECOVERED_PATH" 2>/dev/null)
    log_decision "decision=recovered reason=recovered-from-transcript planFilePath=${RECOVERED_PATH}"
  fi
fi

# Fail-closed: no plan content → deny with actionable path info
if [ -z "$PLAN" ] || [ "$PLAN" = "null" ]; then
  # Diagnostic: CC 2.1.x carries the plan in an out-of-band file whose path is not
  # in tool_input. Capture the raw payload + a key-schema summary so the actual
  # field layout (transcript_path, cwd, hidden plan-file fields) can be inspected.
  dump_payload "$INPUT" "$SESSION_ID"
  TOP_KEYS=$(echo "$INPUT" | jq -rc '(keys // []) | @json' 2>/dev/null || echo "?")
  TI_KEYS=$(echo "$INPUT" | jq -rc '(.tool_input // {} | keys) | @json' 2>/dev/null || echo "?")
  TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
  CWD_VAL=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")
  log_decision "decision=deny reason=no-plan-content-fail-closed resolve=${RESOLVE_REASON:-none} resolvePath=${RESOLVE_PATH:-empty} planFilePath=${PLAN_FILE_PATH:-empty} top_keys=${TOP_KEYS} tool_input_keys=${TI_KEYS} transcript_path=${TRANSCRIPT_PATH:-empty} cwd=${CWD_VAL:-empty}"
  rm -f "$APPROVE_MARKER" "$COUNTER_FILE"
  # Three-state error message routed by the resolver's RESOLVE_REASON. Every
  # branch names the plan file path under evaluation (RESOLVE_PATH) so the user
  # can act — "write your plan to this exact file" instead of a bare directive.
  REASON=""
  case "${RESOLVE_REASON:-}" in
    resolved-but-missing)
      REASON="[ERROR] plan 内容未传入。框架在 transcript 中指定了 plan 文件 \"${RESOLVE_PATH}\"，但该文件尚未写入。请用 Write 将 plan 写入该文件后重新调用 ExitPlanMode。" ;;
    outside-whitelist|symlink-rejected|path-traversal)
      REASON="[ERROR] plan 文件路径 \"${RESOLVE_PATH}\" 非法（${RESOLVE_REASON}），出于安全已拒绝读取。plan 文件必须位于 ~/.claude/plans 下且不能是软链接。" ;;
    *)
      if [ -n "${PLAN_FILE_PATH:-}" ] && [ "${PLAN_FILE_PATH:-}" != "null" ]; then
        REASON="[ERROR] plan 内容未传入。tool_input.plan 为空，planFilePath=\"${PLAN_FILE_PATH}\" 指向的文件不存在。请将 plan 写入该文件后重新调用 ExitPlanMode。"
      else
        REASON="[ERROR] plan 内容未传入。tool_input.plan 和 planFilePath 均为空，且无法从 transcript 反查到 plan 文件（${RESOLVE_REASON:-no-transcript}）。请确保 plan 已写入框架指定的 plan 文件后重试。"
      fi ;;
  esac
  jq -n --arg r "$REASON" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
  exit 0
fi

# --- Approval ack-round: compare plan hash to detect post-approve modifications ---
# APPROVE emits deny (ack-deny) so Claude presents the review to the user; the next
# ExitPlanMode hits this guard — if plan unchanged, allow; if plan changed, re-review.
if [ -f "$APPROVE_MARKER" ]; then
  APPROVED_HASH=$(cat "$APPROVE_MARKER" 2>/dev/null)
  CURRENT_HASH=$(plan_hash "$PLAN")
  if [ -z "$APPROVED_HASH" ] || [ "$CURRENT_HASH" = "$APPROVED_HASH" ]; then
    # True ack-round: plan unchanged (empty marker = legacy format, unconditional allow)
    log_decision "decision=allow reason=ack-round-approved"
    rm -f "$APPROVE_MARKER" "$COUNTER_FILE"
    allow_with_reason "Red Team 审阅已通过，plan 放行。"
  else
    # Plan was modified after approve: marker invalid, delete and fall through to re-review
    log_decision "decision=review-again reason=plan-changed-after-approve"
    rm -f "$APPROVE_MARKER"
    # Fall through to full review pipeline
  fi
fi

# --- Global safety valve: total rounds exhausted → hard deny (tombstone counter) ---
# Never delete counter — tombstone blocks subsequent calls until human intervenes
if [ "$TOTAL_ROUNDS" -ge "$REVIEW_MAX_TOTAL_ROUNDS" ]; then
  log_decision "decision=deny reason=global-safety-valve total=$TOTAL_ROUNDS"
  BLOCK_MSG="## Red Team Review — HARD STOP

审阅已达全局上限（${TOTAL_ROUNDS}/${REVIEW_MAX_TOTAL_ROUNDS}），仍存在未解决的审阅意见。
Plan 被强制拦截。请停止当前操作，将问题升级给用户做人工决策。"
  BLOCK_JSON=$(printf '%s' "$BLOCK_MSG" | jq -Rs .)
  cat << EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":${BLOCK_JSON}}}
EOF
  exit 0
fi

# --- Non-Critical safety valve: CONCERNS rounds exhausted → allow (escalate to user) ---
if [ "$ATTEMPT" -ge "$REVIEW_MAX_ROUNDS" ]; then
  log_decision "decision=allow reason=non-critical-safety-valve round=$ATTEMPT total=$TOTAL_ROUNDS"
  rm -f "$COUNTER_FILE"
  VALVE_MSG="## Red Team Review — ${REVIEW_ENGINE} — ESCALATED

非 Critical 磋商已达上限（${ATTEMPT}/${REVIEW_MAX_ROUNDS}），未能达成一致。Plan 直接呈现给用户做最终裁决。"
  VALVE_JSON=$(printf '%s' "$VALVE_MSG" | jq -Rs .)
  cat << EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":${VALVE_JSON}}}
EOF
  exit 0
fi

# --- Pre-flight manifest check (AFTER non-critical valve, not before) ---
# Format correction, NOT negotiation round: increments TOTAL_ROUNDS only.
# ATTEMPT stays frozen — pre-flight denies do not count toward MAX_ROUNDS.
# Global safety valve (TOTAL_ROUNDS >= 20) still protects against infinite loops.
if needs_manifest "$PLAN" && ! has_manifest "$PLAN"; then
  TOTAL_ROUNDS=$((TOTAL_ROUNDS + 1))
  echo "${ATTEMPT:-0}:${TOTAL_ROUNDS}" > "$COUNTER_FILE"
  log_decision "decision=deny reason=missing-manifest"
  MANIFEST_MSG="## Red Team Pre-flight — MISSING DISPATCH MANIFEST

Plan 涉及 Agent/Task 调度（检测到关键词），但缺少 \`## Dispatch Manifest\` 表格。
请在 plan 中追加 manifest 表格后重新调用 ExitPlanMode。

${MANIFEST_EXAMPLE}"
  MANIFEST_DENY_JSON=$(printf '%s' "$MANIFEST_MSG" | jq -Rs .)
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":${MANIFEST_DENY_JSON}}}
EOF
  exit 0
fi

# --- Pre-flight degenerate manifest check (all agent_type == "-") ---
# Fires when manifest is present but declares zero real agent steps.
if needs_manifest "$PLAN" && has_manifest "$PLAN" && ! manifest_has_real_agent "$PLAN"; then
  TOTAL_ROUNDS=$((TOTAL_ROUNDS + 1))
  echo "${ATTEMPT:-0}:${TOTAL_ROUNDS}" > "$COUNTER_FILE"
  log_decision "decision=deny reason=degenerate-manifest"
  DEGEN_MSG="## Red Team Pre-flight — DEGENERATE DISPATCH MANIFEST

Plan 含 Agent/Task 调度关键词，但 Manifest 所有行 agent_type 均为 \`-\`（全主上下文）。
- 若任务确实简单（单一关注点、无接口变更）：**首选**移除 plan 中的 dispatch 关键词，改写为直接执行描述。
- 若任务复杂：在 manifest 中至少声明一个真实 agent 步骤（agent_type 与 model 两列均填实值）。

${MANIFEST_EXAMPLE}"
  DEGEN_DENY_JSON=$(printf '%s' "$DEGEN_MSG" | jq -Rs .)
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":${DEGEN_DENY_JSON}}}
EOF
  exit 0
fi

# --- 2. Collect project context ---
CWD=$(echo "$INPUT" | jq -r '.cwd // "."')

GLOBAL_MD=""
[ ! -f "$HOME/.claude/CLAUDE.md" ] || GLOBAL_MD=$(head -c 3000 "$HOME/.claude/CLAUDE.md")

PROJECT_MD=""
[ ! -f "$CWD/CLAUDE.md" ] || PROJECT_MD=$(head -c 8000 "$CWD/CLAUDE.md")

# --- 3. Extract recent user messages from transcript ---
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""')
USER_REQ=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  USER_REQ=$(jq -rs '
    [.[] | select(.role == "human" or .role == "user")]
    | .[-3:]
    | map(.content | if type == "array"
        then [.[] | select(.type == "text") | .text] | join("\n")
        elif type == "string" then .
        else "" end)
    | join("\n---\n")
  ' "$TRANSCRIPT" 2>>"$LOG_FILE" || true)
fi

# --- 4. Compose prompt ---
# Static instructions: single canonical source, injected per-channel (see
# variant A below): claude → --system-prompt; agy → inline concat; REST →
# messages[0]. PROMPT_FILE itself carries dynamic content only.
# Quoted heredoc ('EOF') → body is pure literal: $, backtick, parens, and
# apostrophe are all safe, no escaping needed. We use `read -r -d ''` rather
# than `$(cat <<'EOF')`: bash 3.2 (macOS /bin/bash) mis-parses unbalanced
# parens like "Task(" inside a command-substituted heredoc, erroring with
# "unexpected EOF looking for matching )". The read form has no command
# substitution and is immune. `|| true` absorbs read's exit 1 at EOF (set -e).
IFS= read -r -d '' SYSTEM_INSTRUCTIONS << 'EOF' || true
# Red Team Plan Review

You are a senior software architect performing an ADVERSARIAL review of the
following implementation plan. Your job is to find flaws before implementation
begins. Be direct and specific — no generic advice.

## Scope Boundary
The plan under review will be executed in a DIFFERENT AI coding assistant with
its own tools, agent types, and API signatures. You may see tool names, function
calls, or parameter names that do not exist in YOUR environment — this is normal
and correct. DO NOT judge whether tool names or agent type identifiers match your
own system. Focus exclusively on logic, architecture, and engineering quality.

Keep your response under 3000 characters.

## Review Criteria
1. **Correctness** — Does the plan actually solve the stated problem?
2. **Completeness** — Missing steps, edge cases, error handling?
3. **Simplicity** — Is there a simpler approach? Unnecessary complexity?
4. **Safety** — Security risks, data loss, backwards-compatibility breaks?
5. **Testability** — Can changes be verified?
   - **Test strategy presence**: Any plan altering observable behavior (logic, APIs,
     data contracts, UI interactions) must include a Test Strategy section. Exceptions:
     documentation-only, config-only, or deletion of provably-dead code with grep
     evidence in the plan. Missing test strategy for a behavior-changing plan is [Major].
   - **Test pyramid completeness**: When a Test Strategy is present, it must address
     each applicable layer. A plan covering only unit tests while making user-visible
     UI changes, or only listing e2e while introducing new logic without unit coverage,
     is [Major].
   - **E2E selector cascade** *(evidence-gated)*: If the plan or project context reveals
     e2e coverage (Playwright, Cypress, `*.spec.ts` files, `e2e/` directory references),
     then deleting or renaming a UI component, `data-testid`, or route requires
     enumerating affected spec files. Omitting this when e2e evidence is present is
     [Major]. Skip this check if no e2e evidence appears in plan or project context.
   - **Deletion completeness**: Removing an **exported or cross-boundary** symbol
     (public component, exported function, public route, shared testid) without listing
     its consumers (specs, fixtures, imports, callers) is [Major]. Exceptions: purely
     local/internal symbols, or provably dead code with no external consumers (grep
     evidence in the plan).
6. **Architecture fit** — Consistent with project patterns?
7. **Dispatch Economy** — Work nature determines who executes, to protect the
   main context's lifespan and minimize token cost. Classify each step by its
   NATURE (not by a fuzzy complexity estimate), then check the assigned tier:
   - **Decision work** (architecture, root-cause debugging, requirements
     breakdown, plan authoring, review judgment) → tier `opus` → runs in main
     context (manifest model/agent_type = `-`).
   - **Implementation work** (writing code, editing files, producing content)
     → tier `sonnet` → MUST be delegated to a typed agent.
   - **Retrieval work** (read-only exploration, search, data extraction with
     zero reasoning) → tier `haiku` → MUST be delegated to a typed agent.
   The default is to delegate: only decision steps legitimately stay in main
   context. The single whole-plan exemption is **Tier 0** — ALL of: single
   file, no new dependency, no API-contract / DB-schema change, no cross-file
   coordination, not an ops task. A Tier-0 plan needs no manifest at all. Do
   NOT count lines of code to judge Tier 0 — the moment a plan touches multiple
   files, adds a dependency, or changes an interface, it is not Tier 0 and its
   implementation steps must be delegated, regardless of how few lines they are.
   Even a Tier-0 plan, if its text contains dispatch keywords (Task(,
   subagent_type, worker agent, etc.), must still obey the underlying syntax
   gate: either remove the keywords or supply a full manifest — otherwise a
   static check will hard-block it (avoid the split-brain where the reviewer
   approves but the script rejects).
   - **Severity calibration** (do not weaken the existing rule):
     - **Full hoarding** — a non-Tier-0 plan whose manifest leaves ALL
       implementation/retrieval steps on `-` (main session swallowing every
       offloadable task) → [Critical] → REJECT. This preserves the existing
       contract: an all-dash manifest on a complex plan is a Critical blocker.
     - **Partial hoarding** — individual implementation steps kept in main,
       a sonnet-grade task kept in main, OR main context (opus) hoarding
       retrieval/extraction work → [Major] → CONCERNS. Opus hoarding retrieval
       (haiku-grade, zero-reasoning, high-token work) pollutes the main window
       worse than hoarding code-writing, so it must force CONCERNS, never Minor.
     - **Pure mis-tiering / fragmentation** — a sonnet-grade task already inside
       an agent, or implementation steps sharing one file set split across
       multiple agents that each reload the same context → [Minor].
   - Manifest format: Agent steps require both agent_type + model (full name, no
     abbreviation). Main-context steps use `-`. Missing manifest when dispatch
     keywords are present = [Major]. Agent step missing model = [Critical].
8. **Reuse over reinvention** — Does the plan propose building something that already exists in the project dependencies, framework, or standard library? Custom implementations require explicit justification (e.g., "framework X lacks feature Y" with concrete evidence). Without strong justification, prefer existing solutions. This is a [Major] issue.

## Review Discipline
- Focus on gaps the plan author **missed**, not on restating what they already considered.
- Every issue MUST cite specific evidence from the plan or project context.

## Finding Quality Gate (pre-report self-check)
False positives burn scarce negotiation rounds. Gate EVERY finding:

1. **Confidence** — Low confidence + Minor/Major → DROP silently. Low confidence +
   suspected Critical → keep as `[UNVERIFIED]`, downgrade to Major (→ CONCERNS, not REJECT).
2. **False-positive registry** — Never raise: naming/style preferences, justified design
   choices (attack the justification instead), tool/agent-type/parameter names (Scope Boundary).
3. **Severity calibration** — Style is never Major/Critical. Critical requires a concrete,
   named blocker (specific vuln, data-loss path, wrong-result logic).
4. **Verdict↔severity** — Confirm verdict matches highest surviving finding:
   confirmed Critical → REJECT; Major or UNVERIFIED → CONCERNS; Minor-only → APPROVE.

## Severity Definitions
- **[Critical]** — Blocker: security vulnerabilities, data loss, logic errors producing wrong results, breaking changes to existing behavior, fundamental approach flaws
- **[Major]** — Significant gap: missing error handling on critical paths, poor architecture decisions, performance issues under normal load, incomplete implementation, reinventing functionality available in existing dependencies without justification
- **[Minor]** — Polish: naming, style, documentation gaps, minor optimization opportunities

## Verdict Rules
- **APPROVE**: No issues, or only Minor items remaining
- **CONCERNS**: Major items present (including any `[UNVERIFIED]` suspicion) but no confirmed Critical
- **REJECT**: confirmed Critical items present

Verdict is the structured severity signal — the automation routes on verdict tags only,
no body scanning. Strictly follow verdict-severity correspondence (see Finding Quality
Gate check 4 — the verdict must match your highest surviving finding).

## Output Format
- FIRST line must be a verdict tag: <verdict>APPROVE</verdict> or <verdict>CONCERNS</verdict> or <verdict>REJECT</verdict>
- List issues, each prefixed with severity tag: `[Critical]`, `[Major]`, or `[Minor]`
- Each issue format: `[Severity] description → impact → suggested fix`
- A low-confidence but high-severity suspicion (Quality Gate check 1) is emitted as
  `[Major] [UNVERIFIED] description → ...` — surfaced for the human, never as REJECT
- If a severity level has no issues, omit it entirely
- End with brief strengths of the plan (if any)

IMPORTANT: The verdict MUST be wrapped in <verdict></verdict> XML tags on the
very first line. This is machine-parsed. Do NOT place verdict keywords anywhere
else in your response without the tags.

Use Chinese for the review output.
EOF

ENGINE_OUT=""
ENGINE_STATUS=""
ENGINE_PID=""
REQ_FILE=""
PROMPT_FILE=$(mktemp)
# Cleanup: remove temp files and kill tracked engine subprocess.
# Called on EXIT (normal), INT (Ctrl-C), TERM (framework hook timeout),
# and HUP (terminal disconnect). Idempotent — safe to call multiple times.
_cleanup() {
  rm -f "$PROMPT_FILE" "${ENGINE_OUT:-}" "${ENGINE_STATUS:-}" "${REQ_FILE:-}"
  [ -z "${ENGINE_PID:-}" ] || kill "$ENGINE_PID" 2>/dev/null || true
}
trap '_cleanup' EXIT
trap '_cleanup; exit 130' INT TERM HUP

# Engine-specific system injection: PROMPT_FILE holds dynamic content only,
# regardless of engine. Each channel injects SYSTEM_INSTRUCTIONS on its own
# rail: claude → --system-prompt; agy → inline concat; REST → messages[0].
: > "$PROMPT_FILE"
if [ "$REVIEW_ENGINE" = "claude" ]; then
  SYSTEM_PROMPT="$SYSTEM_INSTRUCTIONS"
else
  SYSTEM_PROMPT=""
fi

# Shared dynamic content: stable → volatile ordering
cat >> "$PROMPT_FILE" << DYNEOF
## Coding Standards (Author's Reference)
${GLOBAL_MD:-<not available>}

## Project Architecture
${PROJECT_MD:-<not available>}

## User's Original Request
${USER_REQ:-<not available>}

## Plan to Review
${PLAN}
DYNEOF

# Volatile tail: round context (always last, changes every round)
if [ "$TOTAL_ROUNDS" -gt 0 ]; then
  cat >> "$PROMPT_FILE" << RNDEOF

## Consultation Context
This is round $((TOTAL_ROUNDS + 1)) of adversarial review.
The plan author may have revised or added rebuttals since the previous round.
Evaluate the CURRENT plan on its merits — if prior concerns have been addressed, APPROVE.
RNDEOF
fi

# --- 5. Call review engine ---
if [ "$REVIEW_DRY_RUN" = "1" ]; then
  REVIEW="<verdict>APPROVE</verdict>
[DRY-RUN] 审阅调用已跳过。"
else
  # --- Pre-flight: CLI existence check (permanent failure, no retry) ---
  ENGINE_CMD="agy"
  [ "$REVIEW_ENGINE" != "claude" ] || ENGINE_CMD="claude"
  if ! command -v "$ENGINE_CMD" >/dev/null 2>&1; then
    log_decision "decision=allow reason=engine-not-found engine=$REVIEW_ENGINE"
    allow_with_reason "[WARNING] REVIEW_ENGINE=$REVIEW_ENGINE but '$ENGINE_CMD' not found"
  fi

  # Engine model variables (outside retry loop, avoid repeat assignment)
  if [ "$REVIEW_ENGINE" = "claude" ]; then
    CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"
  else
    # GEMINI_MODEL retained as the REST fallback's model id (OpenAI-compatible payload).
    GEMINI_MODEL="${GEMINI_MODEL:-gemini-3.1-pro-preview}"
    AGY_MODEL="${AGY_MODEL:-Gemini 3.1 Pro (High)}"
  fi

  # Portable timeout: timeout (GNU/Homebrew) > gtimeout (coreutils) > none
  TIMEOUT_CMD=""
  if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
  fi
  # Engine-specific timeout defaults:
  # - agy/Claude: 595s = hook timeout budget, one CLI attempt then REST fallback.
  #   Time-budget guard blocks retry (remaining < ENGINE_TIMEOUT), preserving REST budget.
  ENGINE_TIMEOUT="${REVIEW_ENGINE_TIMEOUT:-595}"

  # --- Gemini degraded-state check ---
  # If Gemini was capacity-exhausted recently and REST is configured,
  # skip CLI entirely — gives REST the full ~115s budget.
  REVIEW_ENGINE_DEGRADE_TTL="${REVIEW_ENGINE_DEGRADE_TTL:-3600}"
  _gemini_skip_cli=0
  _fail_reason=""
  if [ "$REVIEW_ENGINE" = "gemini" ] && [ -n "${REVIEW_API_URL:-}" ] && [ -n "${REVIEW_API_KEY:-}" ]; then
    if [ -f "$DEGRADE_FILE" ]; then
      degrade_ts=$(cat "$DEGRADE_FILE" 2>/dev/null)
      [[ "$degrade_ts" =~ ^[0-9]+$ ]] || degrade_ts=0
      now_ts=$(date +%s)
      degrade_age=$(( now_ts - degrade_ts ))
      if (( degrade_age < REVIEW_ENGINE_DEGRADE_TTL )); then
        remaining_degrade=$(( REVIEW_ENGINE_DEGRADE_TTL - degrade_age ))
        echo "plan-review: gemini degraded state active (${degrade_age}s ago, TTL=${REVIEW_ENGINE_DEGRADE_TTL}s, ${remaining_degrade}s remaining), skipping CLI → REST fallback" >&2
        log_decision "gemini-degraded skip-cli remaining_degrade=${remaining_degrade}s"
        _gemini_skip_cli=1
        _fail_reason="Gemini: degraded state (${degrade_age}s ago, expires in ${remaining_degrade}s)"
      fi
    fi
  fi

  # --- Engine invocation with retry (2 attempts: 1 initial + 1 retry) ---
  # Background + wait pattern: tracks ENGINE_PID so _cleanup can kill the engine
  # process if the hook script itself is terminated (e.g. hook timeout SIGTERM).
  ENGINE_OUT=$(mktemp)
  ENGINE_STATUS="${ENGINE_OUT}.status"
  REVIEW=""
  HOOK_BUDGET="${REVIEW_HOOK_BUDGET:-595}"
  for (( engine_attempt=1; engine_attempt<=2; engine_attempt++ )); do
    # Degraded-state skip: jump out of CLI retry immediately on first iteration.
    if (( engine_attempt == 1 )) && [ "$_gemini_skip_cli" = "1" ]; then
      break
    fi

    # Time-budget guard: on retry, check remaining wall-clock time can fit
    # a full ENGINE_TIMEOUT. Prevents hook timeout SIGTERM from killing
    # the script mid-retry, making REST fallback unreachable.
    if (( engine_attempt > 1 )); then
      remaining=$(( HOOK_BUDGET - SECONDS ))
      if (( remaining < ENGINE_TIMEOUT )); then
        echo "plan-review: time budget exhausted for retry (${remaining}s remaining < ${ENGINE_TIMEOUT}s needed), breaking to fallback..." >&2
        log_decision "skip-retry reason=time-budget remaining=${remaining}s timeout=${ENGINE_TIMEOUT}s budget=${HOOK_BUDGET}s"
        break
      fi
    fi
    engine_exit=0
    # Snapshot log position before call — used after failure to detect capacity-specific 429
    log_pos_before=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$REVIEW_ENGINE" = "claude" ]; then
      # Strip Claude Code internal env vars to prevent recursive hook/plugin loading.
      # Fragile (depends on internal implementation), but necessary: user authenticates
      # via OAuth (claude login), no ANTHROPIC_API_KEY available, so claude -p is the
      # only viable path. Triple isolation: --setting-sources local + PLAN_REVIEW_RUNNING
      # + --tools "" (no tool calls = no PreToolUse events).
      unset CLAUDECODE
      unset CLAUDE_CODE_ENTRYPOINT
      PLAN_REVIEW_RUNNING=1 ${TIMEOUT_CMD:+$TIMEOUT_CMD -k 5 $ENGINE_TIMEOUT} claude -p \
        --model "$CLAUDE_MODEL" \
        --setting-sources local \
        --no-session-persistence \
        --tools "" \
        --disable-slash-commands \
        --system-prompt "$SYSTEM_PROMPT" \
        < "$PROMPT_FILE" > "$ENGINE_OUT" 2>>"$LOG_FILE" &
      ENGINE_PID=$!
      wait "$ENGINE_PID" 2>/dev/null || engine_exit=$?
      ENGINE_PID=""
    else
      # agy does not read stdin as a prompt — must pass inline via -p. ANSI-C
      # quoting ($'\n\n') for a real newline separator; a plain "\n" inside
      # double quotes is a literal backslash-n, not a newline.
      FULL_PROMPT="$SYSTEM_INSTRUCTIONS"$'\n\n'"$(cat "$PROMPT_FILE")"
      # ARG_MAX defense: agy only accepts the prompt as a command-line argument,
      # so an oversized prompt trips E2BIG. Treat this as a CLI failure and
      # fall straight through to REST fallback rather than exec'ing a doomed command.
      # Count BYTES, not characters: the ARG_MAX limit is byte-denominated, but
      # ${#VAR} counts characters under a UTF-8 locale, so a CJK plan (3 bytes/
      # char) would undercount ~3x and defeat the 256KB guard. `wc -c` counts
      # bytes regardless of locale — one fork per hook invocation is negligible,
      # and it sidesteps the LC_ALL=C prefix-assignment locale-leak footgun.
      AGY_PROMPT_BYTES=$(printf '%s' "$FULL_PROMPT" | wc -c | tr -d ' ')
      if [ "$AGY_PROMPT_BYTES" -gt 256000 ]; then
        log_decision "agy-skip reason=prompt-too-large bytes=$AGY_PROMPT_BYTES"
        REVIEW=""
        _fail_reason="agy: prompt too large (${AGY_PROMPT_BYTES}B > 256000B), skipped to REST"
        break
      fi
      ${TIMEOUT_CMD:+$TIMEOUT_CMD -k 5 $ENGINE_TIMEOUT} agy --model "$AGY_MODEL" --sandbox --dangerously-skip-permissions \
        -p "$FULL_PROMPT" > "$ENGINE_OUT" 2>>"$LOG_FILE" &
      ENGINE_PID=$!
      wait "$ENGINE_PID" 2>/dev/null || engine_exit=$?
      ENGINE_PID=""
    fi
    REVIEW=$(cat "$ENGINE_OUT" 2>/dev/null || true)
    : > "$ENGINE_OUT"
    if [ "$engine_exit" != "0" ]; then
      REVIEW=""
      _fail_reason="${REVIEW_ENGINE}: exit ${engine_exit}"
      if [ "$engine_attempt" -lt 2 ]; then
        # Detect capacity-exhausted 429 (MODEL_CAPACITY_EXHAUSTED via cloudcode-pa.googleapis.com).
        # These outages last minutes — the default 2s retry delay is useless;
        # a longer wait gives the server time to recover.
        # Check only log bytes written during this attempt to avoid matching old entries.
        if tail -c "+$((log_pos_before + 1))" "$LOG_FILE" 2>/dev/null \
             | grep -qE "RESOURCE_EXHAUSTED|MODEL_CAPACITY" 2>/dev/null; then
          _fail_reason="${REVIEW_ENGINE}: capacity exhausted (MODEL_CAPACITY_EXHAUSTED)"
          # If REST fallback is configured, skip retry immediately — retrying a
          # capacity-exhausted endpoint wastes the time budget REST needs.
          if [ -n "${REVIEW_API_URL:-}" ] && [ -n "${REVIEW_API_KEY:-}" ]; then
            # Persist degraded state: subsequent hooks skip CLI for TTL seconds.
            if [ "$REVIEW_ENGINE" = "gemini" ]; then
              printf '%s' "$(date +%s)" > "$DEGRADE_FILE" 2>/dev/null || true
              log_decision "gemini-degrade-write ts=$(date +%s)"
            fi
            echo "plan-review: $REVIEW_ENGINE capacity exhausted, skipping retry (REST fallback available)" >&2
            log_decision "rest-skip=capacity-fast-break engine=$REVIEW_ENGINE attempt=$engine_attempt"
            break
          fi
          retry_delay="${REVIEW_CAPACITY_DELAY:-25}"
          echo "plan-review: $REVIEW_ENGINE capacity exhausted, waiting ${retry_delay}s for recovery..." >&2
        else
          retry_delay="${REVIEW_RETRY_DELAY:-2}"
          echo "plan-review: $REVIEW_ENGINE failed (attempt $engine_attempt/2, exit $engine_exit), retrying in ${retry_delay}s..." >&2
        fi
        sleep "$retry_delay"
      fi
      continue
    fi

    # Engine succeeded (exit 0) but returned empty → retry
    if [ -z "$REVIEW" ]; then
      if [ "$engine_attempt" -lt 2 ]; then
        echo "plan-review: engine returned empty response (attempt $engine_attempt/2), retrying..." >&2
        sleep "${REVIEW_RETRY_DELAY:-2}"
      fi
      continue
    fi

    # Non-empty response obtained — exit retry loop
    break
  done

  # --- REST API fallback: CLI exhausted, try OpenAI-compatible endpoint ---
  # Zero-intrusion: only fires when CLI produced no result AND env vars are set.
  # REVIEW_API_URL/REVIEW_API_KEY empty → skip (preserves original fail-open).
  if [ -z "$REVIEW" ] && [ -n "${REVIEW_API_URL:-}" ] && [ -n "${REVIEW_API_KEY:-}" ]; then
    # Persist (or refresh) Gemini degraded state for any failure mode.
    # Covers timeout (exit 124), network errors (ECONNRESET), empty responses, etc.
    # Always refreshes the timestamp — even if the file already exists but has expired.
    # Without refresh, an expired degrade file blocks TTL renewal: the check above lets
    # Gemini run again (_gemini_skip_cli=0), it fails again, but the stale file prevents
    # writing a new timestamp, creating an infinite retry-with-40s-REST-budget loop.
    if [ "$REVIEW_ENGINE" = "gemini" ] && [ "$_gemini_skip_cli" = "0" ]; then
      printf '%s' "$(date +%s)" > "$DEGRADE_FILE" 2>/dev/null || true
      log_decision "gemini-degrade-write ts=$(date +%s) reason=rest-fallback-triggered"
    fi
    echo "plan-review: CLI exhausted, trying REST API fallback..." >&2
    log_decision "rest-start url=${REVIEW_API_URL:+(set)} key=${REVIEW_API_KEY:+(set)}"
    REQ_FILE=$(mktemp)
    # --rawfile (not --arg + $(cat ...)) reads PROMPT_FILE directly inside jq,
    # keeping the large plan body off the command line entirely (no E2BIG risk
    # on this side). messages[0]=system stays a stable prefix across rounds —
    # prefix-cacheable by the upstream provider. stream:true enables SSE below.
    jq -n --arg model "${GEMINI_MODEL:-gemini-3.1-pro-preview}" \
          --arg sys "$SYSTEM_INSTRUCTIONS" \
          --rawfile prompt "$PROMPT_FILE" \
      '{ model: $model, messages: [{ role: "system", content: $sys }, { role: "user", content: $prompt }], max_tokens: 16000, temperature: 0.1, stream: true }' \
      > "$REQ_FILE"

    REST_TIMEOUT="${REVIEW_REST_TIMEOUT:-115}"
    # Stall watchdog: aborts if the stream produces < 1 byte/s for this many
    # seconds. Set well above legitimate TTFT (time-to-first-token) for
    # reasoning models, which can sit silent for tens of seconds before the
    # first SSE chunk arrives — too low a value misfires on a healthy stream.
    STALL_TIMEOUT="${REVIEW_REST_STALL_TIMEOUT:-90}"
    # Clamp to remaining budget: ensure curl self-terminates before hook
    # timeout SIGTERM, preserving diagnostic log writes after curl completes.
    # 3s margin for jq extraction + log_decision after curl returns.
    remaining=$(( HOOK_BUDGET - SECONDS ))
    (( remaining - 3 < REST_TIMEOUT )) && REST_TIMEOUT=$(( remaining - 3 ))
    (( REST_TIMEOUT < 1 )) && REST_TIMEOUT=1
    # -sS: -s suppresses progress meter, -S re-enables error messages (connection-level errors
    # like "Failed to connect" would be silenced by -s alone, making raw_bytes=0 undiagnosable).
    # --no-buffer: disable curl's output buffering so SSE chunks land in ENGINE_OUT as they
    # arrive (only matters for anyone tailing the file live; parsing below still reads it
    # after wait). --speed-limit/--speed-time: curl's own stall watchdog — abort (exit 28)
    # if throughput drops below 1 byte/s for STALL_TIMEOUT seconds, independent of the
    # outer TIMEOUT_CMD wall-clock cap.
    # -w "%{http_code}": write HTTP status to stdout (redirected to ENGINE_STATUS); response
    # body goes to ENGINE_OUT via -o. Read ENGINE_STATUS only AFTER wait completes.
    ${TIMEOUT_CMD:+$TIMEOUT_CMD -k 5 $REST_TIMEOUT} curl -sS \
      --no-buffer --speed-limit 1 --speed-time "$STALL_TIMEOUT" \
      -X POST "${REVIEW_API_URL}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${REVIEW_API_KEY}" \
      -d @"$REQ_FILE" \
      -o "$ENGINE_OUT" \
      -w "%{http_code}" \
      2>>"$LOG_FILE" > "$ENGINE_STATUS" &
    ENGINE_PID=$!
    curl_exit=0
    wait "$ENGINE_PID" 2>/dev/null || curl_exit=$?
    ENGINE_PID=""
    rm -f "$REQ_FILE"; REQ_FILE=""

    # Read status after wait — shell creates ENGINE_STATUS on redirect, content written by curl.
    # Explicit empty check: command substitution strips trailing newlines, but file may be empty
    # (connection-level failure before HTTP handshake) → use "000" as sentinel for no-response.
    rest_http_status=$(cat "$ENGINE_STATUS" 2>/dev/null)
    [ -z "$rest_http_status" ] && rest_http_status="000"

    if [ "$curl_exit" = "28" ]; then
      # Stall watchdog fired — the provider went silent mid-stream. Don't hand
      # a truncated partial body to the SSE parser; treat as a clean failure.
      log_decision "rest-stall-timeout curl_exit=28"
      REVIEW=""
      _fail_reason="${_fail_reason:+${_fail_reason}; }REST: stall timeout (curl exit 28, no data for ${STALL_TIMEOUT}s)"
    else
      # Non-SSE error bypass: a non-2xx status, or a bare JSON object body (error
      # response, not an SSE stream), must skip the SSE parser — feeding an error
      # JSON through the "data: " cleaning pipeline silently drops it and yields an
      # empty REVIEW with no diagnosis.
      first_char=$(tr -d '[:space:]' < "$ENGINE_OUT" 2>/dev/null | head -c 1)
      case "$rest_http_status" in
        2[0-9][0-9]) is_2xx=1 ;;
        *) is_2xx=0 ;;
      esac
      if [ "$is_2xx" = "0" ] || [ "$first_char" = "{" ]; then
        REVIEW=""
        # Only emit rest-debug when there is a body to describe. An empty body
        # (connection-level failure before the HTTP handshake, status 000) has
        # nothing to diagnose — [ -s ] guards against a bare "body_prefix=" line.
        if [ -s "$ENGINE_OUT" ]; then
          rest_error=$(jq -r '.error.message // empty' "$ENGINE_OUT" 2>/dev/null || true)
          if [ -n "$rest_error" ]; then
            log_decision "rest-debug api_error=$(printf '%s' "$rest_error" | head -c 200)"
          else
            # tr -d '\000-\037': strip control characters to keep log single-line safe
            log_decision "rest-debug body_prefix=$(head -c 200 "$ENGINE_OUT" | tr -d '\000-\037')"
          fi
        fi
      else
        # SSE cleaning pipeline: strip the "data: " prefix, then parse each frame
        # in isolation and join delta.content across chunks.
        #   -R  : read each line as a raw string (not pre-parsed JSON), so ONE
        #         malformed frame cannot abort the whole parse.
        #   fromjson? : parse the line to JSON, but the trailing "?" swallows a
        #         parse error on that single line and skips it — a truncated /
        #         garbled mid-stream frame (transient gateway hiccup) drops just
        #         itself instead of discarding every chunk after it. The old
        #         "-rj '.choices...'" form fed the whole stream to jq at once, so
        #         a single bad frame aborted parsing and SILENTLY truncated the
        #         review (2>/dev/null || true hid the exit 5) — a partial body can
        #         carry a stale verdict and wrongly approve. fromjson? also makes
        #         the non-JSON "[DONE]" terminator a no-op; the explicit grep -v
        #         below is kept as belt-and-suspenders and to document intent.
        #   -j  : join output, no per-value newline — O(1) memory, streaming.
        #   "// empty": role-only first frame / finish_reason-only last frame /
        #         empty-choices usage tail carry no content key — skip, don't emit "null".
        REVIEW=$(grep '^data: ' "$ENGINE_OUT" | sed 's/^data: //' | grep -v '^\[DONE\]' | jq -j -R 'fromjson? | .choices[0].delta.content // empty' 2>/dev/null || true)
      fi

      raw_bytes=$(wc -c < "$ENGINE_OUT" | tr -d ' ')
      review_bytes=$(printf '%s' "$REVIEW" | wc -c | tr -d ' ')
      log_decision "rest-result http=$rest_http_status raw_bytes=$raw_bytes review_bytes=$review_bytes"
      if [ -z "$REVIEW" ]; then
        _fail_reason="${_fail_reason:+${_fail_reason}; }REST: http=${rest_http_status} raw_bytes=${raw_bytes}"
      fi
    fi

    : > "$ENGINE_OUT"
    [ -z "$REVIEW" ] || echo "plan-review: REST API fallback succeeded." >&2
  fi

  # All attempts exhausted
  if [ -z "$REVIEW" ]; then
    if [ -n "$_fail_reason" ]; then
      # Engines were tried but all failed — deny with explanation so LLM can retry.
      deny_msg="plan-review: all review engines failed — ${_fail_reason}. Call ExitPlanMode again to retry."
      log_decision "decision=deny reason=engines-failed detail=${_fail_reason}"
      echo "$deny_msg" >&2
      DENY_JSON=$(printf '%s' "$deny_msg" | jq -Rs .)
      cat << EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":${DENY_JSON}}}
EOF
    else
      # No engines attempted (dry-run exits earlier; this path = unconfigured engine)
      log_decision "decision=allow reason=engine-not-attempted"
      allow_with_reason "[WARNING] 引擎调用失败（已重试），审阅跳过。详见 $LOG_FILE"
    fi
    exit 0
  fi
fi

# --- 6. Extract structured verdict (XML-tag isolation, anti-hijack) ---
# Defensive extraction: LLM output is untrusted external input.
#   1. printf — safe for text starting with -n/-E (echo is not), trailing \n for POSIX
#   2. tr upper — case-normalize before matching (BSD sed has no /I flag)
#   3. grep -oE (first pass) — extract <VERDICT>...</VERDICT> tag
#   4. grep -oE (second pass) — extract verdict keyword from the tag
#   5. head -n 1 — LLM may emit multiple tags; guarantee single value
#   || true — grep returns exit 1 on no match; suppress for set -e + pipefail
VERDICT=$(printf "%s\n" "$REVIEW" \
  | tr '[:lower:]' '[:upper:]' \
  | grep -oE '<VERDICT>[[:space:]]*(APPROVE|CONCERNS|REJECT)[[:space:]]*</VERDICT>' \
  | grep -oE 'APPROVE|CONCERNS|REJECT' \
  | head -n 1) || true
if [ -z "$VERDICT" ]; then
  VERDICT="CONCERNS"
  echo "plan-review: verdict tag missing or malformed, falling back to CONCERNS." >&2
fi

# --- 7. Branch on verdict ---
if [ "$VERDICT" = "APPROVE" ]; then
  log_decision "verdict=APPROVE decision=ack-deny"
  # Write plan hash to marker — ack-round guard compares hash to detect post-approve edits
  printf '%s' "$(plan_hash "$PLAN")" > "$APPROVE_MARKER"

  # Parse manifest → dispatch JSON for Layer 2 enforcement (fail-silent: Layer 2 self-disables)
  if has_manifest "$PLAN"; then
    DISPATCH_DIR="${REVIEW_COUNTER_DIR:-/tmp/claude-reviews}"
    mkdir -p "$DISPATCH_DIR" 2>/dev/null || true
    find "$DISPATCH_DIR" -maxdepth 1 -name '.dispatch-*.json' -mmin +30 -delete 2>/dev/null || true
    DISPATCH_FILE="$DISPATCH_DIR/.dispatch-${SESSION_ID}.json"
    parse_manifest_to_json "$PLAN" "$(plan_hash "$PLAN")" > "$DISPATCH_FILE" 2>/dev/null || rm -f "$DISPATCH_FILE"
    if [ -f "$DISPATCH_FILE" ]; then
      dispatch_bytes=$(wc -c < "$DISPATCH_FILE" | tr -d ' ')
      log_decision "manifest-written file=$DISPATCH_FILE bytes=$dispatch_bytes"
    fi
  fi

  if [ "$TOTAL_ROUNDS" -gt 0 ]; then
    APPROVE_HEADER="Red Team Review — ${REVIEW_ENGINE} — APPROVED (Round $((TOTAL_ROUNDS + 1)))"
  else
    APPROVE_HEADER="Red Team Review — ${REVIEW_ENGINE} — APPROVED"
  fi

  # Emit deny so Claude presents the approval to the user (allow reasons are invisible)
  FEEDBACK=$(cat << APPROVE_EOF
## ${APPROVE_HEADER}

审阅引擎已**通过**本次 plan。以下是审阅摘要：

---

${REVIEW}

---

> 请向用户简要展示上述审阅结果，然后直接再次调用 ExitPlanMode（不要修改 plan）。
APPROVE_EOF
  )
  FEEDBACK_JSON=$(printf '%s' "$FEEDBACK" | jq -Rs .)
  cat << EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":${FEEDBACK_JSON}}}
EOF
  exit 0
fi

# CONCERNS or REJECT → update counter, deny with feedback
TOTAL_ROUNDS=$((TOTAL_ROUNDS + 1))

if [ "$VERDICT" = "REJECT" ]; then
  # REJECT (Critical): reset ATTEMPT so subsequent non-Critical rounds restart fresh
  ATTEMPT=0
else
  # CONCERNS: non-Critical, increment ATTEMPT
  ATTEMPT=$((ATTEMPT + 1))
fi

echo "${ATTEMPT}:${TOTAL_ROUNDS}" > "$COUNTER_FILE"
log_decision "verdict=$VERDICT decision=deny round=$ATTEMPT/$REVIEW_MAX_ROUNDS total=$TOTAL_ROUNDS/$REVIEW_MAX_TOTAL_ROUNDS"

# --- 8. Compose deny feedback (severity-differentiated) ---
if [ "$VERDICT" = "REJECT" ]; then
  FEEDBACK_HEADER="Red Team Review — ${REVIEW_ENGINE} — REJECT (Round ${TOTAL_ROUNDS}/${REVIEW_MAX_TOTAL_ROUNDS})"
  PHASE_MSG="审阅引擎发现 Critical 级别问题。非 Critical 磋商计数已重置，解决 Critical 项后可重新获得 ${REVIEW_MAX_ROUNDS} 轮磋商机会。"
else
  REMAINING=$((REVIEW_MAX_ROUNDS - ATTEMPT))
  FEEDBACK_HEADER="Red Team Review — ${REVIEW_ENGINE} — CONCERNS (Round ${ATTEMPT}/${REVIEW_MAX_ROUNDS})"
  PHASE_MSG="磋商剩余轮次：${REMAINING}。若双方无法达成一致，plan 将直接呈现给用户做最终裁决。"
fi

FEEDBACK=$(cat << REVIEW_EOF
## ${FEEDBACK_HEADER}

${PHASE_MSG}

你有两个选择：
1. 如意见合理，修正 plan 后再次调用 ExitPlanMode
2. 如你认为意见不成立，在 plan 中补充辩护理由后再次调用 ExitPlanMode

---

${REVIEW}
REVIEW_EOF
)

FEEDBACK_JSON=$(echo "$FEEDBACK" | jq -Rs .)

cat << EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":${FEEDBACK_JSON}}}
EOF

exit 0
