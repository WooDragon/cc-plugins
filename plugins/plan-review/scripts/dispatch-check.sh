#!/bin/bash
# PreToolUse:Agent/Task hook — Layer 2 dispatch enforcement.
#
# Reads dispatch JSON written by plan-review.sh APPROVE path; if present,
# requires Agent tool call to provide both subagent_type and model.
# Fail-open on ALL anomalies: jq missing, JSON corrupt, session absent, stale file, etc.
#
# Environment variables:
#   DISPATCH_CHECK_DISABLED=1  — kill switch, bypass entirely
#   REVIEW_COUNTER_DIR         — dispatch file directory (default: /tmp/claude-reviews)
set -euo pipefail

INPUT=$(cat)

# Kill switch (highest priority)
[ "${DISPATCH_CHECK_DISABLED:-0}" != "1" ] || exit 0

# jq required for JSON parsing
command -v jq >/dev/null 2>&1 || exit 0

# Extract tool_name and session_id — fail-open on parse errors
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || true)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)

# Only intercept Agent and Task tool calls (belt-and-suspenders with hook matcher)
[ "$TOOL_NAME" = "Agent" ] || [ "$TOOL_NAME" = "Task" ] || exit 0
[ -n "$SESSION_ID" ] || exit 0

DISPATCH_DIR="${REVIEW_COUNTER_DIR:-/tmp/claude-reviews}"
DISPATCH_FILE="$DISPATCH_DIR/.dispatch-${SESSION_ID}.json"

# Opportunistic global cleanup: remove stale dispatch files from all sessions
find "$DISPATCH_DIR" -maxdepth 1 -name '.dispatch-*.json' -mmin +30 -delete 2>/dev/null || true

# No dispatch file → no active plan constraint → allow
[ -f "$DISPATCH_FILE" ] || exit 0

# Stale check (>30min) — dispatch from a previous session leaked through
file_mtime=$(stat -f %m "$DISPATCH_FILE" 2>/dev/null || stat -c %Y "$DISPATCH_FILE" 2>/dev/null || echo 0)
now=$(date +%s)
if (( now - file_mtime > 1800 )); then
  rm -f "$DISPATCH_FILE" 2>/dev/null || true
  exit 0
fi

# JSON sanity check — corrupt dispatch file → fail-open
jq -e '.requires_dispatch_check == true' "$DISPATCH_FILE" >/dev/null 2>&1 || exit 0

# Check that Agent call has both non-empty model AND subagent_type
has_model="no"
has_type="no"
if printf '%s' "$INPUT" | jq -e \
    '.tool_input.model and (.tool_input.model | type == "string") and (.tool_input.model | length > 0)' \
    >/dev/null 2>&1; then
  has_model="yes"
fi
if printf '%s' "$INPUT" | jq -e \
    '.tool_input.subagent_type and (.tool_input.subagent_type | type == "string") and (.tool_input.subagent_type | length > 0)' \
    >/dev/null 2>&1; then
  has_type="yes"
fi

# Both present → silent allow
if [ "$has_model" = "yes" ] && [ "$has_type" = "yes" ]; then
  exit 0
fi

# Compose deny with manifest preview
MANIFEST_PREVIEW=$(jq -r \
  '.steps | map("  - step " + .id + ": agent_type=" + (.agent_type // "-") + ", model=" + (.model // "-")) | join("\n")' \
  "$DISPATCH_FILE" 2>/dev/null || echo "  (manifest parse failed)")

missing=""
[ "$has_type" = "yes" ] || missing="${missing}subagent_type "
[ "$has_model" = "yes" ] || missing="${missing}model"

MSG="dispatch-check: Agent 调用必须显式传 subagent_type 和 model（plan 已声明 Dispatch Manifest，承诺被强制执行）。

当前调用缺失：${missing}

请查阅 Manifest 取值：
${MANIFEST_PREVIEW}

如需关闭强制检查，设置 DISPATCH_CHECK_DISABLED=1。"

DENY_JSON=$(printf '%s' "$MSG" | jq -Rs .)
cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":${DENY_JSON}}}
EOF
exit 0
