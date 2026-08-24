#!/usr/bin/env bats
#
# pr-review skill 的编排所有权合同测试。
#
# 这些测试直接读取 worktree 内交付的 Markdown。它们按稳定 heading 提取非空 section，
# 防止测试复制文档内容后与真实 skill 漂移，也防止空 section 让负断言假绿。

SKILL="$BATS_TEST_DIRNAME/../skills/pr-review/SKILL.md"
GROK_REFERENCE="$BATS_TEST_DIRNAME/../skills/pr-review/references/grok-review.md"

section() {
  python3 - "$1" "$2" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
heading = sys.argv[2]
lines = path.read_text(encoding="utf-8").splitlines()
pattern = re.compile(r"^(#{1,6})\s+" + re.escape(heading) + r"\s*$")
in_fence = False
matches = []
for index, line in enumerate(lines):
    if line.startswith("```"):
        in_fence = not in_fence
        continue
    match = pattern.match(line)
    if match and not in_fence:
        matches.append((index, len(match.group(1))))
if len(matches) != 1:
    raise SystemExit(f"expected one heading: {heading}; found {len(matches)}")
index, level = matches[0]
in_fence = False
body = []
for candidate in lines[index + 1:]:
    if candidate.startswith("```"):
        in_fence = not in_fence
        body.append(candidate)
        continue
    next_heading = re.match(r"^(#{1,6})\s+", candidate)
    if not in_fence and next_heading and len(next_heading.group(1)) <= level:
        break
    body.append(candidate)
text = "\n".join(body).strip()
if not text:
    raise SystemExit(f"empty section: {heading}")
print(text)
PY
}

without_subsection() {
  python3 - "$1" "$2" <<'PY'
import re
import sys

text, heading = sys.argv[1:]
lines = text.splitlines()
pattern = re.compile(r"^(#{1,6})\s+" + re.escape(heading) + r"\s*$")
in_fence = False
matches = []
for index, line in enumerate(lines):
    if line.startswith("```"):
        in_fence = not in_fence
        continue
    match = pattern.match(line)
    if match and not in_fence:
        matches.append((index, len(match.group(1))))
if len(matches) != 1:
    raise SystemExit(f"expected one subsection: {heading}; found {len(matches)}")
start, level = matches[0]
in_fence = False
end = len(lines)
for index in range(start + 1, len(lines)):
    line = lines[index]
    if line.startswith("```"):
        in_fence = not in_fence
        continue
    match = re.match(r"^(#{1,6})\s+", line)
    if not in_fence and match and len(match.group(1)) <= level:
        end = index
        break
print("\n".join(lines[:start] + lines[end:]).strip())
PY
}

label_rhs() {
  python3 - "$1" "$2" <<'PY'
import re
import sys

text, label = sys.argv[1:]
pattern = re.compile(
    r"^\s*-\s+\*\*" + re.escape(label) + r"\*\*：\s*(?:`([^`]+)`|(\S(?:.*\S)?))\s*$",
    re.MULTILINE,
)
matches = pattern.findall(text)
if len(matches) != 1:
    raise SystemExit(f"expected one non-empty {label} label, found {len(matches)}")
print(matches[0][0] or matches[0][1])
PY
}

assert_absent() {
  [[ "$1" != *"$2"* ]]
}

assert_contains() {
  [[ "$1" == *"$2"* ]]
}

assert_order() {
  python3 - "$1" "${@:2}" <<'PY'
import sys

text = sys.argv[1]
position = -1
for needle in sys.argv[2:]:
    found = text.find(needle, position + 1)
    if found < 0:
        raise SystemExit(f"missing or unordered: {needle}")
    position = found
PY
}

assert_no_child_followup_ownership() {
  python3 - "$1" <<'PY'
import sys

for line_number, line in enumerate(sys.argv[1].splitlines(), start=1):
    if "修复子任务" in line and "--followup" in line:
        raise SystemExit(f"child owns followup at line {line_number}: {line}")
PY
}

assert_no_child_runtime_review_resource() {
  python3 - "$1" <<'PY'
import re
import sys

text = sys.argv[1]
patterns = (
    r"--followup",
    r"run_in_background",
    r"(?m)^\s*(?:REVIEW|LOG)\s*=",
    r"(?:pr-review\.sh|/skills/pr-review/scripts/)",
    r"(?:日志目录|log 目录)",
    r"\.(?:log|err)\b",
    r"review exit/log 回传",
)
for pattern in patterns:
    match = re.search(pattern, text)
    if match:
        line = text.count("\n", 0, match.start()) + 1
        raise SystemExit(f"child runtime review resource at line {line}: {match.group(0)}")
PY
}

@test "修复子任务交付合同隔离评审资源与工单所有权" {
  run section "$SKILL" "修复子任务交付合同"
  [ "$status" -eq 0 ]
  child="$output"

  run label_rhs "$child" "交付动作"
  [ "$status" -eq 0 ]
  [ "$output" = "modify,test,commit:new,push" ]

  run label_rhs "$child" "交付回执"
  [ "$status" -eq 0 ]
  [ "$output" = "sha:immutable" ]

  run label_rhs "$child" "禁止职责"
  [ "$status" -eq 0 ]
  [ "$output" = "review:start,review:wait,review:read,review:decide" ]

  run label_rhs "$child" "禁止资源"
  [ "$status" -eq 0 ]
  [ "$output" = "review:script,review:log-dir,review:exit-log" ]

  run assert_no_child_runtime_review_resource "$child"
  [ "$status" -eq 0 ]

  run section "$SKILL" "执行分工（主线裁决，评审正文落盘）"
  [ "$status" -eq 0 ]
  execution="$output"
  run without_subsection "$execution" "修复子任务交付合同"
  [ "$status" -eq 0 ]
  assert_absent "$output" "工单"
}

@test "主线接管复核按标签顺序消费评审资源" {
  run section "$SKILL" "主线接管复核"
  [ "$status" -eq 0 ]
  main="$output"

  assert_order "$main" \
    "**SHA 核对**" \
    "**SHA 核对失败**" \
    "**主线 background followup**" \
    "**完成通知及 exit/log/head 验收**" \
    "**Read 完整日志裁决**"

  run label_rhs "$main" "SHA 核对"
  [ "$status" -eq 0 ]
  [ "$output" = "sha:all-equal(commit-object,local-head,remote-feature-oid,pr-head-oid)" ]

  run label_rhs "$main" "SHA 核对失败"
  [ "$status" -eq 0 ]
  [ "$output" = "review:stop,git:no-reset,git:no-rebase" ]

  assert_contains "$main" "四者均等于immutable SHA"
  assert_absent "$main" "不要改变行为"

  run label_rhs "$main" "完成通知及 exit/log/head 验收"
  [ "$status" -eq 0 ]
  completion="$output"
  assert_contains "$completion" "exit=0"
  assert_contains "$completion" "日志完整"
  assert_contains "$completion" "HEAD"

  assert_contains "$main" "--followup"
  assert_contains "$main" "后台"
  assert_contains "$main" "Read 完整日志"
}

@test "grok 两轮示例由主线启动 r2 并保持两流分文件" {
  run section "$GROK_REFERENCE" "多轮 session 复用"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  assert_order "$output" \
    "# 第 1 轮：全量评审" \
    '"$REVIEW" 123 > "$LOG/123-r1.log" 2> "$LOG/123-r1.err"' \
    "# 第 2 轮：复核，只发复核指令 + 本轮增量 diff" \
    '"$REVIEW" 123 --followup'
  assert_contains "$output" "主线核对 SHA 后"
  assert_contains "$output" "123-r2.log"
  assert_contains "$output" "123-r2.err"

  run section "$SKILL" '默认路径：`pr-review.sh`'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  default_path="$output"

  run assert_no_child_followup_ownership "$default_path"
  [ "$status" -eq 0 ]
  assert_contains "$default_path" "主线核对 SHA 后，以后台方式启动 r2"
  assert_contains "$default_path" '"$REVIEW" 123 --followup'
  assert_contains "$default_path" '"$LOG/123-r2.log"'
  assert_contains "$default_path" '"$LOG/123-r2.err"'
  assert_contains "$default_path" '> "$LOG/123-r2.log" 2> "$LOG/123-r2.err"'
  assert_contains "$default_path" "子任务新建 commit，且不得 amend 首轮 tip"
  assert_absent "$default_path" "修复请 git commit"
}
