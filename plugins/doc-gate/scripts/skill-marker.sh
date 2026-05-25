#!/usr/bin/env bash
# PreToolUse:Skill hook — Records skill invocations for gate enforcement.
#
# When a tracked skill is invoked, writes a session-scoped marker file.
# skill-gate.sh checks this marker to decide whether .md edits are allowed.
#
# NEVER blocks skill invocation — always exits 0.
#
# Environment variables:
#   SKILL_GATE_DISABLED=1  — kill switch
#   SKILL_GATE_DIR         — marker directory (default: /tmp/claude-reviews)
set -euo pipefail

_main() {
  INPUT=$(cat)

  GATE_DIR="${SKILL_GATE_DIR:-/tmp/claude-reviews}"
  TRACKED_SKILLS="doc-maintenance"

  [ "${SKILL_GATE_DISABLED:-0}" != "1" ] || return
  command -v jq >/dev/null 2>&1 || return

  TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || return
  SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || return
  [ "$TOOL_NAME" = "Skill" ] || return
  [ -n "$SESSION_ID" ] || return

  SKILL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_input.skill // ""' 2>/dev/null) || return
  [ -n "$SKILL_NAME" ] || return

  case " $TRACKED_SKILLS " in
    *" $SKILL_NAME "*) ;;
    *) return ;;
  esac

  SESSION_ID="${SESSION_ID//\//_}"
  SKILL_NAME="${SKILL_NAME//\//_}"

  mkdir -p "$GATE_DIR" 2>/dev/null || return
  printf '%s' "$(date +%s)" > "$GATE_DIR/.skill-gate-${SESSION_ID}-${SKILL_NAME}" 2>/dev/null || true

  # Log
  LOG_DIR="${SKILL_GATE_LOG_DIR:-${REVIEW_LOG_DIR:-$HOME/.claude/logs}}"
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '[%s] session=%s tool=Skill skill=%s decision=marker-written\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$SESSION_ID" "$SKILL_NAME" \
    >> "$LOG_DIR/skill-gate.log" 2>/dev/null || true
}

_main 2>/dev/null || true
