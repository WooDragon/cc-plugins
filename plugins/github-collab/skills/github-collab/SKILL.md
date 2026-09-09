---
name: github-collab
description: |
  仓库已配成「管理者掌管 main 分支与 issue，协作者不能合并代码、只能提 PR 和 issue」的形态之后，两个角色各自怎么干活。当需要：
  - 管理者视角：怎么把任务分派给协作者、协作者的 PR 到了怎么处理（先看 CI 再看代码）、怎么做评审裁决、要求修改和 approve 的区别、怎么合并、自己的 PR 怎么合（作者不能 approve 自己）
  - 协作者视角：怎么认领 issue、同仓分支还是 fork、PR 描述该写什么、CI 挂了怎么自己诊断、收到 review 意见怎么逐条响应、PR 显示 `BLOCKED`/`REVIEW_REQUIRED` 合不了是不是权限故障
  - 摩擦点排查：PR 卡住了，卡在 CI 红 / check 一直 pending / review 未 resolve / 分支落后 main / CODEOWNERS 没匹配到人的哪一环，该找谁解决
  - 把仓库配成这个形态：个人仓库 collaborator 权限颗粒度、分支保护规则怎么配、`enforce_admins` 死锁陷阱、required status checks 永久 pending 陷阱
  时调用此 Skill。
  Triggers: github collaboration, 协作者工作流, 管理者工作流, 分支保护, branch protection, PR 卡住, PR blocked, review required, request changes, dismiss stale reviews, enforce_admins, CODEOWNERS, required status checks, 合并权限, collaborator permission, PR 合不了, 派任务给协作者, 提 PR 给这个仓库, 分派 issue.
---

# GitHub 协作模式：管理者与协作者怎么干活

前提形态：仓库已配成「管理者掌管 main 与 issue，协作者只能提 PR 和 issue，不能直接合并」。本 skill 讲两个角色在这个形态下**各自的日常工作流**，配置本身只在 §5 附录里给一次性动作。

## §1 角色与能力边界

| 能力 | 管理者 | 协作者 |
|------|--------|--------|
| 读代码 / clone | ✅ | ✅ |
| 提 issue | ✅ | ✅ |
| 开分支（同仓） | ✅ | 有 write 权限时 ✅，否则走 fork |
| 提 PR | ✅ | ✅ |
| approve PR | ✅（非自己的 PR） | ✅（非自己的 PR） |
| 合并 PR 到 main | ✅ | 条件满足后 ✅——见表下说明 |
| 改分支保护规则 / 仓库设置 | ✅ | ❌ |

> **分支保护挡的是「条件」，不是「人」。** 管理者 approve、CI 转绿之后，有 write 权限的协作者**可以自己点 merge**——GitHub 不会因为他不是 owner 就拦住他。要把「只有某些人能合」限死到身份，需要分支保护的 `restrictions` 字段，而它**只对 organization 拥有的仓库生效**（官方原文：*"User, app, and team restrictions are only available for organization-owned repositories."*），个人账号仓库用不了它。
>
> 所以个人账号仓库下这套形态的真实保证是：**没有管理者的 approve，谁都合不了**；而不是「只有管理者能合」。要后者就得迁到 organization（见 §5）。

判断自己当前是哪个角色，别猜，查权限位——判的就是当前这个仓库，不用管它是不是 fork：

```bash
gh api 'repos/{owner}/{repo}' --jq '.permissions |
  if .admin then "管理者 → §2"
  elif .push then "协作者·可开同仓分支 → §3"
  else "协作者·须 fork → §3" end'
```

`repos/{owner}/{repo}` 是 `gh` 的占位符，从当前工作目录的 remote 自动解析，不用手填。第三档（无 push 权限）决定 §3 第 2 步只能走 fork。

## §2 管理者工作流

按事件顺序排列，不按功能罗列。

### 1. 分派任务

issue 要写到协作者**不用回来追问就能直接开工**的粒度，三要素缺一不可：
- **背景**：为什么要做这个、现状是什么
- **验收标准**：怎么判定这个 issue 算做完（可验证的行为，不是"优化一下"这种空话）
- **边界**：明确不做什么，防止协作者顺手扩大范围

```bash
gh issue create --title "..." --body "..." --assignee <collaborator-username> --label "..."
```

### 2. PR 到达

**先看 CI 再看代码**——CI 未绿就不进入人工 review，否则等 CI 跑完代码又要改一轮，人工评审等于白做一次：

```bash
gh pr checks <pr-number>
```

CI 绿了之后再判断这个 PR 值不值得细看：改动范围是否和 issue 描述的边界一致、diff 大小是否合理、有没有顺手夹带的无关改动。

### 3. 评审

第一遍交给 AI 评审做初筛，具体后端与命令参数见 `pr-review` skill，这里不重复。AI 评审的输出是**建议**，人来做**采纳裁决**：每一条意见都必须显式吸收或驳回，驳回要写明理由，不能沉默忽略——沉默忽略等于让协作者猜你是不是压根没看。

### 4. 要求修改

`Request changes` 与普通 comment 不是一回事：

- **`Request changes`**：阻塞合并，`reviewDecision` 变成 `CHANGES_REQUESTED`。**作者推新 commit 不会自动解除它**——必须由提出这条 review 的人重新提交一次 approve，或由有权限的人显式 dismiss 掉这条 review
- **普通 comment**：不阻塞合并，纯讨论

分支保护开了 `dismiss_stale_reviews` 时，作者一推新 commit，之前的 **approve 会被自动作废**、需要重走一轮 review——这是设计如此，不是 bug。注意它作废的**只有 approve**，`CHANGES_REQUESTED` 不在其列，仍然要那位 reviewer 本人改判才解得开。

### 5. 合并

统一 squash + delete-branch：

```bash
gh pr merge <pr-number> --squash --delete-branch
```

PR 描述里用关闭关键字（`Closes #12`、`Fixes #34`）自动关联并关闭 issue，**每条关键字只认自己后面那一个 issue 编号**——要关闭多个 issue 得写多条关键字（`Closes #12, Closes #34` 或分行各写一条），不能指望一个关键字带多个编号生效。

### 6. 自己的 PR 怎么合

GitHub 平台硬规则：**PR 作者不能 approve 自己的 PR**。单人或双人仓库里，owner 自己开的 PR 永远凑不齐 required approve 数量，正常合并路径走不通，必须走 admin bypass：

```bash
gh pr merge <pr-number> --squash --delete-branch --admin
```

前提：分支保护规则的 `enforce_admins` 必须是 `false`（见 §5 陷阱①），否则这条命令本身也会被拒。

## §3 协作者工作流

### 1. 认领

从 issue 起步，动手前先确认边界读懂了没有；不确定的地方**在 issue 里问清楚再动手**，不要写完一半发现理解错了再回头问——那时候返工成本已经出去了。

### 2. 开分支

先过硬门禁，再谈偏好——§1 的判定直接决定这一步，不是「看情况」。

**无 push 权限（`协作者·须 fork`）→ 只能 fork，没有第二条路：**

```bash
gh repo fork --remote          # 在上游的 clone 里执行
git checkout -b feat/xxx
git push -u origin feat/xxx
gh pr create --title "..." --body "..." --base main
```

`gh repo fork --remote` 会把新 fork 设成 `origin`、把原来的 `origin`（上游）改名成 `upstream`，要换名用 `--remote-name`。cwd 是上游只读 clone 又不 fork 就直接 `git push -u origin`，会被权限拒绝——那是权限问题，不是配置问题。

**有 push 权限（`协作者·可开同仓分支`）→ 优先同仓分支**，因为 fork PR 有两个坑：

- **fork PR 的 `GITHUB_TOKEN` 被降级为只读，且拿不到仓库 secrets**——这两点是官方明说的。实践后果是它通常也拉不动需要认证的上游私有 package：CI 要拉私有 package 时，fork 出来的 PR 会卡在这一步
- **首次贡献者从 fork 提的 PR，workflow 默认不会自动跑**——官方原文 *"By default, all first-time contributors require approval to run workflows"*，需要有 write 权限的人批准（Actions 页面点 "Approve and run"，也可走 API）。**这条说的是公共仓库**：私有仓库的 fork workflow 审批是另一套机制，别把公共仓库的默认值直接套过去。该设置在仓库 / 组织 / 企业三级都可配，管理员可以调成「所有外部贡献者都需审批」或干脆关掉

```bash
git checkout -b feat/xxx
git push -u origin feat/xxx
gh pr create --title "..." --body "..." --base main
```

### 3. 提 PR

描述该覆盖四点，不是随手一句话：
- 改了什么
- 为什么这么改
- 怎么验证的（跑了哪些测试、手测步骤）
- 有没有风险 / 副作用

关联 issue 用 `Closes #<issue-number>`。

### 4. CI 挂了

自己先诊断根因，不要一挂就甩给管理者。区分两种情况：
- **我这次改动引入的失败** → 修，塞进当前 PR
- **和这次改动无关的既有 flaky** → 单独开一个 issue 记录，不要顺手在当前 PR 里"顺便"修掉——那会让这个 PR 的 diff 超出 issue 划定的边界，管理者审起来分不清哪部分是任务本身

### 5. 收到 review

逐条响应，不要挑软柿子捏：
- 同意就改，改完在对话线程里回一句说明改了什么
- 不同意就在线程里讲清楚理由，别沉默 force push 直接把讨论盖掉
- 改完调用 re-request review，让管理者知道可以回来再看一轮

```bash
gh pr edit <pr-number> --add-reviewer <maintainer-username>
```

### 6. 合不了是正常的

```bash
gh pr view <pr-number> --json mergeStateStatus,reviewDecision
# mergeStateStatus: BLOCKED, reviewDecision: REVIEW_REQUIRED
```

这是分支保护按设计工作，不是权限故障，不用去查自己权限哪里出了问题。**也不要去找 `--admin` 参数**——那是管理者专属的 bypass 通道，协作者没有这个权限，也不该有，硬加这个参数只会被拒。

## §4 摩擦点速查：PR 卡住了，卡在哪

| 症状 | 根因 | 谁来解 |
|------|------|--------|
| CI 显示红叉 | 测试真的失败，或环境问题 | 协作者先诊断；确认是既有 flaky 再找管理者 |
| 某个 required check 一直转圈不出结果 | workflow 里该 job 挂了 `if:` 条件（如只在 `push` 触发），PR 事件永远不触发它，check 永久 pending | 管理者（改分支保护的 required checks 清单，或改 workflow 条件） |
| `reviewDecision: REVIEW_REQUIRED` | 还没有人 approve，或人数不够 | 管理者去 review |
| review conversation 显示未 resolve | 分支保护开了 "Require conversation resolution"，某条评论线程没人点 resolve | 提出评论的人确认后 resolve，或协作者回复后管理者 resolve |
| 分支落后 main 合不上 | 分支保护开了 `strict`（要求分支是最新的） | 协作者 `git merge main` 或 `git rebase main` 后重新推送 |
| CODEOWNERS 没匹配到人，review 请求发不出去 | CODEOWNERS 规则路径没覆盖到改动文件，或 CODEOWNERS 本身没合入默认分支 | 管理者检查 CODEOWNERS 规则和生效分支 |

## §5 附录：把仓库配成这个形态（管理者一次性动作）

### 权限颗粒度取舍

个人账号的私有仓库，collaborator 权限只有 **read+write 捆绑这一档**，给不了"能提 PR 但不能直推"这种只读级别——五档细粒度角色（read / triage / write / maintain / admin）是 organization 仓库专属。所以本 skill 讲的形态，落地手段是**给协作者 write 权限、再用分支保护把 write 架空**，而不是靠授予更低的权限档位。

三个方案的取舍：

| 方案 | 权限粒度 | 能强制 PR 审查 | 能限死谁可以合并（`restrictions`） | Actions 额度 | 成本 |
|------|----------|----------------|-----------------------------------|--------------|------|
| 个人账号 + Pro | 只有 read+write 捆绑一档 | 能（靠分支保护） | ❌ 不支持，`restrictions` 是 organization 专属 | 私有仓库有限额度 | 个人订阅费 |
| Free organization | 五档细粒度角色 | 能 | ✅ | 组织级额度，免费档更紧 | 免费 |
| Team organization | 五档细粒度角色 + 更多治理功能 | 能 | ✅ | 组织级额度，更宽 | 按席位收费 |

个人账号仓库靠分支保护能达成「没有管理者 approve 就谁都合不了」，但**达不成「只有管理者能合」**——要限死合并者身份，或者要更细的权限分层（某些人只读、某些人只能 triage），才是迁往 organization 的理由。

### 分支保护规则模板

```bash
gh api -X PUT repos/{owner}/{repo}/branches/{branch}/protection \
  --input - <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "checks": [
      { "context": "ci/build" },
      { "context": "ci/test" }
    ]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false
  },
  "restrictions": null
}
EOF
```

字段作用：

| 字段 | 作用 |
|------|------|
| `required_status_checks.strict` | 要求分支与 base 分支保持最新才能合并 |
| `required_status_checks.checks` | 必须跑绿的 CI check 名单，元素形如 `{"context": "<check 名>"}`，可选加 `"app_id"` 锁定出具该 check 的 App。旧的 `contexts` 字段是纯字符串数组，官方已对它挂出 "Closing down notice" 并明说 *"Use `checks` instead of `contexts` for more fine-grained control"*，新配置不要再用 |
| `enforce_admins` | 是否连管理者也受这套规则约束（见陷阱①，通常设 `false`） |
| `required_pull_request_reviews.required_approving_review_count` | 至少几个 approve 才能合 |
| `required_pull_request_reviews.dismiss_stale_reviews` | 新 commit 是否自动作废旧 approve |
| `required_pull_request_reviews.require_code_owner_reviews` | 是否强制 CODEOWNERS 命中的人 approve |
| `restrictions` | 限制谁能推送 / 合并到该分支。**organization 仓库专属**——官方原文 *"User, app, and team restrictions are only available for organization-owned repositories. Set to null to disable."*；个人账号仓库传 `null`（实测：个人账号仓库回读 protection 时，返回体里根本没有 `restrictions` 这个 key）。传非 `null` 时究竟是报错还是被忽略，官方未作说明，不要当成确定的 422 |

回读验证：

```bash
gh api repos/{owner}/{repo}/branches/{branch}/protection
```

### 四个陷阱

1. **`enforce_admins=true` 在单人仓库导致合并死锁**：作者不能 approve 自己的 PR，owner 又被 `enforce_admins` 卡住不能走 bypass，PR 永远合不上。单人/双人仓库务必设 `enforce_admins=false`，靠 `--admin` bypass 走管理者自己的 PR。
2. **required status checks 选到带触发条件的 job，check 永久 pending**：如果某个 job 有 `if: github.event_name == 'push'` 之类的条件，它在 PR 事件上根本不会运行，对应的 check 永远显示 pending，所有 PR 永久卡住。选 required checks 时确认该 job 在 `pull_request` 事件下会真正跑。
3. **CODEOWNERS 只在默认分支上生效**：必须先把 CODEOWNERS 文件本身合入默认分支，"Require review from Code Owners" 这条保护规则才会真正生效，两者有先后依赖。
4. **纯文档 PR 也会跑全套 CI，但用 `paths-ignore` 跳过又会撞陷阱②**：给 CI workflow 加 `paths-ignore` 让文档改动跳过整套流程，会导致那个 required check 在文档 PR 上根本不产生结果，永久 pending——和陷阱②同一个根因。这两者只能二选一：要么接受文档 PR 也跑全套 CI，要么放弃把该 check 设为 required。
