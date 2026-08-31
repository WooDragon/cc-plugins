#!/usr/bin/env bats

# 从交付文档提取唯一的再派停止条件顶层 bullet 及其缩进续行。
# 参数：可选的文档路径；省略时读取真实 offload-scenarios.md。
# 输出：完整 bullet。返回：结构不符合契约时返回 1。
extract_stop_condition() {
  local source_path="${1:-$BATS_TEST_DIRNAME/../skills/subagent-dispatch/references/offload-scenarios.md}"
  python3 - "$source_path" <<'PY'
import re
import sys
from pathlib import Path
source_path = Path(sys.argv[1])
try:
    lines = source_path.read_text(encoding="utf-8").splitlines()
except (OSError, UnicodeError) as error:
    print(f"提取失败：无法读取 {source_path}: {error}", file=sys.stderr)
    raise SystemExit(1)
heading = "## 反模式（不该卸载 / 卸载判断不宜机械）"
headings = [index for index, line in enumerate(lines) if line.strip() == heading]
if len(headings) != 1:
    print(f"提取失败：目标章节应唯一，实际 {len(headings)} 个", file=sys.stderr)
    raise SystemExit(1)
chapter_start = headings[0] + 1
chapter_end = next(
    (index for index in range(chapter_start, len(lines))
     if re.match(r"^##(?:\s|$)", lines[index])),
    len(lines),
)
chapter = lines[chapter_start:chapter_end]
if not any(line.strip() for line in chapter):
    print("提取失败：目标章节为空", file=sys.stderr)
    raise SystemExit(1)
marker = re.compile(r"^[-*+] +\*\*再派停止条件\*\*(?:\s|：|:|$)")
bullets = [index for index, line in enumerate(chapter) if marker.match(line)]
if len(bullets) != 1:
    print(f"提取失败：目标顶层 bullet 应唯一，实际 {len(bullets)} 个", file=sys.stderr)
    raise SystemExit(1)
target_index = bullets[0]
target_line = chapter[target_index]
first_body = marker.match(target_line).group(0)
if not target_line[len(first_body):].strip(" ：:"):
    print("提取失败：目标再派停止条件 bullet 为空", file=sys.stderr)
    raise SystemExit(1)
selected = [target_line.strip()]
for continuation in chapter[target_index + 1:]:
    if not continuation.strip() or not continuation[0].isspace():
        break
    selected.append(continuation.strip())
print("\n".join(selected))
PY
}

# 为每个用例创建专属临时目录。
# 参数：无。返回：目录创建成功时返回 0，否则返回 mktemp 的状态码。
setup() {
  fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/skill-contract.XXXXXX")"
}

# 仅删除 setup 创建的临时目录。
# 参数：无。返回：目录不存在或删除成功时返回 0。
teardown() {
  if [ -n "${fixture_dir:-}" ] && [ -d "$fixture_dir" ]; then
    rm -rf "$fixture_dir"
  fi
}

# 断言交付 bullet 包含稳定语义片段，并在失败时说明缺失内容。
# 参数：文本、必须出现的片段、失败原因。返回：命中时 0，否则 1。
assert_contains() {
  local text="$1" phrase="$2" reason="$3"
  case "$text" in
    *"$phrase"*) return 0 ;;
  esac
  printf '断言失败：%s；缺少“%s”\n' "$reason" "$phrase" >&2
  return 1
}

# 断言文本不包含指定片段，并在失败时说明不应出现的内容。
# 参数：文本、禁止出现的片段、失败原因。返回：未命中时 0，否则 1。
assert_not_contains() {
  local text="$1" phrase="$2" reason="$3"
  case "$text" in
    *"$phrase"*)
      printf '断言失败：%s；意外包含“%s”\n' "$reason" "$phrase" >&2
      return 1
      ;;
  esac
  return 0
}

@test "再派停止条件要求完整前置条件与至少一项价值依据" {
  run extract_stop_condition
  if [ "$status" -ne 0 ]; then
    printf '用例准备失败：%s\n' "$output" >&2
    return 1
  fi
  assert_contains "$output" "已取得足以支持当前裁决的完整定稿后" "缺少完整裁决支持前置条件"
  assert_contains "$output" "额外即席派发应满足以下至少一项" "缺少额外派发价值门槛"
  assert_contains "$output" "填补一个明确的事实缺口" "缺少事实缺口价值条件"
  assert_contains "$output" "引入一个可能改变当前裁决的独立评审维度" "缺少独立评审价值条件"
  assert_contains "$output" "两项均不满足时，主上下文应直接裁决或收工" "缺少两项均不满足时停止的边界"
}

@test "再派停止条件排除伪独立并保留专域边界" {
  run extract_stop_condition
  if [ "$status" -ne 0 ]; then
    printf '用例准备失败：%s\n' "$output" >&2
    return 1
  fi
  assert_contains "$output" "独立性按待回答的问题、验收标准或证据源判定" "缺少独立性判定依据"
  assert_contains "$output" "仅更换 agent、模型或复述同一问题不构成独立维度" "缺少伪独立排除规则"
  assert_contains "$output" "满足任一项只表示重新套用既有卸载判断，不表示必须派发" "缺少非强制派发边界"
  assert_contains "$output" "本条只约束日常非 team-ops 的额外即席派发" "缺少日常派发边界"
  assert_contains "$output" "首次派发及 PR/plan review 的专域增量规则保持不变" "缺少首次派发与专域增量边界"
  assert_contains "$output" "本条不阻止下一件不同工作的首次派发" "缺少下一件不同工作的首次派发边界"
  assert_contains "$output" "评审定稿后的落地不属于再派" "缺少评审定稿落地边界"
}

@test "再派停止条件提取连续缩进续行并截断普通段落" {
  local fixture="$fixture_dir/offload-fixture.md"
  cat > "$fixture" <<'EOF'
## 反模式（不该卸载 / 卸载判断不宜机械）
- **再派停止条件**：保留首行。
  第一条缩进续行。
  第二条缩进续行。

普通段落不属于 bullet。
EOF

  run extract_stop_condition "$fixture"
  if [ "$status" -ne 0 ]; then
    printf '用例准备失败：%s\n' "$output" >&2
    return 1
  fi
  assert_contains "$output" "- **再派停止条件**：保留首行。" "缺少目标 bullet 首行"
  assert_contains "$output" "第一条缩进续行。" "缺少第一条缩进续行"
  assert_contains "$output" "第二条缩进续行。" "缺少第二条缩进续行"
  assert_not_contains "$output" "普通段落不属于 bullet。" "错误收集未缩进普通段落"
}
