#!/usr/bin/env bash
# doc-gate 路径排除单一来源 — skill-gate.sh / recall-gate.sh 共享。
# 新增排除只改此处；对齐 tools/_doc_gate_common.py 的 EXCLUDED_DIRS 设计意图。
# 命中排除→return 0；否则→return 1。
doc_gate_is_excluded_path() {
  local fp="$1"
  # location 排除（prepend / 统一处理相对路径）
  # pipeline: deep-research 机器生成中间产物，doc-maintenance 工作流不适用。
  # intake: deep-research G0 需求门产物（research-goal 等），Lead 半自动生成。
  # deliverables 刻意【不】排除——最终交付散文档受治理。
  case "/$fp" in
    */.claude/*|*/.claude-plugin/*|*/.agents/directives/*|*/node_modules/*|*/.git/*|*/logs/*|*/pipeline/*|*/intake/*) return 0 ;;
  esac
  # 临时目录排除（绝对路径直配）
  case "$fp" in
    /tmp/*|/var/tmp/*|/var/folders/*|/private/tmp/*) return 0 ;;
  esac
  return 1
}
