#!/bin/bash
# PreCompact hook: Injects plan review state into compaction context.
#
# When conversation compaction occurs during an active plan review session,
# Claude Code exits plan mode without calling ExitPlanMode, causing the
# PreToolUse:ExitPlanMode hook to be bypassed entirely.
#
# This hook fires BEFORE compaction and outputs a systemMessage that gets
# preserved in the compacted context, instructing Claude to call ExitPlanMode
# after compaction to resume the review process.
#
# If no active review session exists, the hook exits silently (exit 0).
set -euo pipefail

INPUT=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
[ -n "$SESSION_ID" ] || exit 0

COUNTER_DIR="${REVIEW_COUNTER_DIR:-/tmp/claude-reviews}"
COUNTER_FILE="$COUNTER_DIR/.review-count-${SESSION_ID}"
APPROVE_MARKER="$COUNTER_DIR/.review-approved-${SESSION_ID}"

# No active review state → no context injection needed
[ -f "$COUNTER_FILE" ] || [ -f "$APPROVE_MARKER" ] || exit 0

# --- Determine review status ---
IFS=: read -r ATTEMPT TOTAL_ROUNDS <<< "$(cat "$COUNTER_FILE" 2>/dev/null || echo "0:0")"
ATTEMPT=${ATTEMPT:-0}
TOTAL_ROUNDS=${TOTAL_ROUNDS:-$ATTEMPT}
[[ "$ATTEMPT" =~ ^[0-9]+$ ]] || ATTEMPT=0
[[ "$TOTAL_ROUNDS" =~ ^[0-9]+$ ]] || TOTAL_ROUNDS=0

REVIEW_MAX_ROUNDS="${REVIEW_MAX_ROUNDS:-${GEMINI_MAX_REVIEWS:-3}}"
REVIEW_MAX_TOTAL_ROUNDS="${REVIEW_MAX_TOTAL_ROUNDS:-20}"

if [ -f "$APPROVE_MARKER" ]; then
  STATUS="APPROVED by review engine — ack-round pending (call ExitPlanMode once more to finalize)"
elif [ "$ATTEMPT" -eq 0 ] && [ "$TOTAL_ROUNDS" -gt 0 ]; then
  STATUS="REJECTED ${TOTAL_ROUNDS} time(s) — Critical issues must be resolved before approval"
else
  STATUS="IN REVIEW — CONCERNS round ${ATTEMPT}/${REVIEW_MAX_ROUNDS}, total ${TOTAL_ROUNDS}/${REVIEW_MAX_TOTAL_ROUNDS}"
fi

# --- Compose systemMessage ---
MSG=$(printf \
'⚠️ PLAN REVIEW IN PROGRESS — DO NOT BYPASS

An adversarial plan review session is active for this conversation.
Review status: %s

After this compaction completes, you MUST:
1. Call ExitPlanMode with the complete plan content (verbatim, not summarized)
2. Do NOT present the plan as a regular assistant message
3. Do NOT treat the plan as approved — the review hook will intercept ExitPlanMode

The plan-review hook will continue the review process when you call ExitPlanMode.' \
  "$STATUS")

MSG_JSON=$(printf '%s' "$MSG" | jq -Rs .)

printf '{"continue":true,"systemMessage":%s}\n' "$MSG_JSON"
