# 研究框架索引

本目录包含 v3 研究框架的执行指令文件。研究任务执行时按需读取。

> 本文件对应原框架的 `framework/INDEX.md`，搬入插件后改名为 `framework-INDEX.md` 以与 `playbooks-INDEX.md` 区分。

---

## 文件清单

| 文件 | 标题 | 一句话描述 | 何时读取 |
|------|------|------------|----------|
| [principles.md](./principles.md) | 核心原则 | 元原则 0 举证责任锚定（横切）+ 独立性、分离性、可追溯性、交叉验证 + 结论演进修正（含 Landing delta 四分类）、补轨机制 6 条原则 | 每个研究项目启动时 |
| [pipeline.md](./pipeline.md) | 管线定义 | 7 stable Stage + G0 需求门（Lead+用户对齐根本目标）+ Stage 8 Landing（experimental）+ Stage 间契约 + Gate 触发条件 | 执行任何 Stage 前 |
| [context-economics.md](./context-economics.md) | 上下文经济学 | Task 隔离规则 + 角色选择表 + 搜索工具链 | 分配工作或启动 Task 前 |
| [quality-gates.md](./quality-gates.md) | 质量门控 | G0 需求门（含目标 sign-off）+ G1 候选集完备性（选型类）+ Stage 8 自检 + 三级 verdict + Sufficiency 三态裁决 + 8 维度 rubric（维度 7 假设审计 / 维度 8 证伪审计）| reviewer 执行审阅 / Lead 过 G0 或 Stage 8 时 |

## 关联

| 项 | 说明 |
|------|------|
| research-harvester / research-analyst / research-reviewer | 3 个专业角色，已成为 deep-research 插件的原生 subagent（用 Task 工具以 `deep-research:research-harvester` 等 spawn），不再是可链接的文件 |
| [playbooks-INDEX.md](./playbooks-INDEX.md) | 按研究类型的执行手册（提供默认源列表和流程变体） |
| `../assets/` | 报告模板和项目初始化模板 |
