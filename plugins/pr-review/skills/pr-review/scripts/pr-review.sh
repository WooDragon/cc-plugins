#!/usr/bin/env bash
#
# pr-review.sh — 统一入口：先用 resolve-backend.sh 机械解析该用哪个后端，再 exec 路由到
# 对应的同构后端脚本（grok-review.sh / claude-review.sh，二者 CLI 参数形态完全一致，
# 故直接透传 "$@" 是安全的）。调用方（无论主线还是派发的子任务）只需要认识这一个入口，
# 不必先跑 resolve-backend.sh 再自行拼后端脚本路径。
#
# copilot 不纳入这层路由——它是异步触发/查询流程（request/rerequest/status 三条路径），
# 参数形态与另两者天然不同；resolve-backend.sh 也从不会自动选出 copilot（只有用户显式
# PR_REVIEW_BACKEND=copilot 才会返回它），此时本脚本报错并指向 copilot-review.sh。
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND=$("$DIR/resolve-backend.sh")
case "$BACKEND" in
  grok)   exec "$DIR/grok-review.sh" "$@" ;;
  claude) exec "$DIR/claude-review.sh" "$@" ;;
  *)      echo "错误: pr-review.sh 只路由 grok/claude 两个同构后端（CLI 参数形态一致）；copilot 是异步流程、参数形态不同，请直接调用 copilot-review.sh" >&2; exit 1 ;;
esac
