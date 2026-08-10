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
  -H "Authorization: Bearer ${SECOND_BRAIN_TOKEN:?未配置 SECOND_BRAIN_TOKEN，见 brain-route 插件 README 的 Environment Variables 节}" \
  -G "${SECOND_BRAIN_URL:?未配置 second-brain 端点，请设置 SECOND_BRAIN_URL，见 brain-route 插件 README 的 Environment Variables 节}/list" \
  --data-urlencode "n=100" \
  --data-urlencode "tag=duplicate-candidate"
```

**陈旧条目**（第 1 层自曝会带出，也可主动扫）：

```bash
curl -sS -m 30 -A "curl/8.7.1" \
  -H "Authorization: Bearer ${SECOND_BRAIN_TOKEN:?未配置 SECOND_BRAIN_TOKEN，见 brain-route 插件 README 的 Environment Variables 节}" \
  -G "${SECOND_BRAIN_URL:?未配置 second-brain 端点，请设置 SECOND_BRAIN_URL，见 brain-route 插件 README 的 Environment Variables 节}/list" \
  --data-urlencode "n=100" \
  --data-urlencode "tag=stale:as-of"
```

**tag 卫生**（`brain-recall` 写入节定了 tag 三档规约——主题域 1-2 个必须 / 具体机制 0-2 个可选 / 禁止全覆盖标记·纯数字·`kind:`·`status:`·`volatility:` 手写值——但 `/capture` 不做校验，违规 tag 会静默进库，靠这里兜底扫）：

```bash
BRAIN_EXPORT=$(mktemp "${TMPDIR:-/tmp}/brain_export.XXXXXX")
trap 'rm -f "$BRAIN_EXPORT"' EXIT
curl -sS -m 30 -A "curl/8.7.1" \
  -H "Authorization: Bearer ${SECOND_BRAIN_TOKEN:?未配置 SECOND_BRAIN_TOKEN，见 brain-route 插件 README 的 Environment Variables 节}" \
  "${SECOND_BRAIN_URL:?未配置 second-brain 端点，请设置 SECOND_BRAIN_URL，见 brain-route 插件 README 的 Environment Variables 节}/export" > "$BRAIN_EXPORT"

# 1. 纯数字 tag —— issue/PR 号被当 tag，聚类和过滤都没用，应移进 content 正文
jq '[.entries[] | (.tags // []) | .[] | select(test("^[0-9]+$"))] | unique' "$BRAIN_EXPORT"

# 2. 全覆盖 tag —— 覆盖率 >=50% 的 tag，零区分度且会被 graph 聚类判为过泛降级
#    排除 kind:/status:/volatility:/cctype: 四类系统派生前缀（本来就高覆盖，不算欠账）
jq '(.entries|length) as $total
    | [.entries[] | (.tags // []) | .[]]
    | group_by(.)
    | map({tag: .[0], count: length, coverage: (length/$total)})
    | map(select(.coverage >= 0.5))
    | map(select(.tag | test("^(kind|status|volatility|cctype):") | not))' "$BRAIN_EXPORT"

# 3. 孤词 tag —— 只有 1 条用到的 tag，仅供人工过目，不是自动欠账
jq '[.entries[] | (.tags // []) | .[]]
    | group_by(.)
    | map({tag: .[0], count: length})
    | map(select(.count == 1))
    | map(.tag)' "$BRAIN_EXPORT"

rm -f "$BRAIN_EXPORT"
```

**孤词 tag 不是错**：具体机制档允许 df=1（`false_green`、`bsd_vs_gnu` 这种是精确检索锚点，本来就该只挂一条）。第 3 条命令的输出只作人工过目，判据是「它是不是一个能容纳后续条目的领域概念被误当成了一次性专名」——是则该并入已有主题域，不是则留着，不要见到 df=1 就一律清理。

三类欠账治法不同，**不要**统一导向下面的合并决策规约——合并决策规约是重复条目合并 + `/forget` 删条目的流程，跟 tag 卫生不是同一件事：

- **全覆盖 tag** → 不删，补足主题域 tag 让它被 `GENERIC_CEIL` 自然排除（见下文「所以「删掉坏 tag」不是可选动作」一段）。
- **纯数字 tag** → 把号码补进 content 正文。**tag 本身删不掉**——它会作为历史残留继续留在词表里，直到该条最后一次引用消失，由每日词表重建自动清理。
- **孤词 tag** → 人工判定它是不是一个能容纳后续条目的领域概念被误当成了一次性专名（见上文「孤词 tag 不是错」一段的判据）：是则补对应主题域 tag，不是则留着。

合并决策规约本身不变——它对重复/陈旧候选条目仍然有效，只是不再是 tag 欠账的默认出口。

**tag 只能加,不能删——这是 REST 面的硬限制,规划整理动作前先认清**：

- `/update` 的 body 只读 `{id, content, volatility}`（`src/routes/capture.ts:136`），**没有 `tags` 字段**。传了会被静默丢弃,不报错。
- 实际写入是 `tagsAfterWrite(existingTags ∪ hashtags)`（`src/capture/store.ts:147`）——旧 tag 一律保留,新 tag 只能靠 content 里嵌 `#tag` 带进去。
- 全部 31 个 REST 端点里**没有一个能删 tag**。`/status` 只改 `status:`，`/patterns/resolve` 只碰 `auto-pattern`。
- `tagsAfterWrite` 会剥掉 `volatility:` 与 `stale:as-of`。所以每次 `/update` **必须按原值回传 `volatility` 字段**,否则该条的 volatility 判定会静默丢失（实测踩过：漏传导致 `volatility:durable` 消失,召回衰减下限从 0.9 掉回 0.6）。
- `#tag` 会被 `extractHashtags` 从正文剔除（`src/text/hashtags.ts:3`）,不污染 content;但同一函数会把 `\s+` 压成单空格,**换行与代码围栏保不住**——正文形态要紧时改用 `/append`。
- hashtag 正则是 `/#\w+/`,`\w` 不含连字符,`#gate-design` 只会被截成 `gate`。tag 名一律用 `[a-z0-9_]`。

**所以「删掉坏 tag」不是可选动作。**遇到零区分度的全覆盖 tag（如某个每条都打的来源标记），治法是**补足主题域 tag 让它自然降级**,而不是想办法删它：`assignGraphClusters` 的 `GENERIC_CEIL`（`public/utils.js:202`，总数的 50%）会主动排除高覆盖 tag,只要库里存在覆盖率低于该线的主题域 tag,过泛 tag 就自己落选。实测 47 条：补主题域后最大簇从 35/47 降到 10/47,`cc-mem`（85% 覆盖）一个没删。

真要物理删 tag,只剩 `wrangler d1 execute --remote` 直改 D1 一条路,且会绕过 Vectorize metadata 同步——属于需要单独裁决的动作,不在日常复核范围。

**全量含统计**（PR 归并前兜底用，一次调用拿到 `recall_count` / `importance_score`）：

```bash
BRAIN_EXPORT=$(mktemp "${TMPDIR:-/tmp}/brain_export.XXXXXX")
trap 'rm -f "$BRAIN_EXPORT"' EXIT
curl -sS -m 30 -A "curl/8.7.1" \
  -H "Authorization: Bearer ${SECOND_BRAIN_TOKEN:?未配置 SECOND_BRAIN_TOKEN，见 brain-route 插件 README 的 Environment Variables 节}" \
  "${SECOND_BRAIN_URL:?未配置 second-brain 端点，请设置 SECOND_BRAIN_URL，见 brain-route 插件 README 的 Environment Variables 节}/export" > "$BRAIN_EXPORT"

jq '[.entries[]
     | select(.recall_count == 0)
     | select((now - (.created_at / 1000)) > (60 * 86400))]' "$BRAIN_EXPORT"

rm -f "$BRAIN_EXPORT"
```

筛出 `recall_count == 0` 且 `created_at` 超 60 天的条目——这些是写进去后从未被任何查询命中的沉底条目，是盲区，只能靠这条命令找到。

**返回 `[]` 先别当命令坏了**：库里最老条目不足 60 天时，空结果就是正确答案。先用 `jq '[.entries[]|select(.recall_count==0)]|length'` 看有多少零召回条目、用 `jq -r '[.entries[]|(now-(.created_at/1000))/86400]|max // 0|floor'` 看最老条目多少天，再判断是筛空还是解析错——两条命令在 `entries` 为空时都返回 `0`，不会报错（`max` 在空数组上原生返回 `null` 会导致后续 `floor` 报 `number required` 崩掉，`// 0` 兜底避免这个问题）。

**三个端点的返回形态不同，jq 不能照抄**：

| 端点 | 条目在哪 | `tags` | `created_at` |
|---|---|---|---|
| `/recall` | `.results[]` | 数组 | number（epoch **毫秒**） |
| `/list` | 顶层就是数组，`.[]` | **JSON 字符串**，需 `fromjson` 才能当数组用 | number（毫秒） |
| `/export` | `.entries[]`（顶层是 `{ok, version, exported_at, entries, edges}`） | 数组 | number（毫秒） |

两个易错点：对 `/export` 写 `.[]` 会迭代到 `ok`（布尔）并报 `Cannot index boolean with string ...`；`created_at` 是毫秒数字，`fromdateiso8601` 只吃 ISO 字符串，对它用必然失败——要除 1000 而不是转换。

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
     -H "Authorization: Bearer ${SECOND_BRAIN_TOKEN:?未配置 SECOND_BRAIN_TOKEN，见 brain-route 插件 README 的 Environment Variables 节}" \
     -H "Content-Type: application/json" \
     -d '{"id":"<保留条目id>", "content":"<合并后完整内容> #tag1 #tag2", "volatility":"<该条原值，从 /export 抄回>"}' \
     "${SECOND_BRAIN_URL:?未配置 second-brain 端点，请设置 SECOND_BRAIN_URL，见 brain-route 插件 README 的 Environment Variables 节}/update"
   ```

   `volatility` 必须从 `/export`（或 `/list`）里该条的原值原样抄回,不能随手填一个值或漏传——漏传或写错跟误传 `tags` 字段是同级事故:都是静默生效、不报错,事后只能靠比对备份才能发现。

   ```bash
   # 删除被合并掉的那条
   curl -sS -m 30 -A "curl/8.7.1" \
     -H "Authorization: Bearer ${SECOND_BRAIN_TOKEN:?未配置 SECOND_BRAIN_TOKEN，见 brain-route 插件 README 的 Environment Variables 节}" \
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
