#!/usr/bin/env bats
# Static content/packaging contracts, not proof of model execution.
# Given this source checkout, inspect its deliverables rather than installed skills.
PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
SKILL_MD="${PLUGIN_DIR}/skills/memory-cleanup/SKILL.md"

assert_cleanup_contract() {
  run python3 - "$SKILL_MD" "$@" <<'PY'
from pathlib import Path
import re
import sys

path, heading, *patterns = sys.argv[1:]
assert Path(path).is_file(), f"Missing new skill: {path}"
text = Path(path).read_text()
match = re.search(r"^## " + re.escape(heading) + r"\n(.*?)(?=^## |\Z)", text, re.M | re.S)
assert match, f"Missing section: {heading}"
for pattern in patterns:
    assert re.search(pattern, match[1]), f"{heading}: missing contract: {pattern}"
PY
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output"
    return 1
  fi
}

@test "packaging: manifest uniquely resolves both skills and cleanup contains only SKILL.md" {
  run python3 - "$PLUGIN_DIR" <<'PY'
from pathlib import Path
import json
import re
import sys

plugin = Path(sys.argv[1]).resolve()
manifest = json.loads((plugin / '.claude-plugin/plugin.json').read_text())
expected = {'./skills/doc-maintenance', './skills/memory-cleanup'}
assert set(manifest['skills']) == expected, 'Missing or unexpected skill registration'
resolved = [(plugin / entry).resolve() for entry in manifest['skills']]
assert len(resolved) == len(set(resolved)) == 2, 'Duplicate skill paths'
assert set(resolved) == {p.parent.resolve() for p in (plugin / 'skills').glob('*/SKILL.md')}
for directory in resolved:
    path = directory / 'SKILL.md'
    assert path.is_file(), f'Missing registered skill: {path}'
cleanup = plugin / 'skills/memory-cleanup'
assert sorted(p.relative_to(cleanup).as_posix() for p in cleanup.rglob('*')) == ['SKILL.md']
text = (cleanup / 'SKILL.md').read_text()
frontmatter = re.match(r'\A---\nname: memory-cleanup\ndescription: ([^\n]+)\n---\n', text)
assert frontmatter, 'Expected name and single-line description frontmatter'
assert all(term in frontmatter[1] for term in ('auto-memory', '常驻', '去重', '过时'))
assert 'TODO' not in text
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "packaging: minor version is synchronized and existing hook declarations remain" {
  [ "$(jq -r .version "${PLUGIN_DIR}/.claude-plugin/plugin.json")" = "2.1.0" ]
  [ "$(jq -r '.plugins[] | select(.name == "doc-gate") | .version' "${REPO_ROOT}/.claude-plugin/marketplace.json")" = "2.1.0" ]
  jq -e '.hooks | keys == ["PostToolUse", "Stop"]' "${PLUGIN_DIR}/hooks/hooks.json" >/dev/null
  jq -e '.hooks.PostToolUse[0] | .matcher == "Edit|Write" and .hooks[0].command == "bash ${CLAUDE_PLUGIN_ROOT}/scripts/doc-entry.sh"' "${PLUGIN_DIR}/hooks/hooks.json" >/dev/null
  jq -e '.hooks.Stop[0].hooks[0].command == "bash ${CLAUDE_PLUGIN_ROOT}/scripts/doc-exit.sh"' "${PLUGIN_DIR}/hooks/hooks.json" >/dev/null
}

@test "contract: project authorization and unknown concurrent edits bound cleanup" {
  assert_cleanup_contract '1. 明确范围' '目标项目' '允许改动' '未提交' '未经授权不跨项目' '未知.*改动.*停止'
}

@test "contract: usefulness uniqueness and open state do not imply permanent context" {
  assert_cleanup_contract '2. 先判常驻' '未知任务类型' '有效偏好' '短入口' '有用不等于常驻' '独有不等于重要' '动态状态.*未关闭 Issue.*独有事故.*不.*常驻资格'
}

@test "contract: semantic authority need not copy old wording and unclear unique memory is discarded" {
  assert_cleanup_contract '3. 再判去留' '语义.*承接' '不.*逐字段复制' '用途不明.*过时.*可靠结论.*直接丢弃' '不建.*待确认.*历史库' '独有但用途不明.*丢弃' '措辞不同.*不.*复制'
}

@test "contract: explicit user constraints survive age but feedback labels grant no exemption" {
  assert_cleanup_contract '3. 再判去留' '独有.*明确用户约束.*不因年代旧.*删除' '用户反馈.*不.*永久豁免'
}

@test "contract: retain only maintainable useful knowledge without bulk incident migration or private facts" {
  assert_cleanup_contract '4. 最小承接' '明确有用.*鲁棒.*简洁.*可维护' '复用已有领域入口' '通用 skill 不.*项目事实' '必要.*无适当归属.*项目文档' '按需路由.*不等于全量内联' '不批量搬运事故'
}

@test "contract: deletion reads contents protects incoming links and separates index from body" {
  assert_cleanup_contract '5. 安全删除' '读取实际内容' '有效入链' '并发改动' '范围内.*引用' '范围外有效引用.*保留正文.*退出常驻.*报告例外' '批准范围内.*无用对象' '不清空未知目录' '索引退出与正文删除分开决定'
}

@test "contract: document reuse is limited and discarded memory need not retain ARCHIVE history" {
  assert_cleanup_contract '文档协作边界' '格式.*链接维护' '应先读取' '\.\./doc-maintenance/SKILL\.md' 'writing-standards\.md' 'ARCHIVE.*不.*自动适用.*授权丢弃.*无用 Memory' 'auto-memory.*排除' '单独核对 Memory.*链接.*入链'
  [ -f "${PLUGIN_DIR}/skills/doc-maintenance/SKILL.md" ]
  [ -f "${PLUGIN_DIR}/skills/doc-maintenance/references/writing-standards.md" ]
}

@test "contract: report measures bytes consistently and does not claim model or full graph coverage" {
  assert_cleanup_contract '6. 验证与短报告' '实际修改.*引用.*保护对象' '同.*口径.*常驻字节.*新增承接内容' '例外' '字节.*不.*token' '静态.*不.*模型.*遵循' '无 finding.*不.*Memory.*全覆盖'
}
