#!/bin/bash
# PreToolUse:Agent/Task hook — Manifest v2 signature-set enforcement.
#
# A valid v2 state written by plan-review.sh declares permitted dispatch
# signatures. Preset signatures require the model field to be omitted; runtime
# signatures require exact type/model values. This hook intentionally tracks no
# step cursor, invocation count, execution order, or global model ownership.
# Fail open on missing, corrupt, stale, or structurally invalid state.
#
# Environment variables:
#   DISPATCH_CHECK_DISABLED=1  — kill switch, bypass entirely
#   REVIEW_COUNTER_DIR         — dispatch file directory (default: /tmp/claude-reviews)
set -euo pipefail

INPUT=$(cat)

[ "${DISPATCH_CHECK_DISABLED:-0}" != "1" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
MANIFEST_LIB="$(dirname "$0")/lib/manifest.sh"
[ -s "$MANIFEST_LIB" ] || exit 0
if ! . "$MANIFEST_LIB"; then
  exit 0
fi

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || true)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)
[ "$TOOL_NAME" = "Agent" ] || [ "$TOOL_NAME" = "Task" ] || exit 0
[ -n "$SESSION_ID" ] || exit 0

DISPATCH_DIR="${REVIEW_COUNTER_DIR:-/tmp/claude-reviews}"
DISPATCH_FILE="$DISPATCH_DIR/.dispatch-${SESSION_ID}.json"
find "$DISPATCH_DIR" -maxdepth 1 -name '.dispatch-*.json' -mmin +30 -delete 2>/dev/null || true
[ -f "$DISPATCH_FILE" ] || exit 0

file_mtime=$(stat -f %m "$DISPATCH_FILE" 2>/dev/null || stat -c %Y "$DISPATCH_FILE" 2>/dev/null || echo 0)
now=$(date +%s)
if (( now - file_mtime > 1800 )); then
  rm -f "$DISPATCH_FILE" 2>/dev/null || true
  exit 0
fi

# A state from pre-v2 plan-review has no schema marker. Preserve compatibility
# for its short TTL but visibly ask the caller to regenerate the approval.
if jq -e '.requires_dispatch_check == true and (has("schema_version") | not)' "$DISPATCH_FILE" >/dev/null 2>&1; then
  migration_message="dispatch-check: Manifest v1 state detected. Matching is skipped for this temporary state; re-run plan review to create schema_version: 2 before relying on dispatch enforcement."
  migration_json=$(printf '%s' "$migration_message" | jq -Rs .)
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":${migration_json}},"systemMessage":${migration_json}}
EOF
  exit 0
fi

# Only a complete, currently supported state can constrain tool calls. The
# shared predicate also proves allowed_signatures are derived from steps; it
# has no catalog scan, frontmatter snapshot, or plugin-list lookup.
dispatch_state_is_valid_v2 "$DISPATCH_FILE" || exit 0

CALL_TYPE=$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || true)
MODEL_PRESENT="no"
if printf '%s' "$INPUT" | jq -e '.tool_input | has("model")' >/dev/null 2>&1; then
  MODEL_PRESENT="yes"
fi
CALL_MODEL=$(printf '%s' "$INPUT" | jq -r '.tool_input.model // ""' 2>/dev/null || true)

# Preset means exact type plus an absent model key, not merely an empty model.
if [ "$MODEL_PRESENT" = "no" ] && jq -e --arg type "$CALL_TYPE" \
    'any(.allowed_signatures[]; .model_source == "preset" and .subagent_type == $type)' \
    "$DISPATCH_FILE" >/dev/null 2>&1; then
  exit 0
fi

# Runtime means exact type and a nonempty exact model string.
if [ "$MODEL_PRESENT" = "yes" ] && [ -n "$CALL_MODEL" ] && jq -e \
    --arg type "$CALL_TYPE" --arg model "$CALL_MODEL" \
    'any(.allowed_signatures[]; .model_source == "runtime" and .subagent_type == $type and .model == $model)' \
    "$DISPATCH_FILE" >/dev/null 2>&1; then
  exit 0
fi

# Explain the common preset error without weakening exact signature matching.
preset_model_hint=""
if [ "$MODEL_PRESENT" = "yes" ] && jq -e --arg type "$CALL_TYPE" \
    'any(.allowed_signatures[]; .model_source == "preset" and .subagent_type == $type)' \
    "$DISPATCH_FILE" >/dev/null 2>&1; then
  preset_model_hint=" The declared preset signature requires you to omit model entirely."
fi

MANIFEST_PREVIEW=$(jq -r '
  .allowed_signatures |
  map(if .model_source == "preset"
      then "  - preset: subagent_type=" + .subagent_type + ", model omitted"
      else "  - runtime: subagent_type=" + .subagent_type + ", model=" + .model
      end) |
  join("\n")
' "$DISPATCH_FILE" 2>/dev/null || echo "  (manifest parse failed)")

MSG="dispatch-check: Agent/Task call does not match an approved Manifest v2 signature.${preset_model_hint}

Declared signatures:
${MANIFEST_PREVIEW}

Preset calls must omit model; runtime calls must provide the exact model. To disable this guard, set DISPATCH_CHECK_DISABLED=1."
DENY_JSON=$(printf '%s' "$MSG" | jq -Rs .)
cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":${DENY_JSON}}}
EOF
exit 0
