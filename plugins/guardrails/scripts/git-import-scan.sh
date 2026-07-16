#!/usr/bin/env bash
# PostToolUse hook (Bash): after a git/gh command that pulls external code
# into the workspace (clone/pull/fetch/merge/checkout/switch/restore/rebase/
# reset/cherry-pick/submodule/apply/am/worktree), scans every agent
# instruction file under the current workspace (cwd) for hidden Unicode
# payloads — the same check instruction-scan.sh runs at session start, but
# triggered by import-shaped git/gh activity mid-session.
#
# Deliberately scans the CURRENT STATE of cwd, never a diff / `git diff` /
# `HEAD@{1}` / clone-target-path resolution. Diffing/reflog logic is a
# rejected design here: it introduces path-offset and reflog-boundary bugs
# that a full re-scan of cwd's current state sidesteps entirely.
#
# Environment variables:
#   GIT_IMPORT_SCAN_DISABLED=1  — kill switch
#   MAX_HITS                    — per-file hit cap (see _gate_scan_hidden; default 10)
#
# Fail-open on ALL anomalies: this hook only ever emits additionalContext,
# never decision:block — never exit 2.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_gate_common.sh"

_main() {
  # Kill switch (frontmost)
  _gate_bypass_on GIT_IMPORT_SCAN_DISABLED && return

  INPUT=$(cat)

  # Preconditions
  _gate_require_jq || return

  COMMAND=$(_gate_field "$INPUT" '.tool_input.command // ""') || return
  [ -n "$COMMAND" ] || return

  # Fast-path short circuit: no git/gh mention at all → out of scope.
  case "$COMMAND" in
    *git*|*gh*) ;;
    *) return ;;
  esac

  # Must also contain an import-shaped action keyword — a bare `git status`
  # or `gh pr view` never pulls external code into the tree.
  case "$COMMAND" in
    *clone*|*pull*|*fetch*|*merge*|*checkout*|*switch*|*restore*|*rebase*|*reset*|*cherry-pick*|*submodule*|*apply*|*am*|*worktree*) ;;
    *) return ;;
  esac

  CWD=$(_gate_field "$INPUT" '.cwd // ""') || return
  [ -n "$CWD" ] || return
  [ -d "$CWD" ] || return

  # Enumerate instruction files currently present in cwd, scan each for
  # hidden Unicode, collect hits. Also track every file found (regardless of
  # hit) so the AI gets a change-notification of what instruction files
  # exist post-import, even when no hidden-char hit fires.
  FOUND=""
  REPORT=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    FOUND="${FOUND}${f}
"
    HITS=$(_gate_scan_hidden "$f") || HITS=""
    [ -n "$HITS" ] || continue
    REPORT="${REPORT}文件 ${f}:
${HITS}

"
  done < <(_gate_instruction_files "$CWD")

  # Nothing found at all → stay silent.
  [ -n "$FOUND" ] || return

  MSG="[git-import-scan] 检测到 git/gh 导入动作（拉取/合并/切换等），当前工作区（${CWD}）存在以下 agent 指令文件："

  MSG="${MSG}

${FOUND}"

  if [ -n "$REPORT" ]; then
    MSG="${MSG}
⚠️ 其中检测到隐藏 Unicode 字符（零宽/双向控制/tag 字符/异常 BOM），存在指令注入风险，请人工核查：

${REPORT}"
  else
    MSG="${MSG}
建议核查这些文件内容是否被本次导入动作变更或新增。"
  fi

  MSG_JSON=$(printf '%s' "$MSG" | jq -Rs .) || return
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":%s}}' "$MSG_JSON"
}

_main 2>/dev/null || true
