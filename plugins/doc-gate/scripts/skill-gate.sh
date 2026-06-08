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

  # Global CLAUDE.md identity + basename exclusions share one nocasematch block.
  # The global match MUST be case-insensitive — macOS/APFS is case-insensitive
  # by default; never assume path casing (a lowercase ~/.claude/claude.md would
  # otherwise slip past the global guard into the */.claude/* allow path).
  shopt -s nocasematch
  # Global config (~/.claude/CLAUDE.md): must gate despite living under .claude/.
  # Strip a trailing slash from HOME — HOME=/x/ yields /x//.claude/... which would
  # miss the match and silently let the global config slip into the */.claude/*
  # allow path. (glob chars in HOME are safe: the quoted pattern matches literally.)
  HOME_DIR="${HOME:-}"; HOME_DIR="${HOME_DIR%/}"
  IS_GLOBAL_CLAUDE=0
  case "$FILE_PATH" in
    "${HOME_DIR}/.claude/CLAUDE.md") IS_GLOBAL_CLAUDE=1 ;;
  esac
  # Basename exclusions — tool-maintained (MEMORY.md) or special-format /
  # non-prose files (SKILL.md, CHANGELOG.md, LICENSE.md). CLAUDE.md, README.md,
  # CONTRIBUTING.md are governed documents now and intentionally NOT listed.
  case "$BASENAME" in
    memory.md|skill.md|changelog.md|license.md) shopt -u nocasematch; return ;;
  esac
  shopt -u nocasematch

  # Location-based exclusions — global CLAUDE.md bypasses ALL of them: once its
  # identity is established it must gate unconditionally, no matter where $HOME
  # lives (a containerized/test HOME under /tmp must not slip through either).
  if [ "$IS_GLOBAL_CLAUDE" != "1" ]; then
    # Path exclusions (prepend / to handle relative paths uniformly)
    case "/$FILE_PATH" in
      */.claude/*|*/.claude-plugin/*|*/.agents/directives/*|*/node_modules/*|*/.git/*) return ;;
    esac
    # Temporary directory exclusions (match absolute paths directly)
    case "$FILE_PATH" in
      /tmp/*|/var/tmp/*|/var/folders/*|/private/tmp/*) return ;;
    esac
  fi

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

  # Deny — global config gets the highest-strength message + distinct log reason.
  local msg
  if [ "$IS_GLOBAL_CLAUDE" = "1" ]; then
    _log "deny" "skill-not-invoked-global"
    msg="文档编辑门禁（全局配置 · 最高强度）：正在编辑全局 CLAUDE.md（${FILE_PATH}）。它注入到每一个任务，是污染面最大的文件，改动需极度克制。

编辑前必须先调用 doc-maintenance skill，并套用最严的「全局 CLAUDE.md 通用化原则」：只增跨 2+ 场景生效、确定后基本不变、非单任务的原则性内容；场景特定内容一律外移到对应 skill 或 docs/。

请使用 Skill 工具调用 doc-maintenance，然后重试此操作。

如需关闭门禁，设置 SKILL_GATE_DISABLED=1。"
  else
    _log "deny" "skill-not-invoked"
    msg="文档编辑门禁：${BASENAME} 是文档文件（.md），编辑前需先调用 doc-maintenance skill 加载文档维护工作流。

请使用 Skill 工具调用 doc-maintenance，然后重试此操作。

如需关闭门禁，设置 SKILL_GATE_DISABLED=1。"
  fi

  local deny_json
  deny_json=$(printf '%s' "$msg" | jq -Rs .)
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}' "$deny_json"
}

_main 2>/dev/null || true
