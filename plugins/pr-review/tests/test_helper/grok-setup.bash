# Shared real-repo fixture for Grok contract and lifecycle scenarios.
setup() {
  export WORK="$BATS_TEST_TMPDIR"
  unset GROK_STUB_RC 2>/dev/null || true
  mkdir -p "$WORK/bin" "$WORK/home" "$WORK/repo" "$WORK/nongit"

  cat > "$WORK/bin/grok" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$GROK_ARGS_LOG"
printf 'call\n' >> "$WORK/grok_calls"
prev=""
wait_timeout=""
promptfile=""
for a in "$@"; do
  if [[ "$prev" == "--background-wait-timeout" ]]; then wait_timeout="$a"; fi
  if [[ "$prev" == "--prompt-file" ]]; then promptfile="$a"; fi
  prev="$a"
done
if [[ -n "$promptfile" ]]; then cp "$promptfile" "$GROK_PROMPT_CAPTURE"; fi
case "${GROK_STUB_MODE:-success}" in
  lifecycle)
    [[ "$wait_timeout" == 120 ]] || { echo 'missing native wait budget' >&2; exit 64; }
    printf 'review body\n%%%%DONE%%%%\n%%%%DONE%%%%\n'
    touch "$WORK/ready"
    # Handshake, not a simulated 120-second timer. The test releases this stage.
    for ((attempt=0; attempt<1000; attempt++)); do
      [[ -f "$WORK/release" ]] && break
      sleep 0.01
    done
    [[ -f "$WORK/release" ]] || { echo 'test barrier timed out' >&2; exit 98; }
    printf 'required late result\n'
    echo 'native background diagnostic' >&2
    exit "${GROK_STUB_RC:-0}" ;;
  fail_arbitrary)
    echo 'native error detail' >&2
    exit "${GROK_STUB_RC:-37}" ;;
  fail_unknown_option)
    echo 'unknown option: --background-wait-timeout' >&2
    exit 2 ;;
  fail_session_invalid)
    echo "Error: Failed to restore session from remote: fetching session record: session get failed: 404 Not Found" >&2
    exit "${GROK_STUB_RC:-1}" ;;
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
  # 隔离宿主环境：断言默认 EFFORT=high/MODEL=grok-4.7 的用例不能吃宿主 export 的 GROK_EFFORT/GROK_MODEL
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
