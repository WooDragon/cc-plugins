#!/usr/bin/env bats
#
# grok-review.sh 单元测试。
#
# 策略：不碰网络，只 stub grok/gh/uuidgen 三个外部命令（打印固定输出、把收到的参数
# 记到临时文件供断言）；git 用真实二进制 + 每个测试自己的临时仓库，因为 diff/untracked
# 语义靠真实 git 验证远比重新实现一份 git diff 的 stub 更可靠。
#
# 覆盖 plan 测试策略 A 组 6 类：参数解析 / 状态文件 / 路径构造 / Fail Fast / 目录权限 / GC。

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/skills/pr-review/scripts/grok-review.sh"

# 从 grok stub 的参数记录文件里取某个 flag 后面紧跟的值（记录格式：一行一个 arg）
get_arg_value() {
  awk -v flag="$2" '$0==flag{getline; print; exit}' "$1"
}

get_perm() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

setup() {
  WORK="$BATS_TEST_TMPDIR"
  mkdir -p "$WORK/bin" "$WORK/home" "$WORK/repo" "$WORK/nongit"

  cat > "$WORK/bin/grok" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$GROK_ARGS_LOG"
prev=""
promptfile=""
for a in "$@"; do
  if [[ "$prev" == "--prompt-file" ]]; then promptfile="$a"; fi
  prev="$a"
done
if [[ -n "$promptfile" ]]; then cp "$promptfile" "$GROK_PROMPT_CAPTURE"; fi
case "${GROK_STUB_MODE:-success}" in
  fail_session_invalid)
    echo "Error: Failed to restore session from remote: fetching session record: session get failed: 404 Not Found" >&2
    exit 1 ;;
  fail_session_invalid_variant)
    echo "Error: session get failed: totally different upstream wording, no 'restore' word here" >&2
    exit 1 ;;
  fail_network)
    echo "Error: 503 Service Unavailable" >&2
    exit 1 ;;
  *)
    echo "OK grok stub review" ;;
esac
EOF
  chmod +x "$WORK/bin/grok"

  cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_CALLS_LOG"
case "$1 $2" in
  "pr view")
    if [[ "$*" == *headRefOid* ]]; then
      # 默认返回当前 git HEAD（→ 与 BASE_SHA 一致、不打假警告）；GH_STUB_PR_HEAD 可覆盖以测 HEAD≠PRhead；
      # GH_STUB_PR_HEAD_EMPTY=1 返回空串以测"取不到 PR head"的 fail-open 告警
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

  # 计数器式 uuidgen：每次调用返回递增的 TESTUUID-N，用于断言"无参再次调用覆写为新 SID"
  cat > "$WORK/bin/uuidgen" <<'EOF'
#!/usr/bin/env bash
n=0
[[ -f "$UUID_COUNTER_FILE" ]] && n=$(cat "$UUID_COUNTER_FILE")
n=$((n+1))
echo "$n" > "$UUID_COUNTER_FILE"
echo "TESTUUID-$n"
EOF
  chmod +x "$WORK/bin/uuidgen"

  export PATH="$WORK/bin:$PATH"
  export HOME="$WORK/home"
  export XDG_STATE_HOME="$WORK/home/.local/state"
  export GROK_ARGS_LOG="$WORK/grok_args.log"
  export GROK_PROMPT_CAPTURE="$WORK/grok_prompt.txt"
  export GH_CALLS_LOG="$WORK/gh_calls.log"
  export UUID_COUNTER_FILE="$WORK/uuid_counter"
  # 隔离宿主环境：断言默认 EFFORT=high/MODEL=grok-4.5 的用例不能吃宿主 export 的 GROK_EFFORT/GROK_MODEL
  # （这工具的用户天天 export GROK_EFFORT=low/high；不 unset 会让默认值断言随宿主环境飘红）
  unset GROK_STUB_MODE GROK_EFFORT GROK_MODEL GH_STUB_PR_HEAD GH_STUB_PR_HEAD_EMPTY GH_STUB_REPO 2>/dev/null || true

  STATE_DIR="$WORK/home/.local/state/pr-review"
  STATE_FILE_42="$STATE_DIR/testowner__testname__42.session"

  cd "$WORK/repo"
  git init -q
  git config user.email test@test.com
  git config user.name test
  echo "hello" > a.txt
  git add a.txt
  git commit -qm init
}

# ---------- 1. 参数解析 ----------

@test "参数解析: --followup 缺值报错" {
  run bash "$SCRIPT" 42 --followup
  [ "$status" -ne 0 ]
  [[ "$output" == *"--followup 缺少值"* ]]
}

@test "参数解析: --since 缺值报错" {
  run bash "$SCRIPT" 42 --followup "x" --since
  [ "$status" -ne 0 ]
  [[ "$output" == *"--since 缺少值"* ]]
}

@test "参数解析: --session 缺值报错" {
  run bash "$SCRIPT" 42 --followup "x" --session
  [ "$status" -ne 0 ]
  [[ "$output" == *"--session 缺少值"* ]]
}

@test "参数解析: PR 非数字报错（复用现有校验）" {
  run bash "$SCRIPT" abc
  [ "$status" -ne 0 ]
  [[ "$output" == *"PR 必须是数字"* ]]
}

@test "参数解析: --session 显式覆盖优先级高于状态文件" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  run bash "$SCRIPT" 42 --followup "x" --session "OVERRIDE-SID"
  [ "$status" -eq 0 ]
  [ "$(get_arg_value "$GROK_ARGS_LOG" "-r")" = "OVERRIDE-SID" ]
}

# ---------- 2. 状态文件 ----------

@test "状态文件: 首轮写出 .session 且含 SID/MODEL/EFFORT/CWD" {
  run bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  [ -f "$STATE_FILE_42" ]
  grep -qx 'SID=TESTUUID-1' "$STATE_FILE_42"
  grep -qx 'MODEL=grok-4.6' "$STATE_FILE_42"
  grep -qx 'EFFORT=high' "$STATE_FILE_42"
  grep -q '^CWD=' "$STATE_FILE_42"
}

@test "状态文件: 目录权限 700" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  [ "$(get_perm "$STATE_DIR")" = "700" ]
}

@test "状态文件: 无参再次调用覆写为新 SID" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  first_sid=$(sed -n 's/^SID=//p' "$STATE_FILE_42")
  bash "$SCRIPT" 42 >/dev/null 2>&1
  second_sid=$(sed -n 's/^SID=//p' "$STATE_FILE_42")
  [ "$first_sid" = "TESTUUID-1" ]
  [ "$second_sid" = "TESTUUID-2" ]
  [ "$first_sid" != "$second_sid" ]
}

@test "状态文件: 复核轮读回同一 SID" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  run bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -eq 0 ]
  [ "$(get_arg_value "$GROK_ARGS_LOG" "-r")" = "TESTUUID-1" ]
}

@test "状态文件: 含等号的 CWD 值 sed 前缀提取不截断" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  sed -i.bak 's|^CWD=.*|CWD=/some/path=weird/value|' "$STATE_FILE_42"
  cd "$WORK/nongit"
  run bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -eq 0 ]
  [ "$(get_arg_value "$GROK_ARGS_LOG" "--cwd")" = "/some/path=weird/value" ]
}

# ---------- 3. 路径构造 ----------

@test "路径构造: 首轮用 -s 建会话并发送全量 diff" {
  run bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  [ "$(get_arg_value "$GROK_ARGS_LOG" "-s")" = "TESTUUID-1" ]
  grep -q "BEGIN UNTRUSTED_.*DIFF" "$GROK_PROMPT_CAPTURE"
  grep -q '+new' "$GROK_PROMPT_CAPTURE"
}

@test "路径构造: 复核轮用 -r 续接，prompt 含 followup+增量 diff 但不含首轮全量 diff" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  echo "changed" > a.txt
  run bash "$SCRIPT" 42 --followup "请复核这处"
  [ "$status" -eq 0 ]
  [ "$(get_arg_value "$GROK_ARGS_LOG" "-r")" = "TESTUUID-1" ]
  grep -q "请复核这处" "$GROK_PROMPT_CAPTURE"
  grep -q "INCREMENTAL DIFF" "$GROK_PROMPT_CAPTURE"
  grep -q "changed" "$GROK_PROMPT_CAPTURE"
  ! grep -q "diff --git a/x b/x" "$GROK_PROMPT_CAPTURE"
}

@test "路径构造: 复核轮增量 diff 含 untracked 新文件（--no-index 标准 diff 格式）" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  echo "brand new content" > newfile.txt
  run bash "$SCRIPT" 42 --followup "看下新文件"
  [ "$status" -eq 0 ]
  grep -q "new file mode" "$GROK_PROMPT_CAPTURE"
  grep -q "brand new content" "$GROK_PROMPT_CAPTURE"
}

@test "路径构造: untracked 含空格文件名不断裂" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  echo "space content" > "b new.txt"
  run bash "$SCRIPT" 42 --followup "看下新文件"
  [ "$status" -eq 0 ]
  grep -q "b new.txt" "$GROK_PROMPT_CAPTURE"
  grep -q "space content" "$GROK_PROMPT_CAPTURE"
}

@test "路径构造: --since <ref> 取指定 ref 到工作区的增量 diff" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  git tag basetag
  echo "line2" >> a.txt
  git commit -qam "second commit"
  run bash "$SCRIPT" 42 --followup "复核" --since basetag
  [ "$status" -eq 0 ]
  grep -q "line2" "$GROK_PROMPT_CAPTURE"
}

@test "路径构造: 工作区干净且无 --since 时增量为空，仅发 followup 文本" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  run bash "$SCRIPT" 42 --followup "工作区干净的复核"
  [ "$status" -eq 0 ]
  grep -q "工作区干净的复核" "$GROK_PROMPT_CAPTURE"
  ! grep -q "INCREMENTAL DIFF" "$GROK_PROMPT_CAPTURE"
  [[ "$output" == *"增量 diff 为空"* ]]
}

# ---------- 4. Fail Fast 三分支 ----------

@test "Fail Fast: 会话失效变体文案仍被宽松正则命中，报错退出且不建新 session" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  before_sid=$(sed -n 's/^SID=//p' "$STATE_FILE_42")
  export GROK_STUB_MODE=fail_session_invalid_variant
  run bash "$SCRIPT" 42 --followup "复核"
  unset GROK_STUB_MODE
  [ "$status" -ne 0 ]
  [[ "$output" == *"PR #42 的 session 已失效/丢失"* ]]
  after_sid=$(sed -n 's/^SID=//p' "$STATE_FILE_42")
  [ "$before_sid" = "$after_sid" ]
}

@test "Fail Fast: 确切实测 stderr 文案（T0 常量）命中失效正则" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  export GROK_STUB_MODE=fail_session_invalid
  run bash "$SCRIPT" 42 --followup "复核"
  unset GROK_STUB_MODE
  [ "$status" -ne 0 ]
  [[ "$output" == *"PR #42 的 session 已失效/丢失"* ]]
}

@test "Fail Fast: 网络/服务错误(503)透传，不误判为失效、不重试" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  export GROK_STUB_MODE=fail_network
  run bash "$SCRIPT" 42 --followup "复核"
  unset GROK_STUB_MODE
  [ "$status" -ne 0 ]
  [[ "$output" != *"session 已失效"* ]]
  [[ "$output" == *"503"* ]]
}

@test "Fail Fast: 无 state 文件时直接报错退出，不跑 grok -r \"\"" {
  run bash "$SCRIPT" 12345 --followup "复核"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PR #12345 无活跃 session"* ]]
  [ ! -f "$GROK_ARGS_LOG" ]
}

# ---------- 5. GC ----------

@test "GC: 首轮写 state 前清理 mtime+30 天前的旧 session 文件" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  old_file="$STATE_DIR/old__repo__1.session"
  touch -t 202001010000 "$old_file"
  [ -f "$old_file" ]
  bash "$SCRIPT" 42 >/dev/null 2>&1
  [ ! -f "$old_file" ]
  [ -f "$STATE_FILE_42" ]
}

# ---------- 向后兼容 ----------

@test "向后兼容: 老用法 grok-review.sh <PR> 无 --followup 时正常出评审" {
  run bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK grok stub review"* ]]
}


# ---------- model/effort 一致性（复核轮沿用首轮，flag 优先）----------

@test "model/effort 一致: 复核轮不带 --effort 时沿用首轮 EFFORT(low)" {
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  printf 'SID=SID-EFF\nMODEL=grok-4.5\nEFFORT=low\nCWD=%s\nCREATED=1\n' "$(git -C "$WORK/repo" rev-parse --show-toplevel)" > "$STATE_FILE_42"
  run env -u GROK_EFFORT bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -eq 0 ]
  grep -qx -- 'low' "$GROK_ARGS_LOG"
  ! grep -qx -- 'high' "$GROK_ARGS_LOG"
}

@test "model/effort 一致: 复核轮显式 --effort 覆盖 state" {
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  printf 'SID=SID-EFF2\nMODEL=grok-4.5\nEFFORT=low\nCWD=%s\nCREATED=1\n' "$(git -C "$WORK/repo" rev-parse --show-toplevel)" > "$STATE_FILE_42"
  run bash "$SCRIPT" 42 --followup "复核" --effort high
  [ "$status" -eq 0 ]
  grep -qx -- 'high' "$GROK_ARGS_LOG"
  ! grep -qx -- 'low' "$GROK_ARGS_LOG"
}

@test "model/effort 一致: 复核轮不带 --model 时沿用首轮 MODEL" {
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  printf 'SID=SID-M\nMODEL=grok-custom-x\nEFFORT=high\nCWD=%s\nCREATED=1\n' "$(git -C "$WORK/repo" rev-parse --show-toplevel)" > "$STATE_FILE_42"
  run env -u GROK_MODEL bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -eq 0 ]
  grep -qx -- 'grok-custom-x' "$GROK_ARGS_LOG"
}

@test "model/effort 一致: 复核轮显式 --model 覆盖 state" {
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  printf 'SID=SID-M2\nMODEL=grok-state-model\nEFFORT=high\nCWD=%s\nCREATED=1\n' "$(git -C "$WORK/repo" rev-parse --show-toplevel)" > "$STATE_FILE_42"
  run bash "$SCRIPT" 42 --followup "复核" --model grok-cli-model
  [ "$status" -eq 0 ]
  grep -qx -- 'grok-cli-model' "$GROK_ARGS_LOG"
  ! grep -qx -- 'grok-state-model' "$GROK_ARGS_LOG"
}

@test "model/effort 一致: 复核轮读回非法 state EFFORT 报错退出" {
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  printf 'SID=SID-BAD\nMODEL=grok-4.5\nEFFORT=bogus\nCWD=\nCREATED=1\n' > "$STATE_FILE_42"
  run env -u GROK_EFFORT bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -ne 0 ]
  [[ "$output" == *"非法 effort"* ]]
}

@test "model/effort 一致: 复核轮 model+effort 同时沿用首轮" {
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  printf 'SID=SID-BOTH\nMODEL=grok-combo\nEFFORT=medium\nCWD=%s\nCREATED=1\n' "$(git -C "$WORK/repo" rev-parse --show-toplevel)" > "$STATE_FILE_42"
  run env -u GROK_MODEL -u GROK_EFFORT bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -eq 0 ]
  grep -qx -- 'grok-combo' "$GROK_ARGS_LOG"
  grep -qx -- 'medium' "$GROK_ARGS_LOG"
}


# ---------- 6. #96 复评加固：参数误用护栏 / state 时序 / BASE_SHA 基线 ----------

@test "参数校验: --since 无 --followup 时报错（非静默忽略）" {
  run bash "$SCRIPT" 42 --since basetag
  [ "$status" -ne 0 ]
  [[ "$output" == *"--since 仅在复核轮"* ]]
}

@test "参数校验: --session 无 --followup 时报错" {
  run bash "$SCRIPT" 42 --session SOME-SID
  [ "$status" -ne 0 ]
  [[ "$output" == *"--session 仅在复核轮"* ]]
}

@test "参数校验: --allow-divergent-base 复核轮误用报错（不静默 no-op）" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  run bash "$SCRIPT" 42 --followup "复核" --allow-divergent-base
  [ "$status" -ne 0 ]
  [[ "$output" == *"--allow-divergent-base 仅在首轮"* ]]
}

@test "参数校验: --followup 值以 - 开头报错（防吞掉后续 flag）" {
  run bash "$SCRIPT" 42 --followup --since basetag
  [ "$status" -ne 0 ]
  [[ "$output" == *"--followup 缺少值"* ]]
}

@test "安全: --repo owner/name 含非法字符报错（防 STATE_FILE 路径逃逸）" {
  run bash "$SCRIPT" 42 --repo "ow ner/name"
  [ "$status" -ne 0 ]
  [[ "$output" == *"含非法字符"* ]]
}

@test "state 时序: 首轮 grok 失败不落盘 state（避免误导性 SID）" {
  export GROK_STUB_MODE=fail_network
  run bash "$SCRIPT" 42
  unset GROK_STUB_MODE
  [ "$status" -ne 0 ]
  [ ! -f "$STATE_FILE_42" ]
}

@test "状态文件: 首轮记录 BASE_SHA（CWD 命中时为当前 HEAD）" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  grep -q '^BASE_SHA=' "$STATE_FILE_42"
  expected=$(git rev-parse HEAD)
  grep -qx "BASE_SHA=$expected" "$STATE_FILE_42"
}

@test "BASE_SHA: 复核轮默认基线涵盖已提交的修复（commit 后 followup 增量非空）" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  echo "committed fix line" >> a.txt
  git commit -qam "fix in review round"
  run bash "$SCRIPT" 42 --followup "复核已提交修复"
  [ "$status" -eq 0 ]
  grep -q "INCREMENTAL DIFF" "$GROK_PROMPT_CAPTURE"
  grep -q "committed fix line" "$GROK_PROMPT_CAPTURE"
}

@test "BASE_SHA: 记录存在但对象在当前 clone 不可达时 Fail Fast（不静默降级 git diff HEAD 造假收敛）" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  # 模拟 rebase/GC/换 clone：BASE_SHA 指向当前 clone 不存在的对象
  sed -i.bak 's|^BASE_SHA=.*|BASE_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef|' "$STATE_FILE_42"
  # 已提交一处修复 + 干净树：旧行为会降级 git diff HEAD → 空增量 → grok 复评空 diff → 假 LGTM
  echo "committed fix after base lost" >> a.txt
  git commit -qam "fix after base lost"
  run bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -ne 0 ]
  [[ "$output" == *"对象在当前 clone 不可达"* ]]
  # Fail Fast 发生在组装 prompt 阶段，未发起复核轮 grok -r 调用（args log 仍是首轮的 -s）
  ! grep -qx -- '-r' "$GROK_ARGS_LOG"
}

@test "BASE_SHA: 对象可达但非当前 HEAD 祖先（rebase/切分支）→ Fail Fast" {
  bash "$SCRIPT" 42 >/dev/null 2>&1   # BASE_SHA=当前 HEAD(A)，原分支仍指向 A（A 保持可达）
  # 造一个与 A 无共同历史的新根：HEAD 不再是 A 的后代，但 A 经原分支 ref 仍可 cat-file -e
  git checkout -q --orphan freshroot
  git commit -qm "unrelated root" --allow-empty
  run bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -ne 0 ]
  [[ "$output" == *"不是当前 HEAD 的祖先"* ]]
  ! grep -qx -- '-r' "$GROK_ARGS_LOG"
}

@test "BASE_SHA: state 里形态非法（'-' 前缀等 state 损坏）→ Fail Fast，不交给 git 误解析" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  # 模拟 state 被改写/截断：BASE_SHA 以 '-' 开头会被 git diff/cat-file 当 option 误解析
  sed -i.bak 's|^BASE_SHA=.*|BASE_SHA=-rf|' "$STATE_FILE_42"
  run bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -ne 0 ]
  [[ "$output" == *"BASE_SHA 形态非法"* ]]
  ! grep -qx -- '-r' "$GROK_ARGS_LOG"
}

@test "SID: state 里形态非法（含空格等 state 损坏）→ Fail Fast，不把脏 SID 交给 grok -r" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  sed -i.bak 's|^SID=.*|SID=bad sid|' "$STATE_FILE_42"
  run bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -ne 0 ]
  [[ "$output" == *"非法 SID"* ]]
  ! grep -qx -- '-r' "$GROK_ARGS_LOG"
}


# ---------- 7. 第二轮复评加固：EFFORT 校验时序 / state 文件权限 / --since ref 校验 ----------

@test "model/effort 一致: 非法 GROK_EFFORT 环境不挡合法 state 回放（复核轮以 state 为准）" {
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  printf 'SID=SID-ENV\nMODEL=grok-4.5\nEFFORT=low\nCWD=%s\nBASE_SHA=\nCREATED=1\n' "$(git -C "$WORK/repo" rev-parse --show-toplevel)" > "$STATE_FILE_42"
  run env GROK_EFFORT=bogus bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -eq 0 ]
  grep -qx -- 'low' "$GROK_ARGS_LOG"
}

@test "状态文件: 首轮写出的 .session 文件权限为 600" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  [ "$(get_perm "$STATE_FILE_42")" = "600" ]
}

@test "参数校验: --since 无效 ref 报错（非静默）" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  run bash "$SCRIPT" 42 --followup "复核" --since nonexistent-ref-xyz
  [ "$status" -ne 0 ]
  [[ "$output" == *"--since 无效 ref"* ]]
}


# ---------- 8. 第三轮复评加固：工作区身份钉死 ----------

@test "工作区身份: --repo 正确但当前在别的 git 仓库 → Fail Fast（拒绝对错误代码续 session）" {
  bash "$SCRIPT" 42 >/dev/null 2>&1   # 首轮在 $WORK/repo，state 记录 CWD=$WORK/repo
  mkdir -p "$WORK/other"
  ( cd "$WORK/other" && git init -q && git config user.email t@t.com && git config user.name t \
    && echo x > y.txt && git add y.txt && git commit -qm other )
  cd "$WORK/other"
  run bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -ne 0 ]
  [[ "$output" == *"工作区不一致"* ]]
}


# ---------- 9. 第四轮复评加固：fork 身份钉解耦 / HEAD 基线警告 ----------

@test "工作区身份: fork 场景（首轮 owner 未命中）CWD 仍落盘，他仓 followup 照样 Fail Fast" {
  # 首轮 --repo 指对，但本地 gh repo view 返回不同 owner（模拟 fork）→ 不传 --cwd，但 CWD 解耦后仍落盘
  GH_STUB_REPO="forkowner forkrepo" bash "$SCRIPT" 42 --repo testowner/testname >/dev/null 2>&1
  grep -qE '^CWD=.+' "$STATE_FILE_42"
  mkdir -p "$WORK/other2"
  ( cd "$WORK/other2" && git init -q && git config user.email t@t.com && git config user.name t \
    && echo z > z.txt && git add z.txt && git commit -qm other2 )
  cd "$WORK/other2"
  run bash "$SCRIPT" 42 --repo testowner/testname --followup "复核"
  [ "$status" -ne 0 ]
  [[ "$output" == *"工作区不一致"* ]]
}

@test "首轮基线: 本地 HEAD 与 PR headRefOid 不一致时默认 Fail Fast（不锚错基线）" {
  run env GH_STUB_PR_HEAD="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" bash "$SCRIPT" 42
  [ "$status" -ne 0 ]
  [[ "$output" == *"与 PR #42 head"* ]]
  [[ "$output" == *"gh pr checkout"* ]]
  [ ! -f "$STATE_FILE_42" ]   # 未落盘错误基线的 session
}

@test "首轮基线: --allow-divergent-base 放行 HEAD≠PRhead（降级为警告，正常建 session）" {
  run env GH_STUB_PR_HEAD="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" bash "$SCRIPT" 42 --allow-divergent-base
  [ "$status" -eq 0 ]
  [[ "$output" == *"--allow-divergent-base 已放行"* ]]
  [ -f "$STATE_FILE_42" ]
}

@test "首轮基线: 本地 HEAD 与 PR headRefOid 一致时不打警告" {
  run bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  [[ "$output" != *"与 PR #42 head"* ]]
}


# ---------- 10. 第五轮复评加固：--session 无 state 不造空文件 ----------

@test "state 卫生: --session 覆盖且无 state 文件时不 touch 造 0 字节空文件" {
  run bash "$SCRIPT" 42 --followup "复核" --session "EXPLICIT-SID"
  [ "$status" -eq 0 ]
  [ "$(get_arg_value "$GROK_ARGS_LOG" "-r")" = "EXPLICIT-SID" ]
  [ ! -f "$STATE_FILE_42" ]
}


# ---------- 11. 第六轮复评加固：无工作区锚点的 session（首轮在非 git 目录建立）----------

@test "工作区身份: 首轮在非 git 目录建 session（CWD 空）→ 复核轮在任意仓库默认 Fail Fast" {
  cd "$WORK/nongit"
  bash "$SCRIPT" 42 --repo testowner/testname >/dev/null 2>&1
  grep -qx 'CWD=' "$STATE_FILE_42"   # 确认 CWD 锚点为空
  # 复核轮身处任意真实 git 仓库——无锚点，拒绝把该仓 diff 当作"本轮修复"续接
  cd "$WORK/repo"
  run bash "$SCRIPT" 42 --repo testowner/testname --followup "复核"
  [ "$status" -ne 0 ]
  [[ "$output" == *"无工作区锚点"* ]]
  ! grep -qx -- '-r' "$GROK_ARGS_LOG"
}

@test "工作区身份: 无锚点 session 显式 --session 视为知情放行（仅告警，不 Fail Fast）" {
  cd "$WORK/nongit"
  bash "$SCRIPT" 42 --repo testowner/testname >/dev/null 2>&1
  sid=$(sed -n 's/^SID=//p' "$STATE_FILE_42")
  cd "$WORK/repo"
  run bash "$SCRIPT" 42 --repo testowner/testname --followup "复核" --session "$sid"
  [ "$status" -eq 0 ]
  [[ "$output" == *"无工作区锚点"* ]]
  [ "$(get_arg_value "$GROK_ARGS_LOG" "-r")" = "$sid" ]
}


# ---------- 12. 第八轮复评加固：session 覆写脚枪 / untracked 敏感文件泄露 / PR head 取不到 ----------

@test "session 卫生: 无参重跑首轮覆写活跃 session 时大字警告（防误触脚枪）" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  run bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  [[ "$output" == *"覆写已存在的活跃 session"* ]]
  [[ "$output" == *"--followup"* ]]
}

@test "安全: 疑似敏感 untracked 文件默认跳过、不上送 API（.env/*.pem），非敏感仍纳入" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  printf 'SECRET=topsecretvalue\n' > .env
  printf 'PRIVATEKEYMATERIAL\n' > server.pem
  printf 'brand new fix code\n' > realfix.txt
  run bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -eq 0 ]
  [[ "$output" == *"跳过疑似敏感 untracked 文件"* ]]
  ! grep -q "topsecretvalue" "$GROK_PROMPT_CAPTURE"
  ! grep -q "PRIVATEKEYMATERIAL" "$GROK_PROMPT_CAPTURE"
  grep -q "brand new fix code" "$GROK_PROMPT_CAPTURE"
}

@test "安全: 样例文件 .env.example 不被误跳（*.example 例外）" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  printf 'EXAMPLE_KEY=changeme\n' > .env.example
  run bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -eq 0 ]
  grep -q "EXAMPLE_KEY=changeme" "$GROK_PROMPT_CAPTURE"
}

@test "安全: tracked（git add）的敏感文件告警但不静默过滤（用户显式纳入的评审内容）" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  printf 'AWS_SECRET=staged-leak-value\n' > .env
  git add .env
  git commit -qm "stage env in review round"
  run bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tracked 增量含疑似敏感文件"* ]]
  # 告警但不过滤：tracked 是用户显式 git add 的评审内容，脚本不代其决定删改 diff
  grep -q "AWS_SECRET=staged-leak-value" "$GROK_PROMPT_CAPTURE"
}


# ---------- 13. 第十轮复评加固：untracked 体积闸 / 敏感启发式扩面 / state MODEL 校验 ----------

@test "安全: 超大 untracked 文件被跳过（体积闸，防大二进制/构建产物风暴）" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  head -c 300000 /dev/zero | tr '\0' 'A' > big.bin   # >256KB
  printf 'small fix\n' > small.txt
  run bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -eq 0 ]
  [[ "$output" == *"跳过超大 untracked 文件"* ]]
  grep -q "small fix" "$GROK_PROMPT_CAPTURE"
  ! grep -q "AAAA" "$GROK_PROMPT_CAPTURE"
}

@test "安全: 敏感启发式覆盖 .envrc 与大小写不敏感（Secrets.yaml）" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  printf 'export TOKEN=abcsecret\n' > .envrc
  printf 'db_password: hunter2val\n' > Secrets.yaml
  run bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -eq 0 ]
  ! grep -q "abcsecret" "$GROK_PROMPT_CAPTURE"
  ! grep -q "hunter2val" "$GROK_PROMPT_CAPTURE"
}

@test "安全: 敏感启发式覆盖主流命名 *.env 与 *secrets*（config.env / my-secrets.yaml）" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  printf 'API_KEY=prodenvleak\n' > config.env
  printf 'token: mysecretsleak\n' > my-secrets.yaml
  run bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -eq 0 ]
  ! grep -q "prodenvleak" "$GROK_PROMPT_CAPTURE"
  ! grep -q "mysecretsleak" "$GROK_PROMPT_CAPTURE"
}

@test "model/effort 一致: 复核轮读回非法 state MODEL 报错退出" {
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  printf 'SID=SID-BADM\nMODEL=bad model\nEFFORT=high\nCWD=%s\nCREATED=1\n' "$(git -C "$WORK/repo" rev-parse --show-toplevel)" > "$STATE_FILE_42"
  run env -u GROK_MODEL bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -ne 0 ]
  [[ "$output" == *"非法 model"* ]]
}

@test "首轮基线: 取不到 PR head 时告警（fail-open 但不静默跳过护栏）" {
  run env GH_STUB_PR_HEAD_EMPTY=1 bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  [[ "$output" == *"无法获取 PR #42 head"* ]]
}

# ---------- 14. effort 收敛：xhigh 只允许作为旧 state 一次性迁移 ----------

@test "effort: 新 CLI 输入 xhigh 在调用 grok 前被拒绝" {
  run bash "$SCRIPT" 42 --effort xhigh
  [ "$status" -ne 0 ]
  [[ "$output" == *"非法 effort: xhigh"* ]]
  [ ! -f "$GROK_ARGS_LOG" ]
}

@test "effort: 新环境输入 xhigh 在调用 grok 前被拒绝" {
  run env GROK_EFFORT=xhigh bash "$SCRIPT" 42
  [ "$status" -ne 0 ]
  [[ "$output" == *"非法 effort: xhigh"* ]]
  [ ! -f "$GROK_ARGS_LOG" ]
}

@test "effort: 所有有效值精确转发给 grok" {
  for effort in none minimal low medium high; do
    rm -f "$GROK_ARGS_LOG"
    run bash "$SCRIPT" 42 --effort "$effort"
    [ "$status" -eq 0 ]
    [ "$(get_arg_value "$GROK_ARGS_LOG" "--effort")" = "$effort" ]
  done
}

@test "effort: 旧 state xhigh 迁移为 high，保留 SID 和其他字段并设为 600" {
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  cwd=$(git -C "$WORK/repo" rev-parse --show-toplevel)
  printf 'SID=SID-LEGACY\nMODEL=grok-4.5\nEFFORT=xhigh\nCWD=%s\nBASE_SHA=\nCREATED=123\n' "$cwd" > "$STATE_FILE_42"
  chmod 644 "$STATE_FILE_42"
  run env -u GROK_EFFORT bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -eq 0 ]
  [[ "$output" == *"迁移为 high"* ]]
  grep -qx 'SID=SID-LEGACY' "$STATE_FILE_42"
  grep -qx 'MODEL=grok-4.5' "$STATE_FILE_42"
  grep -qx 'EFFORT=high' "$STATE_FILE_42"
  grep -qx "CWD=$cwd" "$STATE_FILE_42"
  grep -qx 'BASE_SHA=' "$STATE_FILE_42"
  grep -qx 'CREATED=123' "$STATE_FILE_42"
  [ "$(get_perm "$STATE_FILE_42")" = "600" ]
  [ "$(get_arg_value "$GROK_ARGS_LOG" "--effort")" = "high" ]
}

@test "effort: 显式有效值优先于旧 state，但仍迁移 xhigh" {
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  printf 'SID=SID-PRECEDENCE\nMODEL=grok-4.5\nEFFORT=xhigh\nCWD=%s\nBASE_SHA=\nCREATED=1\n' "$(git -C "$WORK/repo" rev-parse --show-toplevel)" > "$STATE_FILE_42"
  run bash "$SCRIPT" 42 --followup "复核" --effort medium
  [ "$status" -eq 0 ]
  [[ "$output" == *"迁移为 high"* ]]
  grep -qx 'EFFORT=high' "$STATE_FILE_42"
  [ "$(get_arg_value "$GROK_ARGS_LOG" "--effort")" = "medium" ]
}

@test "effort: 复核轮非显式环境 xhigh 即使 state 合法也在调用 grok 前被拒绝" {
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  printf 'SID=SID-VALID\nMODEL=grok-4.5\nEFFORT=high\nCWD=%s\nBASE_SHA=\nCREATED=1\n' "$(git -C "$WORK/repo" rev-parse --show-toplevel)" > "$STATE_FILE_42"
  run env GROK_EFFORT=xhigh bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -ne 0 ]
  [[ "$output" == *"非法 effort: xhigh"* ]]
  [ ! -f "$GROK_ARGS_LOG" ]
}

# ---------- 15. #212 写保护改用 deny 门禁（不再用 --sandbox） ----------

@test "deny: 首轮传 --deny Write(**) 与 --deny Edit(**)" {
  run bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  grep -qF -- '--deny' "$GROK_ARGS_LOG"
  grep -qxF -- 'Write(**)' "$GROK_ARGS_LOG"
  grep -qxF -- 'Edit(**)' "$GROK_ARGS_LOG"
}

@test "deny: 复核轮传 --deny Write(**) 与 --deny Edit(**)" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  run bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -eq 0 ]
  grep -qF -- '--deny' "$GROK_ARGS_LOG"
  grep -qxF -- 'Write(**)' "$GROK_ARGS_LOG"
  grep -qxF -- 'Edit(**)' "$GROK_ARGS_LOG"
}

@test "deny: 首轮不再传 --sandbox" {
  run bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  ! grep -qF -- '--sandbox' "$GROK_ARGS_LOG"
}

@test "deny: 复核轮不再传 --sandbox" {
  bash "$SCRIPT" 42 >/dev/null 2>&1
  run bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -eq 0 ]
  ! grep -qF -- '--sandbox' "$GROK_ARGS_LOG"
}
