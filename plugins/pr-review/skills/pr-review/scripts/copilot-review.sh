#!/usr/bin/env bash
#
# copilot-review.sh — 通过 gh 可靠地触发 / 重新触发 GitHub Copilot code review。
#
# 用法:
#   copilot-review.sh request   <PR> [--repo owner/name]   # 首次请求 Copilot 评审
#   copilot-review.sh rerequest <PR> [--repo owner/name]   # 重新请求（re-request）
#   copilot-review.sh status    <PR> [--repo owner/name]   # 查看 Copilot 评审请求 / 结果状态
#
# 设计依据（均为官方文档 + 本机实测，见 references/copilot-review.md）:
#   - reviewer bot REST login 是 copilot-pull-request-reviewer[bot]（带后缀）
#     GraphQL Bot.login 是 copilot-pull-request-reviewer（不带后缀）
#   - 首次: REST POST requested_reviewers，reviewers 数组塞带 [bot] 后缀的 login。
#   - re-request: REST 复用会被去重，必须走 GraphQL requestReviews + botIds + union:true；
#     并先 DELETE 掉已存在的 review request 兜底，确保真正重新排队。
set -euo pipefail

COPILOT_LOGIN="copilot-pull-request-reviewer[bot]"
COPILOT_LOGIN_GQL="copilot-pull-request-reviewer"
COPILOT_BOT_ID_FALLBACK="BOT_kgDOCnlnWA"
GH_MIN_VERSION="2.88.0"

die() { echo "错误: $*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "未找到 gh CLI"

# 版本检查（仅警告，不阻断；老环境无 sort -V 时也不应让脚本崩）
gh_version=$(gh --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true
if [[ -n "${gh_version:-}" ]]; then
  if [[ "$(printf '%s\n' "$GH_MIN_VERSION" "$gh_version" | sort -V 2>/dev/null | head -1)" != "$GH_MIN_VERSION" ]]; then
    echo "警告: gh $gh_version < ${GH_MIN_VERSION}（gh pr edit --add-reviewer @copilot 不可用，脚本走 REST/GraphQL）" >&2
  fi
fi

SUB="${1:-}"; shift || true
PR="${1:-}"; shift || true
REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo|-R) [[ -n "${2:-}" && "$2" != -* ]] || die "--repo 缺少值"; REPO="${2}"; shift 2 ;;
    *) die "未知参数: $1" ;;
  esac
done

[[ -n "$SUB" && -n "$PR" ]] || die "用法: copilot-review.sh {request|rerequest|status} <PR> [--repo owner/name]"
[[ "$PR" =~ ^[0-9]+$ ]] || die "PR 必须是数字，收到: $PR"

# 解析 owner / name
if [[ -n "$REPO" ]]; then
  [[ "$REPO" =~ ^[^/]+/[^/]+$ ]] || die "--repo 须为 owner/name 格式，收到: $REPO"
  OWNER="${REPO%%/*}"; NAME="${REPO##*/}"
else
  read -r OWNER NAME < <(gh repo view --json owner,name -q '"\(.owner.login) \(.name)"') \
    || die "无法确定当前仓库，请用 --repo owner/name 指定"
fi
[[ -n "$OWNER" && -n "$NAME" ]] || die "owner/name 解析失败"

REPO_FLAG=(-R "$OWNER/$NAME")

# 动态取 Copilot bot 的 node id：从 PR 的 review 请求/记录里反查，失败回退常量
copilot_bot_id() {
  local id
  # COPILOT_LOGIN_GQL 为内置常量，勿改成外部可控输入（否则 jq 注入）
  id=$(gh api graphql -f query='
    query($o:String!,$r:String!,$n:Int!){
      repository(owner:$o,name:$r){
        pullRequest(number:$n){
          reviewRequests(first:50){ nodes{ requestedReviewer{
            __typename ... on Bot { id login } } } }
          latestReviews(first:50){ nodes{ author{
            __typename ... on Bot { id login } } } }
        }
      }
    }' -F o="$OWNER" -F r="$NAME" -F n="$PR" \
    --jq "[.data.repository.pullRequest.reviewRequests.nodes[]?.requestedReviewer, .data.repository.pullRequest.latestReviews.nodes[]?.author] | map(select(.__typename==\"Bot\" and .login==\"$COPILOT_LOGIN_GQL\") | .id) | first // empty" 2>/dev/null || true)
  if [[ -n "$id" ]]; then echo "$id"; else echo "$COPILOT_BOT_ID_FALLBACK"; fi
}

pr_node_id() {
  gh pr view "$PR" "${REPO_FLAG[@]}" --json id -q .id
}

case "$SUB" in
  request)
    echo ">> 首次请求 Copilot 评审 (REST) — $OWNER/$NAME#$PR"
    gh api --method POST \
      "repos/$OWNER/$NAME/pulls/$PR/requested_reviewers" \
      -f "reviewers[]=$COPILOT_LOGIN" >/dev/null
    echo ">> 已请求。用 'status' 确认。"
    ;;

  rerequest)
    echo ">> 重新请求 Copilot 评审 — $OWNER/$NAME#$PR"
    PR_ID="$(pr_node_id)"
    BOT_ID="$(copilot_bot_id)"
    echo "   PR node = $PR_ID"
    echo "   bot id  = $BOT_ID"
    # 兜底: 先删掉可能已存在的 pending review request（忽略「不存在」的报错）
    gh api --method DELETE \
      "repos/$OWNER/$NAME/pulls/$PR/requested_reviewers" \
      -f "reviewers[]=$COPILOT_LOGIN" >/dev/null 2>&1 || true
    # 真正重新排队: GraphQL requestReviews, botIds + union:true（union 保留人类 reviewer）
    gh api graphql -f query='
      mutation($pr:ID!,$bot:ID!){
        requestReviews(input:{pullRequestId:$pr, botIds:[$bot], union:true}){
          pullRequest{ id }
        }
      }' -F pr="$PR_ID" -F bot="$BOT_ID" >/dev/null
    echo ">> 已重新请求。用 'status' 确认。"
    ;;

  status)
    echo ">> Copilot 评审状态 — $OWNER/$NAME#$PR"
    gh api graphql -f query='
      query($o:String!,$r:String!,$n:Int!){
        repository(owner:$o,name:$r){
          pullRequest(number:$n){
            reviewRequests(first:50){ nodes{ requestedReviewer{
              __typename ... on Bot { login } ... on User { login } } } }
            latestReviews(first:50){ nodes{
              author{ __typename ... on Bot { login } ... on User { login } }
              state submittedAt } }
          }
        }
      }' -F o="$OWNER" -F r="$NAME" -F n="$PR" \
      --jq '
        "pending review requests:",
        (.data.repository.pullRequest.reviewRequests.nodes[]?.requestedReviewer.login // empty | "  - \(.)"),
        "latest reviews:",
        (.data.repository.pullRequest.latestReviews.nodes[]? | "  - \(.author.login // "?") : \(.state) \(.submittedAt // "")")'
    ;;

  *)
    die "未知子命令: $SUB （request|rerequest|status）"
    ;;
esac
