# Web Research Playbook

适用于以公开信息搜集为主的研究：技术选型调研、行业趋势分析、产品竞品对比、最佳实践研究等。

---

## 适用场景

- 技术选型调研（框架/工具/平台对比）
- 行业趋势分析（市场规模、竞争格局、发展方向）
- 产品竞品对比（功能矩阵、定价、用户口碑）
- 最佳实践研究（架构模式、工程规范、运维策略）
- 政策/标准跟踪（法规变化、技术标准演进）

不适用：需要访问私有数据库、企业内部文档或付费数据源的研究。

---

## Stage 1: Sources

Lead 确定信息源策略，输出采集指令。

### 搜索关键词矩阵

**harvest.py 项目（主路径）**：关键词矩阵不再由 Lead 预生成——由各面板模型（`panel_models` 配置，当前 gemini/gpt/claude）在 Acquisition 阶段自主分解研究目标、自定关键词，记录于各自 `findings.json` 的 `keywords_used: {zh: [], en: []}` 字段。三模型异构检索策略的并集由架构保证覆盖广度（消除单模型盲区）。Lead 在 Stage 1 只需定义研究目标/范围/约束，写入 goal-file，**不预生成关键词**。

**legacy 链（未启用 harvest.py 或经用户豁免）**：仍需 Lead 建立中英文关键词矩阵：

| 核心概念 | 中文关键词 | 英文关键词 | 变体/同义词 |
|----------|-----------|-----------|-------------|
| {概念 A} | ... | ... | ... |
| {概念 B} | ... | ... | ... |

规则：
- 每个概念至少 2 个中文 + 2 个英文关键词
- 包含专业术语的多种表述（如 AI / 人工智能 / Artificial Intelligence）
- 搜索后根据结果质量迭代优化关键词

### 默认信息源列表

| 分类 | 源 | 用途 |
|------|-----|------|
| 学术 | Google Scholar, arXiv, Semantic Scholar | 论文、综述、基准测试 |
| 官方 | GitHub, 官方文档站, 官方博客 | 技术规格、API 文档、发布日志 |
| 行业报告 | Gartner, IDC, McKinsey, Forrester | 市场数据、趋势预测 |
| 技术社区 | Stack Overflow, Reddit, HackerNews | 开发者观点、实战反馈 |
| 技术媒体 | InfoQ, ACM, IEEE, The New Stack | 深度技术文章 |
| 公司博客 | Google AI Blog, Meta Engineering, AWS Blog | 前沿实践 |

Lead 可根据项目需要增删源。

---

## Stage 2: Acquisition

harvester（Task subagent）执行采集。**禁止**在主上下文直接搜索。

### 采集工具链

**主路径：`harvest.py`**（通过 deep-research skill 说明的 harvest.py 路径发现约定获取，见 SKILL.md）

```bash
python3 <harvest.py 路径> run --goal-file intake/requirements/research-goal.md --out pipeline/1_raw/ [--config <harvest.config.json 路径>] [--local-dir intake/local_sources]
```

三个异构面板模型（由 `harvest.config.json` 的 `panel_models` 配置，当前为 gemini/gpt/claude 三家族）并行各跑独立 agentic loop 自主检索，内部 search 后端链按优先级降级（gemini-grounding → tavily → DuckDuckGo 兜底，见 [context-economics.md](./context-economics.md)）；merge 阶段裁判模型产出共识标签与 Fusion 五元组分析，落盘 `merged-findings.json` + 带机械门数据的 `fetch-report.md`。exit 3（`UNAVAILABLE`）时 harvester 停止并上报 Lead，**不自行转 fallback**（见 deep-research 插件的 research-harvester subagent 工具链）。

**agentic loop 收敛语义（强制收尾兜底）**：每个 panel worker 的 loop 有 `max_steps_per_model` 轮工具预算（LLM 回合数，非工具调用数），system prompt 会告知该预算并引导「先双语搜索摸清源 → fetch 最相关几篇 → 主动停下吐 findings JSON」。**预算耗尽不再直接丢弃已采证据**：loop 结束后强制发一次收尾 synthesis 调用，让 worker 把已 fetch 的证据收敛成 findings，再走同一套引用机械门校验（追不到已 fetch 内容的 claim 照剔）。收尾仍无合法产出才判 `step_limit_no_synthesis` 失败。此设计避免「worker 采足证据却因未主动收尾被整个作废、进而拖垮 quorum」。`wall_clock_s` 超时是另一条独立硬停路径（濒临墙钟死线不再追加调用），不走强制收尾。

> **收尾调用保持 `tools=TOOL_SCHEMAS`（KV-cache 前缀稳定）**：收尾 synthesis 调用**不清空 tools 参数**——它与循环内每一轮的 payload 保持相同的 tools 块，靠 `_FORCED_SYNTHESIS_PROMPT` 的自然语言指令约束模型停止调工具。原因：多数网关将 tools 序列化进 prompt 前缀，tools 从 `TOOL_SCHEMAS` 切成 `None` 会使整个 KV-cache 前缀失效，而收尾恰好发生在上下文最大的一轮，冷算全部 token 会显著抬高延迟并逼近超时。真正阻止模型调工具的是 prompt 文本，不是 schema 的移除。（judge 调用是独立会话、不共享 worker 前缀，保持 `tools=None` 不变。）

**超时与重试（gateway completion 独立于 fetch）**：panel/judge 的 chat-completion 调用有独立超时 `completion_timeout_s`（`harvest.config.json` 的 `limits`，默认 **600s**），与 fetch/search 后端的 `call_timeout_s`（默认 180s）解耦——completion 要跑完整个 agentic 推理，长上下文下远超单次抓取耗时，二者共用一个超时会互相拖累。读取用带默认值的安全方式，旧 config 无该字段时回退 600s（向后兼容）。completion 调用的重试按**异常类归一**：HTTP 状态码错误（429/5xx）与网络层瞬时故障（读超时 `socket.timeout` / `URLError` 无状态码）走同一条 transient 退避链，避免「读超时穿透判死整个 worker」——最该重试的瞬时故障恰恰是无状态码那类。

**claude 模型走 Anthropic 原生路径（prompt caching 生效）**：`panel_models` / `judge_model` 里模型名以 `claude` 开头的，由 `harvest.py` 的 `make_client_factory` 路由到 `AnthropicGatewayClient`——走网关的 Anthropic 原生 `/v1/messages` 入站，而非 gemini/gpt 用的 OpenAI 兼容 `/chat/completions`。原因：OpenAI 兼容转换路径会静默丢弃 `cache_control`，claude 经该路径**永远不缓存**；原生路径下 system/tools/messages 三处的 `cache_control` 原样透传给上游 Anthropic，prompt caching 真正生效（实测二次调用 `cache_read_input_tokens` 命中，历史 token 仅付 0.1× 价）。协议转换（OpenAI↔Anthropic 双向）封装在 client 内的模块级纯函数，`run_worker` / `judge_clusters` 循环零改动、仍只见 OpenAI 形状。缓存断点采**最大化**策略：tools 末块 + system 末块（静态前缀，一次写入长期复用）+ messages 最后一个 content block（每轮移动的会话断点），共 3 个断点（上限 4），全用默认 5min TTL（worker loop 与 judge 均远短于 5min，不必冒 1h TTL 的 beta-header 风险与 2× 写入成本）。`completion_max_tokens`（`limits`，默认 **16384**）为 Anthropic 必填的 `max_tokens` 供值，旧 config 无该字段时回退 16384。claude 原生路径的错误可观测性独立：非 transient 4xx（400 等协议错误）**不重试**，并把 Anthropic 返回的 error body 带进异常，便于现场调协议。

**fallback 链（仅未启用 harvest.py 或经用户豁免 `legacy-exemption.md`）**：

**1. Gemini CLI（主力）**
```bash
gemini -m gemini-3.5-flash -p $'使用Google搜索查找以下问题的最新信息。\n\n规则：\n1. 必须联网搜索，严禁使用内置知识回答\n2. 搜索失败则只返回SEARCH_FAILED\n3. 返回最相关的5-10条结果\n4. 每条格式：标题 | 关键信息（1-2句） | 完整来源URL（必须包含完整路径）\n5. 不要做总结或分析，只返回搜索结果\n6. 去重：同一来源只保留最相关的一条\n7. 排除以下内容农场：CSDN、百度云、腾讯云、华为云、阿里云、火山引擎、稀土掘金\n\n搜索问题：{query}'
```

**2. WebSearch（fallback）**：Gemini CLI 输出包含 `SEARCH_FAILED`、输出为空、或退出码非零时降级使用。

**3. WebFetch**：获取搜索结果中特定 URL 的完整页面内容。

### 双语搜索规则

- 中文搜索：获取本土化实践案例、国内社区讨论、中文技术文章
- 英文搜索：获取国际前沿研究、原创论文、技术标准文档
- 每个核心关键词**必须**分别执行中英文搜索
- 记录中英文搜索结果的覆盖差异

### 信息源黑名单（禁止引用）

CSDN、百度云、腾讯云、华为云、阿里云、火山引擎、稀土掘金、未经验证的个人博客。

### 信息源白名单（优先引用）

官方文档/GitHub、知名学术期刊和会议论文、权威技术媒体（InfoQ、ACM、IEEE）、顶级技术公司博客。

### 采集产物

- 输出到 `pipeline/1_raw/`
- 命名：`YYYYMMDD_HHMMSS_{source}_{description}`
- **必须**产出 fetch-report：tier 分层（T1/T2/T3）、翻页统计、错误汇总、中英文搜索覆盖率

---

## Stage 3: Sanitization

harvester 在同一 Task 内串行执行（与 Acquisition 共享文件上下文）。

- Web 数据通常不需要重度脱敏
- **必须**标注每条信息的来源 URL 和获取时间
- 清除 HTML 噪声、广告内容、无关导航元素
- 输出到 `pipeline/2_cleaned/`

---

## G1: 采集充分性门控

适用维度：覆盖度、时效性、可信度、双语平衡。加权平均 >= 3.5 通过，任一 <= 2 一票否决。

未通过时：harvester 补充采集并重新触发 G1。

---

## Stage 4-5: Decomposition + Synthesis

- Decomposition（analyst）：按主题/维度拆解搜集结果，输出到 `pipeline/3_structured/`
- Synthesis（analyst + Lead）：
  - 交叉对比中英文信息，识别地域偏见和文化差异
  - 构建双语术语对照表
  - 整合多源洞察，生成结论
  - 输出到 `pipeline/4_extracted/`

---

## Stage 6-7: Validation + Delivery

- Validation（reviewer, mode=review）：6 维度审阅
- Delivery（Lead）：最终报告输出到 `deliverables/final/`

### 目标引用量

20 篇左右。不凑数，不灌水。每篇引用**必须**提供原文链接。

---

**关联文件**：[pipeline.md](./pipeline.md) · [quality-gates.md](./quality-gates.md) · [context-economics.md](./context-economics.md)
