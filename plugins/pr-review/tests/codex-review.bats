#!/usr/bin/env bats
#
# codex-review.sh 单元测试。
#
# 策略仿照 claude-review.bats：stub codex/gh 两个外部命令（打印固定输出、把收到的参数记
# 到临时文件供断言）；git 用真实二进制 + 每个测试自己的临时仓库。codex 后端与 grok/claude
# 的关键结构差异——首轮 SID 不是脚本自己生成（不调用 uuidgen），而是从 codex `--json` 输出
# 的 {"type":"thread.started","thread_id":"..."} 里解析出来——故 stub 自己内建一个递增计数器
# 模拟 thread_id 生成，不依赖 uuidgen stub。
#
# 覆盖：首轮建会话并发送全量 diff、复核轮 resume 续接同一 session、effort 合法值集合
# （none/low/medium/high/xhigh/max，与 grok/claude 均不同）+ 非法值拒绝、model 默认值与
# CODEX_REVIEW_MODEL 覆盖、-s read-only 与 --ignore-rules 在首轮/复核轮两条路径均在场、
# .codex.session 与 grok 的 .session、claude 的 .claude.session 互不覆盖、会话失效 Fail Fast、
# 网络错误透传不误判、无 state 文件报错不跑 resume、PR 非数字报错、工作区身份钉死（脚本名
# 断言为 codex-review.sh）。

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/skills/pr-review/scripts/codex-review.sh"
GROK_SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/skills/pr-review/scripts/grok-review.sh"
CLAUDE_SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/skills/pr-review/scripts/claude-review.sh"

# 从 codex stub 的参数记录文件里取某个 flag 后面紧跟的值（记录格式：一行一个 arg）
get_arg_value() {
  awk -v flag="$2" '$0==flag{getline; print; exit}' "$1"
}

setup() {
  WORK="$BATS_TEST_TMPDIR"
  mkdir -p "$WORK/bin" "$WORK/home" "$WORK/repo" "$WORK/nongit"

  # codex stub：不消费任何 uuidgen——thread_id 由 stub 自己维护的计数器生成，模拟真实 codex
  # `--json` 首行输出 {"type":"thread.started","thread_id":"..."}（本机 codex-cli 0.147.0
  # 实测确认的真实契约，见 codex-review.sh 文件头注释）。
  cat > "$WORK/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CODEX_ARGS_LOG"

MODE="first"
OUT_FILE=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "-o" ]]; then OUT_FILE="$a"; fi
  if [[ "$a" == "resume" ]]; then MODE="resume"; fi
  prev="$a"
done

cat - > "$CODEX_PROMPT_CAPTURE" 2>/dev/null || true

case "${CODEX_STUB_MODE:-success}" in
  fail_session_invalid)
    echo "Error: thread/resume: thread/resume failed: no rollout found for thread id bogus-sid (code -32600)" >&2
    exit 1 ;;
  fail_network)
    echo "Error: network unreachable" >&2
    exit 1 ;;
esac

n=0
[[ -f "$THREAD_COUNTER_FILE" ]] && n=$(cat "$THREAD_COUNTER_FILE")
n=$((n+1))
echo "$n" > "$THREAD_COUNTER_FILE"
SID="TESTTHREAD-$n"

if [[ "$MODE" == "first" ]]; then
  echo "{\"type\":\"thread.started\",\"thread_id\":\"$SID\"}"
fi
echo '{"type":"turn.started"}'
echo '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"OK codex stub review"}}'
echo '{"type":"turn.completed","usage":{}}'

if [[ -n "$OUT_FILE" ]]; then
  echo "OK codex stub review" > "$OUT_FILE"
fi
STUB
  chmod +x "$WORK/bin/codex"

  cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_CALLS_LOG"
case "$1 $2" in
  "pr view")
    if [[ "$*" == *headRefOid* ]]; then
      if [[ "${GH_STUB_PR_HEAD_EMPTY:-}" == "1" ]]; then echo ""
      elif [[ -n "${GH_STUB_PR_HEAD:-}" ]]; then echo "$GH_STUB_PR_HEAD"
      else git rev-parse HEAD 2>/dev/null || echo ""; fi
    else
      echo '{"title":"Test PR","body":"Test body"}'
    fi ;;
  "pr diff") printf 'diff --git a/x b/x\n@@ -1 +1 @@\n-old\n+new\n' ;;
  "repo view") echo "${GH_STUB_REPO:-testowner testname}" ;;
  *) echo "gh-stub unhandled: $*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$WORK/bin/gh"

  # 计数器式 uuidgen：grok/claude 两后端首轮生成 SID 用，codex 后端本身不消费它
  cat > "$WORK/bin/uuidgen" <<'EOF'
#!/usr/bin/env bash
n=0
[[ -f "$UUID_COUNTER_FILE" ]] && n=$(cat "$UUID_COUNTER_FILE")
n=$((n+1))
echo "$n" > "$UUID_COUNTER_FILE"
echo "TESTUUID-$n"
EOF
  chmod +x "$WORK/bin/uuidgen"

  # grok/claude stub（仅用于「三后端 state 文件互不覆盖」用例，最简单可跑通即可）
  cat > "$WORK/bin/grok" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$GROK_ARGS_LOG"
echo "OK grok stub review"
EOF
  chmod +x "$WORK/bin/grok"

  cat > "$WORK/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CLAUDE_ARGS_LOG"
cat - > /dev/null
echo "OK claude stub review"
EOF
  chmod +x "$WORK/bin/claude"

  export PATH="$WORK/bin:$PATH"
  export HOME="$WORK/home"
  export XDG_STATE_HOME="$WORK/home/.local/state"
  export CODEX_ARGS_LOG="$WORK/codex_args.log"
  export CODEX_PROMPT_CAPTURE="$WORK/codex_prompt.txt"
  export THREAD_COUNTER_FILE="$WORK/thread_counter"
  export GH_CALLS_LOG="$WORK/gh_calls.log"
  export GROK_ARGS_LOG="$WORK/grok_args.log"
  export CLAUDE_ARGS_LOG="$WORK/claude_args.log"
  export UUID_COUNTER_FILE="$WORK/uuid_counter"
  # 隔离宿主环境：断言默认值的用例不能吃宿主 export 的 CODEX_REVIEW_EFFORT/CODEX_REVIEW_MODEL
  unset CODEX_STUB_MODE CODEX_REVIEW_EFFORT CODEX_REVIEW_MODEL GH_STUB_PR_HEAD GH_STUB_PR_HEAD_EMPTY GH_STUB_REPO 2>/dev/null || true

  STATE_DIR="$WORK/home/.local/state/pr-review"
  STATE_FILE_42="$STATE_DIR/testowner__testname__42.codex.session"
  GROK_STATE_FILE_42="$STATE_DIR/testowner__testname__42.session"
  CLAUDE_STATE_FILE_42="$STATE_DIR/testowner__testname__42.claude.session"

  cd "$WORK/repo"
  git init -q
  git config user.email test@test.com
  git config user.name test
  echo "hello" > a.txt
  git add a.txt
  git commit -qm init
}

@test "首轮: 建会话并发送全量 diff（SID 从 --json thread.started 解析）" {
  run bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  grep -q "BEGIN UNTRUSTED_.*DIFF" "$CODEX_PROMPT_CAPTURE"
  grep -q '+new' "$CODEX_PROMPT_CAPTURE"
  [ -f "$STATE_FILE_42" ]
  grep -qx 'SID=TESTTHREAD-1' "$STATE_FILE_42"
  [[ "$output" == *"OK codex stub review"* ]]
}

@test "复核轮: resume 续接同一 session" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  run bash "$SCRIPT" 42 --followup "请复核这处"
  [ "$status" -eq 0 ]
  grep -qx -- 'resume' "$CODEX_ARGS_LOG"
  [ "$(get_arg_value "$CODEX_ARGS_LOG" "resume")" = "TESTTHREAD-1" ]
  grep -q "请复核这处" "$CODEX_PROMPT_CAPTURE"
}

@test "effort: 合法值 none/low/medium/high/xhigh/max 全部通过并精确转发" {
  for effort in none low medium high xhigh max; do
    rm -f "$CODEX_ARGS_LOG"
    run bash "$SCRIPT" 42 --effort "$effort"
    [ "$status" -eq 0 ]
    [ "$(get_arg_value "$CODEX_ARGS_LOG" "-c")" = "model_reasoning_effort=$effort" ]
  done
}

@test "effort: minimal 被拒绝（codex 合法集合与 grok/claude 均不同——codex 无 minimal）" {
  run bash "$SCRIPT" 42 --effort minimal
  [ "$status" -ne 0 ]
  [[ "$output" == *"非法 effort"* ]]
}

@test "model: 默认值为 gpt-5.6-luna" {
  run bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  [ "$(get_arg_value "$CODEX_ARGS_LOG" "-m")" = "gpt-5.6-luna" ]
}

@test "model: CODEX_REVIEW_MODEL 环境变量可覆盖默认值" {
  run env CODEX_REVIEW_MODEL=codex-custom-x bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  [ "$(get_arg_value "$CODEX_ARGS_LOG" "-m")" = "codex-custom-x" ]
}

@test "沙盒旗标: -s read-only 与 --ignore-rules 在首轮调用里同时在场" {
  run bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  [ "$(get_arg_value "$CODEX_ARGS_LOG" "-s")" = "read-only" ]
  grep -qx -- '--ignore-rules' "$CODEX_ARGS_LOG"
}

@test "沙盒旗标: -s read-only 与 --ignore-rules 在复核轮调用里同样在场（防止只有首轮那份被测试钉住）" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  rm -f "$CODEX_ARGS_LOG"
  run bash "$SCRIPT" 42 --followup "请复核这处"
  [ "$status" -eq 0 ]
  [ "$(get_arg_value "$CODEX_ARGS_LOG" "-s")" = "read-only" ]
  grep -qx -- '--ignore-rules' "$CODEX_ARGS_LOG"
}

@test "state 文件: 用 .codex.session 后缀，与同 PR 的 grok .session、claude .claude.session 三方互不覆盖" {
  bash "$GROK_SCRIPT" 42 >/dev/null 2>&1
  [ -f "$GROK_STATE_FILE_42" ]
  grep -qx 'SID=TESTUUID-1' "$GROK_STATE_FILE_42"

  bash "$CLAUDE_SCRIPT" 42 >/dev/null 2>&1
  [ -f "$CLAUDE_STATE_FILE_42" ]
  grep -qx 'SID=TESTUUID-2' "$CLAUDE_STATE_FILE_42"

  run bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  [ -f "$STATE_FILE_42" ]
  grep -qx 'SID=TESTTHREAD-1' "$STATE_FILE_42"

  # 三份文件都在、内容独立、互不覆盖
  [ -f "$GROK_STATE_FILE_42" ]
  [ -f "$CLAUDE_STATE_FILE_42" ]
  [ -f "$STATE_FILE_42" ]
  grep -qx 'SID=TESTUUID-1' "$GROK_STATE_FILE_42"
  grep -qx 'SID=TESTUUID-2' "$CLAUDE_STATE_FILE_42"
  grep -qx 'SID=TESTTHREAD-1' "$STATE_FILE_42"
}

@test "Fail Fast: 会话失效（no rollout found for thread）时报错退出，不产生误导性 state 更新" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  before_sid=$(sed -n 's/^SID=//p' "$STATE_FILE_42")
  export CODEX_STUB_MODE=fail_session_invalid
  run bash "$SCRIPT" 42 --followup "复核"
  unset CODEX_STUB_MODE
  [ "$status" -ne 0 ]
  [[ "$output" == *"PR #42 的 session 已失效/丢失"* ]]
  after_sid=$(sed -n 's/^SID=//p' "$STATE_FILE_42")
  [ "$before_sid" = "$after_sid" ]
}

@test "Fail Fast: 网络错误透传，不误判为会话失效" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  export CODEX_STUB_MODE=fail_network
  run bash "$SCRIPT" 42 --followup "复核"
  unset CODEX_STUB_MODE
  [ "$status" -ne 0 ]
  [[ "$output" != *"session 已失效"* ]]
  [[ "$output" == *"network unreachable"* ]]
}

@test "Fail Fast: 无 state 文件时直接报错退出，不跑 codex resume" {
  run bash "$SCRIPT" 12345 --followup "复核"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PR #12345 无活跃 session"* ]]
  [ ! -f "$CODEX_ARGS_LOG" ]
}

@test "参数解析: PR 非数字报错" {
  run bash "$SCRIPT" abc
  [ "$status" -ne 0 ]
  [[ "$output" == *"PR 必须是数字"* ]]
}

@test "身份钉死: codex-review.sh 复用共享 lib 的工作区一致性校验（--repo 正确但当前在别的 git 仓库 → Fail Fast，报错脚本名为 codex-review.sh）" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  mkdir -p "$WORK/other"
  ( cd "$WORK/other" && git init -q && git config user.email t@t.com && git config user.name t \
    && echo x > y.txt && git add y.txt && git commit -qm other )
  cd "$WORK/other"
  run bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -ne 0 ]
  [[ "$output" == *"工作区不一致"* ]]
}

@test "身份钉死: 无工作区锚点 session 拒绝续接时，报错文案里的脚本名是 codex-review.sh 而不是 grok-review.sh" {
  cd "$WORK/nongit"
  bash "$SCRIPT" 42 --repo testowner/testname >/dev/null 2>&1
  grep -qx 'CWD=' "$STATE_FILE_42"
  cd "$WORK/repo"
  run bash "$SCRIPT" 42 --repo testowner/testname --followup "复核"
  [ "$status" -ne 0 ]
  [[ "$output" == *"无工作区锚点"* ]]
  [[ "$output" == *"codex-review.sh 42"* ]]
  [[ "$output" != *"grok-review.sh"* ]]
}
