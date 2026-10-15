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

# 读取真实交付文档；指定标题时只返回该顶层章节，避免别节措辞掩盖缺项。
read_contract_text() {
  python3 - "$BATS_TEST_DIRNAME/../$1" "${2:-}" <<'PY'
import re
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8")
heading = sys.argv[2]
if heading:
    lines = text.splitlines()
    matches = [index for index, line in enumerate(lines) if line == heading]
    if len(matches) != 1:
        raise SystemExit(f"目标章节应唯一：{heading}，实际 {len(matches)} 个")
    start = matches[0] + 1
    end = next((index for index in range(start, len(lines))
                if re.match(r"^##(?:\s|$)", lines[index])), len(lines))
    text = "\n".join(lines[start:end])
if not text.strip():
    raise SystemExit("目标契约为空")
print(text)
PY
}

@test "范围围栏以原要求和可读来源说明工作必要性" {
  local text
  text="$(read_contract_text skills/subagent-dispatch/references/dispatch-contract.md '## 铁律②：范围围栏')"
  assert_contains "$text" "不做这件事，原来的哪项完成条件或必要约束会不成立？现有证据为什么回答不了？" "缺少必要性两问原文"
  assert_contains "$text" "每次真实工作委托" "必要性义务未覆盖真实工作委托"
  assert_contains "$text" "原用户授权、适用的既有安全／质量约束，以及这些边界内批准的计划" "原要求来源不完整"
  assert_contains "$text" "接收者可直接读取的来源定位" "缺少可读取的原要求依据"
  assert_contains "$text" "候选任务自己新增的 DoD、报告、测试或 manifest 不能循环证明自身必要" "候选交付可以自证必要"
}

@test "范围围栏区分首次证据缺口与复验证据失效" {
  local text
  text="$(read_contract_text skills/subagent-dispatch/references/dispatch-contract.md '## 铁律②：范围围栏')"
  assert_contains "$text" "首次实现尚无结果证据时，说明尚缺什么即可" "首次工作被要求先造证明"
  assert_contains "$text" "不要求先制作证明材料" "缺少首次证明边界"
  assert_contains "$text" "复验应说明已有证据为何失效或尚未覆盖" "缺少复验依据"
  assert_contains "$text" "换执行者、换报告、非功能表示差异不自动使证据失效" "无关变化可作废已有证据"
}

@test "范围围栏保留原授权内纠错而不授权新增目标" {
  local text
  text="$(read_contract_text skills/subagent-dispatch/references/dispatch-contract.md '## 铁律②：范围围栏')"
  assert_contains "$text" "原授权内必要调查、修复和针对性复测仍属原执行" "必要纠错被新规则阻断"
  assert_contains "$text" "原计划未逐字列出不构成禁止" "计划被误读成逐字白名单"
  assert_contains "$text" "新增目标、权限或独立交付仍走原有停止和裁决路径" "必要性说明扩大了授权"
}

@test "范围围栏允许简短复用并排除通知和递归前审" {
  local text
  text="$(read_contract_text skills/subagent-dispatch/references/dispatch-contract.md '## 铁律②：范围围栏')"
  assert_contains "$text" "短正文或可直接读取的既有引用" "必要性说明强制增加证明文件"
  assert_contains "$text" "纯通知、待命和不改变工作的澄清不是新工作委托" "非工作消息被强制重新派发"
  assert_contains "$text" "审阅委托同样应说明必要性" "审阅委托缺少必要性义务"
  assert_contains "$text" "不递归新增“审阅这次审阅是否必要”的任务" "审阅要求递归造前审"
}

@test "范围围栏只复用已有 redteam 前审且不承诺全路径拦截" {
  local text
  text="$(read_contract_text skills/subagent-dispatch/references/dispatch-contract.md '## 铁律②：范围围栏')"
  assert_contains "$text" "已有 redteam 前审入口" "未接入既有前审"
  assert_contains "$text" "无前审路径保留原执行路径，不新增前审流程" "无前审路径被补造前审"
  assert_contains "$text" "前审批准只覆盖送审对象" "前审批准被扩展到以后派发"
  assert_contains "$text" "后置审阅不计作执行前防护" "后审冒充前审"
  assert_contains "$text" "不保证所有路径都自动加载或执行前阻断" "夸大全路径硬拦截"
}

@test "必要性两问仅在范围围栏维护正文且 skill 入口要求前置阅读" {
  local text skill question
  question='不做这件事，原来的哪项完成条件或必要约束会不成立？现有证据为什么回答不了？'
  text="$(read_contract_text skills/subagent-dispatch/references/dispatch-contract.md)"
  skill="$(read_contract_text skills/subagent-dispatch/SKILL.md)"
  run python3 -c 'import sys; assert sys.argv[1].count(sys.argv[2]) == 1' "$text" "$question"
  [ "$status" -eq 0 ]
  assert_not_contains "$skill" "$question" "skill 入口复制了两问正文"
  assert_contains "${skill%%---$'\n\n'*}" "派发必要性" "description 未暴露必要性入口"
  text="$(read_contract_text skills/subagent-dispatch/SKILL.md '## 四铁律速查')"
  assert_contains "$text" "②范围围栏 | 说明工作必要性与证据缺口" "铁律②摘要未同步"
  assert_contains "$skill" "真实工作委托前应先读取" "缺少派发前置阅读义务"
  assert_contains "$skill" '[references/dispatch-contract.md 的「铁律②：范围围栏」](references/dispatch-contract.md#铁律②范围围栏)' "入口未定位权威章节"
}

@test "Team 只复用必要性内容且授权生命周期仍归 TeamOps" {
  local text
  text="$(read_contract_text skills/subagent-dispatch/SKILL.md '## 与其他机制的边界')"
  assert_contains "$text" "Team 仅复用铁律②的必要性内容" "Team 未复用必要性规则"
  assert_contains "$text" "派发授权、生命周期、回传与阶段仍归 TeamOps" "Team 控制边界丢失"
  assert_contains "$text" "不将 ad-hoc 的整套机制套入 Team" "ad-hoc 机制侵入 Team"
  assert_not_contains "$text" "不适用本 skill" "旧的全盘排除与必要性复用冲突"
}

@test "定稿纪律摘要要求定稿依据而不按篇幅拒绝" {
  local text
  text="$(read_contract_text skills/subagent-dispatch/SKILL.md '## 四铁律速查')"
  assert_contains "$text" "结论须来自已定稿的产物" "摘要缺少定稿前置条件"
  assert_contains "$text" "影响决定的依据和未决事项" "摘要缺少决定所需内容"
  assert_contains "$text" "原始证据可通过可核查的引用提供" "摘要未允许证据引用"
  assert_contains "$text" "中间回传不能替代定稿" "摘要缺少中间回传边界"
  assert_not_contains "$text" "不采信精简/中间回传" "摘要仍按篇幅一刀切拒绝"
}

@test "定稿纪律允许证据直接定位并保留最终消息义务" {
  local text
  text="$(read_contract_text skills/subagent-dispatch/references/dispatch-contract.md '## 铁律④：定稿纪律（己方，主 agent 侧）')"
  assert_contains "$text" "完整性指当前交付的结论、影响决定的依据和未决事项" "完整性未定义为决定所需内容"
  assert_contains "$text" "不要求复制全文日志" "完整性仍可能被读为全文复制"
  assert_contains "$text" "接收者可读的直接定位" "引用缺少可核查的访问边界"
  assert_contains "$text" "关键原文可摘录" "缺少关键原文摘录许可"
  assert_contains "$text" "摘录应保留已证与未证的边界" "摘录可能丢失证据边界"
  assert_contains "$text" "最终报告本身仍应在最终消息中交付" "引用取代了最终消息产物"
  assert_contains "$text" '不应只回“已完成/见文件”' "缺少单行完成说明的排除"
}

@test "定稿纪律正反例区分简短定稿与初步定性" {
  local text
  text="$(read_contract_text skills/subagent-dispatch/references/dispatch-contract.md '## 铁律④：定稿纪律（己方，主 agent 侧）')"
  assert_contains "$text" "4 个 bug 全 CONFIRMED" "原反例的初步定性丢失"
  assert_contains "$text" "3 个 REFUTED" "原反例的最终反证丢失"
  assert_contains "$text" "问题在最终定性缺失，不在篇幅短" "反例仍归罪于篇幅"
  assert_contains "$text" "简短的定稿报告" "正例未允许简短定稿"
  assert_contains "$text" "依据和未决事项" "正例缺少决定所需内容"
  assert_contains "$text" "中间回传不能替代定稿" "缺少不应据初步定性决策的边界"
  assert_not_contains "$text" "不采信精简/中间回传" "规范仍一刀切排除精简回传"
  assert_not_contains "$text" "收到精简/中间回传时" "正例仍将篇幅等同于未定稿"
  assert_not_contains "$text" "先拿到精简回传" "反例仍把篇幅作为失败原因"
}

@test "定稿证据引用不改变标准行与消息文件双载体边界" {
  local text
  text="$(read_contract_text skills/subagent-dispatch/SKILL.md '## 定稿标记：`%%DONE%%`')"
  assert_contains "$text" '> 末尾单独一行输出 `%%DONE%%`。在此之前给出完整报告，含验证矩阵（被验证物路径+实际执行的命令 vs 交付物路径）与未完成项两节。' "标准行被改写"
  assert_contains "$text" "两个载体各管各的、不互相替代" "消息与文件边界丢失"
  assert_contains "$text" "报告与结论**仍须在最终消息里**给出" "最终消息义务丢失"
  assert_contains "$text" "`.wip` 追加写 + 末行 `%%DONE%%`" "WIP 交付模式丢失"
  assert_contains "$text" "promote-wip.sh <target_path>" "WIP 发布入口丢失"
}

@test "README 定稿契约允许引用但不允许仅回完成说明" {
  local text
  text="$(read_contract_text README.md '## The `%%DONE%%` Contract')"
  assert_contains "$text" "Finalization is independent of report length" "README 混淆篇幅与最终性"
  assert_contains "$text" "conclusions, decision-relevant grounds, and unresolved matters" "README 缺少决定所需内容"
  assert_contains "$text" "direct references that the recipient can read and verify" "README 缺少可核查引用许可"
  assert_contains "$text" "not a requirement to copy full logs" "README 将完整性扩大为全文日志"
  assert_contains "$text" "established and unverified claims" "README 摘录丢失已证与未证边界"
  assert_contains "$text" "Intermediate updates cannot replace a finalized deliverable" "README 未排除中间回传替代定稿"
  assert_contains "$text" "The final message must still deliver the report itself" "README 缺少最终消息义务"
  assert_contains "$text" 'not just a "done / see file" status note' "README 未排除完成说明替代产物"
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
