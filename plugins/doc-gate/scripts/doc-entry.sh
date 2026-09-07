#!/usr/bin/env bash
# PostToolUse:Edit/Write hook — Doc-entry injection layer.
#
# On every .md file edit/write, injects writing standards and CLAUDE.md
# principles directly into model context (additionalContext). Zero state:
# no marker files, no session_id tracking, no logging. Judgment criteria
# are stateless and re-injected on every edit to survive context compression.
#
# Environment variables:
#   DOC_ENTRY_GATE_DISABLED=1   — kill switch
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_doc_gate_exclude.sh"

_main() {
  INPUT=$(cat)

  [ "${DOC_ENTRY_GATE_DISABLED:-0}" != "1" ] || return
  command -v jq >/dev/null 2>&1 || return

  TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || return
  [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ] || return

  FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null) || return
  [ -n "$FILE_PATH" ] || return

  # Hard filter: .md extension only
  BASENAME="${FILE_PATH##*/}"
  case "$BASENAME" in *.[mM][dD]) ;; *) return ;; esac

  # Global CLAUDE.md identity check — must be case-insensitive on macOS/APFS.
  # Strip trailing slash from HOME to prevent path doubling (HOME=/x/ → /x//.claude/...).
  shopt -s nocasematch
  HOME_DIR="${HOME:-}"; HOME_DIR="${HOME_DIR%/}"
  IS_GLOBAL_CLAUDE=0
  case "$FILE_PATH" in
    "${HOME_DIR}/.claude/CLAUDE.md") IS_GLOBAL_CLAUDE=1 ;;
  esac

  # Basename exclusions — tool-maintained (MEMORY.md) or special-format files
  # (SKILL.md, CHANGELOG.md, LICENSE.md). CLAUDE.md, README.md, CONTRIBUTING.md
  # are governed documents intentionally NOT listed here.
  if doc_gate_is_excluded_basename "$BASENAME"; then
    shopt -u nocasematch
    return
  fi
  shopt -u nocasematch

  # Location-based exclusions — global CLAUDE.md bypasses ALL of them.
  if [ "$IS_GLOBAL_CLAUDE" != "1" ]; then
    if doc_gate_is_excluded_path "$FILE_PATH"; then return; fi
  fi

  # Resolve absolute path to writing-standards.md — try CLAUDE_PLUGIN_ROOT first,
  # then script-relative location. This is a two-candidate loop (not ${VAR:-fallback})
  # because a stale or wrong CLAUDE_PLUGIN_ROOT should not suppress the fallback retry.
  # If no candidate resolves, emit the summary alone — never a broken path.
  local standards_rel="skills/doc-maintenance/references/writing-standards.md"
  local standards_self=""
  standards_self=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd) || standards_self=""
  local standards_path=""
  local standards_cand
  for standards_cand in "${CLAUDE_PLUGIN_ROOT:-}" "$standards_self"; do
    [ -n "$standards_cand" ] || continue
    if [ -f "${standards_cand}/${standards_rel}" ]; then
      # Normalize to absolute — a subagent with an unknown cwd cannot resolve a
      # relative path, and CLAUDE_PLUGIN_ROOT is not guaranteed to be absolute.
      local standards_abs
      standards_abs=$(cd "$standards_cand" 2>/dev/null && pwd) || standards_abs=""
      [ -n "$standards_abs" ] || continue
      standards_path="${standards_abs}/${standards_rel}"
      break
    fi
  done

  # Build payload — three segments concatenated.
  # Segment 1: Title + reference (conditionally includes path).
  local payload="以下判据适用于刚写入 ${FILE_PATH} 的叙述性段落。"
  if [ -n "$standards_path" ]; then
    payload="${payload}权威条文（正反例、豁免边界、语种适用）在 ${standards_path} 的 §A，本文只含判据不含例子。"
  fi
  payload="${payload}

A1 一句一事——一句只承载一个可执行动作，动作数超过一个即为违反。
A2 明确主语 + 主动动词——施事已知却被隐去（非必要被动式）即为违反。
A3 术语统一——同一概念全文只用同一术语；比对范围含文档既有段落，不止新增内容。
A4 单一精确含义——\"处理\"\"支持\"\"优化\"等脱离上下文无法还原具体动作的词一律替换，A4 自身无豁免（A13 的对象类豁免另计，见下）。
A5 术语需定义——专业术语首次出现且读者不能就地理解时须给出定义或链接。
A6 名词群精简——连续 3 个以上无助词修饰的名词堆叠即为违反；中文侧含\"的\"字串叠加。
A7 程序性文本三要素——操作步骤须同时给出条件、动作、预期结果，缺任一项即不完整。
A8 肯定式优先——句中两个否定词叠加即为违反。
A9 助动词受控——强度词须落在\"应 / 宜 / 可 / 不应\"四级之一；\"建议\"\"最好\"\"尽量\"即为违反。
A10 拼写变体一致（仅英文）——同一文档不混用 American / British 变体。
A11 冠词完整（仅英文）——电报体省略冠词即为违反。
A12 避免悬垂分词（仅英文）——分词短语逻辑主语与主句主语不一致即为违反。
A13 豁免边界——代码、命令、标识符、产品名、法律文本、引文、文件路径原样保留，A1-A12 对这些对象不生效，不得为合规而静默改写。"

  # Segment 2: Objective trigger conditions (all files)
  payload="${payload}

以下条件锚在模型对自身刚完成动作的直接知识上，不依赖任何被扣住的文档内容（因而不构成自指）；其中 CREATE/RENAME/ARCHIVE 可直接观测，RESTRUCTURE/DEDUP 的边界需要判断——误判代价只是多调一次 doc-maintenance，是刻意选择的偏向。命中或判断成立即对应后续动作：
- 目标文件是 CLAUDE.md：需调 doc-maintenance skill，套用其「CLAUDE.md 通用化原则」四判据。
- 本次操作属于 CREATE / RENAME / ARCHIVE / RESTRUCTURE / DEDUP：需调 doc-maintenance skill，走对应检查单。
- 写入内容含英文叙述段落：需读 writing-standards.md §A 的 A10-A12 原文。
- 写入内容紧邻代码块、命令、路径，或含引文 / 法规原文：需读 A13 原文确认豁免边界。"

  # Segment 3: Global CLAUDE.md principles (only for global config)
  if [ "$IS_GLOBAL_CLAUDE" = "1" ]; then
    payload="${payload}

本次目标是全局 CLAUDE.md，它注入到每一个任务，是污染面最大的文件。通用化原则四判据：只增原则性内容、跨 2+ 场景生效、确定后基本不变、非单一任务专属；场景特定内容归对应 skill 或 docs/。四判据须全过。"
  fi

  # Output JSON with additionalContext.
  # --arg already JSON-encodes the value; pre-encoding with `jq -Rs .` would
  # double-encode it and ship the model a quoted literal full of \n escapes
  # instead of readable text. Pass the raw payload.
  local output
  output=$(jq -n --arg ctx "$payload" \
    '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}')
  printf '%s' "$output"
}

_main 2>/dev/null || true
