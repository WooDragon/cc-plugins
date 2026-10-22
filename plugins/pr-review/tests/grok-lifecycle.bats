#!/usr/bin/env bats
# These are CLI contract doubles, not evidence that a native Grok hang is fixed.
SCRIPT="$BATS_TEST_DIRNAME/../skills/pr-review/scripts/grok-review.sh"
load test_helper/grok-setup

arg_value() {
  awk -v flag="$1" '$0==flag{getline; print; exit}' "$GROK_ARGS_LOG"
}

seed_state() {
  mkdir -p "$STATE_DIR"
  printf 'SID=OLD-SID\nMODEL=grok-4.6\nEFFORT=high\nCWD=%s\nBASE_SHA=%s\nCREATED=123\n' \
    "$(git rev-parse --show-toplevel)" "$(git rev-parse HEAD)" > "$STATE_FILE_42"
  touch -t 202001010000 "$STATE_FILE_42"
  cp -p "$STATE_FILE_42" "$WORK/original-state"
}

assert_state_unchanged() {
  cmp "$WORK/original-state" "$STATE_FILE_42"
  [ "$(stat -f %m "$STATE_FILE_42")" = "$(stat -f %m "$WORK/original-state")" ]
}

teardown() {
  if [[ -n "${review_pid:-}" ]]; then
    touch "$WORK/release"
    wait "$review_pid" || true
  fi
}

# ready is created AFTER body/markers are emitted; release permits the late result.
start_at_barrier() {
  export GROK_STUB_MODE=lifecycle GROK_STUB_RC="$1"
  shift
  (
    set +e
    bash "$SCRIPT" 42 "$@" > "$WORK/stdout" 2> "$WORK/stderr"
    printf '%s\n' "$?" > "$WORK/returned"
  ) 3>&- &
  review_pid=$!
  local attempt
  for ((attempt=0; attempt<1000; attempt++)); do
    [[ -f "$WORK/ready" || -f "$WORK/returned" ]] && break
    sleep 0.01
  done
  [ -f "$WORK/ready" ]
  [ ! -f "$WORK/returned" ]
  kill -0 "$review_pid"
  [ "$(grep -c '^%%DONE%%$' "$WORK/stdout")" -eq 2 ]
  ! grep -q 'required late result' "$WORK/stdout"
}

finish_barrier() {
  touch "$WORK/release"
  wait "$review_pid"
  review_pid=""
  [ "$(< "$WORK/returned")" -eq "$1" ]
  printf 'review body\n%%%%DONE%%%%\n%%%%DONE%%%%\nrequired late result\n' > "$WORK/expected"
  cmp "$WORK/expected" "$WORK/stdout"
  grep -qx 'native background diagnostic' "$WORK/stderr"
}

@test "lifecycle: 首轮默认4.7，env覆盖，CLI覆盖env并持久记录实际模型" {
  for model in grok-4.7 grok-env grok-cli; do
    case "$model" in
      grok-4.7) run bash "$SCRIPT" 42 ;;
      grok-env) run env GROK_MODEL=grok-env bash "$SCRIPT" 42 ;;
      grok-cli) run env GROK_MODEL=grok-env bash "$SCRIPT" 42 --model grok-cli ;;
    esac
    [ "$status" -eq 0 ]
    [ "$(arg_value -m)" = "$model" ]
    grep -qx "MODEL=$model" "$STATE_FILE_42"
  done
}

@test "lifecycle: 复核旧4.6优先env，显式覆盖非sticky且不迁移旧模型" {
  seed_state
  run env GROK_MODEL=grok-env bash "$SCRIPT" 42 --followup "讨论"
  [ "$status" -eq 0 ]
  [ "$(arg_value -m)" = grok-4.6 ]
  run env GROK_MODEL=grok-env bash "$SCRIPT" 42 --followup "讨论" --model grok-cli
  [ "$status" -eq 0 ]
  [ "$(arg_value -m)" = grok-cli ]
  cmp "$WORK/original-state" "$STATE_FILE_42"
  run bash "$SCRIPT" 42 --followup "讨论"
  [ "$status" -eq 0 ]
  [ "$(arg_value -m)" = grok-4.6 ]
}

@test "lifecycle: 复核缺MODEL才回退env或4.7默认" {
  seed_state
  sed -i.bak '/^MODEL=/d' "$STATE_FILE_42"
  run env GROK_MODEL=grok-env bash "$SCRIPT" 42 --followup "讨论"
  [ "$status" -eq 0 ]
  [ "$(arg_value -m)" = grok-env ]
  run bash "$SCRIPT" 42 --followup "讨论"
  [ "$status" -eq 0 ]
  [ "$(arg_value -m)" = grok-4.7 ]
}

@test "lifecycle: 两轮均传120秒原生等待及最终综合规则，不加禁用子任务旗标" {
  for round in first followup; do
    if [[ "$round" = first ]]; then
      run bash "$SCRIPT" 42
    else
      run bash "$SCRIPT" 42 --followup "讨论"
    fi
    [ "$status" -eq 0 ]
    [ "$(arg_value --background-wait-timeout)" = 120 ]
    [ "$(arg_value --output-format)" = plain ]
    [ -n "$(arg_value --prompt-file)" ]
    [[ "$(arg_value --rules)" == *'最终综合评审'* ]]
    [[ "$(arg_value --rules)" == *'不原样转录内部派发结束标记'* ]]
    ! grep -qxE -- '-p|--no-wait-for-background|--no-subagents' "$GROK_ARGS_LOG"
  done
}

@test "lifecycle: 首轮输出两次标记后仍等待，收齐晚到正文才新建state" {
  start_at_barrier 0
  [ ! -f "$STATE_FILE_42" ]
  finish_barrier 0
  grep -qx 'MODEL=grok-4.7' "$STATE_FILE_42"
}

@test "lifecycle: 首轮重跑输出后仍不覆盖state，真正成功才覆盖" {
  seed_state
  start_at_barrier 0
  assert_state_unchanged
  finish_barrier 0
  grep -qx 'SID=TESTUUID-1' "$STATE_FILE_42"
}

@test "lifecycle: 普通复核输出标记后不touch，真正成功才刷新mtime" {
  seed_state
  start_at_barrier 0 --followup "复核"
  assert_state_unchanged
  finish_barrier 0
  cmp "$WORK/original-state" "$STATE_FILE_42"
  [ "$(stat -f %m "$STATE_FILE_42")" != "$(stat -f %m "$WORK/original-state")" ]
}

@test "lifecycle: 首轮后台超时精确透传73，保留两流且不创建state" {
  start_at_barrier 73
  [ ! -f "$STATE_FILE_42" ]
  finish_barrier 73
  [ ! -f "$STATE_FILE_42" ]
}

@test "lifecycle: 首轮后台超时不覆盖已有state或mtime" {
  seed_state
  start_at_barrier 73
  assert_state_unchanged
  finish_barrier 73
  assert_state_unchanged
}

@test "lifecycle: 普通复核后台超时不刷新state或mtime" {
  seed_state
  start_at_barrier 73 --followup "复核"
  assert_state_unchanged
  finish_barrier 73
  assert_state_unchanged
}

@test "lifecycle: 两轮普通错误精确透传37，不重试、不改state" {
  seed_state
  export GROK_STUB_MODE=fail_arbitrary GROK_STUB_RC=37
  run bash "$SCRIPT" 42
  [ "$status" -eq 37 ]
  [[ "$output" == *'native error detail'* ]]
  assert_state_unchanged
  run bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -eq 37 ]
  [[ "$output" == *'native error detail'* ]]
  assert_state_unchanged
  [ "$(wc -l < "$WORK/grok_calls" | tr -d ' ')" -eq 2 ]
}

@test "lifecycle: 两轮旧CLI不识别参数返回2，不去参重试或改变state" {
  seed_state
  export GROK_STUB_MODE=fail_unknown_option
  run bash "$SCRIPT" 42
  [ "$status" -eq 2 ]
  [[ "$output" == *'unknown option: --background-wait-timeout'* ]]
  assert_state_unchanged
  run bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -eq 2 ]
  [[ "$output" == *'unknown option: --background-wait-timeout'* ]]
  assert_state_unchanged
  [ "$(wc -l < "$WORK/grok_calls" | tr -d ' ')" -eq 2 ]
}

@test "lifecycle: 会话失效保留诊断与退出码，不重建session" {
  seed_state
  export GROK_STUB_MODE=fail_session_invalid GROK_STUB_RC=37
  run bash "$SCRIPT" 42 --followup "复核"
  [ "$status" -eq 37 ]
  [[ "$output" == *'session 已失效/丢失'* ]]
  [[ "$output" == *'404 Not Found'* ]]
  assert_state_unchanged
  [ "$(arg_value -r)" = OLD-SID ]
  [ "$(wc -l < "$WORK/grok_calls" | tr -d ' ')" -eq 1 ]
}

@test "lifecycle: xhigh调用前迁移例外在后台超时后仍保留" {
  seed_state
  sed -i.bak 's/EFFORT=high/EFFORT=xhigh/' "$STATE_FILE_42"
  start_at_barrier 73 --followup "复核"
  grep -qx 'EFFORT=high' "$STATE_FILE_42"
  grep -qx 'MODEL=grok-4.6' "$STATE_FILE_42"
  finish_barrier 73
  grep -qx 'EFFORT=high' "$STATE_FILE_42"
}
