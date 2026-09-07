#!/usr/bin/env bash
# doc-gate 排除单一来源 — doc-entry.sh / doc-exit.sh 共享。
# 新增排除只改此处。本清单与 tools/_doc_gate_common.py 的 EXCLUDED_DIRS
# 管辖对象不同：本清单决定哪些编辑豁免 doc-maintenance 工作流门禁，
# EXCLUDED_DIRS 决定语料库（BM25/link graph）索引哪些文件。
#
# 两清单只允许一个方向分叉：「本清单不检查，但 EXCLUDED_DIRS 仍索引」
# ——即 deliverables/*、.claude-plugin/*。这些文件编辑不需要走门禁，但
# 仍是应被 recall/orphan/断链检查覆盖的真实文档，且改动它们能让 A2 修复后
# 的 dirty_set 超集机制正确识别「已被改动」，finding 可自终止。
#
# 反方向——「本清单检查但 EXCLUDED_DIRS 不索引」——是活 bug 不是允许的分叉
# (A3, #219)：脏文件通过本清单进了检查集，但 os.walk 跳过它所在目录，它就
# 永远拿不到 backward/all_files 里的位置，图谱侧只能判它 orphan=True 且
# 链向它的边只能落进 dangling——编辑它换不来 finding 消失，是满足不了的
# 门禁。.venv/research/docs-graph-tests 曾只在 EXCLUDED_DIRS 里，未同步进本
# 清单，就踩了这个坑；现已补齐，两清单在这三项上重新对齐。
# 命中排除→return 0；否则→return 1。
doc_gate_is_excluded_path() {
  local fp="$1"
  # location 排除（prepend / 统一处理相对路径）
  # pipeline: deep-research 机器生成中间产物，doc-maintenance 工作流不适用。
  # intake: deep-research G0 需求门产物（research-goal 等），Lead 半自动生成。
  # deliverables: 有自己的质量体系（G1-G3 + Stage 6）、管辖对象与本 gate 不同而排除。
  # .agents: team-ops 运行时工作区整体排除，不止 directives——handoffs/intel/tasks
  # 同属协议中间产物，消费者是协议机器而非人类读者，使用侧 .gitignore 也按整目录
  # 忽略。曾只排除 directives，intel 等角色 tools 不含 Skill、无法自行调
  # doc-maintenance 解锁而被拦死无法自救（#176）。
  # .venv/research/docs-graph-tests: EXCLUDED_DIRS 里 os.walk 就跳过的目录，
  # 必须同步排除，否则检查集与图谱索引集出现交叉（A3, #219）。
  case "/$fp" in
    */.claude/*|*/.claude-plugin/*|*/.agents/*|*/node_modules/*|*/.git/*|*/logs/*|*/pipeline/*|*/intake/*|*/deliverables/*|*/.venv/*|*/research/*|*/docs-graph-tests/*) return 0 ;;
  esac
  # 临时目录排除（绝对路径直配）
  case "$fp" in
    /tmp/*|/var/tmp/*|/var/folders/*|/private/tmp/*) return 0 ;;
  esac
  return 1
}

# Basename 排除 — 工具维护文件（MEMORY.md）与特殊格式文件（SKILL.md、CHANGELOG.md、LICENSE.md）。
# CLAUDE.md / README.md / CONTRIBUTING.md 是受管文档，故意不列入排除（它们受 doc-maintenance
# 工作流管辖，不需在这里提前退出）。命中排除→return 0；否则→return 1。
doc_gate_is_excluded_basename() {
  local bn="$1"
  shopt -s nocasematch
  case "$bn" in
    memory.md|skill.md|changelog.md|license.md)
      shopt -u nocasematch
      return 0
      ;;
  esac
  shopt -u nocasematch
  return 1
}
