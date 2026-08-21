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
LIB_CONSULT="$SCRIPT_DIR/lib/consult.sh"
PROMPT_ASSET_PLAN="$SCRIPT_DIR/assets/review-plan.md"
PROMPT_ASSET_COMMON="$SCRIPT_DIR/assets/review-common.md"

for _lib in "$LIB_COMMON" "$LIB_PLAN_SOURCE" "$LIB_MANIFEST" "$LIB_VERDICT"; do
  # `-s` (exists AND non-empty) catches both gaps in one test: a missing
  # file fails `-f` already, but an empty file (or one gutted of all its
  # function bodies) passes `-f` clean, then `source` "succeeds" (sourcing
  # zero bytes is valid bash, exit 0) and the very next call to a helper
  # defined in it — e.g. log_entry() a few lines below — dies with
  # "command not found" (exit 127), no allow JSON ever printed. That is a
  # silent fail-closed, the opposite of this script's stated contract.
  if [ ! -s "$_lib" ]; then
    echo "plan-review: lib file missing or empty: $_lib, allowing." >&2
    echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"[WARNING] lib file missing or empty, plan-review skipped"}}'
    exit 0
  fi
done
unset _lib

# --- Bootstrap: source with fail-open on syntax/read errors ---
# `[ -s ]` above only proves the file exists and is non-empty — a file that
# clears both but has a bash syntax error (or lost its read permission) still
# fails here. `source`'s
# own exit status captures that case too: a syntax error inside the sourced
# file does not abort the *parent* script's parsing, it only fails the
# `source` command itself, so wrapping each call in `if ! source ...` is
# sufficient — no per-file `bash -n` pre-check needed (that would fork bash
# 4x on every single hook invocation to guard a vanishingly rare failure
# mode). Same allow + [WARNING] shape as the existence check above, and must
# `exit 0` immediately: none of these libs' helpers (e.g. allow_with_reason,
# itself defined in lib/common.sh) can be assumed to exist once any one of
# them fails to load.
_source_lib() {
  local _lib="$1"
  # shellcheck disable=SC1090
  if ! source "$_lib" 2>>"$LOG_FILE"; then
    echo "plan-review: failed to source $_lib, allowing." >&2
    echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"[WARNING] lib file failed to load, plan-review skipped"}}'
    exit 0
  fi
}
_source_lib "$LIB_COMMON"
_source_lib "$LIB_PLAN_SOURCE"
_source_lib "$LIB_MANIFEST"
_source_lib "$LIB_VERDICT"
# NOTE: `unset -f _source_lib` deliberately deferred until after the engine
# libs (rest.sh + the selected engine) are sourced further down — this
# function is reused there too, see the second bootstrap block below.

# --- Engine temp-resource cleanup registry (MUST be declared before trap
#     registration below): engines (codex's workdir/prompt/err) and the REST
#     fallback (status/req) append their own private temp paths here instead
#     of _cleanup hardcoding their names. Declaring these arrays here, before
#     `trap` is registered, is load-bearing under `set -u` — if the script
#     exits early (e.g. a pre-flight guard below, before any engine is even
#     selected), the trap still fires and evaluates `${#ENGINE_TMP_FILES[@]}`;
#     an array that was NEVER declared throws "unbound variable" there (unlike
#     a scalar, which `${var:-}` protects even when undeclared), which would
#     make the trap itself die and skip the `kill "$ENGINE_PID"` cleanup below
#     it entirely.
ENGINE_TMP_FILES=()
ENGINE_TMP_DIRS=()

# --- Cleanup trap (registered here, right after lib sourcing, so any early
#     exit — including the pre-flight guards below — is covered; previously
#     this trapped only after PROMPT_FILE=$(mktemp) much later in the script,
#     leaving every earlier exit path without cleanup coverage. Every var
#     defaults to empty (":-") since most of them are not assigned until deep
#     inside the engine-invocation section further down; rm -f/rmdir/kill on
#     an empty or already-gone target is a harmless no-op. Called on EXIT
#     (normal), INT (Ctrl-C), TERM (framework hook timeout), and HUP (terminal
#     disconnect). Idempotent — safe to call multiple times.
#     ENGINE_ERR is a contract channel like PROMPT_FILE/ENGINE_OUT — the
#     orchestrator allocates it (ENGINE_ERR="${ENGINE_OUT}.err", set once
#     below) for EVERY engine, unconditionally, so it is hardcoded here
#     rather than routed through the generic ENGINE_TMP_FILES registry (which
#     is for engine-PRIVATE resources only, e.g. codex's sandboxed workdir).
_cleanup() {
  # Defensive stderr backfill BEFORE reaping temp files: if the hook is
  # killed (SIGTERM on hook timeout) mid-invoke, $ENGINE_ERR can hold this
  # round's stderr that never reached the normal in-loop backfill_engine_err
  # call below (see the retry loop) — that content would otherwise be lost
  # forever to the `rm -f` on the next line. 143 (128+SIGTERM) is a fixed
  # literal, not a real exit code: trap context has no way to recover the
  # actual one, and "the hook got killed mid-round" is itself failure enough
  # to justify running codex's engine_err_filter() path. Guarded via
  # `declare -F` because backfill_engine_err may not be defined yet (an
  # earlier guard can exit before lib/common.sh is even sourced) — the whole
  # line must never let this trap itself fail.
  # Reentrancy: TERM/INT/HUP fires _cleanup and then EXIT fires it again, so
  # this runs twice. It stays idempotent because backfill_engine_err truncates
  # $ENGINE_ERR after flushing it — the second pass sees an empty file and its
  # own `[ -s ]` guard returns early. No double-write.
  declare -F backfill_engine_err >/dev/null 2>&1 && backfill_engine_err 143 || true
  rm -f "${PROMPT_FILE:-}" "${ENGINE_OUT:-}" "${ENGINE_ERR:-}"
  [ ${#ENGINE_TMP_FILES[@]} -eq 0 ] || rm -f "${ENGINE_TMP_FILES[@]}"
  [ ${#ENGINE_TMP_DIRS[@]}  -eq 0 ] || rmdir "${ENGINE_TMP_DIRS[@]}" 2>/dev/null || true
  ENGINE_TMP_FILES=()
  ENGINE_TMP_DIRS=()
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

# --- Engine selection: whitelist case, never string-concat into a source
#     path (REVIEW_ENGINE is externally controlled via env var — string
#     concatenation into `source` would be a path-injection surface). This
#     is the ONLY branch on REVIEW_ENGINE's value left in this file; adding a
#     4th engine is "write lib/engines/<name>.sh, add one line here".
#     NOTE: the `*)` fallback to agy.sh is CURRENT BEHAVIOR preserved as-is —
#     an unrecognized REVIEW_ENGINE value (or the default "gemini") has
#     always fallen through to the agy code path in the pre-refactor script,
#     since only "claude" and "codex" were ever special-cased. Whether an
#     unrecognized value should instead fail loudly is a separate, deliberate
#     policy decision left to a follow-up — out of scope for this zero
#     behavior-change refactor.
case "$REVIEW_ENGINE" in
  claude) ENGINE_LIB="claude.sh" ; ENGINE_CMD="claude" ;;
  codex)  ENGINE_LIB="codex.sh"  ; ENGINE_CMD="${CODEX_BIN:-codex}" ;;
  *)      ENGINE_LIB="agy.sh"    ; ENGINE_CMD="agy" ;;
esac
LIB_ENGINES_DIR="$SCRIPT_DIR/lib/engines"
LIB_REST="$LIB_ENGINES_DIR/rest.sh"
LIB_ENGINE_SELECTED="$LIB_ENGINES_DIR/$ENGINE_LIB"

for _lib in "$LIB_REST" "$LIB_ENGINE_SELECTED" "$LIB_CONSULT"; do
  # Same `-s` rationale as the first bootstrap block above: an empty file
  # passes `-f` clean, `source` "succeeds" on zero bytes, and the first call
  # into a helper this lib was supposed to define (e.g. engine_probe) then
  # dies with "command not found" (exit 127) — silent fail-closed, no allow
  # JSON. `-s` catches missing AND empty in one test.
  if [ ! -s "$_lib" ]; then
    echo "plan-review: lib file missing or empty: $_lib, allowing." >&2
    echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"[WARNING] lib file missing or empty, plan-review skipped"}}'
    exit 0
  fi
done
unset _lib

# shellcheck source=lib/engines/rest.sh
_source_lib "$LIB_REST"
# shellcheck disable=SC1090  # dynamic path — engine chosen by the whitelisted case above
_source_lib "$LIB_ENGINE_SELECTED"
# shellcheck source=lib/consult.sh
_source_lib "$LIB_CONSULT"
unset -f _source_lib

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
# Dispatch state shares the review-state directory for its whole lifecycle:
# stale cleanup below and APPROVE serialization must not derive it separately.
DISPATCH_DIR="$COUNTER_DIR"
COUNTER_FILE="$COUNTER_DIR/.review-count-${SESSION_ID}"
APPROVE_MARKER="$COUNTER_DIR/.review-approved-${SESSION_ID}"
# Gemini degraded state file (global, no session suffix — persists across hooks)
DEGRADE_FILE="$COUNTER_DIR/.gemini-degraded"
# agy conversation_id cache (session-scoped) — lets multi-round review reuse
# agy's own server-side session so the static prompt prefix hits prompt cache
# instead of being resent every round. Lifetime = one review cycle (see cleanup
# points at the no-plan fail-closed / ack-round-approved / non-critical-valve exits).
CONV_FILE="$COUNTER_DIR/.conversation-${SESSION_ID}"
# Round-memory thread (all engines, orchestrator-owned — see
# inject_review_thread() below). Accumulates each round's CONCERNS/REJECT
# verdict so an engine with no cross-round memory of its own (claude
# --no-session-persistence, codex --ephemeral, REST) — and agy itself, once
# its CONV_FILE handle is lost — can still see prior findings next round.
# Lifetime mirrors CONV_FILE at every cycle-ending cleanup point EXCEPT
# plan-changed-after-approve, which appends a revision marker instead of
# clearing it (see that branch below) — that is the highest-value moment for
# cross-round memory, not a cycle end.
HISTORY_FILE="$COUNTER_DIR/.review-history-${SESSION_ID}"
# Dispatch state is session-scoped, but stale files are global debris. Clean
# them for every valid plan-review invocation, including Tier0 plans that have
# no Manifest and therefore never enter the approval serializer branch.
find "$DISPATCH_DIR" -maxdepth 1 -name '.dispatch-*.json*' -mmin +30 -delete 2>/dev/null || true

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
  rm -f "$APPROVE_MARKER" "$COUNTER_FILE" "${CONV_FILE:-}" "${HISTORY_FILE:-}"
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
    rm -f "$APPROVE_MARKER" "$COUNTER_FILE" "${CONV_FILE:-}" "${HISTORY_FILE:-}"
    allow_with_reason "Red Team 审阅已通过，plan 放行。"
  else
    # Plan was modified after approve: marker invalid, delete and fall through to re-review.
    # Also drop the conversation handle — the session history is about the OLD
    # plan; reusing it to review a DIFFERENT plan would resume stale context.
    # The re-review must start a fresh first round for the new plan.
    #
    # HISTORY_FILE is DELIBERATELY NOT cleared here — this is not a cycle
    # end (COUNTER_FILE survives, TOTAL_ROUNDS keeps counting), and prior
    # review findings on this plan are exactly the highest-value context to
    # carry into the re-review. CONV_FILE must still be dropped because it
    # embeds the FULL OLD plan text server-side; HISTORY_FILE only holds past
    # verdicts/findings, which age far better — append a marker instead so
    # the engine knows a revision happened at this point in the thread.
    log_decision "decision=review-again reason=plan-changed-after-approve conv-cleared"
    rm -f "$APPROVE_MARKER" "${CONV_FILE:-}"
    printf '\n### [plan revised after approve — re-verify prior findings against the new revision]\n\n' \
      >> "$HISTORY_FILE" 2>>"$LOG_FILE" || log_decision "history-write-failed" || true
    # Fall through to full review pipeline
  fi
fi

# --- Global safety valve: total rounds exhausted → hard deny (tombstone counter) ---
# Never delete counter — tombstone blocks subsequent calls until human intervenes
if [ "$TOTAL_ROUNDS" -ge "$REVIEW_MAX_TOTAL_ROUNDS" ]; then
  log_decision "decision=deny reason=global-safety-valve total=$TOTAL_ROUNDS"
  # Keep the COUNTER_FILE tombstone, but the review cycle is over — no further
  # engine call will happen, so drop the session ref to avoid an orphan CONV_FILE.
  rm -f "${CONV_FILE:-}" "${HISTORY_FILE:-}"
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
  rm -f "$COUNTER_FILE" "${CONV_FILE:-}" "${HISTORY_FILE:-}"
  VALVE_MSG="## Red Team Review — ${REVIEW_ENGINE} — ESCALATED

非 Critical 磋商已达上限（${ATTEMPT}/${REVIEW_MAX_ROUNDS}），未能达成一致。Plan 直接呈现给用户做最终裁决。"
  VALVE_JSON=$(printf '%s' "$VALVE_MSG" | jq -Rs .)
  cat << EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":${VALVE_JSON}}}
EOF
  exit 0
fi

# --- Pre-flight manifest checks (AFTER non-critical valve, not before) ---
# Format correction, NOT negotiation round: increments TOTAL_ROUNDS only.
# ATTEMPT stays frozen — pre-flight denies do not count toward MAX_ROUNDS.
# Global safety valve (TOTAL_ROUNDS >= 20) still protects against infinite loops.
if has_manifest "$PLAN" && ! validate_manifest_v2 "$PLAN"; then
  TOTAL_ROUNDS=$((TOTAL_ROUNDS + 1))
  echo "${ATTEMPT:-0}:${TOTAL_ROUNDS}" > "$COUNTER_FILE"
  log_decision "decision=deny reason=invalid-manifest detail=${MANIFEST_ERROR:-unknown}"
  INVALID_MANIFEST_MSG="## Red Team Pre-flight — INVALID DISPATCH MANIFEST

Manifest v2 结构错误：${MANIFEST_ERROR:-unknown}。
请按以下固定列顺序和行规则修正后重新调用 ExitPlanMode。

${MANIFEST_EXAMPLE}"
  INVALID_MANIFEST_JSON=$(printf '%s' "$INVALID_MANIFEST_MSG" | jq -Rs .)
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":${INVALID_MANIFEST_JSON}}}
EOF
  exit 0
fi

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

if needs_manifest "$PLAN" && ! manifest_has_agent_signature "$PLAN"; then
  TOTAL_ROUNDS=$((TOTAL_ROUNDS + 1))
  echo "${ATTEMPT:-0}:${TOTAL_ROUNDS}" > "$COUNTER_FILE"
  log_decision "decision=deny reason=dispatch-hoarding"
  HOARDING_MSG="## Red Team Pre-flight — DISPATCH HOARDING

Plan 声明了 Agent/Task 调度意图，但 Manifest v2 没有任何 \`agent\` 行。不得把全部工作囤积在 Main。
Tier0 工作若保留在 Main，必须同时移除 Manifest 与全部调度关键词；否则显式声明至少一个 Agent step 后重新调用 ExitPlanMode。

${MANIFEST_EXAMPLE}"
  HOARDING_JSON=$(printf '%s' "$HOARDING_MSG" | jq -Rs .)
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":${HOARDING_JSON}}}
EOF
  exit 0
fi

# --- 2. Collect project context ---
CWD=$(echo "$INPUT" | jq -r '.cwd // "."')

# clamp_head_bytes (lib/common.sh) replaces a naive `head -c N`: modern review
# engines have 200K+ token context, so the limits below are raised well past
# the old 3000/8000 defaults (a real project CLAUDE.md once got silently cut
# mid-way through a load-bearing environment-constraint section at byte 8473,
# making the engine structurally blind to a genuine defect) — and the clamp
# is UTF-8-safe where a bare `head -c` is not (see lib/common.sh for why).
GLOBAL_MD=""
[ ! -f "$HOME/.claude/CLAUDE.md" ] || GLOBAL_MD=$(clamp_head_bytes "$GLOBAL_MD_BYTES" < "$HOME/.claude/CLAUDE.md")

PROJECT_MD=""
[ ! -f "$CWD/CLAUDE.md" ] || PROJECT_MD=$(clamp_head_bytes "$PROJECT_MD_BYTES" < "$CWD/CLAUDE.md")

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
# SYSTEM_INSTRUCTIONS content lives in two assets under scripts/assets/ —
# review-plan.md (plan-specific framing/criteria) and review-common.md
# (engine-agnostic rubric, also consumable by an out-of-plugin caller via
# --system-prompt-file) — concatenated in that order (review-plan.md's
# framing language must come first; review-common.md was originally the
# TAIL of the single asset), not inline, so the review rubric stays editable
# without touching bash. Missing/empty asset fails open (same allow +
# [WARNING] shape as the jq-missing guard above). A plain $(...) would
# silently strip the file's trailing newline; the original `read -r -d ''`
# heredoc preserved it (bash always terminates a heredoc's last content line
# with \n, and `read -d ''` never finds its NUL delimiter so nothing gets
# stripped), so we append a sentinel byte before capture and strip only the
# sentinel back off — this reproduces the exact prior byte sequence.
for PROMPT_ASSET in "$PROMPT_ASSET_PLAN" "$PROMPT_ASSET_COMMON"; do
  if [ ! -f "$PROMPT_ASSET" ] || [ ! -s "$PROMPT_ASSET" ]; then
    echo "plan-review: missing/empty prompt asset $PROMPT_ASSET, allowing." >&2
    echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"[WARNING] prompt asset missing/empty, plan-review skipped"}}'
    exit 0
  fi
done
unset PROMPT_ASSET
# The `printf '\n'` between the two tr streams is load-bearing, not
# decorative: review-plan.md ends mid-paragraph (criterion 8's prose) and
# review-common.md opens with a `## ` heading (Version Identifiers Are Ground
# Truth) — markdown requires a blank line before a heading or it gets glued
# to the preceding paragraph on render. Before the split, this exact boundary
# sat inside one file with a blank line separating the sections; splitting
# into two files and concatenating them back-to-back silently dropped that
# blank line, so it has to be reinserted here to reproduce the original byte
# layout at the seam.
SYSTEM_INSTRUCTIONS=$( { tr -d '\r' < "$PROMPT_ASSET_PLAN"; printf '\n'; tr -d '\r' < "$PROMPT_ASSET_COMMON"; }; printf 'x')
SYSTEM_INSTRUCTIONS="${SYSTEM_INSTRUCTIONS%x}"
# Anchor check: `-s` only proves each file has SOME bytes — a truncated asset
# (e.g. left as a single space or a lone newline by a bad edit) still passes
# `-s` but carries no real reviewing instructions. `<verdict>` is the one
# string the CONCATENATED result MUST contain: it is the literal tag
# extract_verdict() (lib/verdict.sh) greps the engine's response for — if the
# assembled prompt doesn't instruct the engine to emit that tag, no review
# response will ever parse, silently degrading every verdict to the CONCERNS
# fallback instead of failing open visibly. The tag lives in review-common.md
# post-split, but the check validates the assembled SYSTEM_INSTRUCTIONS
# (rather than either single file) because that is what the engine actually
# receives — the one thing the rest of the pipeline depends on.
if ! grep -qF '<verdict>' <<< "$SYSTEM_INSTRUCTIONS"; then
  echo "plan-review: prompt assets ($PROMPT_ASSET_PLAN + $PROMPT_ASSET_COMMON) missing <verdict> anchor (truncated?), allowing." >&2
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"[WARNING] prompt asset truncated, plan-review skipped"}}'
  exit 0
fi

ENGINE_OUT=""
ENGINE_STATUS=""
ENGINE_PID=""
REQ_FILE=""
PROMPT_FILE=$(mktemp)

# Engine-specific system injection: PROMPT_FILE holds dynamic content only,
# regardless of engine. Each channel injects SYSTEM_INSTRUCTIONS on its own
# rail: claude → --system-prompt (set in claude.sh's engine_probe); agy →
# inline concat (agy.sh's engine_invoke); REST → messages[0] (rest.sh's
# rest_invoke).
: > "$PROMPT_FILE"

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

# --- Round memory injection (A4) ---
# Responsibility for cross-round memory lives in the ORCHESTRATOR (this
# script), not in any one engine's own session mechanism — `--conversation`
# (agy) is a token-cost optimization on top of this, never the sole source of
# truth. Appends HISTORY_FILE's accumulated prior-round verdicts as a
# "## Prior Review Thread" section onto PROMPT_FILE, but only when no engine
# already has its own live cross-round memory for THIS round (see condition
# below) — otherwise the same findings would be sent twice (once via the
# engine's native session, once via this thread).
#
# inject_review_thread [force] — three call sites, each covering a distinct
# moment where the "does the engine already have native memory?" answer can
# change:
#   1. Composition time (before the retry loop): the common case — first
#      round, or an engine with no native memory concept at all (claude,
#      codex; REST is covered separately, see site 3).
#   2. Immediately after engine_extract() returns, inside the retry loop,
#      before ANY branch on this round's outcome (empty / non-zero exit /
#      capacity / success). By the time engine_extract() returns, this
#      round's native-handle state is FINAL, however it got there — this
#      single point subsumes every way agy's CONV_FILE can end up invalid
#      this round: an orchestrator-level `rm` on non-zero CLI exit (folded
#      in right above this call, see the retry loop), agy's OWN internal rm
#      inside engine_extract() on a 0-exit-but-unparseable envelope (a path
#      the orchestrator cannot otherwise see), or simply never having been
#      live to begin with. One check here replaces what used to be two
#      separate patches pinned next to each `rm -f CONV_FILE` call site —
#      those were symptom-chasing (they only covered the two rm's the
#      orchestrator itself performs, and READ THE SAME race the malformed-
#      envelope case exploits: rm and inject must be adjacent in the SAME
#      control-flow step, not independently duplicated at each call site).
#   3. Right before the REST fallback (`force=force`, see below). REST is
#      not "agy with a possibly-cleared CONV_FILE" — it is a DIFFERENT
#      engine that never has session memory of any kind, agy's or anyone
#      else's. Gating REST's injection on agy's CONV_FILE state is a
#      category error: it produced a real gap when a round aborted BEFORE
#      ever reaching engine_extract() (e.g. agy's own ARG_MAX guard,
#      _ENGINE_ABORT_RETRY=1) — CONV_FILE was never touched that round, so
#      it can still look "live" even though REST, about to receive this
#      exact prompt, has no way to consume that liveness. `force` skips the
#      native-memory CONDITION only; the HISTORY_INJECTED guard below still
#      applies, so a round that already injected via site 1 or 2 does not
#      inject a second time via REST.
HISTORY_INJECTED=0
inject_review_thread() {
  [ "$HISTORY_INJECTED" != "1" ] || return 0
  local force="${1:-}"
  # No usable native cross-round memory right now (engine never had one, OR
  # it has one but the handle is empty/missing — first round, or lost after
  # an extract failure / CLI error) AND there is prior thread content to
  # offer. `${ENGINE_HAS_NATIVE_MEMORY:-0}` is unset (0) for every engine
  # except agy (see lib/engines/agy.sh) — claude/codex/REST always qualify.
  # `force=force` (REST call site only) short-circuits straight past the
  # native-memory condition — see call site 3's rationale above.
  if { [ "$force" = "force" ] || [ "${ENGINE_HAS_NATIVE_MEMORY:-0}" != "1" ] || [ ! -s "${CONV_FILE:-}" ]; } \
     && [ -s "$HISTORY_FILE" ]; then
    # `if { block; } >> file; then` (not a bare block) is load-bearing: `-s`
    # is true for a directory too (not just a regular file), so a HISTORY_FILE
    # that is somehow unreadable (directory collision, permission error) must
    # degrade this round to "no thread" rather than let `cat` inside
    # clamp_tail_bytes crash under `set -e` with NO decision JSON ever
    # emitted — the one failure mode this whole script exists to avoid (see
    # the file header). Commands inside an `if` condition are exempt from
    # `set -e`, same exemption A3's write-side `||` chain relies on.
    if {
      printf '\n## Prior Review Thread\n\n'
      clamp_tail_bytes "$HISTORY_INJECT_BYTES" < "$HISTORY_FILE"
    } >> "$PROMPT_FILE" 2>>"$LOG_FILE"; then
      HISTORY_INJECTED=1
    else
      log_decision "history-inject-failed" || true
    fi
  fi
}

# Call site 1 (composition time): evaluated BEFORE the volatile round-context
# tail below, so an injected thread reads as prior context to that framing,
# not the other way around.
inject_review_thread

# Volatile tail: round context (always last, changes every round). The delta
# review rules below apply regardless of engine or whether a "## Prior Review
# Thread" section was injected above (an engine with its own live native
# session, e.g. agy mid-conversation, still needs these rules — its memory of
# prior findings comes from its own session history instead of the injected
# thread, but the re-verification discipline is identical either way).
if [ "$TOTAL_ROUNDS" -gt 0 ]; then
  cat >> "$PROMPT_FILE" << RNDEOF

## Consultation Context
This is round $((TOTAL_ROUNDS + 1)) of adversarial review.
The plan author may have revised or added rebuttals since the previous round.
Evaluate the CURRENT plan on its merits — if prior concerns have been addressed, APPROVE.

Delta review rules (this round builds on prior rounds — see any
"## Prior Review Thread" section above, or your own session memory):
${DELTA_REVIEW_RULES}
RNDEOF
fi

# --- 5. Call review engine ---
if [ "$REVIEW_DRY_RUN" = "1" ]; then
  REVIEW="<verdict>APPROVE</verdict>
[DRY-RUN] 审阅调用已跳过。"
else
  # consult.sh's run_consultation() is engine-neutral, so it reads ARTIFACT/
  # ROUND_INDEX instead of this hook's own PLAN/TOTAL_ROUNDS — see agy.sh's
  # resume branch (Section B rename) for why: a future out-of-plugin driver
  # (second-opinion.sh) has no "plan" concept, only "an artifact under review".
  ARTIFACT="$PLAN"
  ROUND_INDEX="$TOTAL_ROUNDS"

  # Weak hooks consumed by run_consultation() (see lib/consult.sh's own
  # header comment) — this hook is the "plan-review" caller, so all three
  # simply forward to inject_review_thread(), exactly as the pre-extraction
  # inline call sites did.
  consult_on_round_end() { inject_review_thread; }
  consult_on_rest_prepare() { inject_review_thread force; }
  consult_on_rest_success() { rm -f "${CONV_FILE:-}"; }

  if ! run_consultation; then
    log_decision "decision=allow reason=engine-not-found engine=$REVIEW_ENGINE"
    # Orphan-out cleanup: no engine call will ever happen this cycle, but the
    # cycle itself is NOT over (COUNTER_FILE/CONV_FILE deliberately survive —
    # same contract as before this change). Only HISTORY_FILE is dropped:
    # leaving it would let plan A's findings leak into plan B's review if a
    # later, unrelated ExitPlanMode reuses this SESSION_ID — a new
    # contamination surface this thread mechanism itself introduces, unlike
    # COUNTER_FILE (a stale count is merely inaccurate, not cross-plan noise).
    rm -f "${HISTORY_FILE:-}"
    allow_with_reason "[WARNING] REVIEW_ENGINE=$REVIEW_ENGINE but '$ENGINE_PROBE_REASON' not found"
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
      # Same orphan-out rationale as the engine-not-found branch above: only
      # HISTORY_FILE is dropped (not COUNTER_FILE/CONV_FILE) to block
      # cross-plan thread contamination without changing the existing
      # counter-survival contract for this exit.
      rm -f "${HISTORY_FILE:-}"
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
    mkdir -p "$DISPATCH_DIR" 2>/dev/null || true
    DISPATCH_FILE="$DISPATCH_DIR/.dispatch-${SESSION_ID}.json"
    DISPATCH_TEMP=$(mktemp "$DISPATCH_DIR/.dispatch-${SESSION_ID}.json.XXXXXX" 2>/dev/null || true)
    if [ -n "$DISPATCH_TEMP" ] \
       && parse_manifest_to_json "$PLAN" "$(plan_hash "$PLAN")" > "$DISPATCH_TEMP" 2>/dev/null \
       && dispatch_state_is_valid_v2 "$DISPATCH_TEMP"; then
      mv -f "$DISPATCH_TEMP" "$DISPATCH_FILE"
      dispatch_bytes=$(wc -c < "$DISPATCH_FILE" | tr -d ' ')
      log_decision "manifest-written file=$DISPATCH_FILE bytes=$dispatch_bytes"
    else
      rm -f "${DISPATCH_TEMP:-}" "$DISPATCH_FILE"
      log_decision "manifest-write-skipped reason=invalid-json"
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

# --- Round memory: record this round (A3) ---
# Only CONCERNS/REJECT ever reach this line — APPROVE exits earlier via
# render_approve_feedback(), and REVIEW_DRY_RUN's synthetic verdict is always
# APPROVE (see the dry-run branch above), so no dry-run/APPROVE special-case
# is needed here: both are structurally excluded already. Recorded for EVERY
# engine, including agy — agy's own `--conversation` memory is a token-cost
# optimization, not the source of truth; this file is what backs any round
# where a live native session is unavailable (see inject_review_thread()).
# Write failure must not kill the hook under `set -e` (a full /tmp is not
# this mechanism's problem to solve), but must not fail silently either:
# `|| log_decision ... || true` — the first `||` only fires on a write
# error, and itself falls back to `|| true` in case even that log write fails.
{
  printf '### Round %s — %s\n\n' "$TOTAL_ROUNDS" "$VERDICT"
  printf '%s' "$REVIEW" | clamp_head_bytes "$HISTORY_ROUND_BYTES"
  printf '\n\n'
} >> "$HISTORY_FILE" 2>>"$LOG_FILE" || log_decision "history-write-failed" || true

# --- 8. Compose deny feedback (delegated to lib/verdict.sh, severity-differentiated) ---
render_concerns_or_reject_feedback "$VERDICT" "$ATTEMPT" "$TOTAL_ROUNDS" "$REVIEW_ENGINE" \
  "$REVIEW_MAX_ROUNDS" "$REVIEW_MAX_TOTAL_ROUNDS" "$REVIEW"
