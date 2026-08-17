#!/usr/bin/env bats
#
# claude-review.sh 单元测试。
#
# 策略仿照 grok-review.bats：stub claude/gh/uuidgen 三个外部命令（打印固定输出、把收到的
# 参数记到临时文件供断言）；git 用真实二进制 + 每个测试自己的临时仓库。
#
# 覆盖：首轮 --session-id / 复核轮 --resume、effort 合法值集合（与 grok 刻意不同）、
# model 默认值与环境变量覆盖、隔离旗标齐全（含各旗标的精确值，不只是旗标名存在）+
# unset 内部变量与 ANTHROPIC_*/CLAUDE_AGENT_* 路由变量（防 grok 网关泄漏进 claude 子进程）、
# state 文件 .claude.session 后缀与 grok 的 .session 互不覆盖、会话失效 Fail Fast。

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/skills/pr-review/scripts/claude-review.sh"
GROK_SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/skills/pr-review/scripts/grok-review.sh"

# 从 claude stub 的参数记录文件里取某个 flag 后面紧跟的值（记录格式：一行一个 arg）
get_arg_value() {
  awk -v flag="$2" '$0==flag{getline; print; exit}' "$1"
}

setup() {
  WORK="$BATS_TEST_TMPDIR"
  mkdir -p "$WORK/bin" "$WORK/home" "$WORK/repo" "$WORK/nongit"

  cat > "$WORK/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CLAUDE_ARGS_LOG"
{ env | grep -E '^CLAUDECODE=|^CLAUDE_CODE_ENTRYPOINT=|^ANTHROPIC_API_KEY=|^ANTHROPIC_BASE_URL=|^ANTHROPIC_API_BASE_URL=|^CLAUDE_AGENT_API_BASE_URL=|^ANTHROPIC_AUTH_TOKEN=|^ANTHROPIC_DEFAULT_OPUS_MODEL=|^ANTHROPIC_DEFAULT_SONNET_MODEL=|^ANTHROPIC_DEFAULT_HAIKU_MODEL=|^ANTHROPIC_SMALL_FAST_MODEL='; } > "$CLAUDE_ENV_SNAPSHOT" || true
cat - > "$CLAUDE_PROMPT_CAPTURE"
case "${CLAUDE_STUB_MODE:-success}" in
  fail_session_invalid)
    echo "No conversation found with session ID: bogus-sid" >&2
    exit 1 ;;
  fail_network)
    echo "Error: network unreachable" >&2
    exit 1 ;;
  *)
    echo "OK claude stub review" ;;
esac
EOF
  chmod +x "$WORK/bin/claude"

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

  # 计数器式 uuidgen：每次调用返回递增的 TESTUUID-N
  cat > "$WORK/bin/uuidgen" <<'EOF'
#!/usr/bin/env bash
n=0
[[ -f "$UUID_COUNTER_FILE" ]] && n=$(cat "$UUID_COUNTER_FILE")
n=$((n+1))
echo "$n" > "$UUID_COUNTER_FILE"
echo "TESTUUID-$n"
EOF
  chmod +x "$WORK/bin/uuidgen"

  # grok stub（用于「两后端 state 文件互不覆盖」用例，最简单可跑通即可）
  cat > "$WORK/bin/grok" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$GROK_ARGS_LOG"
echo "OK grok stub review"
EOF
  chmod +x "$WORK/bin/grok"

  export PATH="$WORK/bin:$PATH"
  export HOME="$WORK/home"
  export XDG_STATE_HOME="$WORK/home/.local/state"
  export CLAUDE_ARGS_LOG="$WORK/claude_args.log"
  export CLAUDE_PROMPT_CAPTURE="$WORK/claude_prompt.txt"
  export CLAUDE_ENV_SNAPSHOT="$WORK/claude_env_snapshot.txt"
  export GH_CALLS_LOG="$WORK/gh_calls.log"
  export GROK_ARGS_LOG="$WORK/grok_args.log"
  export UUID_COUNTER_FILE="$WORK/uuid_counter"
  # 隔离宿主环境：断言默认值的用例不能吃宿主 export 的 CLAUDE_REVIEW_EFFORT/CLAUDE_REVIEW_MODEL
  unset CLAUDE_STUB_MODE CLAUDE_REVIEW_EFFORT CLAUDE_REVIEW_MODEL GH_STUB_PR_HEAD GH_STUB_PR_HEAD_EMPTY GH_STUB_REPO 2>/dev/null || true
  # 模拟"正在 Claude Code 会话内部"的场景，验证脚本调用前会 unset 掉这两个变量
  export CLAUDECODE=1
  export CLAUDE_CODE_ENTRYPOINT=cli

  STATE_DIR="$WORK/home/.local/state/pr-review"
  STATE_FILE_42="$STATE_DIR/testowner__testname__42.claude.session"
  GROK_STATE_FILE_42="$STATE_DIR/testowner__testname__42.session"

  cd "$WORK/repo"
  git init -q
  git config user.email test@test.com
  git config user.name test
  echo "hello" > a.txt
  git add a.txt
  git commit -qm init
}

@test "首轮: 用 --session-id 建会话并发送全量 diff" {
  run bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  [ "$(get_arg_value "$CLAUDE_ARGS_LOG" "--session-id")" = "TESTUUID-1" ]
  grep -q "BEGIN UNTRUSTED_.*DIFF" "$CLAUDE_PROMPT_CAPTURE"
  grep -q '+new' "$CLAUDE_PROMPT_CAPTURE"
  [ -f "$STATE_FILE_42" ]
  grep -qx 'SID=TESTUUID-1' "$STATE_FILE_42"
}

@test "复核轮: 用 --resume 续接同一 session" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  run bash "$SCRIPT" 42 --followup "请复核这处"
  [ "$status" -eq 0 ]
  [ "$(get_arg_value "$CLAUDE_ARGS_LOG" "--resume")" = "TESTUUID-1" ]
  grep -q "请复核这处" "$CLAUDE_PROMPT_CAPTURE"
}

@test "effort: 合法值 low/medium/high/xhigh/max 全部通过并精确转发" {
  for effort in low medium high xhigh max; do
    rm -f "$CLAUDE_ARGS_LOG"
    run bash "$SCRIPT" 42 --effort "$effort"
    [ "$status" -eq 0 ]
    [ "$(get_arg_value "$CLAUDE_ARGS_LOG" "--effort")" = "$effort" ]
  done
}

@test "effort: none/minimal 被拒绝（与 grok 合法集合刻意不同）" {
  run bash "$SCRIPT" 42 --effort none
  [ "$status" -ne 0 ]
  [[ "$output" == *"非法 effort"* ]]

  run bash "$SCRIPT" 42 --effort minimal
  [ "$status" -ne 0 ]
  [[ "$output" == *"非法 effort"* ]]
}

@test "model: 默认值为 claude-opus-5" {
  run bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  [ "$(get_arg_value "$CLAUDE_ARGS_LOG" "--model")" = "claude-opus-5" ]
}

@test "model: CLAUDE_REVIEW_MODEL 环境变量可覆盖默认值" {
  run env CLAUDE_REVIEW_MODEL=claude-custom-x bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  [ "$(get_arg_value "$CLAUDE_ARGS_LOG" "--model")" = "claude-custom-x" ]
}

@test "隔离旗标: --tools 后面紧跟空字符串（不是某个具体工具名列表）" {
  run bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  # 存在性断言：先确认 --tools 旗标本身没有整段消失（否则下面的值断言在旗标缺失时同样通过空串，起不到回归防护）
  grep -qx -- '--tools' "$CLAUDE_ARGS_LOG"
  [ "$(get_arg_value "$CLAUDE_ARGS_LOG" "--tools")" = "" ]
}

@test "隔离旗标: --setting-sources 后面紧跟空字符串（不是 local——local 会加载 cwd 下 .claude/settings.local.json 并真实执行其中的 hook，即使 --tools \"\" 已禁用工具调用；已实测复现该漏洞）" {
  run bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  # 存在性断言：同上，先确认 --setting-sources 旗标本身没有整段消失
  grep -qx -- '--setting-sources' "$CLAUDE_ARGS_LOG"
  [ "$(get_arg_value "$CLAUDE_ARGS_LOG" "--setting-sources")" = "" ]
}

@test "隔离旗标: --disable-slash-commands 出现在调用里" {
  run bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  grep -qx -- '--disable-slash-commands' "$CLAUDE_ARGS_LOG"
}

@test "隔离旗标: --no-session-persistence 不出现在调用里（本设计与 plan-review 的 claude engine 的关键差异——加了这个旗标会话不落盘，--resume 完全失效）" {
  run bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  ! grep -qx -- '--no-session-persistence' "$CLAUDE_ARGS_LOG"
}

@test "隔离旗标: 调用前 CLAUDECODE/CLAUDE_CODE_ENTRYPOINT 已被 unset" {
  run bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  [ ! -s "$CLAUDE_ENV_SNAPSHOT" ]
}

@test "安全: 当前会话若经 claude-wrapper.sh 的 grok 分支启动（ANTHROPIC_* 路由变量已注入进程环境），claude -p 子进程不会继承 grok 网关的 BASE_URL/API_KEY/model 路由" {
  export ANTHROPIC_API_KEY="fake-grok-key"
  export ANTHROPIC_BASE_URL="https://fake-grok-gateway.invalid"
  export ANTHROPIC_API_BASE_URL="https://fake-grok-gateway.invalid"
  export CLAUDE_AGENT_API_BASE_URL="https://fake-grok-gateway.invalid"
  export ANTHROPIC_AUTH_TOKEN="fake-grok-token"
  export ANTHROPIC_DEFAULT_OPUS_MODEL="grok/grok-4.6"
  export ANTHROPIC_DEFAULT_SONNET_MODEL="grok/grok-4.6"
  export ANTHROPIC_DEFAULT_HAIKU_MODEL="grok/grok-4.6-mini"
  export ANTHROPIC_SMALL_FAST_MODEL="grok/grok-4.6-mini"
  run bash "$SCRIPT" 42
  unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_API_BASE_URL CLAUDE_AGENT_API_BASE_URL \
    ANTHROPIC_AUTH_TOKEN ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
    ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_SMALL_FAST_MODEL
  [ "$status" -eq 0 ]
  # claude stub 的 env 快照里，这一组变量一个都不该出现——出现即代表 grok 网关泄漏进子进程
  [ ! -s "$CLAUDE_ENV_SNAPSHOT" ]
  # --model 仍是我们自己解析出的 claude-opus-5，未被泄漏的 ANTHROPIC_DEFAULT_OPUS_MODEL 覆盖
  [ "$(get_arg_value "$CLAUDE_ARGS_LOG" "--model")" = "claude-opus-5" ]
}

@test "复核轮隔离旗标: --tools/--setting-sources 在 --resume 路径上同样齐全（防止两份独立维护的旗标行只有首轮那份被测试钉住）" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  rm -f "$CLAUDE_ARGS_LOG"
  run bash "$SCRIPT" 42 --followup "请复核这处"
  [ "$status" -eq 0 ]
  grep -qx -- '--tools' "$CLAUDE_ARGS_LOG"
  [ "$(get_arg_value "$CLAUDE_ARGS_LOG" "--tools")" = "" ]
  grep -qx -- '--setting-sources' "$CLAUDE_ARGS_LOG"
  [ "$(get_arg_value "$CLAUDE_ARGS_LOG" "--setting-sources")" = "" ]
}

@test "复核轮安全: --resume 路径上 claude -p 子进程同样不继承 grok 网关的 ANTHROPIC_*/CLAUDE_AGENT_* 路由变量" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  export ANTHROPIC_API_KEY="fake-grok-key"
  export ANTHROPIC_BASE_URL="https://fake-grok-gateway.invalid"
  export ANTHROPIC_API_BASE_URL="https://fake-grok-gateway.invalid"
  export CLAUDE_AGENT_API_BASE_URL="https://fake-grok-gateway.invalid"
  export ANTHROPIC_AUTH_TOKEN="fake-grok-token"
  export ANTHROPIC_DEFAULT_OPUS_MODEL="grok/grok-4.6"
  export ANTHROPIC_DEFAULT_SONNET_MODEL="grok/grok-4.6"
  export ANTHROPIC_DEFAULT_HAIKU_MODEL="grok/grok-4.6-mini"
  export ANTHROPIC_SMALL_FAST_MODEL="grok/grok-4.6-mini"
  run bash "$SCRIPT" 42 --followup "请复核这处"
  unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_API_BASE_URL CLAUDE_AGENT_API_BASE_URL \
    ANTHROPIC_AUTH_TOKEN ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
    ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_SMALL_FAST_MODEL
  [ "$status" -eq 0 ]
  [ ! -s "$CLAUDE_ENV_SNAPSHOT" ]
  [ "$(get_arg_value "$CLAUDE_ARGS_LOG" "--model")" = "claude-opus-5" ]
}

@test "state 文件: 用 .claude.session 后缀，且与同 PR 的 grok state 文件互不覆盖" {
  # 先跑一次 mock 过的 grok 首轮
  bash "$GROK_SCRIPT" 42 >/dev/null 2>&1
  [ -f "$GROK_STATE_FILE_42" ]
  grep -qx 'SID=TESTUUID-1' "$GROK_STATE_FILE_42"

  # 再跑一次 mock 过的 claude 首轮（uuid 计数器共享，故这次是 TESTUUID-2）
  run bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  [ -f "$STATE_FILE_42" ]
  grep -qx 'SID=TESTUUID-2' "$STATE_FILE_42"

  # 两份文件都在、内容独立、互不覆盖
  [ -f "$GROK_STATE_FILE_42" ]
  [ -f "$STATE_FILE_42" ]
  grep -qx 'SID=TESTUUID-1' "$GROK_STATE_FILE_42"
  grep -qx 'SID=TESTUUID-2' "$STATE_FILE_42"
}

@test "Fail Fast: 会话失效（No conversation found）时报错退出，不产生误导性 state 更新" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  before_sid=$(sed -n 's/^SID=//p' "$STATE_FILE_42")
  export CLAUDE_STUB_MODE=fail_session_invalid
  run bash "$SCRIPT" 42 --followup "复核"
  unset CLAUDE_STUB_MODE
  [ "$status" -ne 0 ]
  [[ "$output" == *"PR #42 的 session 已失效/丢失"* ]]
  after_sid=$(sed -n 's/^SID=//p' "$STATE_FILE_42")
  [ "$before_sid" = "$after_sid" ]
}

@test "Fail Fast: 网络错误透传，不误判为会话失效" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  export CLAUDE_STUB_MODE=fail_network
  run bash "$SCRIPT" 42 --followup "复核"
  unset CLAUDE_STUB_MODE
  [ "$status" -ne 0 ]
  [[ "$output" != *"session 已失效"* ]]
  [[ "$output" == *"network unreachable"* ]]
}

@test "Fail Fast: 无 state 文件时直接报错退出，不跑 claude --resume" {
  run bash "$SCRIPT" 12345 --followup "复核"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PR #12345 无活跃 session"* ]]
  [ ! -f "$CLAUDE_ARGS_LOG" ]
}

@test "参数解析: PR 非数字报错" {
  run bash "$SCRIPT" abc
  [ "$status" -ne 0 ]
  [[ "$output" == *"PR 必须是数字"* ]]
}

@test "身份钉死: claude-review.sh 复用共享 lib 的工作区一致性校验（--repo 正确但当前在别的 git 仓库 → Fail Fast）" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  mkdir -p "$WORK/other"
  ( cd "$WORK/other" && git init -q && git config user.email t@t.com && git config user.name t \
    && echo x > y.txt && git add y.txt && git commit -qm other )
  cd "$WORK/other"
  run bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -ne 0 ]
  [[ "$output" == *"工作区不一致"* ]]
}

@test "身份钉死: 无工作区锚点 session 拒绝续接时，报错文案里的脚本名是 claude-review.sh 而不是 grok-review.sh" {
  cd "$WORK/nongit"
  bash "$SCRIPT" 42 --repo testowner/testname >/dev/null 2>&1
  grep -qx 'CWD=' "$STATE_FILE_42"   # 确认 CWD 锚点为空（首轮在非 git 目录建立）
  cd "$WORK/repo"
  run bash "$SCRIPT" 42 --repo testowner/testname --followup "复核"
  [ "$status" -ne 0 ]
  [[ "$output" == *"无工作区锚点"* ]]
  [[ "$output" == *"claude-review.sh 42"* ]]
  [[ "$output" != *"grok-review.sh"* ]]
}
