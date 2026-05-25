#!/usr/bin/env bash
# PreToolUse:Edit/Write hook — Skill gate enforcement.
#
# Denies .md documentation file edits unless doc-maintenance skill was
# already invoked in this session. Fail-open on ALL anomalies.
#
# Environment variables:
#   SKILL_GATE_DISABLED=1       — kill switch
#   SKILL_GATE_DIR              — marker directory (default: /tmp/claude-reviews)
#   SKILL_GATE_LOG_DIR          — log directory (default: REVIEW_LOG_DIR or ~/.claude/logs)
#   SKILL_GATE_STALE_MIN        — marker stale threshold minutes (default: 120)
set -euo pipefail

_log() {
  local log_dir="${SKILL_GATE_LOG_DIR:-${REVIEW_LOG_DIR:-$HOME/.claude/logs}}"
  mkdir -p "$log_dir" 2>/dev/null || return
  printf '[%s] session=%s tool=%s path=%s decision=%s reason=%s\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    "${SESSION_ID:-unknown}" "${TOOL_NAME:-unknown}" "${FILE_PATH:-unknown}" \
    "$1" "$2" >> "$log_dir/skill-gate.log" 2>/dev/null || true
}

_main() {
  INPUT=$(cat)

  GATE_DIR="${SKILL_GATE_DIR:-/tmp/claude-reviews}"
  STALE_MIN="${SKILL_GATE_STALE_MIN:-120}"
  REQUIRED_SKILL="doc-maintenance"

  [ "${SKILL_GATE_DISABLED:-0}" != "1" ] || return
  command -v jq >/dev/null 2>&1 || return

  TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || return
  SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || return
  [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ] || return
  [ -n "$SESSION_ID" ] || return

  FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null) || return
  [ -n "$FILE_PATH" ] || return

  # Hard filter: .md extension only (zero subprocess, case pattern)
  BASENAME="${FILE_PATH##*/}"
  case "$BASENAME" in *.[mM][dD]) ;; *) return ;; esac

  # Basename exclusions (meta files, not governed by doc-maintenance)
  # readme.md excluded by basename — docs/README.md also excluded (known trade-off)
  shopt -s nocasematch
  case "$BASENAME" in
    claude.md|memory.md|skill.md|readme.md|changelog.md|contributing.md|license.md)
      shopt -u nocasematch; return ;;
  esac
  shopt -u nocasematch

  # Path exclusions (prepend / to handle relative paths uniformly)
  case "/$FILE_PATH" in
    */.claude/*|*/.claude-plugin/*|*/node_modules/*|*/.git/*) return ;;
  esac

  # Path sanitization (match skill-marker.sh convention)
  SESSION_ID="${SESSION_ID//\//_}"

  # Ensure GATE_DIR exists (cold start: /tmp cleared after OS reboot)
  [ -n "$GATE_DIR" ] && mkdir -p "$GATE_DIR" 2>/dev/null || true

  # Stale cleanup
  find "$GATE_DIR" -maxdepth 1 -name '.skill-gate-*' -mmin +"$STALE_MIN" -delete 2>/dev/null || true

  # Marker check — explicit match, lock and key
  if [ -f "$GATE_DIR/.skill-gate-${SESSION_ID}-${REQUIRED_SKILL}" ]; then
    _log "allow" "marker-found"
    return
  fi

  # GATE_DIR not writable → markers can't be created → dead-lock → fail-open
  [ -w "$GATE_DIR" ] || return

  # Deny
  _log "deny" "skill-not-invoked"

  local msg
  msg="文档编辑门禁：${BASENAME} 是文档文件（.md），编辑前需先调用 doc-maintenance skill 加载文档维护工作流。

请使用 Skill 工具调用 doc-maintenance，然后重试此操作。

如需关闭门禁，设置 SKILL_GATE_DISABLED=1。"

  local deny_json
  deny_json=$(printf '%s' "$msg" | jq -Rs .)
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}' "$deny_json"
}

_main 2>/dev/null || true
