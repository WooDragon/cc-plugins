# 报告交付物矩阵

定义 Delivery Stage 最终输出的结构和要求。所有交付物输出到 `deliverables/final/`。

---

## 交付物清单

| 文件 | 路径 | 必需 | 说明 |
|------|------|:----:|------|
| 主报告 | `report.md` | Y | 完整研究报告 |
| 执行摘要 | `executive_summary.md` | Y | 1-2 页核心发现和建议 |
| 参考文献 | `references.md` | Y | >= 20 篇，含完整链接 |
| 术语对照表 | `glossary.md` | 按需 | 中英文术语对照（双语研究必需） |
| 附录 | `appendix/` | 按需 | 详细数据、方法论说明 |

---

## 主报告 (report.md)

```
# {研究主题}深度研究报告

## 执行摘要
- 核心发现（3-5 个要点）
- 关键建议（具体可执行）
- 影响评估（短期/长期）

## 1. 研究背景与目标
### 1.1 研究背景
### 1.2 研究目标
### 1.3 研究范围
### 1.4 研究方法

## 2. 现状分析
### 2.1 行业概况
### 2.2 技术现状
### 2.3 市场格局
### 2.4 关键玩家

## 3. 深度洞察
### 3.1 核心发现
### 3.2 趋势分析
### 3.3 机会识别
### 3.4 风险评估

## 4. 案例研究
### 4.1 成功案例
### 4.2 失败教训
### 4.3 最佳实践

## 5. 战略建议
### 5.1 短期行动（0-6 个月）
### 5.2 中期规划（6-12 个月）
### 5.3 长期愿景（1-3 年）

## 6. 实施路线图
### 6.1 优先级排序
### 6.2 资源需求
### 6.3 时间计划
### 6.4 成功指标

## 附录
### A. 详细数据
### B. 方法论说明
### C. 术语表

## 参考文献
（独立文件 references.md，此处放简要索引）
```

---

## 执行摘要 (executive_summary.md)

**长度**：1-2 页（500-1000 字）

**必含内容**：
- 研究背景（1-2 句）
- 核心发现（3-5 个要点，每点 1-2 句）
- 关键建议（按优先级排序，具体可执行）
- 风险提示（主要不确定因素）

**禁止**：冗长背景介绍、技术细节堆砌、空泛建议。

---

## 参考文献 (references.md)

**数量**：>= 20 篇，按重要性排序。

**格式**：
```
[序号] 作者. "标题". 来源. 年份. [链接](URL) [访问日期: YYYY-MM-DD]
```

**示例**：
```
[1] Smith, J. "AI Industry Report 2024". Gartner Research. 2024. [链接](https://example.com/report) [访问日期: 2026-05-18]
[2] 张三. "大模型技术趋势分析". InfoQ 中文站. 2025. [链接](https://infoq.cn/article/xxx) [访问日期: 2026-05-18]
```

**要求**：
- 每条引用**必须**包含可访问的完整 URL
- 标注访问日期
- 中英文文献分别标注语言来源
- 按重要性而非字母顺序排序

---

## 术语对照表 (glossary.md)

双语研究场景**必须**产出。

**格式**：

| 英文术语 | 中文术语 | 缩写 | 定义 |
|----------|---------|------|------|
| {English Term} | {中文术语} | {ABBR} | {简要定义} |

---

## 附录 (appendix/)

按需产出，可包含：
- `detailed_data.md` -- 详细数据表格
- `methodology.md` -- 研究方法论说明
- `raw_comparisons.md` -- 原始对比矩阵

---

## HTML 展示报告 (report.html)

`report.html` 是 report.md 的 **VIEW 层**——自包含 HTML 展示视图，不是独立权威。由插件内置的确定性渲染器 `scripts/render.py` 在 Delivery 定稿后渲染（stdlib-only，零时间戳/零随机，byte-identical 幂等），契约是 `report.html = f(report.md)`：零新事实，只把已有内容映射进 house style 组件（verdict-bar / table-wrap / phase-timeline 等），可选的 `<!-- ds:xxx -->` 视觉标注由 research-analyst / research-publisher 按需产出。ds: 指令词汇表、内容映射见 [report-html-guide.md](./report-html-guide.md)；模板结构见 [report-shell.html.tmpl](./report-shell.html.tmpl)。delivery 门是重渲即校验：首渲 `render.py` 成功 + 非空 + `git add` 建基线；复渲 `render.py && git diff --exit-code report.html`，md 改而 html 未同步重渲即 FAIL。

---

**关联文件**：[pipeline.md](../references/pipeline.md) Stage 7 · [review-rubric.md](./review-rubric.md) · [report-html-guide.md](./report-html-guide.md)
