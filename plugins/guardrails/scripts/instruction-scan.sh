#!/usr/bin/env bash
# SessionStart hook: scans every agent instruction file under the session's
# cwd tree for hidden Unicode payloads (zero-width, bidi-control, tag chars,
# stray BOM) that could smuggle instructions past a human skim-reading the
# file. Purely informational — this hook can only add additionalContext, it
# has no way to block a session from starting.
#
# Environment variables:
#   INSTRUCTION_SCAN_DISABLED=1  — kill switch
#   MAX_HITS                     — per-file hit cap before truncating (see
#                                  _gate_scan_hidden in _gate_common.sh; default 10)
#
# Fail-open on ALL anomalies: missing jq/perl, missing cwd, no instruction
# files, any parse error — all degrade to silent no-op, never a hard failure.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_gate_common.sh"

_main() {
  # Kill switch (frontmost) — checked before consuming stdin so the disabled
  # path is as cheap as possible.
  _gate_bypass_on INSTRUCTION_SCAN_DISABLED && return

  INPUT=$(cat)

  # Preconditions
  _gate_require_jq || return

  CWD=$(_gate_field "$INPUT" '.cwd // ""') || return
  [ -n "$CWD" ] || return
  [ -d "$CWD" ] || return

  # Enumerate instruction files, scan each for hidden Unicode, collect hits.
  REPORT=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    HITS=$(_gate_scan_hidden "$f") || HITS=""
    [ -n "$HITS" ] || continue
    REPORT="${REPORT}文件 ${f}:
${HITS}

"
  done < <(_gate_instruction_files "$CWD")

  # Out-of-tree symlinks: content is unverifiable (never opened, to avoid scan
  # escape), so surface the fact rather than dropping it silently.
  ESCAPES=$(_gate_symlink_escapes "$CWD") || ESCAPES=""

  # Nothing to report → stay silent.
  [ -n "$REPORT" ] || [ -n "$ESCAPES" ] || return

  MSG="[instruction-scan] 检测到 agent 指令文件安全隐患，请人工核查："

  if [ -n "$REPORT" ]; then
    MSG="${MSG}

隐藏 Unicode 字符（零宽/双向控制/tag 字符/异常 BOM），存在指令注入风险：

${REPORT}"
  fi

  if [ -n "$ESCAPES" ]; then
    MSG="${MSG}

以下指令文件是指向工作区外的 symlink，扫描器无法核验其内容，请人工审查目标：

${ESCAPES}
"
  fi

  MSG_JSON=$(printf '%s' "$MSG" | jq -Rs .) || return
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}' "$MSG_JSON"
}

_main 2>/dev/null || true
