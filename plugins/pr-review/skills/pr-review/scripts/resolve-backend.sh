#!/usr/bin/env bash
#
# resolve-backend.sh — 机械化解析本次 pr-review 该用哪个后端，stdout 只输出一个后端名
# （grok/claude/copilot），无副作用、无外部调用。
#
# 优先级：PR_REVIEW_BACKEND 显式覆盖 > 自动探测（当前会话是否经 wrapper 走 grok 路径）
# > 默认 grok（现状不变）。
#
# 自动探测依据：~/.claude/scripts/claude-wrapper.sh 的 grok 分支会把
# ANTHROPIC_DEFAULT_OPUS_MODEL 设为 grok/grok-4.6 这种 grok/* 形态；anthropic/兜底分支
# 设为 claude-opus-5。若当前会话本身就经 wrapper 走 grok 路径，用同一个 grok 模型自己
# 评审自己生成的代码复评价值存疑，此时默认改走 claude 后端。
set -euo pipefail

case "${PR_REVIEW_BACKEND:-}" in
  grok|claude|copilot) echo "$PR_REVIEW_BACKEND"; exit 0 ;;
  "") ;;
  *) echo "错误: 非法 PR_REVIEW_BACKEND=${PR_REVIEW_BACKEND}（合法: grok/claude/copilot）" >&2; exit 1 ;;
esac

case "${ANTHROPIC_DEFAULT_OPUS_MODEL:-}" in
  grok/*) echo "claude" ;;
  *)      echo "grok" ;;
esac
