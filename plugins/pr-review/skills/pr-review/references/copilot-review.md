# Copilot 后端：触发 GitHub Copilot 评审 PR

用 `gh` 可靠地让 GitHub Copilot 评审 PR。**首次触发**和**重新触发**走**不同机制**——搞混会静默失败。

**要求**：`gh` ≥ 2.88.0 + Copilot Pro / Pro+ / Max 订阅。

## 快速用法

```bash
scripts/copilot-review.sh request   <PR> [--repo owner/name]   # 首次请求
scripts/copilot-review.sh rerequest <PR> [--repo owner/name]   # 重新请求
scripts/copilot-review.sh status    <PR> [--repo owner/name]   # 查状态/结果
```

不带 `--repo` 时自动用当前仓库。

---

## 身份标识（REST vs GraphQL 不同）

| 用途 | REST login | GraphQL Bot.login | node ID |
|---|---|---|---|
| **代码评审 bot** | `copilot-pull-request-reviewer[bot]` | `copilot-pull-request-reviewer` | `BOT_kgDOCnlnWA` |
| Copilot 编码 agent（**不是** reviewer） | `copilot-swe-agent[bot]` | `copilot-swe-agent` | `BOT_kgDOC9w8XQ` |

- **REST `reviewers[]` 必须带 `[bot]` 后缀**。不带解析到同名 Organization（2025-05 创建的占位号），返回 422。
- **GraphQL `Bot.login` 不带 `[bot]`**。jq 过滤时用不带后缀的 login。

---

## 首次触发

```bash
gh pr edit <PR> --add-reviewer @copilot
```

或等价 REST：

```bash
gh api --method POST \
  "repos/{owner}/{repo}/pulls/<PR>/requested_reviewers" \
  -f "reviewers[]=copilot-pull-request-reviewer[bot]"
```

**不要**用 `@copilot` 评论提及触发——那走 coding-agent 语境，不触发 code review。

---

## 重新触发（re-request）

REST 复用首次调用会被 GitHub 去重。必须走 GraphQL：

```bash
PR_ID=$(gh pr view <PR> --json id -q .id)

# 兜底：先删掉已存在的 pending request
gh api --method DELETE \
  "repos/{owner}/{repo}/pulls/<PR>/requested_reviewers" \
  -f "reviewers[]=copilot-pull-request-reviewer[bot]" 2>/dev/null || true

# 真正重新排队
gh api graphql -f query='
  mutation($pr:ID!,$bot:ID!){
    requestReviews(input:{pullRequestId:$pr, botIds:[$bot], union:true}){
      pullRequest{ id }
    }
  }' -F pr="$PR_ID" -F bot="BOT_kgDOCnlnWA"
```

- `botIds` 放 node ID（不是 login）。`union:true` 保留现有人类 reviewer。
- 先 DELETE 再 requestReviews——防止 pending 状态去重导致不触发。

---

## 自动评审

repo Settings → Rules → Rulesets → 勾选 "Automatically request Copilot code review"。无需手动 API 调用。

---

## 传闻纠正

1. `@copilot` 评论提及 ≠ code review 触发。走 request-reviewer 机制。
2. re-request 必须 GraphQL（REST 被去重）。`botIds` + `union:true`。
3. `BOT_kgDOC9w8XQ` 是 swe-agent 不是 reviewer。

## 来源

- REST review-requests：https://docs.github.com/en/rest/pulls/review-requests
- 手动请求 Copilot 评审：https://docs.github.com/en/copilot/how-tos/use-copilot-agents/request-a-code-review/use-code-review
- 自动评审配置：https://docs.github.com/en/copilot/how-tos/use-copilot-agents/request-a-code-review/configure-automatic-review
- GA 公告：https://github.blog/changelog/2025-04-03-introducing-copilot-code-review
- re-request 讨论：https://github.com/orgs/community/discussions/186152
