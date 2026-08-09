---
name: brain-curate
description: |
  外挂 RAG 记忆库 second-brain 的复核与去重整理。当出现：
  - 召回结果（`brain-recall`）里条目带 `duplicate-candidate` 或 `stale:as-of` 标签
  - PR 归并前的记忆复核
  - 怀疑 brain 内容重复或陈旧
  时调用此 Skill。
---

# second-brain 复核 Skill

## 配置前提

本 skill 依赖两个环境变量，**须写入 `~/.claude/settings.json` 的 `env` 段**——Bash 里 `export` 传不进 hook 与新 session 进程：

| 变量 | 用途 |
|---|---|
| `SECOND_BRAIN_URL` | second-brain 实例的 REST base，例如 `https://brain.example.com` |
| `SECOND_BRAIN_TOKEN` | 该实例的 `AUTH_TOKEN`（Bearer 鉴权用） |

未配置时下面的命令会带着变量名报错而非静默打错端点。后端是什么、怎么自建，见 `brain-route` 插件 README 的 Backend Dependency 节。

REST base 由 `SECOND_BRAIN_URL` 指定，鉴权 `Authorization: Bearer $SECOND_BRAIN_TOKEN`（从环境变量读，绝对不要把 token 字面值写进任何文件）。所有请求都需带 UA 头 `-A "curl/8.7.1"`，否则 Cloudflare 返回 403 + `error code: 1010`。

---

## 两层触发时机

不用定时任务：内容劣化由**写入**造成，不由**时间**造成。日历判据（如"每天跑一次"）在没有新写入时白跑一次浪费一次调用，在密集写入期又不够勤——两头不讨好。

1. **读路径自曝（主）**：`brain-recall` 每次 `/recall` 返回的条目都带 `tags`，欠账主动出现在你眼前，且此时你正关心该话题、判断合并/保留的成本最低。不需要计数器、状态文件、cron，看见就处理。

2. **PR 归并前兜底（副）**：扫全量，覆盖"写进去但从没被召回过"的盲区——这类条目不会通过第 1 层自曝，因为没人查询过它们所在的话题。

---

## 复核清单

**重复候选**（第 1 层自曝会带出，也可主动扫）：

```bash
curl -sS -m 30 -A "curl/8.7.1" \
  -H "Authorization: Bearer $SECOND_BRAIN_TOKEN" \
  -G "${SECOND_BRAIN_URL:?未配置 second-brain 端点，请设置 SECOND_BRAIN_URL，见 brain-route 插件 README 的 Environment Variables 节}/list" \
  --data-urlencode "n=100" \
  --data-urlencode "tag=duplicate-candidate"
```

**陈旧条目**（第 1 层自曝会带出，也可主动扫）：

```bash
curl -sS -m 30 -A "curl/8.7.1" \
  -H "Authorization: Bearer $SECOND_BRAIN_TOKEN" \
  -G "${SECOND_BRAIN_URL:?未配置 second-brain 端点，请设置 SECOND_BRAIN_URL，见 brain-route 插件 README 的 Environment Variables 节}/list" \
  --data-urlencode "n=100" \
  --data-urlencode "tag=stale:as-of"
```

**全量含统计**（PR 归并前兜底用，一次调用拿到 `recall_count` / `importance_score`）：

```bash
curl -sS -m 30 -A "curl/8.7.1" \
  -H "Authorization: Bearer $SECOND_BRAIN_TOKEN" \
  "${SECOND_BRAIN_URL:?未配置 second-brain 端点，请设置 SECOND_BRAIN_URL，见 brain-route 插件 README 的 Environment Variables 节}/export" > /tmp/brain_export.json

jq '[.[] | select(.recall_count == 0)] | .[] | select(
  (now - (.created_at | fromdateiso8601)) > (60*86400)
)' /tmp/brain_export.json
```

筛出 `recall_count == 0` 且 `created_at` 超 60 天的条目——这些是写进去后从未被任何查询命中的沉底条目，是盲区，只能靠这条命令找到。

---

## 合并决策规约

**人工裁决，逐条列出建议交用户确认，不自动改数据。**流程：

1. 拿到重复/陈旧候选列表后，逐条读全文，判断：真重复该合并、还是表面相似但各有独立事实该保留两条。
2. 把判断结果和理由列给用户，等确认，不要在没确认前就执行合并。
3. 确认合并后，**由你（不是服务端）手工写出合并后的完整内容**——必须保全各条独有的实测数据、行号、计数,不能只留一条丢掉另一条的细节。
4. 执行落地：
   ```bash
   # 整段替换成合并后内容
   curl -sS -m 30 -A "curl/8.7.1" \
     -H "Authorization: Bearer $SECOND_BRAIN_TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"id":"<保留条目id>", "content":"<合并后完整内容>", "tags":["..."]}' \
     "${SECOND_BRAIN_URL:?未配置 second-brain 端点，请设置 SECOND_BRAIN_URL，见 brain-route 插件 README 的 Environment Variables 节}/update"

   # 删除被合并掉的那条
   curl -sS -m 30 -A "curl/8.7.1" \
     -H "Authorization: Bearer $SECOND_BRAIN_TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"id":"<被合并条目id>"}' \
     "${SECOND_BRAIN_URL:?未配置 second-brain 端点，请设置 SECOND_BRAIN_URL，见 brain-route 插件 README 的 Environment Variables 节}/forget"
   ```

不要依赖服务端在 `/capture` 时自动给出的 `merged_content`——那是写入阶段的自动合并（见 `brain-recall`），上限 400 字符且会丢 incoming tags，不适合当作正式合并结果使用；本 skill 的合并流程是复核阶段的手工合并，两者不是同一件事。

---

## 已知缺口（写清楚，避免误以为系统会自己收敛）

- **无条目级自动删除**——条目只会被 deprecate 或降权，永不自动消失，只能靠上面的 `/forget` 手工删除。
- **`importance_score` 写入时由 LLM 打一次分，此后永不更新**——不会随时间或使用情况自动调整，过时的初始打分会一直留着。
- **召回正反馈**：`1 + log1p(recall_count)`——热的条目更热、冷的条目沉底。`durable` 档能缓解衰减，但不能消除这个正反馈循环，冷门但正确的教训仍会逐渐边缘化。
- **压缩条件苛刻，规模小时基本不触发**：需要同 tag 下 >10 条、且都超过 60 天、且 `recall_count < 2`。在几十条规模的 brain 里这个条件基本凑不齐，别指望它自动收敛,该手工复核的还是要手工复核。
