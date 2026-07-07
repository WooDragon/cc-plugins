# HTML 渲染设计规范

契约：`report.html = f(report.md)`，零新事实。HTML 是 report.md 的派生展示层（VIEW），report.md 永远是 PRIMARY 权威。

**本手册是 research-publisher 阶段2视觉优化的组件词汇与建议，仅在阶段1完整初稿已过机械门 PASS 后生效。价值排序：完整性优先于美观，美观优先于组件密度。**

---

## ① 组件词汇表

| 组件类 | 内容语义 |
|---|---|
| `.hero` | 标题区：eyebrow 标签、主标题、副标题、元信息（日期/范围） |
| `.verdict-bar` | 执行摘要的核心结论条，2-3 格并列展示「结论/推荐方案/关键限制」 |
| `.section` | 正文默认容器，每个一级/二级标题对应一个 section |
| 染色表（`table` + `td.good/warn/bad` + `tr.rec`） | 多方案对比矩阵，用颜色编码优劣，推荐行高亮 |
| `.card-grid` | 并列要点/风险/tradeoff，无顺序语义 |
| `.callout` | 关键提示、核心矛盾、强调性论断 |
| `.phase-timeline` | 分阶段路线图，有顺序语义（Phase 0→N，可含可选阶段） |
| `.data-grid` | 数据/维度就绪度盘点，三态标注 |
| `.pain-list` | 并列问题/盲区清单 |
| `.arch-diagram` | ASCII 架构图/流程图，保留字符画排版 + 局部染色 |
| `.tag` | 内联状态标注（推荐/现状/风险等短词） |

---

## ② 内容→组件映射规则

这是 publisher 做渲染判断的依据，**映射是判断，不是机械转换**。

| report.md 内容形态 | 渲染成 | 识别信号 |
|---|---|---|
| 执行摘要的核心结论/推荐方案 | verdict-bar（2-3 格） | 「结论」/「推荐方案」/「核心发现」标题 |
| N 方案对比矩阵 | signal 染色表（✅→good/⚠️→warn/❌→bad，推荐方案行加 `tr.rec`） | markdown 表格含 ✅/⚠️/❌ 或明显对比语义 |
| 分层建议 / 阶段路线图 | phase-timeline | 「Phase N」/「层 1/2/3」/「短期/中期/长期」 |
| 数据/维度就绪度 | data-grid（ready/partial/missing） | 「已就绪」/「缺失」/「数据空白」 |
| 并列风险/tradeoff/要点 | card-grid | 「风险」/「tradeoff」等并列要点 |
| 关键提示/核心矛盾 | callout | 「核心原因」/「关键」强调段 |
| ASCII 架构图/流程图 | arch-diagram（pre + 染色 span） | 代码块含框线/箭头字符 |
| 并列问题清单 | pain-list | 「盲区」/「痛点」/「问题」并列 |
| 内联状态词 | tag | 状态标注 |
| 普通段落/列表 | 常规 `section p` / `ul` | 不满足以上任何识别信号 |

### 分级建议：完整性满足的前提下，高信息密度内容优先组件化

以下映射按建议强度分两档，前提是阶段1的完整性已经达标——**朴素但完整的呈现本身就是合格产物**，组件化是在此基础上的锦上添花：

- **优先组件化（SHOULD，够格就用，没时间/没余力也可以留作朴素文本）**：
  - N 方案对比矩阵 → signal 染色表（推荐行加 `tr.rec`）
  - 分层建议 / 阶段路线图 / 短中长期规划 → `.phase-timeline`
  - 数据/维度就绪度盘点 → `.data-grid`
  - 并列问题/盲区/痛点清单 → `.pain-list`
  - 并列风险/tradeoff/要点 → `.card-grid`
  - 关键提示/核心矛盾 → `.callout`
  - ASCII 架构图 → `.arch-diagram`
  - 内联状态词 → `.tag`
- **默认（大多数内容都落在这里）**：普通叙述段落用 `section p` / `ul`，不必强求组件。

组件是为了让高信息密度的内容形态更易读，不是为了给每一段都找个盒子装。§⑥ 的黄金标准范例展示了组件化拉满后的效果密度，那是密度天花板，不是及格线。

---

## ③ 主题变体选择规则

默认 **midnight**（暗色），除非报告性质明显偏亮色场景：

- **midnight**（默认）：技术/工程类报告，适合大多数深度研究产出
- **daylight**：偏商业/评审场景，或用户明确偏好打印/亮色阅读

渲染时在 `<html data-theme="...">` 写入选定主题，两套 CSS 变量已在模板里定义好，无需额外改动。

---

## ④ 硬约束（渲染铁律）

- **自包含**：零外部资源。字体用 `local()`，CSS 全部内联在 `<style>` 中，不引用外部 JS/CSS/图片。产出单个 `.html` 文件必须能离线打开。
- **引用链接零丢失**：report.md 正文中所有链接都要转成 `<a href="url">…</a>`，一个不漏——既包括 `[文字](url)` 形式，也包括**裸 URL**（正文里直接出现的 `https://…`，无 markdown 语法）。机械门对两种形式都校验。例外：fenced code block 与 inline code span 内的 URL 是示例/标识符（如 curl 命令、config 片段），渲染成 `<pre>`/`<code>` 纯文本、**不** linkify，机械门也不校验它们。
- **双语术语原样保留**：report.md 中的中英文术语对照（如「Contextual Thompson Sampling」）渲染时不做增删改写。
- **零新事实**：HTML 只能包含 report.md（+ executive_summary.md / references.md）已有的信息。不得新增数据、不得编造示例、不得"合理推测"补全空白。
  - **边界界定（视觉再表达 ≠ 新事实）**：把 report.md 正文里**已经描述过**的架构/对比/流程，重新编码成 arch-diagram / signal 染色表 / phase-timeline / data-grid / card-grid 等视觉组件，属于「视觉再表达」，是被鼓励的，**不算**新事实——同一份事实换一种视觉结构呈现是允许且鼓励的。真正违规的新事实只有三类：① 新增 report.md 里没有的数据/数字，② 编造示例，③ 对空白做"合理推测"补全。判断标准不是"变了没有"，而是"事实本身变了没有"：结构变、事实不变 = 合规；事实本身被无中生有 = 违规。
- **hero 区同样受「零新事实」约束**：TITLE/EYEBROW/H1/SUB/META 都是 HTML 内容，不是可另取数的"元信息区"。这些字段只能提炼自渲染源本身——report.md 头部（标题、撰写日期、研究类型、执行摘要）、references.md（可数出的来源条数）。严禁从项目 CLAUDE.md、pipeline 中间产物、MEMORY 或任何 report.md 之外的地方取数填进 hero。hero-meta 的每一项都应能在 report.md/executive_summary/references 里 grep 到出处；report.md 头部没有的数字（如候选数）就不放，宁缺毋滥。
- **Correction Record / 多文档场景如实呈现**：若 report.md 头部有 SUPERSEDED/部分修正声明，或 `deliverables/final/INDEX.md`（权威关系索引，模板资产名是 `deliverables-index.md.tmpl`，渲染落盘后即 `INDEX.md`）标注了权威关系（PRIMARY/CURRENT/HISTORICAL/VIEW），HTML 必须用 `.callout` 显著标出「本节已被 Correction Record 修订」。**不得抹平已修正、已下调的结论**——渲染层没有权限替原始判断"美化"。

---

## ⑤ AI 味弱文案规约

规约只作用于展示层的组织性文案（标题、eyebrow、标签），**不用于重写正文事实**——渲染时不改写 report.md 的措辞与结论。

- **去营销腔**：不用「unbelievable」/「best-ever」/超级形容词/感叹号堆砌
- **主动语态、句子式大小写**：标题用句子式大小写，不用 Title Case 也不用全部大写（`.section-label` 的 uppercase 是 CSS text-transform 效果，不是文案本身要求）
- **具体优于聪明**：show don't tell，eyebrow/标签用具体信息（如「Feasibility Research」「Phase 0 · 增强指标采集」）而非抽象修辞
- **结构装置必须编码真实语义**：编号（Phase N）、eyebrow、分隔线不做纯装饰，只在内容真是序列/分类时使用；没有顺序语义的并列内容不要硬套编号
- **Chanel 原则（出门前减一件配饰）**：克制。删掉不服务内容理解的装饰性组件——如果一段内容用 `section p` 就说得清楚，不要为了"好看"硬套 card-grid 或 tag
  - **边界**：克制针对的是装饰性冗余——不服务内容理解的纯装饰组件、重复的 tag、无意义的编号。§② 列的高密度内容形态（对比矩阵/路线图/数据盘点等）有余力时优先用对应组件呈现效果更好，但朴素呈现不算失败，不必为了"不退化"而勉强套组件。

---

## ⑥ Gold-standard 渲染范例

这是**密度天花板参照，不是及格线**——够不到这个密度不算失败，丢了章节才算失败。下面这段合成范例演示 §① 词汇表里的组件如何协同构成一份丰富的报告：`verdict-bar` + signal 染色表（含 `tr.rec`）+ `card-grid` + `phase-timeline` + `data-grid` + `callout` + `arch-diagram`，每种至少一处。

主题是虚构的通用技术选型场景（消息队列中间件选型），数据全部合成，仅用于展示渲染密度，不代表真实评测结论。片段只展示 `{{CONTENT}}` 部分（复用模板 house style 的 `<style>`，此处不重复），对应 `<body><div class="page">...</div></body>` 内部结构：

```html
<header class="hero">
  <div class="hero-eyebrow">Infrastructure Feasibility Research</div>
  <h1>消息队列中间件选型：Kafka / RabbitMQ / Pulsar 对比评估</h1>
  <p class="hero-sub">面向高吞吐事件管道场景的选型研究，评估三种候选方案在吞吐、运维复杂度与生态成熟度上的权衡。</p>
  <div class="hero-meta">
    <span>2026-07-01</span>
    <span>Feasibility Research</span>
    <span>12 sources</span>
  </div>
</header>

<div class="verdict-bar">
  <div class="verdict-cell">
    <span class="verdict-label">结论</span>
    <span class="verdict-value green">可行，推荐 Kafka</span>
  </div>
  <div class="verdict-cell">
    <span class="verdict-label">推荐方案</span>
    <span class="verdict-value">Kafka（分区并行 + 生态成熟）</span>
  </div>
  <div class="verdict-cell">
    <span class="verdict-label">关键限制</span>
    <span class="verdict-value amber">运维团队需补齐 ZK/KRaft 运维能力</span>
  </div>
</div>

<section class="section">
  <div class="section-label">方案对比</div>
  <h2>三种候选方案的核心指标对比</h2>
  <div class="table-wrap">
    <table>
      <thead><tr><th>维度</th><th>Kafka</th><th>RabbitMQ</th><th>Pulsar</th></tr></thead>
      <tbody>
        <tr><td>峰值吞吐</td><td class="good">达标（&gt;500k msg/s）</td><td class="bad">不达标（&lt;50k msg/s）</td><td class="good">达标（&gt;400k msg/s）</td></tr>
        <tr><td>运维复杂度</td><td class="warn">中（需管理 broker 集群）</td><td class="good">低（单体易上手）</td><td class="bad">高（BookKeeper 额外组件）</td></tr>
        <tr class="rec"><td>生态成熟度</td><td class="good">高（Connect/Streams 生态完整）</td><td class="warn">中</td><td class="warn">中（社区较小）</td></tr>
      </tbody>
    </table>
  </div>
</section>

<section class="section">
  <h2>并列风险</h2>
  <div class="card-grid">
    <div class="card">
      <div class="card-title">分区再均衡风险</div>
      <p>扩容或 broker 故障时的分区再均衡可能造成短暂消费延迟。</p>
    </div>
    <div class="card">
      <div class="card-title">运维学习曲线</div>
      <p>团队此前无 Kafka 运维经验，KRaft 模式的元数据管理需要额外培训。</p>
    </div>
    <div class="card">
      <div class="card-title">客户端版本兼容</div>
      <p>老版本客户端在协议升级后可能出现兼容性问题，需统一升级计划。</p>
    </div>
  </div>
</section>

<div class="callout">
  <p><strong>核心矛盾：</strong>吞吐达标的方案（Kafka/Pulsar）运维复杂度更高，运维复杂度低的方案（RabbitMQ）吞吐不达标——没有同时满足两者的选项，取舍不可避免。</p>
</div>

<section class="section">
  <h2>推进路线图</h2>
  <div class="phase-timeline">
    <div class="phase">
      <div class="phase-rail"><div class="phase-dot"></div><div class="phase-line"></div></div>
      <div class="phase-content">
        <div class="phase-name">Phase 0 · 单集群 PoC</div>
        <div class="phase-desc">搭建 3 节点 Kafka 集群，跑通<strong>目标业务的真实流量镜像</strong>，验证吞吐与延迟基线。</div>
      </div>
    </div>
    <div class="phase">
      <div class="phase-rail"><div class="phase-dot"></div><div class="phase-line"></div></div>
      <div class="phase-content">
        <div class="phase-name">Phase 1 · 灰度接入</div>
        <div class="phase-desc">选取一条非核心业务线灰度接入，观察一个完整发布周期的稳定性。</div>
      </div>
    </div>
    <div class="phase">
      <div class="phase-rail"><div class="phase-dot optional"></div></div>
      <div class="phase-content">
        <div class="phase-name optional-label">Phase 2 · 全量迁移（可选，视灰度结果）</div>
        <div class="phase-desc">灰度稳定后再评估全量迁移窗口，不预设时间表。</div>
      </div>
    </div>
  </div>
</section>

<section class="section">
  <h2>数据就绪度盘点</h2>
  <div class="data-grid">
    <div class="data-cell">
      <div class="data-name">历史流量基线</div>
      <div class="data-source">监控平台 90 天留存</div>
      <div class="data-status ready">● 已就绪 · 可直接用于容量估算</div>
    </div>
    <div class="data-cell">
      <div class="data-name">峰值突发模式</div>
      <div class="data-source">日志采样</div>
      <div class="data-status partial">◐ 部分可得 · 仅覆盖工作日</div>
    </div>
    <div class="data-cell">
      <div class="data-name">跨机房延迟基线</div>
      <div class="data-source">—</div>
      <div class="data-status missing">○ 缺失 · 需补测</div>
    </div>
  </div>
</section>

<section class="section">
  <h2>参考架构</h2>
  <div class="arch-diagram">
    <pre>
Producer ──▶ <span class="hl">Kafka Cluster (3 broker)</span> ──▶ Consumer Group
                  │
                  ├─ <span class="green">Topic: events (12 partitions)</span>
                  └─ <span class="amber">Topic: retries (3 partitions, backoff)</span>
<span class="dim">副本因子 3，min.insync.replicas=2</span>
    </pre>
  </div>
</section>
```

**这是密度天花板**：一份报告里，结论用 verdict-bar，对比用染色表，风险用 card-grid，路线图用 phase-timeline，数据盘点用 data-grid，架构用 arch-diagram，核心矛盾用 callout。有余力时朝这个方向优化，但完整、朴素的呈现同样是合格产物。

---

## ⑦ 关联

- `report-shell.html.tmpl` — house style HTML 模板（本规范的实现载体）
- `deliverable-matrix.md` — 交付物矩阵（report.md 的结构定义，report.html 的内容来源）
- research-publisher subagent — 本规范的执行者
- `tests/fixtures/example.report.md` + `example.report.html` — 与本节范例同源的黄金标准 fixture 配对（md↔html 一致性 + verify 脚本自测基准）
