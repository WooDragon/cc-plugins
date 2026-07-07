#!/usr/bin/env bash
# PreToolUse:Edit/Write hook — Recall gate enforcement.
#
# On first edit of a .md file this session, runs BM25 recall + link graph
# analysis. If related docs, orphan status, or broken outlinks are found,
# denies with a structured Chinese message. Subsequent edits to the same file
# pass through silently. Fail-open on ALL anomalies.
#
# Environment variables:
#   RECALL_GATE_DISABLED=1       — kill switch
#   RECALL_GATE_ROOT             — explicit repo root override (bypasses auto-detection)
#   RECALL_GATE_THRESHOLD        — min BM25 score (default: 0.30)
#   RECALL_GATE_TOP_N            — max recall results (default: 5)
#   RECALL_GATE_STALE_MIN        — marker staleness minutes (default: 120)
#   SKILL_GATE_DIR               — shared marker directory (default: /tmp/claude-reviews)
#   SKILL_GATE_LOG_DIR           — log directory
#   SKILL_GATE_DISABLED          — if "1", recall-gate acts independently (no double-deny guard)
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_doc_gate_exclude.sh"

_log() {
  local log_dir="${SKILL_GATE_LOG_DIR:-${REVIEW_LOG_DIR:-$HOME/.claude/logs}}"
  mkdir -p "$log_dir" 2>/dev/null || return
  printf '[%s] session=%s tool=%s path=%s decision=%s reason=%s\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    "${SESSION_ID:-unknown}" "${TOOL_NAME:-unknown}" "${FILE_PATH:-unknown}" \
    "$1" "$2" >> "$log_dir/recall-gate.log" 2>/dev/null || true
}

_main() {
  INPUT=$(cat)

  # Phase 1: Kill switch
  [ "${RECALL_GATE_DISABLED:-0}" != "1" ] || return

  # Phase 2: Preconditions
  command -v jq >/dev/null 2>&1 || return
  command -v python3 >/dev/null 2>&1 || return

  # Phase 3: Input extract
  TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || return
  SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || return
  [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ] || return
  [ -n "$SESSION_ID" ] || return

  FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null) || return
  [ -n "$FILE_PATH" ] || return

  # Phase 4: .md filter
  BASENAME="${FILE_PATH##*/}"
  case "$BASENAME" in *.[mM][dD]) ;; *) return ;; esac

  # Phase 5: Basename exclusions (tool-maintained or special-format files)
  shopt -s nocasematch
  case "$BASENAME" in
    memory.md|skill.md|changelog.md|license.md) shopt -u nocasematch; return ;;
  esac
  shopt -u nocasematch

  # Phase 6: Path exclusions
  if doc_gate_is_excluded_path "$FILE_PATH"; then return; fi

  GATE_DIR="${SKILL_GATE_DIR:-/tmp/claude-reviews}"
  STALE_MIN="${RECALL_GATE_STALE_MIN:-120}"

  # Path sanitization
  SESSION_ID="${SESSION_ID//\//_}"

  # Phase 7: Per-file marker — allow on subsequent edits
  FILE_HASH=$(printf '%s' "$FILE_PATH" | shasum -a 256 2>/dev/null | cut -c1-16) || return
  RECALL_MARKER=".recall-gate-${SESSION_ID}-${FILE_HASH}"
  [ -n "$GATE_DIR" ] && mkdir -p "$GATE_DIR" 2>/dev/null || true
  if [ -f "$GATE_DIR/$RECALL_MARKER" ]; then
    _log "allow" "recall-marker-found"
    return
  fi

  # Phase 8: Double-deny guard — let skill-gate handle the deny unless it is disabled
  if [ "${SKILL_GATE_DISABLED:-0}" != "1" ]; then
    SKILL_MARKER=".skill-gate-${SESSION_ID}-doc-maintenance"
    if [ ! -f "$GATE_DIR/$SKILL_MARKER" ]; then
      # skill-gate will fire first; don't pile on a second deny
      return
    fi
  fi

  # Phase 9: Stale cleanup
  find "$GATE_DIR" -maxdepth 1 -name '.recall-gate-*' -mmin +"$STALE_MIN" -delete 2>/dev/null || true

  # Phase 10: Content extract (root detection moved to Python — detect_root)
  if [ "$TOOL_NAME" = "Write" ]; then
    CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // ""' 2>/dev/null) || return
  else
    CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // ""' 2>/dev/null) || return
  fi

  # Phase 11: Python invoke — fail-open on any error
  TOOL_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/tools"
  RESULT=$(printf '%s' "$CONTENT" | python3 "$TOOL_DIR/recall-gate.py" \
    --target-file "$FILE_PATH" \
    --threshold "${RECALL_GATE_THRESHOLD:-0.30}" \
    --top-n "${RECALL_GATE_TOP_N:-5}" \
    --json gate 2>/dev/null) || return

  # Phase 12: Parse result
  HAS_FINDINGS=$(printf '%s' "$RESULT" | jq -r '.has_findings // false' 2>/dev/null) || return

  [ "$HAS_FINDINGS" = "true" ] || return

  # Phase 13: Write marker + format deny message + output deny JSON

  # GATE_DIR must be writable to place the marker
  [ -w "$GATE_DIR" ] || return
  touch "$GATE_DIR/$RECALL_MARKER" 2>/dev/null || true

  _log "deny" "recall-findings"

  # Build deny message dynamically
  MSG="文档关联提醒（首次编辑 ${BASENAME}，后续编辑不再提示）："

  RECALL_LEN=$(printf '%s' "$RESULT" | jq '.recall | length' 2>/dev/null) || RECALL_LEN=0
  if [ "${RECALL_LEN:-0}" -gt 0 ] 2>/dev/null; then
    MSG="${MSG}

相关文档（可能存在内容重叠）："
    RECALL_LINES=$(printf '%s' "$RESULT" | jq -r '.recall | to_entries[] | "  \(.key + 1). [\(.value.score)] \(.value.path)"' 2>/dev/null) || RECALL_LINES=""
    [ -n "$RECALL_LINES" ] && MSG="${MSG}
${RECALL_LINES}"
  fi

  ORPHAN=$(printf '%s' "$RESULT" | jq -r '.orphan // false' 2>/dev/null) || ORPHAN=false
  if [ "$ORPHAN" = "true" ]; then
    MSG="${MSG}

结构信号：当前文件无入链（未被索引），建议补充索引链接。"
  fi

  BROKEN_LEN=$(printf '%s' "$RESULT" | jq '.broken_outlinks | length' 2>/dev/null) || BROKEN_LEN=0
  if [ "${BROKEN_LEN:-0}" -gt 0 ] 2>/dev/null; then
    MSG="${MSG}

出链验证：内容引用了不存在的文件："
    BROKEN_LINES=$(printf '%s' "$RESULT" | jq -r '.broken_outlinks[] | "  - \(.target)"' 2>/dev/null) || BROKEN_LINES=""
    [ -n "$BROKEN_LINES" ] && MSG="${MSG}
${BROKEN_LINES}"
  fi

  MSG="${MSG}

确认无重复后，重试此操作即可通过。"

  DENY_JSON=$(printf '%s' "$MSG" | jq -Rs .)
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}' "$DENY_JSON"
}

_main 2>/dev/null || true
