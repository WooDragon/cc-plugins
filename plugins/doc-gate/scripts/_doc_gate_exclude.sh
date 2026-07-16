#!/usr/bin/env bash
# doc-gate 路径排除单一来源 — skill-gate.sh / recall-gate.sh 共享。
# 新增排除只改此处。本清单与 tools/_doc_gate_common.py 的 EXCLUDED_DIRS
# 允许分叉——两者管辖对象不同：本清单决定哪些编辑豁免 doc-maintenance
# 工作流门禁，EXCLUDED_DIRS 决定 recall-gate 语料库（BM25/link graph）索引
# 哪些文件。例如 deliverables/*：本清单排除（见下方注释），但
# EXCLUDED_DIRS 仍索引它——deliverables 依然是应被 recall/orphan/断链检查
# 覆盖的真实文档，只是编辑它不需要走门禁。不要求两边清单一致。
# 命中排除→return 0；否则→return 1。
doc_gate_is_excluded_path() {
  local fp="$1"
  # location 排除（prepend / 统一处理相对路径）
  # pipeline: deep-research 机器生成中间产物，doc-maintenance 工作流不适用。
  # intake: deep-research G0 需求门产物（research-goal 等），Lead 半自动生成。
  # deliverables: 与 ADR-010（主 session 成本根治）结构性冲突而排除——
  # deliverables 写入必走 subagent、marker 按 session_id 落盘，合法过门路径不存在，
  # 实测 100% 旁路率；且有自己的质量体系（G1-G3 + Stage 6），管辖对象与本 gate 不同。
  case "/$fp" in
    */.claude/*|*/.claude-plugin/*|*/.agents/directives/*|*/node_modules/*|*/.git/*|*/logs/*|*/pipeline/*|*/intake/*|*/deliverables/*) return 0 ;;
  esac
  # 临时目录排除（绝对路径直配）
  case "$fp" in
    /tmp/*|/var/tmp/*|/var/folders/*|/private/tmp/*) return 0 ;;
  esac
  return 1
}
