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

for _lib in "$LIB_REST" "$LIB_ENGINE_SELECTED"; do
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

# clamp_head_bytes (lib/common.sh) replaces a naive `head -c N`: modern review
# engines have 200K+ token context, so the limits below are raised well past
# the old 3000/8000 defaults (a real project CLAUDE.md once got silently cut
# mid-way through a load-bearing environment-constraint section at byte 8473,
# making the engine structurally blind to a genuine defect) — and the clamp
# is UTF-8-safe where a bare `head -c` is not (see lib/common.sh for why).
GLOBAL_MD=""
[ ! -f "$HOME/.claude/CLAUDE.md" ] || GLOBAL_MD=$(clamp_head_bytes 8000 < "$HOME/.claude/CLAUDE.md")

PROJECT_MD=""
[ ! -f "$CWD/CLAUDE.md" ] || PROJECT_MD=$(clamp_head_bytes 24000 < "$CWD/CLAUDE.md")

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
# Anchor check: `-s` only proves the file has SOME bytes — a truncated asset
# (e.g. left as a single space or a lone newline by a bad edit) still passes
# `-s` but carries no real reviewing instructions. `<verdict>` is the one
# string this file MUST contain: it is the literal tag extract_verdict()
# (lib/verdict.sh) greps the engine's response for — if the prompt asset
# doesn't instruct the engine to emit that tag, no review response will ever
# parse, silently degrading every verdict to the CONCERNS fallback instead of
# failing open visibly. Reusing that same load-bearing string as the anchor
# (rather than an arbitrary section heading that could be renamed with zero
# functional impact) means this check can only pass if the asset still does
# the one thing the rest of the pipeline actually depends on.
if ! grep -qF '<verdict>' "$PROMPT_ASSET"; then
  echo "plan-review: prompt asset $PROMPT_ASSET missing <verdict> anchor (truncated?), allowing." >&2
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"[WARNING] prompt asset truncated, plan-review skipped"}}'
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
# HISTORY_INJECTED guards against double-injection across this function's TWO
# call sites (see below): composition time, and again right before the REST
# fallback. Both sites can legitimately evaluate true in the SAME round (e.g.
# agy's CONV_FILE gets cleared mid-round after a failed CLI attempt) — the
# guard, not the condition, is what prevents that from injecting twice.
HISTORY_INJECTED=0
inject_review_thread() {
  [ "$HISTORY_INJECTED" != "1" ] || return 0
  # No usable native cross-round memory right now (engine never had one, OR
  # it has one but the handle is empty/missing — first round, or lost after
  # an extract failure / CLI error) AND there is prior thread content to
  # offer. `${ENGINE_HAS_NATIVE_MEMORY:-0}` is unset (0) for every engine
  # except agy (see lib/engines/agy.sh) — claude/codex/REST always qualify.
  if { [ "${ENGINE_HAS_NATIVE_MEMORY:-0}" != "1" ] || [ ! -s "${CONV_FILE:-}" ]; } \
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
      clamp_tail_bytes 24000 < "$HISTORY_FILE"
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
  # Orchestrator owns the stderr CHANNEL for every engine (agy/claude/codex
  # alike) — allocated unconditionally here, not codex-private. Each engine
  # redirects its own invocation's stderr into it (2>"$ENGINE_ERR") and
  # declares, via $ENGINE_ERR_POLICY (set in its engine_probe()), what the
  # orchestrator is allowed to do with the CONTENT: "verbatim" (agy/claude)
  # backfills it into LOG_FILE unconditionally; "filtered" (codex) only logs
  # a privacy-filtered excerpt on failure, via the engine's own
  # engine_err_filter() hook — see backfill_engine_err() in lib/common.sh.
  ENGINE_ERR="${ENGINE_OUT}.err"
  REVIEW=""
  HOOK_BUDGET="${REVIEW_HOOK_BUDGET:-595}"

  # --- Pre-flight: CLI existence check (permanent failure, no retry) + one-
  #     time per-engine setup (model resolution, temp resource prep) —
  #     delegated to the sourced engine's engine_probe(), called once outside
  #     the retry loop below. ---
  if ! engine_probe; then
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

    # --- Call the sourced engine's invoke hook. agy's invoke may set
    #     _ENGINE_ABORT_RETRY=1 (oversized prompt, ARG_MAX defense) to signal
    #     an immediate break BEFORE extraction/exit-code handling — mirroring
    #     the pre-refactor inline `break`. A literal `break` inside the
    #     function itself would be bash-version-dependent (verified: bash 3.2
    #     propagates it to this loop, bash 5.x does not), so an explicit flag
    #     is the only portable signal.
    _ENGINE_ABORT_RETRY=0
    engine_invoke
    if [ "$_ENGINE_ABORT_RETRY" = "1" ]; then
      break
    fi

    # Capacity-exhaustion detection (used further below) MUST scan the raw
    # $ENGINE_ERR before backfill_engine_err (next) truncates it (see
    # lib/common.sh) — capture into a flag now, consumed later instead of
    # re-grepping a file that will already be empty by then.
    _capacity_hit=0
    grep -qE "RESOURCE_EXHAUSTED|MODEL_CAPACITY" "$ENGINE_ERR" 2>/dev/null && _capacity_hit=1

    # Backfill this round's $ENGINE_ERR into LOG_FILE per the engine's own
    # $ENGINE_ERR_POLICY (see lib/common.sh) — unconditionally for
    # "verbatim" engines (success and failure alike), failure-only and
    # filtered for codex. Also truncates $ENGINE_ERR once backfilled, so a
    # later defensive re-backfill (_cleanup on hook-kill) is a harmless no-op
    # in the normal exit path.
    backfill_engine_err "$engine_exit"

    engine_extract
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
        # $_capacity_hit was captured above (BEFORE backfill_engine_err ran)
        # from this round's raw, un-truncated $ENGINE_ERR directly — NOT
        # LOG_FILE. This is the fix for the codex fast-break bug: codex's raw
        # stderr never reaches LOG_FILE wholesale (privacy filter, see
        # engine_err_filter in lib/engines/codex.sh), so grepping LOG_FILE
        # only ever caught this pattern for agy/claude by coincidence —
        # codex's fast-break depended on the capacity keyword happening to
        # survive the 500-byte filtered codex-diag excerpt. All three engines
        # are treated identically here because $ENGINE_ERR always held this
        # round's complete, unfiltered stderr regardless of engine (at the
        # time it was captured, before this same round's backfill truncated it).
        if [ "$_capacity_hit" = "1" ]; then
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

    # Call site 2 (A4 Critical fix): CONV_FILE may have been cleared by a
    # failed CLI attempt in the retry loop above, AFTER call site 1 already
    # evaluated the injection condition as false (native memory looked live
    # at composition time). REST reads PROMPT_FILE verbatim (rest_invoke's
    # --rawfile) — without this second call, REST would receive a prompt
    # with NO thread at all, reproducing exactly the failure mode this
    # mechanism exists to fix: default engine succeeds once (native memory
    # looks available), fails on capacity/timeout next round, and the
    # eventual REST fallback silently loses all prior context.
    # HISTORY_INJECTED guards this from double-injecting on top of call site
    # 1 in the (rarer) case where call site 1 already injected this round.
    inject_review_thread
    rest_invoke
    rest_extract

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
  printf '%s' "$REVIEW" | clamp_head_bytes 6000
  printf '\n\n'
} >> "$HISTORY_FILE" 2>>"$LOG_FILE" || log_decision "history-write-failed" || true

# --- 8. Compose deny feedback (delegated to lib/verdict.sh, severity-differentiated) ---
render_concerns_or_reject_feedback "$VERDICT" "$ATTEMPT" "$TOTAL_ROUNDS" "$REVIEW_ENGINE" \
  "$REVIEW_MAX_ROUNDS" "$REVIEW_MAX_TOTAL_ROUNDS" "$REVIEW"
