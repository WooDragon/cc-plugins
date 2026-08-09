---
name: brain-recall
description: |
  外挂 RAG 记忆库 second-brain 检索，用于召回跨项目的通用工程教训。当需要：
  - 建 git worktree
  - 写或改 hook / 护栏门禁
  - 写门禁或 bash 测试
  - 并行派 subagent
  - 限定范围 git 提交
  - PR 评审复核
  - 装或迁插件
  - 验收拆分重构
  - 设计门禁降级或豁免
  时调用此 Skill，先检索是否已有相关实测教训。
---

# second-brain 检索 Skill

## 配置前提

本 skill 依赖两个环境变量，**须写入 `~/.claude/settings.json` 的 `env` 段**——Bash 里 `export` 传不进 hook 与新 session 进程：

| 变量 | 用途 |
|---|---|
| `SECOND_BRAIN_URL` | second-brain 实例的 REST base，例如 `https://brain.example.com` |
| `SECOND_BRAIN_TOKEN` | 该实例的 `AUTH_TOKEN`（Bearer 鉴权用） |

未配置时下面的命令会带着变量名报错而非静默打错端点。后端是什么、怎么自建，见 `brain-route` 插件 README 的 Backend Dependency 节。

外挂 RAG 记忆库，REST base 由 `SECOND_BRAIN_URL` 指定，鉴权 `Authorization: Bearer $SECOND_BRAIN_TOKEN`（token 从环境变量读，绝对不要把 token 字面值写进任何文件）。它是 CC 记忆系统的补充层，只存跨项目通用的工程教训；确定性内容（CLAUDE.md 铁律、skill 调度表、docs 导航）仍走本地文件，不进 brain。

---

## 查询构造规约（核心）：描述处境，不要猜关键词

把当前处境原样摘要 100-200 字提交，包含：在干什么、用什么工具、下一步打算怎么做。

**必须保留具体动作词与工具名**（`commit`/`export`/`printf`/`worktree`/`$HOME`）——恰恰是那些你不觉得重要的动作词才是记忆的锚点。

**禁止**：
- 自己做关键词提取（服务端有全语料 df 统计，你没有，你的先验是错的）
- 加「有什么坑吗」这类元问题（不含语料词，纯稀释）

一句话概括：**把 prompt 当查询，而不是把查询当 prompt**。

**为什么**：服务端 `distillToRareTerms` 在 embedding 之前先按语料 df 把查询压到最稀有的 3 个词。短查询已经被你手工精简过一次，服务端再压一次，等于删掉了本该留下的动作词。5 场景对照实测：情景描述（130-190 字）胜 3 平 1 负 1，唯一一次目标掉出前 5 出现在短查询。

实测例：
- 反例：查「并行 subagent 冲突」→ 目标 MISS
- 正例：查「并行派发三个 subagent 改不同文件，各自 commit 自己的改动」→ 目标排第 1

差别是动作词 `commit`——写短查询时不知道问题出在 commit 上，长查询把它原样带进去了服务端才能压中。

再举一组对照：
- 反例：查「hook 测试环境变量污染」→ 意图对但词太泛，压不到具体点
- 正例：查「造门禁夹具用 heredoc 测试逃生舱变量，跑之前要先清 shell 里残留的 env，不然所有 BLOCK 用例会假通过」→ 命中带具体失败模式的教训条目

---

## 调用方式

```bash
curl -sS -m 30 \
  -A "curl/8.7.1" \
  -H "Authorization: Bearer ${SECOND_BRAIN_TOKEN:?未配置 SECOND_BRAIN_TOKEN，见 brain-route 插件 README 的 Environment Variables 节}" \
  --data-urlencode "query=<把 100-200 字处境摘要原样放这里>" \
  --data-urlencode "topK=5" \
  -G "${SECOND_BRAIN_URL:?未配置 second-brain 端点，请设置 SECOND_BRAIN_URL，见 brain-route 插件 README 的 Environment Variables 节}/recall"
```

**必须带 UA 头** `-H "User-Agent: curl/8.7.1"`（等价于上面的 `-A`）。Cloudflare 对默认 UA（如 curl 不带 `-A` 时的默认串，或空 UA）返回 403 + `error code: 1010`，症状与 token 失效同形——排障时先查这个,再怀疑 token。

也可走 MCP endpoint `${SECOND_BRAIN_URL:?未配置 second-brain 端点，请设置 SECOND_BRAIN_URL，见 brain-route 插件 README 的 Environment Variables 节}/mcp` 的 `recall` 工具，效果等价于上面的 REST 调用。

**延迟预期**：recall 实测 5.7-11s，不是即时返回，规划 Task timeout 时留够。

---

## 结果解读

**score 不可作相关性阈值**：服务端按本次返回结果的最高分归一化，所以排第一的条目永远显示 100 分——哪怕它跟查询完全不相关。判据只能是**排序位次**（前 1-2 条通常最相关）与**内容本身**（读条目文本判断是否真的适用），不要设「score > 80 才采信」之类的阈值,那个阈值没有意义。

返回条目带 `tags`。见到 `duplicate-candidate` 或 `stale:as-of` 就是欠账信号,转 `brain-curate` skill 处理,不要在 recall 场景里自己动手改。

---

## 边界

召回是概率性的,漏召回只意味着少一个提示,不代表出错。**凡「漏 = 规则被违反」的内容不在 brain 里,别去 brain 找铁律**——CLAUDE.md 里的硬约束、skill 调度表、docs 导航这类确定性内容本来就不会存进 brain,brain 召不到不是 bug。

brain 挂了或超时就照常干活,不阻塞主任务——它是补充层不是关键路径。

---

## 写入

新学到跨项目工程教训时:

```bash
curl -sS -m 30 \
  -A "curl/8.7.1" \
  -H "Authorization: Bearer ${SECOND_BRAIN_TOKEN:?未配置 SECOND_BRAIN_TOKEN，见 brain-route 插件 README 的 Environment Variables 节}" \
  -H "Content-Type: application/json" \
  -d '{"content":"...", "tags":["..."], "volatility":"durable", "source":"claude"}' \
  "${SECOND_BRAIN_URL:?未配置 second-brain 端点，请设置 SECOND_BRAIN_URL，见 brain-route 插件 README 的 Environment Variables 节}/capture"
```

**为什么钉 `volatility: durable`**:召回衰减下限 0.9,默认档 `state` 是 0.6 会让老教训随时间沉底,而工程教训(踩过的坑、实测出的约束)不因时间失效,不该被当成会过期的状态数据处理。

**去重**:服务端自带去重(相似度 ≥0.95 直接 block,≥0.85 返回 `warning:"similar"`)。收到 `warning:"similar"` 时**由你读全文决定合并还是保留,不要让服务端自动 merge**——服务端合并出的 `merged_content` 上限 400 字符且会丢掉 incoming tags,实测会把新写入里的实测数据(具体数字、行号)丢掉。人工判断:内容确实重复就手动整理后走 `brain-curate` 的合并流程;不重复就保留两条。

**写入索引滞后**:向量 upsert 走 `ctx.waitUntil`,响应先返回、索引后建。刚写入的条目 60-90s 内查不到,不是写失败,别在这个窗口内重复写入或误判丢失。
