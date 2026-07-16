# HTML 渲染注释词汇表

契约：`report.html = f(report.md)`，零新事实，由构造保证——`scripts/render.py`
是 stdlib-only、零时间戳/零随机的确定性渲染器，同一份 report.md 渲染任意次都
byte-identical。渲染铁律（自包含/href 纯净/链接与章节守恒/零 `<script>`）不再
是需要 agent 自律遵守的规则，而是 render.py 的实现保证——这份文档因此收缩为
**纯词汇表**：`<!-- ds:xxx -->` 注释指令与 house 模板组件类的对应关系，以及
何时该标注、何时不必标注。

**执行者**：research-analyst 在 Stage 7 生成 report.md 时，或 research-publisher
（可选的视觉注释建议者角色）事后补标注，都只产出/调整 md 中的 `<!-- ds:xxx -->`
注释行本身，从不产出 HTML。实际渲染统一由 `python3 scripts/render.py
<report.md>` 执行，语法与受控子集的权威定义见该脚本的模块 docstring。

---

## 组件词汇表

| ds: 指令 | 附着对象 | 渲染成 | 内容语义 |
|---|---|---|---|
| （无注释，默认） | `##`/`###` 标题 | `.section` | 正文默认容器，每个 `##`/`###` 对应一个小节 |
| （无注释，默认） | GFM 表格 | `.table-wrap` | 表格默认映射，无需标注 |
| （无注释，默认） | 引用块 `>` | `.callout`（中性色） | 引述/提示，无需标注即得中性 callout |
| `ds:hero` | 文档级（不附着块） | `.hero` | 标题区 eyebrow/sub/meta/theme 覆写；不设默认值时从标题与首段确定性提取 |
| `ds:verdict-bar` | 列表（2-3 项） | `.verdict-bar` | 执行摘要核心结论条，`**Label**：Value`，可选 `(green)`/`(amber)` 语气 |
| `ds:card-grid` | 列表 | `.card-grid` | 并列要点/风险/tradeoff，无顺序语义 |
| `ds:pain-list` | 列表 | `.pain-list` | 并列问题/盲区清单 |
| `ds:phase-timeline` | 列表 | `.phase-timeline` | 分阶段路线图，`**Phase N · 名称**：说明`，`[optional]` 前缀标可选阶段 |
| `ds:data-grid` | 列表 | `.data-grid` | 数据/维度就绪度盘点，`**Name** \| source \| status: desc`，status 属于 {ready,partial,missing} |
| `ds:arch-diagram` | 围栏代码块 | `.arch-diagram` | ASCII 架构图/流程图，原样保留排版 |
| `ds:callout tone=...` | 引用块或段落 | `.callout` | 关键提示/核心矛盾，`tone` 可选 `green`/`amber`/`red` |
| `ds:badge type=credibility level=N` | `###` 标题 | 标题旁 `.tag` | 可信度分级徽记，N 属于 {2,3,4,5} |
| `ds:badge type=decision-record` | `###` 标题 | `.decision-record` | 该小节整体标注为「内部设计输入，非外部采集事实」 |
| `ds:appendix` | `##` 标题 | `.archived-appendix` | 整节标注为已归档/已放弃路线，灰化呈现 |

语法权威定义（参数写法、附着规则、fail-loud 行为）在 `scripts/render.py` 模块
docstring，本表只是速查。

---

## 内容→组件映射建议

这是 analyst/publisher 做标注判断的依据，**映射是判断，不是机械转换**——render.py
不会替你判断"这段该配哪个组件"，它只忠实执行你标注的指令。

| report.md 内容形态 | 建议标注 | 识别信号 |
|---|---|---|
| 执行摘要的核心结论/推荐方案 | `ds:verdict-bar`（2-3 项） | 「结论」/「推荐方案」/「核心发现」 |
| 分层建议 / 阶段路线图 | `ds:phase-timeline` | 「Phase N」/「层 1/2/3」/「短期/中期/长期」 |
| 数据/维度就绪度 | `ds:data-grid` | 「已就绪」/「缺失」/「数据空白」 |
| 并列风险/tradeoff/要点 | `ds:card-grid` | 「风险」/「tradeoff」等并列要点 |
| 并列问题清单 | `ds:pain-list` | 「盲区」/「痛点」/「问题」并列 |
| 关键提示/核心矛盾 | `ds:callout` | 「核心原因」/「关键」强调段 |
| ASCII 架构图/流程图 | `ds:arch-diagram` | 代码块含框线/箭头字符 |
| 可信度分级引用小节 | `ds:badge type=credibility` | 「Credibility N」标注 |
| 内部设计输入（非外部采集） | `ds:badge type=decision-record` | 「decision record」/「内部裁决」标注 |
| 已放弃路线存档 | `ds:appendix` | 「已归档」/「已放弃路线」标注 |
| N 方案对比矩阵 | 不标注（GFM 表格默认已是 `.table-wrap`） | markdown 表格 |
| 普通段落/列表 | 不标注 | 不满足以上任何识别信号 |

### 分级建议：完整性满足的前提下，高信息密度内容优先标注

**朴素但完整的默认渲染本身就是合格产物**——`##`/`###` 默认映射到 `.section`，
列表默认映射到 `<ul>`/`<ol>`，一个字不标注也能产出结构完整的报告。标注是在此
基础上的锦上添花，不是及格线：

- **优先标注（够格就标，没时间/没余力留白也完全可以）**：执行摘要
  核心结论、阶段路线图、数据就绪度盘点、并列问题/风险清单、核心矛盾提示、
  ASCII 架构图
- **默认不标注（大多数内容都落在这里）**：普通叙述段落、已经是表格的对比
  矩阵（`.table-wrap` 是默认映射，不需要 `ds:` 指令）

---

## 主题变体选择规则

默认 **midnight**（暗色），除非报告性质明显偏亮色场景。用 `ds:hero theme=...`
覆写：

- **midnight**（默认，不标注即为此值）：技术/工程类报告，适合大多数深度研究产出
- **daylight**：偏商业/评审场景，或用户明确偏好打印/亮色阅读

---

## 内容纪律（标注时依然适用，不因渲染确定性而失效）

- **零新事实**：`ds:hero` 的 eyebrow/sub/meta 字段只能提炼自 report.md 本身
  （标题、首段、可数出的来源条数），不得取自项目 CLAUDE.md、pipeline 中间
  产物或任何 report.md 之外的地方；render.py 对未显式覆写的字段只会从标题
  与首段做确定性提取，从不"合理推测"补全。
- **双语术语原样保留**：标注不改变 report.md 正文的中英文术语对照写法。
  render.py 对内联文本只做 markdown 到 HTML 的机械转换，不改写措辞。
- **视觉再表达不等于新事实**：把正文里已经描述过的内容用 `ds:` 指令重新编码为
  视觉组件属于「视觉再表达」，被鼓励；真正违规的只有三类——新增数据、编造
  示例、对空白做合理推测补全。判断标准是「事实本身变了没有」，不是「结构
  变了没有」。
- **Correction Record / 多文档场景如实呈现**：若 report.md 头部有 SUPERSEDED
  声明，用 `ds:callout tone=amber`（或更醒目的 `red`）标注在声明段落上，不得
  抹平已修正、已下调的结论。

---

## 标注范例

以下 markdown 片段演示词汇表里的指令如何在 report.md 里实际书写（这是标注
**输入**，不是渲染产物）：

```markdown
<!-- ds:hero eyebrow="Infrastructure Feasibility Research" sub="面向高吞吐事件管道场景的选型研究" meta="2026-07-01;Feasibility Research;12 sources" theme=midnight -->
# 消息队列中间件选型：Kafka / RabbitMQ / Pulsar 对比评估

<!-- ds:verdict-bar -->
- **结论**：可行，推荐 Kafka (green)
- **推荐方案**：Kafka（分区并行 + 生态成熟）
- **关键限制**：运维团队需补齐 ZK/KRaft 运维能力 (amber)

## 并列风险

<!-- ds:card-grid -->
- **分区再均衡风险**：扩容或 broker 故障时的分区再均衡可能造成短暂消费延迟。
- **运维学习曲线**：团队此前无 Kafka 运维经验，KRaft 模式的元数据管理需要额外培训。

<!-- ds:callout tone=amber -->
> 核心矛盾：吞吐达标的方案运维复杂度更高，运维复杂度低的方案吞吐不达标。

## 推进路线图

<!-- ds:phase-timeline -->
1. **Phase 0 · 单集群 PoC**：搭建 3 节点 Kafka 集群，验证吞吐与延迟基线。
2. [optional] **Phase 2 · 全量迁移**：灰度稳定后再评估，不预设时间表。

## 数据就绪度盘点

<!-- ds:data-grid -->
- **历史流量基线** | 监控平台 90 天留存 | ready: 可直接用于容量估算
- **跨机房延迟基线** | 无 | missing: 需补测

## 参考架构

<!-- ds:arch-diagram -->
    Producer --> Kafka Cluster (3 broker) --> Consumer Group
```

这份片段覆盖了词汇表大多数指令的协同使用，展示的是标注密度天花板，不是及格线
——完整、朴素（不标注任何 `ds:` 指令）的呈现同样是合格产物。

---

## 关联

- `render.py`（`scripts/`）— 确定性渲染器，本词汇表语法的权威实现与执行者
- `report-shell.html.tmpl` — house style HTML 模板（渲染骨架，render.py 的填充目标）
- `deliverable-matrix.md` — 交付物矩阵（report.md 的结构定义，report.html 的内容来源）
- `research-analyst` / `research-publisher` subagent — 本词汇表的使用者（标注职责，不渲染）
- `tests/test_render.py` — render.py 的确定性渲染测试（含 href 纯净、幂等、ds: 指令覆盖）
