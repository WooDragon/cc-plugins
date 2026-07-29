#!/bin/bash
# PreToolUse hook: Adversarial plan review via cross-model consultation.
#
# Triggered when Plan agent calls ExitPlanMode (via PreToolUse matcher).
# Flow (severity-aware adversarial consultation):
#   ExitPlanMode called → hook intercepts → review engine (Gemini/Claude/Codex) reviews:
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
#   REVIEW_ENGINE=gemini         — review engine: "gemini" (default), "claude", or "codex"
#   CLAUDE_MODEL=opus            — Claude engine model (default: opus)
#   AGY_MODEL=<id>               — agy CLI model (default: Gemini 3.1 Pro (High))
#   GEMINI_MODEL=<id>            — REST fallback model id (default: gemini-3.1-pro-preview)
#   CODEX_BIN=<path>             — codex engine binary override (default: codex on PATH)
#   CODEX_MODEL=<id>             — codex engine model (default: inherit ~/.codex/config.toml)
#   REVIEW_ENGINE_TIMEOUT=N      — engine call timeout seconds (default: 595; needs timeout/gtimeout)
#   REVIEW_REST_TIMEOUT=N        — REST API fallback curl timeout, default 115 (equals HOOK_BUDGET; clamp logic caps actual value to remaining-3)
#   REVIEW_REST_STALL_TIMEOUT=N  — REST SSE stall watchdog seconds, default 90 (curl --speed-time)
#   REVIEW_HOOK_BUDGET=N         — hook total time budget, default 595 (600 hook timeout - 5s margin)
#   REVIEW_RETRY_DELAY=N         — seconds between retries on non-capacity failure (default: 2)
#   REVIEW_CAPACITY_DELAY=N      — seconds to wait when MODEL_CAPACITY_EXHAUSTED detected (default: 25)
#   REVIEW_API_URL=<url>         — REST API fallback base URL (OpenAI-compatible, e.g. https://proxy.example.com)
#   REVIEW_API_KEY=<key>         — REST API fallback auth key (Bearer token)
#   REVIEW_ENGINE_DEGRADE_TTL=N  — seconds Gemini stays in degraded state after capacity exhaustion (default: 600)
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

# --- Bootstrap: resolve script dir + verify lib files before sourcing ---
# Cannot call allow_with_reason() here — it is defined in lib/common.sh, not
# yet sourced (chicken-and-egg). Inline literal JSON mirrors its exact shape
# (same allow + [WARNING] pattern as the jq-missing guard above).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LIB_COMMON="$SCRIPT_DIR/lib/common.sh"
LIB_PLAN_SOURCE="$SCRIPT_DIR/lib/plan-source.sh"
LIB_MANIFEST="$SCRIPT_DIR/lib/manifest.sh"
LIB_VERDICT="$SCRIPT_DIR/lib/verdict.sh"
PROMPT_ASSET="$SCRIPT_DIR/assets/review-system-prompt.md"

for _lib in "$LIB_COMMON" "$LIB_PLAN_SOURCE" "$LIB_MANIFEST" "$LIB_VERDICT"; do
  if [ ! -f "$_lib" ]; then
    echo "plan-review: missing lib file $_lib, allowing." >&2
    echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"[WARNING] lib file missing, plan-review skipped"}}'
    exit 0
  fi
done
unset _lib

# shellcheck source=lib/common.sh
source "$LIB_COMMON"
# shellcheck source=lib/plan-source.sh
source "$LIB_PLAN_SOURCE"
# shellcheck source=lib/manifest.sh
source "$LIB_MANIFEST"
# shellcheck source=lib/verdict.sh
source "$LIB_VERDICT"

# --- Cleanup trap (registered here, right after lib sourcing, so any early
#     exit — including the pre-flight guards below — is covered; previously
#     this trapped only after PROMPT_FILE=$(mktemp) much later in the script,
#     leaving every earlier exit path without cleanup coverage. Every var
#     defaults to empty (":-") since most of them are not assigned until deep
#     inside the engine-invocation section further down; rm -f/rmdir/kill on
#     an empty or already-gone target is a harmless no-op. Called on EXIT
#     (normal), INT (Ctrl-C), TERM (framework hook timeout), and HUP (terminal
#     disconnect). Idempotent — safe to call multiple times.
_cleanup() {
  rm -f "${PROMPT_FILE:-}" "${ENGINE_OUT:-}" "${ENGINE_STATUS:-}" "${REQ_FILE:-}"
  rm -f "${ENGINE_ERR:-}" "${CODEX_PROMPT_FILE:-}" "${CODEX_PROMPT_FILE:+${CODEX_PROMPT_FILE}.u8}"
  [ -z "${CODEX_WORKDIR:-}" ] || rmdir "${CODEX_WORKDIR:-}" 2>/dev/null || true
  [ -z "${ENGINE_PID:-}" ] || kill "${ENGINE_PID:-}" 2>/dev/null || true
}
trap '_cleanup' EXIT
trap '_cleanup; exit 130' INT TERM HUP

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
# agy conversation_id cache (session-scoped) — lets multi-round review reuse
# agy's own server-side session so the static prompt prefix hits prompt cache
# instead of being resent every round. Lifetime = one review cycle (see cleanup
# points at the no-plan fail-closed / ack-round-approved / non-critical-valve exits).
CONV_FILE="$COUNTER_DIR/.conversation-${SESSION_ID}"

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
  rm -f "$APPROVE_MARKER" "$COUNTER_FILE" "${CONV_FILE:-}"
  # Error message routed by the resolver's RESOLVE_REASON (see
  # lib/plan-source.sh: plan_source_error_reason) — sets $REASON directly.
  plan_source_error_reason
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
    rm -f "$APPROVE_MARKER" "$COUNTER_FILE" "${CONV_FILE:-}"
    allow_with_reason "Red Team 审阅已通过，plan 放行。"
  else
    # Plan was modified after approve: marker invalid, delete and fall through to re-review.
    # Also drop the conversation handle — the session history is about the OLD
    # plan; reusing it to review a DIFFERENT plan would resume stale context.
    # The re-review must start a fresh first round for the new plan.
    log_decision "decision=review-again reason=plan-changed-after-approve conv-cleared"
    rm -f "$APPROVE_MARKER" "${CONV_FILE:-}"
    # Fall through to full review pipeline
  fi
fi

# --- Global safety valve: total rounds exhausted → hard deny (tombstone counter) ---
# Never delete counter — tombstone blocks subsequent calls until human intervenes
if [ "$TOTAL_ROUNDS" -ge "$REVIEW_MAX_TOTAL_ROUNDS" ]; then
  log_decision "decision=deny reason=global-safety-valve total=$TOTAL_ROUNDS"
  # Keep the COUNTER_FILE tombstone, but the review cycle is over — no further
  # engine call will happen, so drop the session ref to avoid an orphan CONV_FILE.
  rm -f "${CONV_FILE:-}"
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
  rm -f "$COUNTER_FILE" "${CONV_FILE:-}"
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
# SYSTEM_INSTRUCTIONS content lives in $PROMPT_ASSET (scripts/assets/
# review-system-prompt.md), not inline — keeps the review rubric editable
# without touching bash. Missing/empty asset fails open (same allow +
# [WARNING] shape as the jq-missing guard above). A plain $(...) would
# silently strip the file's trailing newline; the original `read -r -d ''`
# heredoc preserved it (bash always terminates a heredoc's last content line
# with \n, and `read -d ''` never finds its NUL delimiter so nothing gets
# stripped), so we append a sentinel byte before capture and strip only the
# sentinel back off — this reproduces the exact prior byte sequence.
if [ ! -f "$PROMPT_ASSET" ] || [ ! -s "$PROMPT_ASSET" ]; then
  echo "plan-review: missing/empty prompt asset $PROMPT_ASSET, allowing." >&2
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"[WARNING] prompt asset missing/empty, plan-review skipped"}}'
  exit 0
fi
SYSTEM_INSTRUCTIONS=$(tr -d '\r' < "$PROMPT_ASSET"; printf 'x')
SYSTEM_INSTRUCTIONS="${SYSTEM_INSTRUCTIONS%x}"

ENGINE_OUT=""
ENGINE_STATUS=""
ENGINE_PID=""
REQ_FILE=""
PROMPT_FILE=$(mktemp)

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
  case "$REVIEW_ENGINE" in
    claude) ENGINE_CMD="claude" ;;
    codex)  ENGINE_CMD="${CODEX_BIN:-codex}" ;;
  esac
  if ! command -v "$ENGINE_CMD" >/dev/null 2>&1; then
    log_decision "decision=allow reason=engine-not-found engine=$REVIEW_ENGINE"
    allow_with_reason "[WARNING] REVIEW_ENGINE=$REVIEW_ENGINE but '$ENGINE_CMD' not found"
  fi

  # Engine model variables (outside retry loop, avoid repeat assignment)
  if [ "$REVIEW_ENGINE" = "claude" ]; then
    CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"
  elif [ "$REVIEW_ENGINE" = "codex" ]; then
    # Empty CODEX_MODEL means inherit codex's own ~/.codex/config.toml default.
    CODEX_MODEL="${CODEX_MODEL:-}"
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
  REVIEW_ENGINE_DEGRADE_TTL="${REVIEW_ENGINE_DEGRADE_TTL:-600}"
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

  # codex-only temp resources: a sandboxed workdir (-C target, deliberately NOT
  # the project cwd — codex runs read-only but there's no reason to hand it the
  # real tree), a merged prompt file (system instructions + PROMPT_FILE's
  # dynamic content — kept SEPARATE from PROMPT_FILE itself so the REST
  # fallback's --rawfile read of PROMPT_FILE doesn't double-send the system
  # instructions), and an isolated stderr capture (codex echoes the FULL
  # prompt to stderr — see the diagnostic backfill below, never let this reach
  # LOG_FILE wholesale). Declared as empty defaults unconditionally so set -u
  # never fires on the gemini/claude paths, and created only when
  # REVIEW_ENGINE=codex so those paths gain zero new mktemp calls.
  CODEX_WORKDIR="" CODEX_PROMPT_FILE="" ENGINE_ERR="" PROMPT_LINES=0
  if [ "$REVIEW_ENGINE" = "codex" ]; then
    CODEX_WORKDIR=$(mktemp -d)
    CODEX_PROMPT_FILE=$(mktemp)
    ENGINE_ERR="${ENGINE_OUT}.err"
    { printf '%s\n\n' "$SYSTEM_INSTRUCTIONS"; cat "$PROMPT_FILE"; } > "$CODEX_PROMPT_FILE"
    printf '\n' >> "$CODEX_PROMPT_FILE"
    # UTF-8 sanitation (codex-only — the other engines never see this file).
    # GLOBAL_MD/PROJECT_MD are truncated by BYTE count (`head -c 3000` / `-c 8000`),
    # which slices a multi-byte character in half whenever a CLAUDE.md is non-ASCII
    # near the cut. codex hard-rejects such input — it does not degrade, it aborts:
    #   "Failed to read prompt from stdin: input is not valid UTF-8 (invalid byte
    #    at offset N). Convert it to UTF-8 and retry"
    # …making REVIEW_ENGINE=codex unusable for anyone with a non-ASCII CLAUDE.md.
    # `iconv -c` drops only the orphaned bytes and keeps every valid character.
    # Guarded on iconv's presence and on success (`&& mv || rm`), so a missing or
    # failing iconv degrades to the unsanitized file rather than an empty prompt.
    if command -v iconv >/dev/null 2>&1; then
      if iconv -f UTF-8 -t UTF-8 -c < "$CODEX_PROMPT_FILE" > "${CODEX_PROMPT_FILE}.u8" 2>/dev/null; then
        mv -f "${CODEX_PROMPT_FILE}.u8" "$CODEX_PROMPT_FILE"
      else
        rm -f "${CODEX_PROMPT_FILE}.u8"
      fi
    fi
    # Counted AFTER sanitation: PROMPT_LINES drives the diagnostic backfill's
    # positional cut, which must match the file codex actually received.
    PROMPT_LINES=$(wc -l < "$CODEX_PROMPT_FILE")
  fi

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
    elif [ "$REVIEW_ENGINE" = "codex" ]; then
      # Model id can contain spaces (see AGY_MODEL's default "Gemini 3.1 Pro
      # (High)" precedent above) — must be an array, not ${VAR:+...} word-splitting.
      CODEX_MODEL_ARGS=()
      [ -z "$CODEX_MODEL" ] || CODEX_MODEL_ARGS=(-m "$CODEX_MODEL")
      ${TIMEOUT_CMD:+$TIMEOUT_CMD -k 5 $ENGINE_TIMEOUT} "$ENGINE_CMD" exec \
        --skip-git-repo-check -s read-only --ephemeral --color never \
        -C "$CODEX_WORKDIR" ${CODEX_MODEL_ARGS[@]+"${CODEX_MODEL_ARGS[@]}"} \
        -o "$ENGINE_OUT" - < "$CODEX_PROMPT_FILE" > /dev/null 2> "$ENGINE_ERR" &
      ENGINE_PID=$!
      wait "$ENGINE_PID" 2>/dev/null || engine_exit=$?
      ENGINE_PID=""

      if [ "$engine_exit" != "0" ]; then
        # --- Privacy boundary: codex echoes the FULL prompt to stderr before
        # its real diagnostics (global CLAUDE.md + project CLAUDE.md + recent
        # conversation + the plan). Never let ENGINE_ERR reach LOG_FILE
        # wholesale — backfill only a filtered tail, two-layer defense:
        #   Layer A (positional): locate the banner's SECOND "--------" line
        #     (within the first 20 lines) followed by a line that is exactly
        #     "user" — that marks where the echoed prompt begins; cut it out
        #     using PROMPT_LINES (captured once, outside the retry loop) to
        #     find where it ends, keeping the banner + the real tail after it.
        #     Any of the three guards failing falls through to the fail-closed
        #     `tail -n 20` branch, which still preserves diagnostics for
        #     failures that happen before codex echoes anything (auth/network).
        #   Layer B (content-based): grep -Fvxf strips any surviving line that
        #     is byte-identical to a prompt line — this is what survives codex
        #     version drift in line counts (banner shape / prompt line count
        #     changing between versions).
        # `|| true` on the ECHO_END lookup and the final pipe are MANDATORY:
        # set -euo pipefail means a grep returning 1 (no match / everything
        # filtered out) would otherwise kill the hook before it emits its
        # decision JSON.
        # LC_ALL=C on both greps (command-scoped, not exported — deliberately
        # narrower than the LC_ALL=C prefix-assignment pattern avoided
        # elsewhere in this file): CODEX_PROMPT_FILE embeds GLOBAL_MD/
        # PROJECT_MD truncated by BYTE count (`head -c`), which can slice a
        # multi-byte UTF-8 character in half. Under the active UTF-8 locale
        # that makes grep abort with "illegal byte sequence" — silently
        # emptying CODEX_DIAG (the trailing `|| true` hides the failure).
        # Forcing the C locale makes grep treat input as raw bytes, matching
        # this pipeline's real behavior anyway: -F is already a fixed-string
        # byte match, and -x needs no locale-aware collation.
        CODEX_DIAG=$(
          ECHO_END=$(head -n 20 "$ENGINE_ERR" | grep -n '^--------$' | sed -n '2p' | cut -d: -f1) || true
          NEXT_LINE=$(sed -n "$(( ${ECHO_END:-0} + 1 ))p" "$ENGINE_ERR" 2>/dev/null)
          if [ -n "$ECHO_END" ] && [ "$ECHO_END" -le 20 ] && [ "$NEXT_LINE" = "user" ]; then
            { head -n "$ECHO_END" "$ENGINE_ERR"
              tail -n "+$(( ECHO_END + PROMPT_LINES + 2 ))" "$ENGINE_ERR"; }
          else
            tail -n 20 "$ENGINE_ERR"
          fi \
          | LC_ALL=C grep -Fvxf "$CODEX_PROMPT_FILE" \
          | LC_ALL=C grep '[^[:space:]]' \
          | head -c 500 || true
        )
        # tr -d '\000-\037': strip control chars, keep log single-line safe
        # (mirrors the existing rest-debug body_prefix backfill).
        log_decision "codex-diag $(printf '%s' "$CODEX_DIAG" | tr -d '\000-\037')"
      fi
    else
      # --- agy multi-round session reuse ---
      # Read back a previously-captured agy conversation_id (if any) so this
      # round can resume it instead of resending the full static prefix — the
      # prefix (system instructions + GLOBAL_MD/PROJECT_MD/USER_REQ) already
      # lives in agy's server-side session history, which lets the provider
      # hit prompt cache on it. Validate strictly (36-char UUID) since a
      # malformed/stale value would make `--conversation` resume garbage.
      CONV_ID=$(cat "${CONV_FILE:-}" 2>/dev/null | tr 'A-F' 'a-f' || true)
      [[ "$CONV_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || CONV_ID=""
      CONV_ARGS=()
      [ -z "$CONV_ID" ] || CONV_ARGS=(--conversation "$CONV_ID")

      # agy does not read stdin as a prompt — must pass inline via -p. ANSI-C
      # quoting ($'\n\n') for a real newline separator; a plain "\n" inside
      # double quotes is a literal backslash-n, not a newline.
      if [ -z "$CONV_ID" ]; then
        # First round (no session to resume yet): send the full static+dynamic prompt.
        AGY_PROMPT="$SYSTEM_INSTRUCTIONS"$'\n\n'"$(cat "$PROMPT_FILE")"
      else
        # Reuse round: static prefix already lives in agy's session history —
        # resend only the volatile tail. Mirror the first-round Consultation
        # Context framing (round number + "APPROVE if prior concerns addressed")
        # so the reuse round carries the same negotiation semantics, not a bare
        # plan dump. Resending the delta only (not the static context) is the
        # point — it gets appended to session history, so duplicating context
        # would cost tokens, not save them.
        AGY_PROMPT="## Consultation Context
This is round $((TOTAL_ROUNDS + 1)) of adversarial review.
The plan author may have revised or added rebuttals since the previous round.
Evaluate the CURRENT plan on its merits — if prior concerns have been addressed, APPROVE.

## Plan to Review
${PLAN}"
      fi
      # ARG_MAX defense: agy only accepts the prompt as a command-line argument,
      # so an oversized prompt trips E2BIG. Treat this as a CLI failure and
      # fall straight through to REST fallback rather than exec'ing a doomed command.
      # Count BYTES, not characters: the ARG_MAX limit is byte-denominated, but
      # ${#VAR} counts characters under a UTF-8 locale, so a CJK plan (3 bytes/
      # char) would undercount ~3x and defeat the 256KB guard. `wc -c` counts
      # bytes regardless of locale — one fork per hook invocation is negligible,
      # and it sidesteps the LC_ALL=C prefix-assignment locale-leak footgun.
      AGY_PROMPT_BYTES=$(printf '%s' "$AGY_PROMPT" | wc -c | tr -d ' ')
      if [ "$AGY_PROMPT_BYTES" -gt 256000 ]; then
        log_decision "agy-skip reason=prompt-too-large bytes=$AGY_PROMPT_BYTES"
        REVIEW=""
        _fail_reason="agy: prompt too large (${AGY_PROMPT_BYTES}B > 256000B), skipped to REST"
        break
      fi
      ${TIMEOUT_CMD:+$TIMEOUT_CMD -k 5 $ENGINE_TIMEOUT} agy --model "$AGY_MODEL" --sandbox --dangerously-skip-permissions \
        ${CONV_ARGS[@]+"${CONV_ARGS[@]}"} --output-format json \
        -p "$AGY_PROMPT" > "$ENGINE_OUT" 2>>"$LOG_FILE" &
      ENGINE_PID=$!
      wait "$ENGINE_PID" 2>/dev/null || engine_exit=$?
      ENGINE_PID=""
    fi
    if [ "$REVIEW_ENGINE" = "claude" ] || [ "$REVIEW_ENGINE" = "codex" ]; then
      REVIEW=$(cat "$ENGINE_OUT" 2>/dev/null || true)
    else
      # --- agy JSON response unwrap (--output-format json) ---
      # agy's JSON is NOT well-formed (the "response" field contains raw
      # unescaped newlines), so jq/python json.loads chokes on it. Everything
      # below is deliberate sed/awk text slicing — zero jq, zero python.
      REVIEW=""
      if [ "$engine_exit" = "0" ] && [ -s "$ENGINE_OUT" ]; then
        # Capture the real conversation_id agy assigned (self-chosen server-side
        # UUID; a client-invented one would not resume anything). `q` after the
        # first match — no pipe, no SIGPIPE. Tolerate a lowercase-normalized id;
        # persist is DEFERRED until response extraction succeeds (see below) so a
        # broken envelope never leaves a CONV_FILE that the next round resumes.
        NEW_CONV=$(sed -n '/"conversation_id"/{s/.*"conversation_id"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F-]\{36\}\)".*/\1/p;q;}' "$ENGINE_OUT" 2>/dev/null || true)
        NEW_CONV=$(printf '%s' "$NEW_CONV" | tr 'A-F' 'a-f')

        # Extract the "response" field value and unescape it. Deliberately NOT
        # keyed to field order/position — scan forward from the "response":"
        # marker and stop at the first UNESCAPED double-quote, so trailing keys
        # (usage, etc.) after response in the object don't matter.
        REVIEW=$(awk '
          BEGIN { RS="\x01" }
          {
            s = $0
            # Tolerate optional whitespace around the key colon
            # ("response" : "...") — do not bet on the compact serialization.
            if (match(s, /"response"[ \t]*:[ \t]*"/) == 0) { exit }
            s = substr(s, RSTART + RLENGTH)
            out = ""; i = 1; n = length(s)
            while (i <= n) {
              c = substr(s, i, 1)
              if (c == "\\") {
                i++
                nc = substr(s, i, 1)
                if (nc == "n") out = out "\n"
                else if (nc == "t") out = out "\t"
                else if (nc == "\"") out = out "\""
                else if (nc == "\\") out = out "\\"
                else if (nc == "r") out = out "\r"
                else if (nc == "u") {
                  # \uXXXX: Go encoding/json HTML-safe mode escapes <, >, & and
                  # U+2028/U+2029 this way by default (XSS defense) — that set
                  # is what agy actually emits, verified by reproduction. Any
                  # other \uXXXX is passed through literally (backslash intact)
                  # rather than silently dropped, so an unanticipated escape is
                  # visibly wrong instead of corrupting the tag structure.
                  hex = tolower(substr(s, i + 1, 4))
                  if (hex == "003c") out = out "<"
                  else if (hex == "003e") out = out ">"
                  else if (hex == "0026") out = out "&"
                  else if (hex == "2028" || hex == "2029") out = out "\n"
                  else out = out "\\u" substr(s, i + 1, 4)
                  i += 4
                }
                else out = out nc
                i++
              } else if (c == "\"") {
                break
              } else {
                out = out c
                i++
              }
            }
            printf "%s", out
          }
        ' "$ENGINE_OUT" 2>/dev/null || true)

        # Fallback: never hand the shell-wrapped JSON to the downstream verdict
        # extractor — the raw envelope can contain echoed-back <verdict> tags
        # from the prompt and cause a false match. Extraction failure = empty
        # REVIEW, which the existing empty-response retry/REST path handles.
        #
        # CONV_FILE persist policy (only when we got a usable review): persisting
        # a conversation_id from a call whose response we COULDN'T parse would
        # make the next round resume a session we can't actually consume — so
        # persist only on non-empty REVIEW, and drop any stale CONV_FILE on
        # extract failure (the session may be shaped wrong / unusable this cycle).
        if [ -n "$REVIEW" ]; then
          if [[ "$NEW_CONV" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
            printf '%s' "$NEW_CONV" > "${CONV_FILE}.tmp.$$" 2>/dev/null && mv -f "${CONV_FILE}.tmp.$$" "$CONV_FILE" 2>/dev/null || true
            log_decision "agy-conversation id=$NEW_CONV reuse=$([ -n "$CONV_ID" ] && echo yes || echo no)"
          fi
          log_decision "agy-success"
        else
          rm -f "${CONV_FILE:-}"
          log_decision "agy-response-extract-failed conv-cleared"
        fi

        # Usage observation (best-effort, never fatal if absent/unparseable).
        # `q` after first match — consistent with the conversation_id sed, no
        # pipe, no SIGPIPE.
        AGY_IN=$(sed -n 's/.*"input_tokens"[[:space:]]*:[[:space:]]*\([0-9]\{1,\}\).*/\1/p;/"input_tokens"/q' "$ENGINE_OUT" 2>/dev/null || true)
        AGY_TOTAL=$(sed -n 's/.*"total_tokens"[[:space:]]*:[[:space:]]*\([0-9]\{1,\}\).*/\1/p;/"total_tokens"/q' "$ENGINE_OUT" 2>/dev/null || true)
        [ -z "$AGY_IN" ] && [ -z "$AGY_TOTAL" ] || log_decision "agy-usage in=${AGY_IN:-?} total=${AGY_TOTAL:-?}"
      fi
    fi
    : > "$ENGINE_OUT"
    if [ "$engine_exit" != "0" ]; then
      REVIEW=""
      _fail_reason="${REVIEW_ENGINE}: exit ${engine_exit}"
      # Any non-zero CLI exit (timeout 124, resume-rejected, network, plain 1)
      # invalidates the resume handle — drop it so the next round starts a fresh
      # full first round instead of re-sending a --conversation onto a session
      # that just failed. The capacity branch below also rm's it (harmless dup).
      rm -f "${CONV_FILE:-}"
      if [ "$engine_attempt" -lt 2 ]; then
        # Detect capacity-exhausted 429 (MODEL_CAPACITY_EXHAUSTED via cloudcode-pa.googleapis.com).
        # These outages last minutes — the default 2s retry delay is useless;
        # a longer wait gives the server time to recover.
        # Check only log bytes written during this attempt to avoid matching old entries.
        if tail -c "+$((log_pos_before + 1))" "$LOG_FILE" 2>/dev/null \
             | grep -qE "RESOURCE_EXHAUSTED|MODEL_CAPACITY" 2>/dev/null; then
          _fail_reason="${REVIEW_ENGINE}: capacity exhausted (MODEL_CAPACITY_EXHAUSTED)"
          # Drop any cached conversation_id: the session on agy's side may be
          # invalid/unrecoverable after a capacity outage — don't resume onto it.
          rm -f "${CONV_FILE:-}"
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
      # SIGPIPE-safe first-char probe: `tr <big-file | head -c 1` lets head close
      # the pipe after 1 byte while tr is still streaming the whole body, so tr
      # dies with SIGPIPE (141). Under `set -o pipefail` the pipeline inherits 141
      # and `set -e` then kills the hook mid-REST-fallback — before any decision
      # JSON is emitted — on any sizable body (a normal long review response is
      # enough). Bounding the read with a leading `head -c 100` means no stage
      # faces an unbounded producer, so nothing gets SIGPIPE; 100 bytes is ample
      # to find the first non-space char (leading whitespace before '{'/'data:').
      first_char=$(head -c 100 "$ENGINE_OUT" 2>/dev/null | tr -d '[:space:]' | head -c 1)
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

# --- 6. Extract structured verdict (delegated to lib/verdict.sh) ---
VERDICT=$(extract_verdict "$REVIEW")

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

  # Emit deny so Claude presents the approval to the user (allow reasons are invisible)
  render_approve_feedback "$TOTAL_ROUNDS" "$REVIEW_ENGINE" "$REVIEW"
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

# --- 8. Compose deny feedback (delegated to lib/verdict.sh, severity-differentiated) ---
render_concerns_or_reject_feedback "$VERDICT" "$ATTEMPT" "$TOTAL_ROUNDS" "$REVIEW_ENGINE" \
  "$REVIEW_MAX_ROUNDS" "$REVIEW_MAX_TOTAL_ROUNDS" "$REVIEW"
