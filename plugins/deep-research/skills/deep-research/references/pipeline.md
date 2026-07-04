# 研究管线定义（7 Stage + Stage 8 experimental）

本文件定义 v3 管线的 7 个 stable Stage、1 个 experimental Stage（Stage 8 Landing）、Stage 间契约和 Gate 触发条件。

---

## Stage 总览

```
Sources → ❰G0❱ → [harvester] Acquisition → ❰G1❱
  → [harvester] Sanitization
  → [analyst] Decomposition → ❰G2❱
  → [analyst+Lead] Synthesis → ❰G3❱
  → [reviewer] Validation
  → [Lead] Delivery
  ⋯⋯ → [Lead] Landing & Feedback（Stage 8, experimental, 仅落地后触发）
```

> **G0 需求门**（Sources 后、Acquisition 前）：Lead 与用户对齐问题正确性 + 根本目标，输出 Go / Recycle。区别于 G1/G2/G3 审「执行充分性」，G0 审「问题正确性 + 根本目标对齐」，在源头拦截「解决错问题」。G0 产出 `intake/requirements/research-goal.md`（primary_job + Non-Goals + 用户 sign-off），是举证责任锚定（[principles.md](./principles.md) 元原则 0）的物理入口。定义见 [quality-gates.md](./quality-gates.md)。
>
> **管线形态**：v3 初始把研究当单向漏斗（终点 Delivery）；「框架演进调研」证明研究是螺旋——Delivery 之后的落地实测会推翻结论、裂变补轨。落地回填走 deliverables 层的 Correction Record（见 [principles.md](./principles.md) 原则 5），不回写 pipeline。**Stage 8 Landing & Feedback** 把这条螺旋显式落成管线阶段（见下）。
>
> ⚠ **EXPERIMENTAL（Stage 8）**：本阶段为 track_h 草案（#11）落地，待 ≥1 真实项目字面复制验证后转 stable。验证通过去标记升 stable；暴露问题走 Correction Record 修正（原则 5）。验证记录见 #11。**Stage 8 对存量项目可选、不强制**，不影响已 stable 的 7-Stage 主体。

## Stage 详细定义

### Stage 1: Sources（Lead 执行）

| 项 | 说明 |
|---|---|
| 执行者 | Lead session |
| 输入 | 用户需求 + 项目 CLAUDE.md |
| 输出 | 采集指令（含目标、源列表、范围约束、脱敏豁免清单） |
| 产物位置 | 不落盘，直接作为 harvester 的 Task prompt |

Lead 确定信息源策略：学术 / Web / API / 代码 / 文献。playbook 提供该类型的默认源列表，Lead 可增删。

### ❰G0❱ Problem Validation Gate: 需求正确性 + 根本目标对齐

- 触发点：Sources 完成后、Acquisition 启动前
- 执行者：**Lead + 用户对齐**（主上下文，不派 subagent）
- 判定维度：问题陈述（Job Story）、问题/解法分离、判定权归属、最大不确定性、**根本目标已与用户 sign-off**
- 产出：`intake/requirements/research-goal.md`（primary_job + goal + non_goals + 研究类型 + sign-off）
- 输出：**Go**（进入采集）/ **Recycle**（问题定义或根本目标含糊/缺失，不进采集）
- 细则见 [quality-gates.md](./quality-gates.md) G0 章节

### Stage 2: Acquisition（harvester 执行）

| 项 | 说明 |
|---|---|
| 执行者 | research-harvester（Task subagent），主路径经 `harvest.py` 多模型采集（gemini/gpt/claude 三面板并行 + 裁判 merge，harvest.py 路径见 SKILL.md 的路径发现约定），未启用/经豁免项目走 legacy 手工采集 |
| 输入 | Lead 的采集指令 |
| 输出目录 | `pipeline/1_raw/`（含 `harvest/<model>/findings.json`）+ `pipeline/verification/`（harvest.py 项目） |
| 产物 | 原始数据文件 + fetch-report + `merged-findings.json`（harvest.py 项目，带共识标签）+ `harvest-verify.json`（机械门校验记录） |
| 命名 | `YYYYMMDD_HHMMSS_{source}_{description}` |

fetch-report 必填字段：tier 分层（T1/T2/T3）、翻页统计、错误汇总、中英文搜索覆盖率；harvest.py 项目另加多模型共识统计、引用校验统计、本地材料清单（见 deep-research 插件的 research-harvester subagent）。

### Stage 3: Sanitization（harvester 执行）

| 项 | 说明 |
|---|---|
| 执行者 | research-harvester（同一 Task，与 Acquisition 串行） |
| 输入目录 | `pipeline/1_raw/` |
| 输出目录 | `pipeline/2_cleaned/` |
| 产物 | 脱敏后数据文件 |

脱敏协议见 deep-research 插件的 research-harvester subagent。

### ❰G1❱ Sufficiency Gate: 采集充分性

- 触发点：Acquisition + Sanitization 完成后
- 执行者：research-reviewer（mode=sufficiency）
- 适用维度：覆盖度、时效性、可信度、双语平衡
- 通过条件：见 [quality-gates.md](./quality-gates.md)
- 未通过：harvester 补充采集，重新触发 G1

### Stage 4: Decomposition（analyst 执行）

| 项 | 说明 |
|---|---|
| 执行者 | research-analyst（Task subagent） |
| 输入目录 | `pipeline/2_cleaned/`（只读） |
| 输出目录 | `pipeline/3_structured/` |
| 产物 | 域拆解文件（每域独立） |

### ❰G2❱ Sufficiency Gate: 拆解充分性

- 触发点：Decomposition 完成后
- 执行者：research-reviewer（mode=sufficiency）
- 适用维度：覆盖度、深度、交叉验证率
- 未通过：analyst 补充拆解或 Lead 决定补充采集（回退到 Stage 2）

### Stage 5: Synthesis（analyst + Lead 执行）

| 项 | 说明 |
|---|---|
| 执行者 | research-analyst + Lead session |
| 输入目录 | `pipeline/3_structured/` + `pipeline/2_cleaned/`（只读） |
| 输出目录 | `pipeline/4_extracted/` |
| 产物 | 洞察报告 + deliverables 草稿 |

Lead 参与综合分析中不可委托的连贯思考和战略判断。

### ❰G3❱ Sufficiency Gate: 综合充分性

- 触发点：Synthesis 完成后
- 执行者：research-reviewer（mode=sufficiency）
- 适用维度：6 个充分性维度 + 双环学习 + 反驳搜索
- 未通过：**FAIL** → analyst 修订或 Lead 决定回退到更早 Stage；**RECYCLE**（发生双环学习，问题假设被推翻）→ 强制回退到 G0 重校准问题定义

### Stage 6: Validation（reviewer 执行）

| 项 | 说明 |
|---|---|
| 执行者 | research-reviewer（mode=review） |
| 输入 | `pipeline/4_extracted/` + deliverables 草稿 |
| 输出 | 审阅报告（verdict + 维度评分 + 问题清单 + 修改建议） |

5 维度审阅：准确性、完整性、逻辑性、可操作性、可追溯性。verdict 规则见 [quality-gates.md](./quality-gates.md)。

### Stage 7: Delivery（Lead 执行）

| 项 | 说明 |
|---|---|
| 执行者 | Lead session |
| 输入 | 审阅通过的产物 |
| 输出目录 | `deliverables/final/` |
| 产物 | report.md + executive_summary.md + 附录 |

### Stage 8: Landing & Feedback（Lead 执行，experimental）

> ⚠ **EXPERIMENTAL（Stage 8）**：本阶段为 track_h 草案（#11）落地，待 ≥1 真实项目字面复制验证后转 stable。验证通过去标记升 stable；暴露问题走 Correction Record 修正（原则 5）。验证记录见 #11。

| 项 | 说明 |
|---|---|
| 执行者 | **Lead session**（落地实测后自评回写，不派 subagent） |
| 触发点 | 已交付结论被真实落地、产生「设计预期 vs 落地实际」的 delta 之后（与主管线异步，非每个项目必经） |
| 输入 | 已交付结论（`deliverables/final/`）+ 落地环境实测反馈 |
| 输出目录 | `deliverables/final/`（追加，不覆盖原文） |
| 产物 | landing 回填文档（五段结构，见模板）+ 按需触发的 Correction Record / 补轨 handoff |

**Landing 五段结构**（模板 [landing-feedback.md.tmpl](../assets/landing-feedback.md.tmpl)）：① 落地概览 → ② 设计→实践 Delta 表（四分类，见 [principles.md](./principles.md) 原则 5）→ ③ delta 分述 → ④ 方法论边界声明（n=1 防护）→ ⑤ 权威指针 + 补轨登记。

**Landing delta 四分类**（逐条对照「设计预期 vs 落地实际」归类，触发不同下游动作）：

| delta 类 | 触发动作 |
|---------|---------|
| ① 被验证正确 | 标注稳定，无动作 |
| ② 被推翻 | 走 Correction Record（独立文件，原则 5） |
| ③ 暴露留白 | 注册补轨 handoff（原则 6 补轨登记表） |
| ④ 正向 emergent（设计未预见的正确涌现） | 反推设计约束是否过保守，喂回下轮设计假设 |

> **Landing 不设 Gate**：Stage 8 是 Lead 落地后的自评回写，不是审阅门。Correction Record 自身的下游影响仍受原则 5 约束；裂变出的补轨独立走 G1/G2/G3（原则 6）。详见 [quality-gates.md](./quality-gates.md)「Stage 8 自检」。

---

## Stage 间契约

1. **pipeline 不可变 + 正向流动**：`pipeline/` 是不可变研究快照，数据只能从低编号目录流向高编号目录，禁止反向写入或修改已落盘产物
2. **只读上游**：下游角色对上游 pipeline 目录只有读权限
3. **修正流（deliverables 层）**：`deliverables/` 是可演进派生层。落地实测推翻结论时，走 Correction Record 追加补偿文档（不覆盖原文、不回写 pipeline），这是合法路径，**不算「反向」**。机制见 [principles.md](./principles.md) 原则 5
4. **Landing delta 分流（Stage 8, experimental）**：Stage 8 识别的 delta 按四分类分流到既有 stable 机制，不新造路径——②被推翻 → Correction Record（原则 5）；③暴露留白 → 补轨 handoff，录入项目 CLAUDE.md 补轨登记表（原则 6）；④正向 emergent → 喂回下轮设计假设（无文件落点，是上行信号）。全部落 deliverables 层或登记表，不回写 pipeline
5. **命名一致**：所有 pipeline 产物使用 `YYYYMMDD_HHMMSS_{source}_{description}` 命名；补轨产物加 `track_{x}_` 前缀（见 principles.md 原则 6）
6. **Gate 阻塞**：G0/G1/G2/G3 未通过时，后续 Stage 禁止启动
7. **回退权限**：只有 Lead 可以决定 Stage 回退。G3 裁决 RECYCLE 时强制回退到 G0 重校准问题定义（区别于 FAIL 的原阶段补充）

**关联文件**：[principles.md](./principles.md) · [quality-gates.md](./quality-gates.md) · 角色定义见 deep-research 插件的 research-harvester / research-analyst / research-reviewer subagent
