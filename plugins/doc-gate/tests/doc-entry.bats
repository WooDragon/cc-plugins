#!/usr/bin/env bats
# BDD tests for doc-entry.sh (PostToolUse injection layer)

setup() {
  source "${BATS_TEST_DIRNAME}/test_helper/common-setup.bash"
  common_setup
}

teardown() {
  common_teardown
}

# ============================================================
# Injection success paths
# ============================================================

@test "injection: Edit on ordinary .md produces additionalContext JSON" {
  INPUT=$(build_edit_input file_path="/project/docs/guide.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  echo "$HOOK_STDOUT" | jq . >/dev/null 2>&1
  [ "$?" -eq 0 ]
  local event_name
  event_name=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.hookEventName')
  [ "$event_name" = "PostToolUse" ]
  local context
  context=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
  [ -n "$context" ]
}

@test "injection: Write on ordinary .md produces additionalContext JSON" {
  INPUT=$(build_write_input file_path="/project/docs/guide.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  echo "$HOOK_STDOUT" | jq . >/dev/null 2>&1
  [ "$?" -eq 0 ]
  local event_name
  event_name=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.hookEventName')
  [ "$event_name" = "PostToolUse" ]
  local context
  context=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
  [ -n "$context" ]
}

@test "injection: .MD (uppercase) is recognized and injects" {
  INPUT=$(build_write_input file_path="/project/docs/README.MD")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  local context
  context=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
  [ -n "$context" ]
}

@test "injection: output is valid JSON with correct structure" {
  INPUT=$(build_edit_input file_path="/project/docs/guide.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  echo "$HOOK_STDOUT" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null
  echo "$HOOK_STDOUT" | jq -e '.hookSpecificOutput.additionalContext != null' >/dev/null
}

# ============================================================
# Payload content assertions (core architecture protection)
# ============================================================

@test "payload: contains A6 judgment criteria (noun pile, 的 string handling)" {
  INPUT=$(build_edit_input file_path="/project/docs/guide.md")
  run_entry_gate
  assert_additional_context_contains "名词群精简"
  assert_additional_context_contains '的'
}

@test "payload: contains A9 four-level mapping (应 / 宜 / 可 / 不应)" {
  INPUT=$(build_edit_input file_path="/project/docs/guide.md")
  run_entry_gate
  assert_additional_context_contains "应 / 宜 / 可 / 不应"
}

@test "payload: contains A10-A12 (English-only criteria, not stripped)" {
  INPUT=$(build_edit_input file_path="/project/docs/guide.md")
  run_entry_gate
  assert_additional_context_contains "拼写变体一致（仅英文）"
  assert_additional_context_contains "冠词完整（仅英文）"
  assert_additional_context_contains "悬垂分词（仅英文）"
}

@test "payload: contains the target file path for context binding" {
  INPUT=$(build_edit_input file_path="/project/docs/special-guide.md")
  run_entry_gate
  assert_additional_context_contains "/project/docs/special-guide.md"
}

@test "payload: contains an absolute path to writing-standards.md via the script-relative fallback" {
  # Unconditional hard assertion, no either-branch escape hatch: A1 is
  # injected unconditionally regardless of whether the path resolved, so an
  # if/else that falls back to asserting A1 is present is vacuously true on
  # both paths and immune to a broken path-resolution regression.
  #
  # CLAUDE_PLUGIN_ROOT is unset here (not exported by common_setup, and no
  # prior test in this file leaves it exported) so this exercises exactly
  # the script-relative fallback branch (`standards_self` in doc-entry.sh)
  # that run_entry_gate's plain `bash "$ENTRY_SCRIPT"` invocation actually
  # takes by default.
  unset CLAUDE_PLUGIN_ROOT

  INPUT=$(build_edit_input file_path="/project/docs/guide.md")
  run_entry_gate
  local context
  context=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext // ""')

  local abs_path
  abs_path=$(echo "$context" | grep -oE '/[^[:space:]]*writing-standards\.md' | head -1)
  [ -n "$abs_path" ]
  # Must be an actual absolute path to a file that exists on disk, not just
  # the bare filename string appearing somewhere in the payload.
  [ "${abs_path:0:1}" = "/" ]
  [ -f "$abs_path" ]
}

@test "payload: contains the four objective trigger conditions" {
  INPUT=$(build_edit_input file_path="/project/docs/guide.md")
  run_entry_gate
  assert_additional_context_contains "目标文件是 CLAUDE.md"
  assert_additional_context_contains "本次操作属于 CREATE / RENAME / ARCHIVE / RESTRUCTURE / DEDUP"
  assert_additional_context_contains "写入内容含英文叙述段落"
  assert_additional_context_contains "写入内容紧邻代码块"
}

# ============================================================
# Critical architecture regression: stateless re-injection
# ============================================================

@test "stateless: same file edited twice in same session both get injected (no deny-once)" {
  # First edit
  INPUT=$(build_edit_input file_path="/project/docs/guide.md" session_id="test-session")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  local first_output="$HOOK_STDOUT"

  # Second edit of same file, same session
  INPUT=$(build_edit_input file_path="/project/docs/guide.md" session_id="test-session")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  local second_output="$HOOK_STDOUT"

  # Both must have additionalContext (no state-based filtering)
  echo "$first_output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
  echo "$second_output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
}

# ============================================================
# Exclusion paths (should not inject)
# ============================================================

@test "excluded: .txt file produces no output" {
  INPUT=$(build_edit_input file_path="/project/docs/notes.txt")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "excluded: memory.md produces no output" {
  INPUT=$(build_edit_input file_path="/project/memory.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "excluded: SKILL.md (case-insensitive) produces no output" {
  INPUT=$(build_edit_input file_path="/project/SKILL.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "excluded: CHANGELOG.md produces no output" {
  INPUT=$(build_edit_input file_path="/project/CHANGELOG.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "excluded: node_modules/ path produces no output" {
  INPUT=$(build_edit_input file_path="/project/node_modules/pkg/README.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "excluded: /tmp/ path produces no output" {
  INPUT=$(build_edit_input file_path="/tmp/draft.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "excluded: Read tool (not Edit/Write) produces no output" {
  INPUT=$(build_raw_input "Read" session_id="test-session")
  INPUT=$(echo "$INPUT" | jq '.tool_input.file_path = "/project/docs/guide.md"')
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

# ============================================================
# Global CLAUDE.md special handling
# ============================================================

@test "global CLAUDE.md: ~/.claude/CLAUDE.md is recognized and injects with universalization segment" {
  INPUT=$(build_edit_input file_path="${HOME}/.claude/CLAUDE.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  assert_additional_context_contains "通用化原则四判据"
}

@test "global CLAUDE.md: lowercase ~/.claude/claude.md also recognized (case-insensitive APFS)" {
  INPUT=$(build_edit_input file_path="${HOME}/.claude/claude.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  assert_additional_context_contains "通用化原则四判据"
}

@test "global CLAUDE.md: HOME with trailing slash still recognized" {
  local home_with_slash="${HOME}/"
  INPUT=$(build_edit_input file_path="${home_with_slash}.claude/CLAUDE.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  assert_additional_context_contains "通用化原则四判据"
}

@test "project-level CLAUDE.md: injects but WITHOUT universalization segment" {
  INPUT=$(build_edit_input file_path="/project/CLAUDE.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  local context
  context=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext')
  # Must contain general criteria
  echo "$context" | grep -q "A1 一句一事"
  # Must NOT contain the universalization four principles
  if echo "$context" | grep -q "通用化原则四判据"; then
    echo "Project-level CLAUDE.md should not have universalization segment"
    return 1
  fi
}

# ============================================================
# Fail-open behavior
# ============================================================

@test "fail-open: DOC_ENTRY_GATE_DISABLED=1 produces no output" {
  export DOC_ENTRY_GATE_DISABLED=1
  INPUT=$(build_edit_input file_path="/project/docs/guide.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "fail-open: malformed JSON input produces no output, exit 0" {
  INPUT="{ this is not json }"
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "fail-open: empty stdin produces no output, exit 0" {
  INPUT=""
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ] || {
    echo "Exit code was $HOOK_EXIT, not 0"
    return 1
  }
  [ -z "$HOOK_STDOUT" ] || {
    echo "HOOK_STDOUT was not empty: [$HOOK_STDOUT]"
    return 1
  }
}

@test "fail-open: missing file_path produces no output" {
  INPUT=$(jq -n '{tool_name: "Edit", session_id: "test", tool_input: {}}')
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "fail-open: unresolvable writing-standards path still injects criteria without broken path" {
  # Simulate unreachable standards file by setting CLAUDE_PLUGIN_ROOT to nonexistent dir
  export CLAUDE_PLUGIN_ROOT="/nonexistent/path"
  INPUT=$(build_edit_input file_path="/project/docs/guide.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  # Should inject with criteria
  assert_additional_context_contains "A1 一句一事"
  # Should NOT contain a broken path like '/nonexistent/path'
  local context
  context=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext')
  if echo "$context" | grep -q "/nonexistent"; then
    echo "Broken path should not be in output"
    return 1
  fi
}

# ============================================================
# Regression: Bug 1 — additionalContext encoding
# ============================================================

@test "regression: additionalContext is raw text, not a double-encoded JSON string literal" {
  INPUT=$(build_edit_input file_path="/project/docs/guide.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]

  # Extract additionalContext and verify it's raw text (not a quoted string)
  local context
  context=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext // ""')

  # Test 1: First character must NOT be a double quote (sign of double-encoding)
  local first_char
  first_char=$(printf '%s' "$context" | head -c 1)
  [ "$first_char" != '"' ] || {
    echo "additionalContext starts with '\"' — signs of double-encoding"
    return 1
  }

  # Test 2: Output must contain real newlines (line count > 1), not literal \n
  local line_count
  line_count=$(echo "$context" | wc -l)
  [ "$line_count" -gt 1 ] || {
    echo "additionalContext has only 1 line — expected multiple real newlines"
    return 1
  }

  # Test 3: Output must NOT contain literal two-character sequences \n
  if echo "$context" | grep -F '\n' >/dev/null 2>&1; then
    echo "additionalContext contains literal \\n sequences (sign of escape encoding)"
    return 1
  fi
}

# ============================================================
# Regression: Bug 2 — absolute path normalization
# ============================================================

@test "regression: a RELATIVE CLAUDE_PLUGIN_ROOT is normalized to an absolute standards path" {
  # This regression test verifies that when CLAUDE_PLUGIN_ROOT is set to a RELATIVE
  # path (e.g., "plugins/doc-gate"), the resolved writing-standards.md path in the
  # output is normalized to an ABSOLUTE path. The fix at lines 69-71 of doc-entry.sh
  # (cd "$standards_cand" && pwd) converts CLAUDE_PLUGIN_ROOT's relative path to absolute.
  #
  # Why this test exists:
  # - Without the fix, a relative CLAUDE_PLUGIN_ROOT would leak directly into output
  #   as "plugins/doc-gate/skills/doc-maintenance/references/writing-standards.md"
  # - With the fix, it becomes "/absolute/path/to/plugins/doc-gate/skills/.../writing-standards.md"
  # - If relative paths ever leak, subagents with unknown cwd cannot resolve them
  #
  # Why workdir is from BATS_TEST_DIRNAME, not $PWD:
  # - $PWD is the shell's cwd when calling bats, not the test file's directory
  # - From a different directory (e.g., CI, or cd /tmp && bats), $PWD would be wrong
  # - BATS_TEST_DIRNAME is always the test directory (plugins/doc-gate/tests)
  # - Computing plugin_parent as "$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)" gives
  #   the repo root, which is where "plugins/doc-gate" resolves correctly
  # - This eliminates cwd dependency and makes the test work from any location

  INPUT=$(build_edit_input file_path="/project/docs/guide.md")

  # Derive workdir from BATS_TEST_DIRNAME (test directory) instead of $PWD
  # This ensures the relative "plugins/doc-gate" path resolves correctly
  # regardless of where bats was invoked from
  local plugin_parent
  plugin_parent=$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)

  # Run with relative CLAUDE_PLUGIN_ROOT=doc-gate from its parent directory
  # This ensures the first candidate (CLAUDE_PLUGIN_ROOT) is triggered
  run_entry_gate_with_root "doc-gate" "$plugin_parent"
  [ "$HOOK_EXIT" -eq 0 ]

  local context
  context=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext // ""')

  # Hard assert 1: writing-standards.md must be present in output
  if ! echo "$context" | grep -q 'writing-standards\.md'; then
    echo "FAILED: writing-standards.md not found in context"
    echo "Context: $context"
    return 1
  fi

  # Hard assert 2: the path must be absolute (starts with /)
  local line_with_path
  line_with_path=$(echo "$context" | grep -E '在 /.*writing-standards\.md' | head -1)

  if [ -z "$line_with_path" ]; then
    echo "FAILED: no absolute path line found (pattern: 在 /.*writing-standards.md)"
    echo "Context: $context"
    return 1
  fi

  # Hard assert 3: must NOT contain any non-absolute form of writing-standards.md
  # (e.g., "plugins/..." or just "writing-standards.md" without a path prefix)
  if echo "$context" | grep -q -E '(在 [^/]|: [^/].*writing-standards\.md)'; then
    echo "FAILED: found relative or unqualified writing-standards.md path"
    local bad_lines
    bad_lines=$(echo "$context" | grep -E '(在 [^/]|: [^/].*writing-standards\.md)' || true)
    echo "Bad lines: $bad_lines"
    return 1
  fi

  return 0
}

# Static workflow contracts read the candidate skill beside this test, not the
# installed cache. Scope each assertion to its section so another operation
# cannot accidentally satisfy a missing obligation.
assert_skill_contract() {
  run python3 - "${BATS_TEST_DIRNAME}/../skills/doc-maintenance/SKILL.md" "$@" <<'PY'
from pathlib import Path
import re
import sys

path, heading, *obligations = sys.argv[1:]
text = Path(path).read_text()
start = text.index(heading + "\n") + len(heading) + 1
level = len(heading.split(" ", 1)[0])
end = re.search(r"^#{1," + str(level) + r"} ", text[start:], re.M)
section = text[start:start + end.start()] if end else text[start:]
for obligation in obligations:
    assert obligation in section, f"{path}: {heading}: missing obligation: {obligation}"
PY
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output"
    return 1
  fi
}

@test "skill contract: classify all six operations and check combinations separately" {
  assert_skill_contract '## 1. 操作类型判定' \
    '| **CREATE** | 新建文件' '| **MODIFY** | 编辑已有文件内容' \
    '| **RENAME** | 改变文件名或路径' '| **ARCHIVE** | 废弃或下线文件' \
    '| **RESTRUCTURE** | 目录调整、索引重建、批量整理' \
    '| **DEDUP** | 定期查重 / 去重审计' \
    '对每种类型分别走检查单'
}

@test "skill contract: common principles retain placement naming and single-source rules" {
  assert_skill_contract '## 2. 通用原则' \
    '以下原则适用于所有文档操作' '两者不混写' \
    '任意两条' '超过一个业务域才看得懂' '包含具体命令或参数' \
    '会随版本、拓扑、节点变化而频繁变更' '已经在下游文档有权威版本' \
    '只负责路由和约束' '业务域（它属于哪个系统或模块）' \
    '拓扑/场景（适用于哪种部署形态）' '可观测判别特征' \
    '兄弟条目之间至少有一个稳定可观测特征不同' \
    '文件名暴露业务域和场景' '拒绝泛化动作词' \
    '只保留一份权威版本' '下游用祈使式引用指向' \
    '已存在文档被改出的重复与存量重复一同靠定期 DEDUP'
}

@test "skill contract: reference mechanisms keep their applicability boundaries" {
  assert_skill_contract '### 跨文档引用' \
    '不会自动展开普通 Markdown 链接' \
    '| `@path/to/file` | 仅 CLAUDE.md 系列文件 |' '最多 4 跳' \
    '| `.claude/rules/*.md` + `paths:` frontmatter | 按文件路径触发的作用域规则 |' \
    '| Skill `references/` | 深度工作流前置知识 |' \
    '| **祈使式引用**（下方格式） | 普通 .md 文档互引 |' \
    '{触发时机}必须先读取' '优先原生机制，祈使式引用是兜底' \
    '普通 .md 中写 `@path` — 不会被识别'
}

@test "skill contract: global CLAUDE requires all four criteria while project rules differ" {
  assert_skill_contract '### CLAUDE.md 通用化原则（全局 vs 项目级分级）' \
    '**跨域性**：是否跨 2+ 独立场景生效' \
    '**稳定性**：是否确定后基本不变' \
    '**鲁棒性**：是否是高鲁棒的原则/约定' \
    '**只放原则**：是否只是原则/约定/路由' \
    '四判据**全部**通过才可增' \
    '四判据作为参考；允许项目专属约定' '这不是 deny'
}

@test "skill contract: narrative writing reads full standards and preserves A13 materials" {
  assert_skill_contract '### 表述规范' \
    '§A 歧义层（硬约束，逐条必判）' '§B 排版层（次要，机械可判定）' \
    '撰写或改写任何叙述性段落前，应先读取 `references/writing-standards.md`' \
    'CREATE 与 MODIFY 同样适用' '条目编号、判据、正反例与语种适用细则只有那一份权威版本' \
    '按 A13 原样保留代码、命令、标识符、产品名、法律文本、引文和文件路径'
}

@test "skill contract: pre-flight converges instance data and checks CREATE collisions before writing" {
  assert_skill_contract '### 4.1 Pre-flight（写前必做）' \
    '主机名、IP、端口、账号、版本号' '强制执行' \
    '全局 grep 目标数据的所有出现位置（文件 + 行号）' \
    '若有 → 指向它，不重写' '行内硬编码（禁止）' \
    '将权威版本写入单一来源文件' '命令块保留可执行内容' \
    '冗余文件整个删除，不留空壳' '更新入口索引' \
    '定位对应检查单（§5）' '读取其层位定义' \
    '确认目标文档应放在哪一层、文件名是否恰当' \
    '如为 CREATE，确认不存在已有文档覆盖同一内容' '不作为写前预判的替代'
}

@test "skill contract: post-flight binds common checks to CREATE and MODIFY with distinct scopes" {
  assert_skill_contract '### 4.3 Post-flight（写后自查）' \
    '逐项走检查单中的检查项' 'CREATE 补条目' \
    'MODIFY 核对出口检查报出的 `stale_inlinks` 名单是否需要同步描述' \
    'ARCHIVE 移除条目，RENAME 修正条目' \
    '新增的链接可达，修改的路径已全局同步' \
    '立即修正后再报告完成' '旧路径/旧值零残留' \
    '确认为空壳则直接删除并记录，不确定则保留并在完成报告中标注 warning' \
    'CREATE 全文、MODIFY 新增/改写段落应对照 §A 原文判据逐条自查' \
    '按原文重点复核 A3 / A9' '仅 CLAUDE.md 按 §2「CLAUDE.md 通用化原则」检查'
}

@test "skill contract: CREATE inherits shared checks and retains its own obligations" {
  assert_skill_contract '### 5.1 CREATE — 新增文档' \
    '应先执行 §4.1、遵循 §2，写后逐项完成 §4.3' \
    '**兄弟可判别**' '索引条目已加入可观测判别特征以区分' \
    '**无冗余重复**' '与已有共享文档不重复' '若重复超 60%，应考虑抽取共享层' \
    '实例化数据（具体主机名、IP、端口）写入面向所有实例的通用文档' \
    '同一信息在理论文档和操作手册中各写一遍，形成两份权威源' \
    '只属于某一场景的特化步骤写入通用手册'
}

@test "skill contract: MODIFY inherits shared checks and compares A3 against existing paragraphs" {
  assert_skill_contract '### 5.2 MODIFY — 修改文档' \
    '应先执行 §4.1、遵循 §2，写后逐项完成 §4.3' \
    '**相邻入口清晰**' '仍能从本文档找到相邻的兄弟文档' \
    '**风格一致**' '占位符风格、命名惯例与文档现有内容一致' \
    'A3 的比对范围含文档既有段落，不止新增段落' \
    '链向脏文件、但自身未被同步改动的文档' \
    '凭证/安全相关文档中混入架构拓扑说明（职责跨层）' \
    '通用文档中部分命令用占位符、部分硬编码具体值（风格不一致）' \
    '上层入口因"顺手"被塞入具体操作步骤'
}

@test "skill contract: RENAME scans all references before rename and verifies no old names remain" {
  assert_skill_contract '### 5.3 RENAME — 重命名文档' \
    '`docs-graph.py backlinks <旧文件>`' '工具不可用时，全局 grep 旧文件名为兜底' \
    '替换所有引用后，再执行重命名' '重命名后再次全局搜索旧文件名，确认无遗漏' \
    '入口索引、README、共享索引、兄弟文档中的入口条目已全部更新' \
    '漏掉跨目录或跨项目引用'
}

@test "skill contract: ARCHIVE removes the active entry but preserves history and replacement links" {
  assert_skill_contract '### 5.4 ARCHIVE — 归档文档' \
    '文档顶部写明归档原因和当前替代入口' \
    '主入口索引不再将其作为一线手册暴露' \
    '有价值的历史背景保留到归档目录或 Issue，而非直接删除' \
    '如已被新文档取代，从归档文档反向链接到当前权威入口'
}

@test "skill contract: RESTRUCTURE checks framework root impact global links and three-hop access" {
  assert_skill_contract '### 5.5 RESTRUCTURE — 目录重组 / 索引重建' \
    '先读取其层位定义和收敛规则' \
    '新增索引 / 合并索引 / 拆分目录 / 归档迁移 / 层级调整' \
    '`docs-graph.py check` 确认移动后无断链' '工具不可用时，全局引用扫描为兜底' \
    '根级文档的变更影响多个子项目，不能当局部问题处理' \
    '通常 3 跳内定位目标文档' '兄弟目录和上层索引的连锁影响'
}

@test "skill contract: DEDUP preserves nonblocking discovery disposition and cross-project verification" {
  assert_skill_contract '### 5.6 DEDUP — 定期查重' \
    '不做阻断式门禁' '已存在文档被改出的重复无自动信号' \
    '`docs-graph.py orphans`' '`docs-graph.py --root <顶层> orphans`' \
    '辅以人工 / LLM 审计可疑相似对' '内容更全 / 更新 / 位置更合理' \
    '删副本 / 合并差异到权威源 / 都不权威则抽取到 shared 层' \
    '`docs-graph.py backlinks <副本>`' '全部改指权威源' \
    '`docs-graph.py check` 确认零断链' \
    '排除 ops 配置 / 命令片段的固有复用' '所有反向引用已改指权威源' \
    '跨项目重复的扫描根已覆盖所有相关子仓库' \
    '把固有复用（占位符路径、无版本漂移的命令片段）误判为待治理重复'
}
