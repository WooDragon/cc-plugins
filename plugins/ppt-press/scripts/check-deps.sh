#!/usr/bin/env bash
# check-deps.sh — PPT framework dependency checker
# Usage: bash <plugin-root>/scripts/check-deps.sh --scope <init|create|deploy|manage>
# Exit: 0 = all pass, 1 = has failures
set -euo pipefail

SCOPE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$SCOPE" ]]; then
  echo "Usage: check-deps.sh --scope <init|create|deploy|manage>" >&2
  exit 2
fi

FAILURES=0

pass() { printf '[PASS] %s\n' "$1"; }
fail() {
  printf '[FAIL] %s\n' "$1"
  printf '       修复: %s\n' "$2"
  FAILURES=$((FAILURES + 1))
}

check_node() {
  if command -v node >/dev/null 2>&1; then
    NODE_VER=$(node -v | sed 's/^v//')
    NODE_MAJOR=$(echo "$NODE_VER" | cut -d. -f1)
    if [[ "$NODE_MAJOR" -ge 18 ]]; then
      pass "node >= 18 (v${NODE_VER})"
    else
      fail "node >= 18 — 当前 v${NODE_VER}" "安装 Node.js 18+: brew install node"
    fi
  else
    fail "node — 未安装" "brew install node"
  fi
}

check_npm() {
  if command -v npm >/dev/null 2>&1; then
    pass "npm ($(npm -v))"
  else
    fail "npm — 未安装" "brew install node (npm 随 node 附带)"
  fi
}

check_framework() {
  if [[ -f "astro.config.ts" ]]; then
    pass "astro.config.ts 存在"
  else
    fail "astro.config.ts — 不存在（非 PPT 框架项目）" "调用 ppt-init skill 初始化项目"
  fi
  if [[ -f "src/layouts/DeckLayout.astro" ]]; then
    pass "src/layouts/DeckLayout.astro 存在"
  else
    fail "src/layouts/DeckLayout.astro — 不存在" "调用 ppt-init skill 初始化项目"
  fi
}

check_node_modules() {
  if [[ -d "node_modules" ]]; then
    pass "node_modules/ 存在"
  else
    fail "node_modules/ — 不存在" "npm install"
  fi
}

check_deploy_script() {
  if [[ -f "scripts/deploy.sh" ]]; then
    pass "scripts/deploy.sh 存在"
  else
    fail "scripts/deploy.sh — 不存在" "调用 ppt-init skill 并选择启用 deploy 模块"
  fi
}

check_aws_cli() {
  if command -v aws >/dev/null 2>&1; then
    pass "aws CLI ($(aws --version 2>&1 | head -1))"
  else
    fail "aws CLI — 未安装" "brew install awscli"
  fi
}

check_python3() {
  if command -v python3 >/dev/null 2>&1; then
    pass "python3 ($(python3 --version 2>&1))"
  else
    fail "python3 — 未安装" "brew install python3"
  fi
}

check_env_file() {
  if [[ -f ".env" ]] && grep -q 'AWS_PROFILE' .env 2>/dev/null; then
    pass ".env 含 AWS_PROFILE"
  else
    fail ".env 缺失或无 AWS_PROFILE" "创建 .env: echo 'AWS_PROFILE=<your-profile>' > .env"
  fi
}

check_playwright() {
  local PW_DIR
  if [[ "$(uname)" == "Darwin" ]]; then
    PW_DIR="$HOME/Library/Caches/ms-playwright"
  else
    PW_DIR="$HOME/.cache/ms-playwright"
  fi
  if [[ -d "$PW_DIR" ]] && [[ "$(ls -A "$PW_DIR" 2>/dev/null)" ]]; then
    pass "Playwright browsers 已安装"
  else
    fail "Playwright browsers — 未安装" "npx playwright install"
  fi
}

check_list_decks() {
  if [[ -f "scripts/list-decks.js" ]]; then
    pass "scripts/list-decks.js 存在"
  else
    fail "scripts/list-decks.js — 不存在" "调用 ppt-init skill 初始化项目"
  fi
}

# --- Dispatch by scope ---
echo "=== PPT 依赖检查 (scope: ${SCOPE}) ==="
echo ""

case "$SCOPE" in
  init)
    check_node
    check_npm
    ;;
  create)
    check_node
    check_npm
    check_framework
    check_node_modules
    ;;
  deploy)
    check_node
    check_npm
    check_framework
    check_node_modules
    check_deploy_script
    check_aws_cli
    check_python3
    check_env_file
    check_playwright
    ;;
  manage)
    check_node
    check_list_decks
    ;;
  *)
    echo "Unknown scope: ${SCOPE}" >&2
    echo "Valid: init, create, deploy, manage" >&2
    exit 2
    ;;
esac

echo ""
if [[ $FAILURES -eq 0 ]]; then
  echo "全部通过"
  exit 0
else
  echo "有 ${FAILURES} 项未通过 — 请按上方「修复」命令逐一解决后重新运行"
  exit 1
fi
