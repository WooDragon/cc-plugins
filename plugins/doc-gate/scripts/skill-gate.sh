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

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_doc_gate_exclude.sh"

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
    if doc_gate_is_excluded_path "$FILE_PATH"; then return; fi
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

  # Writing-standards summary appended to both deny branches below. The summary
  # is UNCONDITIONAL — it is the payload that must reach the agent; only the
  # path reference is conditional. Resolve an absolute references path so a
  # subagent with an unknown cwd can still read it — never inject a relative
  # path here (deny branch: unreadable path means the agent retries blind and
  # may stall). Try CLAUDE_PLUGIN_ROOT first, then the script's own location
  # (same convention as recall-gate.sh's TOOL_DIR) — note this is a two-
  # candidate loop, not `${CLAUDE_PLUGIN_ROOT:-fallback}`: that form skips the
  # fallback whenever the variable is merely *set*, so a stale or wrong root
  # would suppress the script-relative retry. If no candidate resolves to an
  # existing file, emit the summary alone — never a broken path.
  # Deliberately NO item summary here (issue #139): a readable digest makes the
  # model feel it already knows the rules and skip the authoritative file, so the
  # self-check passes on rules it never read. Emit the imperative + the path only.
  local standards_ref="

表述规范：撰写或改写任何叙述性段落前，须读取 doc-maintenance 的 references/writing-standards.md，按其原文判据逐条自查。本消息不复述条目——判据只有那一份权威版本。"

  local standards_rel="skills/doc-maintenance/references/writing-standards.md"
  local standards_self=""
  standards_self=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd) || standards_self=""
  local standards_path=""
  local standards_cand
  for standards_cand in "${CLAUDE_PLUGIN_ROOT:-}" "$standards_self"; do
    [ -n "$standards_cand" ] || continue
    if [ -f "${standards_cand}/${standards_rel}" ]; then
      standards_path="${standards_cand}/${standards_rel}"
      break
    fi
  done
  if [ -n "$standards_path" ]; then
    standards_ref="${standards_ref}

权威条文（正反例、豁免边界、语种适用）：${standards_path}"
  fi

  # Deny — global config gets the highest-strength message + distinct log reason.
  local msg
  if [ "$IS_GLOBAL_CLAUDE" = "1" ]; then
    _log "deny" "skill-not-invoked-global"
    msg="文档编辑门禁（全局配置 · 最高强度）：正在编辑全局 CLAUDE.md（${FILE_PATH}）。它注入到每一个任务，是污染面最大的文件，改动需极度克制。

编辑前必须先调用 doc-maintenance skill，并套用最严的「全局 CLAUDE.md 通用化原则」：只增跨 2+ 场景生效、确定后基本不变、非单任务的原则性内容；场景特定内容一律外移到对应 skill 或 docs/。

请使用 Skill 工具调用 doc-maintenance，然后重试此操作。禁止通过环境变量绕过门禁——仅当 skill 工具本身故障无法调用时，才可设置 SKILL_GATE_DISABLED=1 临时放行。${standards_ref}"
  else
    _log "deny" "skill-not-invoked"
    msg="文档编辑门禁：${BASENAME} 是文档文件（.md），编辑前需先调用 doc-maintenance skill 加载文档维护工作流。

请使用 Skill 工具调用 doc-maintenance，然后重试此操作。禁止通过环境变量绕过门禁——仅当 skill 工具本身故障无法调用时，才可设置 SKILL_GATE_DISABLED=1 临时放行。${standards_ref}"
  fi

  local deny_json
  deny_json=$(printf '%s' "$msg" | jq -Rs .)
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}' "$deny_json"
}

_main 2>/dev/null || true
