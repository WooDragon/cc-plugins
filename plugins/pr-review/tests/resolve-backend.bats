#!/usr/bin/env bats
#
# resolve-backend.sh 与 pr-review.sh 路由单元测试。
#
# resolve-backend.sh 纯函数式无副作用，直接跑真实脚本、断言 stdout/exit。
# pr-review.sh 路由用例 mock 掉 grok-review.sh/claude-review.sh 为占位可执行脚本。

RESOLVE_SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/skills/pr-review/scripts/resolve-backend.sh"
PR_REVIEW_SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/skills/pr-review/scripts/pr-review.sh"

setup() {
  WORK="$BATS_TEST_TMPDIR"
  unset PR_REVIEW_BACKEND ANTHROPIC_DEFAULT_OPUS_MODEL 2>/dev/null || true
}

# ---------- resolve-backend.sh ----------

@test "resolve-backend: PR_REVIEW_BACKEND=grok 直通" {
  run env PR_REVIEW_BACKEND=grok bash "$RESOLVE_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "grok" ]
}

@test "resolve-backend: PR_REVIEW_BACKEND=claude 直通" {
  run env PR_REVIEW_BACKEND=claude bash "$RESOLVE_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "claude" ]
}

@test "resolve-backend: PR_REVIEW_BACKEND=copilot 直通" {
  run env PR_REVIEW_BACKEND=copilot bash "$RESOLVE_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "copilot" ]
}

@test "resolve-backend: 非法 PR_REVIEW_BACKEND 报错" {
  run env PR_REVIEW_BACKEND=bogus bash "$RESOLVE_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"非法 PR_REVIEW_BACKEND=bogus"* ]]
}

@test "resolve-backend: ANTHROPIC_DEFAULT_OPUS_MODEL=grok/xxx 时自动选 claude" {
  run env ANTHROPIC_DEFAULT_OPUS_MODEL=grok/grok-4.6 bash "$RESOLVE_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "claude" ]
}

@test "resolve-backend: 未设置 ANTHROPIC_DEFAULT_OPUS_MODEL 时默认 grok" {
  run bash "$RESOLVE_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "grok" ]
}

@test "resolve-backend: ANTHROPIC_DEFAULT_OPUS_MODEL 非 grok/* 值时默认 grok" {
  run env ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5 bash "$RESOLVE_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "grok" ]
}

# ---------- pr-review.sh 路由 ----------

setup_backend_stubs() {
  mkdir -p "$WORK/scripts_dir"
  cp "$PR_REVIEW_SCRIPT" "$WORK/scripts_dir/pr-review.sh"
  cp "$RESOLVE_SCRIPT" "$WORK/scripts_dir/resolve-backend.sh"

  cat > "$WORK/scripts_dir/grok-review.sh" <<'EOF'
#!/usr/bin/env bash
echo "GROK_REVIEW_CALLED $*"
EOF
  cat > "$WORK/scripts_dir/claude-review.sh" <<'EOF'
#!/usr/bin/env bash
echo "CLAUDE_REVIEW_CALLED $*"
EOF
  chmod +x "$WORK/scripts_dir/pr-review.sh" "$WORK/scripts_dir/resolve-backend.sh" \
    "$WORK/scripts_dir/grok-review.sh" "$WORK/scripts_dir/claude-review.sh"
}

@test "pr-review.sh: PR_REVIEW_BACKEND=grok 时路由到 grok-review.sh 并透传参数" {
  setup_backend_stubs
  run env PR_REVIEW_BACKEND=grok bash "$WORK/scripts_dir/pr-review.sh" 42 --effort high
  [ "$status" -eq 0 ]
  [[ "$output" == "GROK_REVIEW_CALLED 42 --effort high" ]]
}

@test "pr-review.sh: PR_REVIEW_BACKEND=claude 时路由到 claude-review.sh 并透传参数" {
  setup_backend_stubs
  run env PR_REVIEW_BACKEND=claude bash "$WORK/scripts_dir/pr-review.sh" 42 --followup "复核"
  [ "$status" -eq 0 ]
  [[ "$output" == "CLAUDE_REVIEW_CALLED 42 --followup 复核" ]]
}

@test "pr-review.sh: PR_REVIEW_BACKEND=copilot 时报错并提示改用 copilot-review.sh" {
  setup_backend_stubs
  run env PR_REVIEW_BACKEND=copilot bash "$WORK/scripts_dir/pr-review.sh" 42
  [ "$status" -ne 0 ]
  [[ "$output" == *"copilot-review.sh"* ]]
}
