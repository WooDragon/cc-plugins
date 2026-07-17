# 模板索引

本目录包含 v3 研究框架的通用模板文件。

---

| 文件 | 用途 | 使用方式 |
|------|------|----------|
| `project-claude-md.tmpl` | 项目 CLAUDE.md 模板 | 创建新项目时复制到项目根目录并填充占位符 |
| `research-goal.md.tmpl` | 研究根本目标锚模板（元原则 0 载体） | 创建新项目时复制到 `intake/requirements/research-goal.md`；G0 与用户对齐后填充 primary_job + Non-Goals + sign-off |
| `decision-pivot.md.tmpl` | 判据锚点变更记录模板（含必填「废止短语清单」段） | 判据变更时复制到 `intake/requirements/decision-pivot-N.md`；废止短语清单是 `scripts/pivot_scan.py` 确定性核销的锚点，未列全不算 signed-off（cc-plugins#126） |
| `project-gitignore.tmpl` | 项目 .gitignore 模板 | 创建新项目时复制为 `.gitignore` |
| `review-rubric.md` | 审阅 5 评分维度 + 维度6 作废集核销（质性，非评分） | reviewer (mode=review) 在 Validation Stage 参照 |
| `sufficiency-rubric.md` | 充分性 8 维度评分细则（维度 7 假设审计 / 维度 8 证伪审计 + G1 候选集完备性） | reviewer (mode=sufficiency) 在 G1/G2/G3 参照 |
| `fetch-report.md.tmpl` | 采集报告模板（含候选集完备性字段，仅选型类） | harvester 在 Acquisition 后产出，供 G1 决策 |
| `deliverable-matrix.md` | 报告交付物矩阵 | Lead 在 Delivery Stage 参照，确定最终输出结构 |
| `deliverables-index.md.tmpl` | 交付物权威关系索引模板 | 多文档 deliverables 必备，声明 PRIMARY/CURRENT/HISTORICAL（见 principles.md 原则 5） |
| `landing-feedback.md.tmpl` | Stage 8 Landing 回填模板（⚠ experimental） | Lead 在 Stage 8 落地实测后回写，五段结构（落地概览 / 四分类 Delta 表 / delta 分述 / 方法论边界声明 / 权威指针+补轨登记）。待 #11 字面复制验证后转 stable |
| `report-shell.html.tmpl` | report.html house style 模板（暗色/亮色双主题、零 JS、自包含） | 插件内置确定性渲染器 `scripts/render.py` 渲染 report.md 为 HTML 时填充占位符（不再由 agent 现场生成） |
| `report-html-guide.md` | HTML 渲染注释词汇表（`<!-- ds:xxx -->` 指令与组件类对应、内容→组件映射建议） | research-analyst / research-publisher 标注 report.md 时参照，判断内容该配哪个 ds: 指令 |

## 关联

- Playbooks: `../references/playbooks-INDEX.md` -- 研究类型剧本
- Framework: `../references/framework-INDEX.md` -- 管线、质量门控、上下文经济学
- Agents: 见 deep-research 插件的 research-harvester / research-analyst / research-reviewer / research-publisher subagent
