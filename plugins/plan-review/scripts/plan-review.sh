#!/bin/bash
# PreToolUse hook: Adversarial plan review via cross-model consultation.
#
# Triggered when Plan agent calls ExitPlanMode (via PreToolUse matcher).
# Flow (adversarial consultation model):
#   ExitPlanMode called → hook intercepts → review engine (Gemini/Claude) reviews:
#     APPROVE  → allow through immediately
#     CONCERNS/REJECT → deny with feedback, Claude revises or rebuts
#     → re-calls ExitPlanMode → engine reviews again → repeat
#   After REVIEW_MAX_ROUNDS without consensus → allow through (user decides)
#
# Environment variables:
#   REVIEW_DISABLED=1        — bypass entirely (fallback: GEMINI_REVIEW_OFF)
#   REVIEW_DRY_RUN=1         — skip engine call, synthetic APPROVE (fallback: GEMINI_DRY_RUN)
#   REVIEW_MAX_ROUNDS=N      — max consultation rounds, default 3 (fallback: GEMINI_MAX_REVIEWS)
#   REVIEW_ENGINE=gemini     — review engine: "gemini" (default) or "claude"
#   CLAUDE_MODEL=opus        — Claude engine model (default: opus)
#   GEMINI_MODEL=<id>        — Gemini engine model (default: gemini-3-pro-preview)
set -euo pipefail

INPUT=$(cat)

# --- Pre-requisites ---
command -v jq >/dev/null 2>&1 || { echo "plan-review: missing jq, allowing." >&2; exit 0; }

# --- Logging (write failure → discard, never let side-channel kill core logic) ---
LOG_DIR="${REVIEW_LOG_DIR:-$HOME/.claude/logs}"
mkdir -p "$LOG_DIR" 2>/dev/null && LOG_FILE="${LOG_DIR}/plan-review.log" || LOG_FILE="/dev/null"

# --- Namespace unification (legacy GEMINI_* fallback — never break userspace) ---
REVIEW_DISABLED="${REVIEW_DISABLED:-${GEMINI_REVIEW_OFF:-0}}"
REVIEW_DRY_RUN="${REVIEW_DRY_RUN:-${GEMINI_DRY_RUN:-0}}"
REVIEW_MAX_ROUNDS="${REVIEW_MAX_ROUNDS:-${GEMINI_MAX_REVIEWS:-3}}"
REVIEW_ENGINE="${REVIEW_ENGINE:-gemini}"

# --- Recursive guard: claude -p subprocess inherits this, bail immediately ---
[ "${PLAN_REVIEW_RUNNING:-}" != "1" ] || exit 0

# --- Kill switch ---
[ "$REVIEW_DISABLED" != "1" ] || exit 0

# --- Guard: only ExitPlanMode (belt-and-suspenders with matcher) ---
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
[ "$TOOL_NAME" = "ExitPlanMode" ] || exit 0

# --- Session ID for counter isolation ---
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
[ -n "$SESSION_ID" ] || exit 0

# --- Attempt counter (tmpfs-backed, system handles cleanup) ---
COUNTER_DIR="${REVIEW_COUNTER_DIR:-/tmp/claude-reviews}"
mkdir -p "$COUNTER_DIR"
COUNTER_FILE="$COUNTER_DIR/.review-count-${SESSION_ID}"

# --- Safety valve: max rounds reached → escalate to user ---
ATTEMPT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
if [ "$ATTEMPT" -ge "$REVIEW_MAX_ROUNDS" ]; then
  rm -f "$COUNTER_FILE"
  echo "Max reviews ($REVIEW_MAX_ROUNDS) reached — escalating to user." >&2
  exit 0
fi

# --- 1. Extract plan content ---
PLAN=$(echo "$INPUT" | jq -r '.tool_input.plan // ""')

if [ -z "$PLAN" ] || [ "$PLAN" = "null" ]; then
  # Fallback: read most recent plan file
  PLAN_DIR="${REVIEW_PLAN_DIR:-$HOME/.claude/plans}"
  if [ -d "$PLAN_DIR" ]; then
    PLAN_FILE=$(find "$PLAN_DIR" -maxdepth 1 -name '*.md' -not -name '.*' \
      -print0 2>>"$LOG_FILE" | xargs -0 ls -t 2>>"$LOG_FILE" | head -1)
    if [ -n "${PLAN_FILE:-}" ]; then
      PLAN=$(cat "$PLAN_FILE")
    fi
  fi
fi

# Nothing to review → allow
if [ -z "$PLAN" ] || [ "$PLAN" = "null" ]; then
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
PROMPT_FILE=$(mktemp)
trap 'rm -f "$PROMPT_FILE"' EXIT

cat > "$PROMPT_FILE" << 'PROMPT_HEADER'
# Red Team Plan Review

You are a senior software architect performing an ADVERSARIAL review of the
following implementation plan. Your job is to find flaws before implementation
begins. Be direct and specific — no generic advice.

Keep your response under 2000 characters.
PROMPT_HEADER

cat >> "$PROMPT_FILE" << PROMPT_CONTEXT

## Coding Standards (Author's Reference)
${GLOBAL_MD:-<not available>}

## Project Architecture
${PROJECT_MD:-<not available>}

## User's Original Request
${USER_REQ:-<not available>}

## Plan to Review
${PLAN}
PROMPT_CONTEXT

# Include round context so reviewer knows this may be a rebuttal round
if [ "$ATTEMPT" -gt 0 ]; then
  cat >> "$PROMPT_FILE" << ROUND_CONTEXT

## Consultation Context
This is round $((ATTEMPT + 1)) of adversarial review. The plan author may have
revised or added rebuttals since the previous round. Evaluate the CURRENT plan
on its merits — if prior concerns have been addressed, APPROVE.
ROUND_CONTEXT
fi

cat >> "$PROMPT_FILE" << 'PROMPT_CRITERIA'

## Review Criteria
1. **Correctness** — Does the plan actually solve the stated problem?
2. **Completeness** — Missing steps, edge cases, error handling?
3. **Simplicity** — Is there a simpler approach? Unnecessary complexity?
4. **Safety** — Security risks, data loss, backwards-compatibility breaks?
5. **Testability** — Can changes be verified? Missing test scenarios?
6. **Architecture fit** — Consistent with project patterns?

## Output Format
- FIRST line must be a verdict tag: <verdict>APPROVE</verdict> or <verdict>CONCERNS</verdict> or <verdict>REJECT</verdict>
- Then list specific issues by severity (Critical / Major / Minor)
- Each issue: description -> impact -> suggested fix
- End with brief strengths of the plan (if any)

IMPORTANT: The verdict MUST be wrapped in <verdict></verdict> XML tags on the
very first line. This is machine-parsed. Do NOT place verdict keywords anywhere
else in your response without the tags.

Use Chinese for the review output.
PROMPT_CRITERIA

# --- 5. Call review engine ---
if [ "$REVIEW_DRY_RUN" = "1" ]; then
  REVIEW="<verdict>APPROVE</verdict>
[DRY-RUN] 审阅调用已跳过。"
else
  # --- Pre-flight: CLI existence check (fail-open) ---
  ENGINE_CMD="gemini"
  [ "$REVIEW_ENGINE" != "claude" ] || ENGINE_CMD="claude"
  if ! command -v "$ENGINE_CMD" >/dev/null 2>&1; then
    echo "plan-review: REVIEW_ENGINE=$REVIEW_ENGINE but '$ENGINE_CMD' not found. Skipping." >&2
    exit 0
  fi

  # --- Engine invocation (failure → allow + warning) ---
  if [ "$REVIEW_ENGINE" = "claude" ]; then
    CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"
    # Strip Claude Code internal env vars to prevent recursive hook/plugin loading.
    # Fragile (depends on internal implementation), but necessary: user authenticates
    # via OAuth (claude login), no ANTHROPIC_API_KEY available, so claude -p is the
    # only viable path. Triple isolation: --setting-sources local + PLAN_REVIEW_RUNNING
    # + --tools "" (no tool calls = no PreToolUse events).
    unset CLAUDECODE
    unset CLAUDE_CODE_ENTRYPOINT
    REVIEW=$(PLAN_REVIEW_RUNNING=1 claude -p \
      --model "$CLAUDE_MODEL" \
      --setting-sources local \
      --no-session-persistence \
      --tools "" \
      --disable-slash-commands \
      --system-prompt "You are a senior software architect performing an adversarial red-team review. Output verdict as <verdict>APPROVE</verdict>, <verdict>CONCERNS</verdict>, or <verdict>REJECT</verdict>. Then list issues by severity. Use Chinese." \
      < "$PROMPT_FILE" 2>>"$LOG_FILE") || {
      echo "plan-review: claude -p failed (exit $?), see $LOG_FILE. Allowing." >&2
      exit 0
    }
  else
    GEMINI_MODEL="${GEMINI_MODEL:-gemini-3-pro-preview}"
    REVIEW=$(gemini -m "$GEMINI_MODEL" < "$PROMPT_FILE" 2>>"$LOG_FILE") || {
      echo "plan-review: gemini failed (exit $?), see $LOG_FILE. Allowing." >&2
      exit 0
    }
  fi
fi

# Empty review → allow
[ -n "$REVIEW" ] || exit 0

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
  rm -f "$COUNTER_FILE"
  exit 0  # Consensus reached — allow through
fi

# CONCERNS or REJECT → increment counter, deny with feedback
ATTEMPT=$((ATTEMPT + 1))
echo "$ATTEMPT" > "$COUNTER_FILE"
REMAINING=$((REVIEW_MAX_ROUNDS - ATTEMPT))

# --- 8. Compose deny feedback (peer consultation framing) ---
FEEDBACK=$(cat << REVIEW_EOF
## Red Team Review — ${REVIEW_ENGINE} (Round ${ATTEMPT}/${REVIEW_MAX_ROUNDS})

审阅引擎对本 plan 提出了以下意见。你有两个选择：
1. 如意见合理，修正 plan 后再次调用 ExitPlanMode
2. 如你认为意见不成立，在 plan 中补充辩护理由后再次调用 ExitPlanMode

磋商剩余轮次：${REMAINING}。若双方无法达成一致，plan 将直接呈现给用户做最终裁决。

---

${REVIEW}
REVIEW_EOF
)

FEEDBACK_JSON=$(echo "$FEEDBACK" | jq -Rs .)

cat << EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":${FEEDBACK_JSON}}}
EOF

exit 0
