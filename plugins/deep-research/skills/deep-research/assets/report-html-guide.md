# HTML 渲染设计规范

契约：`report.html = f(report.md)`，零新事实。HTML 是 report.md 的派生展示层（VIEW），report.md 永远是 PRIMARY 权威。research-publisher agent 用 `report-shell.html.tmpl`（house style 模板）渲染 report.md 为单文件 HTML 时，本文档是渲染判断的依据。

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

拿不准就用最朴素的 `section` + `p`，不要硬套组件。组件是为了让高信息密度的内容形态更易读，不是为了给每一段都找个盒子装。

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

---

## ⑥ 关联

- `report-shell.html.tmpl` — house style HTML 模板（本规范的实现载体）
- `deliverable-matrix.md` — 交付物矩阵（report.md 的结构定义，report.html 的内容来源）
- research-publisher subagent — 本规范的执行者
