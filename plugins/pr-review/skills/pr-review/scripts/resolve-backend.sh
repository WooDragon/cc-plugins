#!/usr/bin/env bash
#
# resolve-backend.sh — 机械化解析本次 pr-review 该用哪个后端，stdout 只输出一个后端名
# （grok/claude/copilot/codex），无副作用、无外部调用。
#
# 优先级：PR_REVIEW_BACKEND 显式覆盖（grok/claude/copilot/codex）> 默认 claude。
# grok/codex 不再参与默认路由，只有显式设置 PR_REVIEW_BACKEND 才会选中。
set -euo pipefail

case "${PR_REVIEW_BACKEND:-}" in
  grok|claude|copilot|codex) echo "$PR_REVIEW_BACKEND"; exit 0 ;;
  "") echo "claude" ;;
  *) echo "错误: 非法 PR_REVIEW_BACKEND=${PR_REVIEW_BACKEND}（合法: grok/claude/copilot/codex）" >&2; exit 1 ;;
esac
