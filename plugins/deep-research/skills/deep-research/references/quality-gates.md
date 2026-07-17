# 质量门控机制

本文件定义 G0 需求门、三级 verdict、Sufficiency 裁决（含 RECYCLE）、双安全阀、Sufficiency Gate rubric 和审阅 5 维度。设计参考了 plan-review hook 的对抗审阅模式；G0 门与双环/反驳维度由「框架演进调研」落地（借 JTBD / Stage-Gate / 双环学习 / Einstellung Effect 研究）。

---

## G0 Problem Validation Gate（需求门）

研究需求形成后、Acquisition 启动前触发。区别于 G1/G2/G3 审「执行充分性」，**G0 审「问题正确性 + 根本目标对齐」**——在源头拦截「解决错问题」这类需走完整个落地周期才暴露的坑（前项目把判定权错放系统侧，认知科学诊断为 Einstellung Effect）。

> **G0 是举证责任锚定（元原则 0）的物理入口**：这是全程唯一引入「模型外信号」的环节。primary_job 与 Non-Goals 由**用户**确认（不是 Lead 自评臆断），后续 G1/G3 的 cite 回链检查全部锚定本门产出的 `research-goal.md`。机制见 [principles.md](./principles.md) 元原则 0。

| 项 | 说明 |
|---|---|
| 执行者 | **Lead + 用户对齐**（主上下文，不派 subagent，不消耗采集预算） |
| 触发点 | 研究需求形成后、Acquisition（Stage 2）启动前 |
| 产出 | `intake/requirements/research-goal.md`（primary_job + goal + non_goals + 研究类型 + 用户 sign-off） |
| 输出 | **Go**（问题清晰且目标已 sign-off，进入采集）/ **Recycle**（问题定义或目标需修订，不进采集） |

判定 5 维度：

1. **问题陈述**：以 Job Story 格式表达「When [情境]，需要 [动机]，以便 [结果]」（借 JTBD）。
2. **问题/解法分离**：问题陈述不含预设解法（solution-agnostic）——避免把「想用的方案」伪装成「要解的问题」。
3. **判定权/控制权归属**：显式标注哪些判断由系统做、哪些由 LLM/用户做 ← 直接针对前项目踩的坑。
4. **最大不确定性识别**：标出方向上最大的未知（借 Boehm 风险象限）。
5. **根本目标已与用户对齐并 sign-off**（元原则 0 落点）：`primary_job` + Non-Goals 已由用户确认，落盘到 `research-goal.md`。Non-Goals 必须显式写「什么不能当判据」（直杀判据漂移）。

> **G0 不设 Kill，但 primary_job 含糊/缺失 → Recycle**：研究问题校准后继续，只在「问题定义不清」或「根本目标未与用户对齐 / 含糊」时 Recycle。含糊的 primary_job 本身就是「问题未对齐」，不放行——这一条把「用户没想清就开跑」的坑挡在源头。Lead 与用户对齐即可，5 维度逐条过，避免新增门拖慢启动。

---

## Stage 8 自检（experimental，非 Gate）

> ⚠ **EXPERIMENTAL（Stage 8）**：本节为 track_h 草案（#11）落地，待 ≥1 真实项目字面复制验证后转 stable。验证记录见 #11。

**Stage 8 Landing 不新增 Gate**——它是 Lead 落地实测后的自评回写，不是审阅门，不派 reviewer。理由：Landing 消费的是真实落地反馈而非待审产物，其下游动作（Correction Record / 补轨）各自已受 stable 机制约束，无需再设一道门拦自己。

Lead 在写 landing 回填文档（[landing-feedback.md.tmpl](../assets/landing-feedback.md.tmpl)）时逐条自检：

| 自检项 | 要求 |
|--------|------|
| delta 四分类完整 | 每条「设计预期 vs 落地实际」delta 已归入 ①/②/③/④，无遗漏（四分类见 [principles.md](./principles.md) 原则 5） |
| ②被推翻有 Correction Record | 每条②已追加独立 `correction-*.md` 并双向链接（原则 5） |
| ③留白有补轨登记 | 每条③已录入项目 CLAUDE.md 补轨登记表（owner + 触发 delta + 研究目标，原则 6） |
| ④正向 emergent 已文字化 | 显式记录「这个超预期发现能否反推设计太保守」的上行信号 |
| 方法论边界声明 | n=1 防护五项（理论推广非总体推广 / 厚描述 / 竞争性解释 / 边界条件 / 复制逻辑升级）已写入 |

> 自检失败不阻塞——Stage 8 是回写不是审阅，自检是质量提示。但补轨一旦裂变出来，独立走 G1/G2/G3（原则 6），与主轨同标准。

---

## 三级 Verdict

reviewer（mode=review）产出的裁决：

| Verdict | 含义 | 后续动作 |
|---------|------|----------|
| **APPROVED** | 无阻塞问题，可进入下一 Stage | 流转到下一 Stage |
| **NEEDS REVISION** | 有具体可修复的问题 | revision_count+1，原作者修复后重新提交审阅 |
| **REJECTED** | 方向性错误 | Lead 重新决策，可能回退到更早 Stage |

**verdict 格式**：审阅报告首行必须包含 `<verdict>APPROVED</verdict>` / `<verdict>NEEDS REVISION</verdict>` / `<verdict>REJECTED</verdict>`，机器解析仅匹配标签内内容，正文中出现的关键词不会被误匹配。

## 双安全阀

防止审阅死循环，参考 plan-review 的 attempt/total 双计数器设计：

### 安全阀 1: revision 次数上限

- NEEDS REVISION 时 revision_count 递增，上限 **3 次**
- 达到上限 → escalate 给 Lead 做人工裁决
- REJECTED 重置 revision_count（方向变了，重新计数）

### 安全阀 2: 引擎调用失败

- reviewer 引擎调用失败或返回空响应 → **静默放行**（fail-open）
- 不阻塞工作流，记录失败日志供事后审计
- 这是最后防线，正常情况下不应触发

**设计哲学**：安全阀 1 保护迭代收敛；安全阀 2 保护工作流可用性。两者都是"放行"而非"阻断"——研究进度优先于完美质量。

## Sufficiency Gate Rubric（8 维度）

reviewer（mode=sufficiency）在 G1/G2/G3 三个门使用。维度 1-6 是 1-5 评分的「充分性」维度；维度 7-8 是 G3 专属的「方向正确性」质性检查，借双环学习 + Einstellung Effect 研究，并由元原则 0 增强为「前提层 + 判据层」对抗：

| 维度 | 说明 | 评分 | G1 | G2 | G3 |
|------|------|------|:--:|:--:|:--:|
| 覆盖度 (Coverage) | 信息源是否覆盖目标范围 | 1-5 | ✓ | ✓ | ✓ |
| 深度 (Depth) | 是否深入到可操作的洞察层级 | 1-5 | — | ✓ | ✓ |
| 时效性 (Recency) | 信息是否足够新 | 1-5 | ✓ | — | ✓ |
| 可信度 (Credibility) | 信息源权威度加权平均 | 1-5 | ✓ | — | ✓ |
| 双语平衡 (Bilingual Balance) | 中英文信息比例是否合理 | 1-5 | ✓ | — | ✓ |
| 交叉验证率 (Cross-Validation) | 关键事实被多源确认的比例 | 1-5 | — | ✓ | ✓ |
| 假设审计 (Assumption Audit) | 结论是否推翻原始假设（双环）+ 支撑前提是否都成立（KAC） | 检查 | — | — | ✓ |
| 证伪审计 (Falsification Audit) | 是否做反驳搜索 + 判据能否 cite research-goal + 证伪步骤是否未被偷省 | 检查 | — | — | ✓ |

> **G1 候选集完备性**（仅选型类）是 G1 的独立质性检查，不占评分维度，见上方「候选集完备性检查」章节。

**维度 7-8 详解（G3 专属，由元原则 0 增强）**：

- **维度 7 假设审计（Assumption Audit）**：合并双环学习 + Key Assumptions Check。
  - **双环学习**：研究结论是否迫使修改原始问题假设？区分单环（在原框架内修补）/ 双环（推翻原框架）。**发生双环 → 裁决 RECYCLE，回 G0 重校准问题定义**。
  - **KAC（关键假设检查）**：列出支撑核心结论的全部前提，逐条标 **Solid / Caveated / Unsupported**。**有 Unsupported 前提支撑核心结论 → 此项不通过（FAIL）**——这是攻击「前提层」，对抗「评审与生成共享同一套未验证前提」。
- **维度 8 证伪审计（Falsification Audit）**：合并反驳搜索 + 判据回链 + 证伪不可省（cite 机械门）。
  - **反驳搜索**：强制回答「如果结论是错的，最可能因为什么」+ 是否已采集足以反驳的证据（Diagnostic Time-out，对抗 Einstellung Effect）。未做 → 不通过。
  - **判据回链（机械门）**：每个评判判据必须能 cite `research-goal.md` 的**具体小节标题或原句文本**（不用行号——行号随编辑漂移会误杀）。cite 不上即判据无效。这是机械裁决，不要求 reviewer 主观重判前提（跳出同模型回音壁）。
  - **证伪不可省 + 对称举证**：结论为「维持现状 / 省成本」时，唯一能证伪当前假设的步骤必须「已做」或「已显式记录豁免理由（确证无法证伪 / 成本不对称）」二选一，**皆无 → 不通过**。现状不享有「默认正确」信用，但回链得上 primary_job 的现状结论不被额外惩罚（防矫枉过正）。

详解见 [principles.md](./principles.md) 元原则 0。

### 通过条件

- **通过 (PASS)**：适用维度的加权平均分 ≥ **3.5**
- **一票否决**：任一适用维度 ≤ **2** 分 → Gate 不通过，无论平均分
- 未通过时，reviewer 必须指出具体不足维度和改进建议

### Sufficiency 三态裁决

Sufficiency Gate 的裁决不只有 PASS/FAIL，新增 **RECYCLE**（借 Stage-Gate Recycle 机制）：

| 裁决 | 含义 | 后续动作 |
|------|------|----------|
| **PASS** | 适用维度达标 | 流转下一 Stage |
| **FAIL** | 执行质量不足（覆盖/深度/验证等不够） | 原阶段补充后重新触发同一 Gate |
| **RECYCLE** | **方向需返工**：问题定义错、需求归属错、发生双环学习 | **强制回退到 G0 / 更早阶段重新定义**，区别于 FAIL（原阶段补充即可） |

> FAIL 与 RECYCLE 的区别：FAIL 是「做得不够」，在原阶段补；RECYCLE 是「做错了方向」，必须回 G0 重校准问题。RECYCLE 由 G3 的「双环学习」维度触发（见下）。

## Gate 裁决机读标记

所有 Gate（G0-G3）裁决输出必须包含独立一行机读标记：

```
GATE_VERDICT: G<N> PASS|FAIL|RECYCLE
```

如 `GATE_VERDICT: G1 PASS`、`GATE_VERDICT: G3 RECYCLE`。这是硬性不变量——`hooks/gate_check.py` 的 SubagentStop 门禁只匹配这行标记核验「PASS 宣称」是否属实，不解析自然语言裁决文本。hook 的职责仅限核验，不复裁 Gate：`FAIL`/`RECYCLE` 是合法裁决，必须放行送达 Lead 以触发补采/回退，只有「宣称 PASS 但机械门不认」才会被拦。未输出该标记的裁决对 hook 不可见（fail-open 放行，不代表通过 Gate——处置权仍在 Lead）。

### Gate 触发点

- **G0**（Acquisition 前）：问题是否正确 + 根本目标是否对齐？Job Story / 问题解法分离 / 判定权归属 / 最大不确定性 / 根本目标 sign-off。Lead 与用户对齐，输出 Go / Recycle。
- **G1**（Acquisition 后）：采集是否充分？覆盖度、时效性、可信度、双语平衡 + **候选集完备性**（仅选型类研究）
- **G2**（Decomposition 后）：拆解是否充分？覆盖度、深度、交叉验证率
- **G3**（Synthesis 后）：综合是否充分 + 方向是否正确？全部 6 个充分性维度 + 假设审计（双环学习 + KAC）+ 证伪审计（反驳搜索 + cite 回链）

### 候选集完备性检查（G1，仅选型类研究）

> **适用条件**：仅当研究产物为「N 个互斥方案择一」（`research-goal.md` 研究类型 = `selection`）时触发。非选型类研究（综述 / 趋势 / 事实核验）此项 **N/A**，不强制。这是举证责任锚定（[principles.md](./principles.md) 元原则 0）在候选集层的落点。

质性检查（非 1-5 评分），G1 触发，规则：

- **候选基数 < 3 → 强制补搜**（借 Paul Nutt 决策研究：单/双方案决策失败率是多方案的数倍，~85% 失败决策从未生成替代方案）。补足 ≥3 个独立候选后方可进入 Decomposition。
- **饱和判定**：harvester 声明「搜完」时必须回答「最近 2 轮检索有无新候选**类别**出现」。有 → 继续搜；无 → 允许停止，但须在 fetch-report 标注 `saturation reached after N rounds`（借 PRISMA 主题饱和 + 信息觅食停止规则）。
- 未做饱和判定、或候选基数 < 3 未补搜 → **G1 不通过（FAIL）**。

### 引用校验机械门（G1，harvest.py 项目）

项目启用 `harvest.py` 采集时（通过 deep-research skill 说明的 harvest.py 路径发现约定获取，见 SKILL.md），G1 追加一道**确定性代码门**（非 LLM 判断），由 `python3 <harvest.py 路径> check <project-dir>` 执行，三态 exit code：

| exit code | 含义 | G1 处置 |
|-----------|------|---------|
| 0 | PASS：引用校验通过、法定人数达标、claims > 0、（被拒 claim 数 < 2 或 INVALID 引用率 ≤ 5%） | 机械门通过，继续走上方 Sufficiency 评分 |
| 1 | FAIL（含 `verdict: UNAVAILABLE`，即多模型采集全挂） | **G1 自动 FAIL 阻塞**，须上报用户裁决；**禁止静默转 legacy 继续采集**——不完整调研冒充完整调研比失败更糟。恢复路径：修复后重跑 `harvest.py run`，或经用户显式同意写入 `pipeline/verification/legacy-exemption.md` 后转 N/A |
| 2 | N/A：项目从未启用 harvest.py（现行人工采集流程不受影响），或存在用户豁免记录 `legacy-exemption.md` | 机械门不适用，走现行人工 Sufficiency 审查 |

引用率门槛是**双条件与**：被拒 claim 数 ≥ 2 **且** INVALID 引用率 > 5% 才判 FAIL——真实冒烟中出现过小样本下单条孤立被拒（已过一次重试、已被剔除出最终产物）把整锅判 FAIL 的假阳性，门槛本意是拦系统性造假，不是拦单条噪声。被拒 claim 的具体内容和拒绝原因见 `harvest/<alias>/rejected_claims.json`。

法定人数达标但存在缺席模型（quorum_met = true，非全员存活）不算 FAIL，但 reviewer 须在报告中标注哪一路模型缺席及原因。

机械门与 Sufficiency 评分是**与**关系：机械门 FAIL 直接阻塞，不进入评分；机械门 PASS/N/A 后仍须过既有覆盖度/时效性/可信度/双语平衡评分。

## 审阅 5 维度（mode=review）

reviewer 执行 Validation Stage 时使用：

| 维度 | 说明 | 评估要点 |
|------|------|----------|
| 准确性 (Accuracy) | 数据和事实是否正确 | 交叉验证结果、数据源可靠性 |
| 完整性 (Completeness) | 是否覆盖研究范围所有关键方面 | 目标范围对照检查 |
| 逻辑性 (Coherence) | 推理链是否严密，结论是否自洽 | 论据→结论的逻辑链 |
| 可操作性 (Actionability) | 建议是否具体可执行 | 避免空泛建议 |
| 可追溯性 (Traceability) | 结论是否能追溯到具体信息源 | pipeline 引用完整性 |

每维度 1-5 分，审阅报告必须包含每维度评分和具体问题。

## 作废集核销检查（Stage 6，存在 decision-pivot 时适用）

> **适用条件**：仅当项目 `intake/requirements/` 下存在至少一份 `decision-pivot-*.md` 时触发。无 pivot 的项目此项 **N/A**，不强制。机制详见 [pipeline.md](./pipeline.md)「decision-pivot 作废集核销」、脚本 `scripts/pivot_scan.py`，设计权威 [research#48](https://github.com/WooDragon/research/issues/48)。

质性检查（非 1-5 评分，附加于上方 5 维度审阅），Stage 6 触发，规则：

- **前置条件**：pivot 必须已通过 `pivot_scan.py --check-signoff`（废止短语清单已列全且非纯占位符 + signed_off 段「用户已确认决策变更/对齐状态」与「废止短语清单已列全」两个 checkbox 均已打勾）。未通过 check-signoff 的 pivot 不算生效，本检查不适用，但 reviewer 须在报告中标注「pivot 未 signed-off，作废集核销待补」。
- **核销对象是盘上 TSV，不是现场重算**：`pivot_scan.py --scan` 产出的工单落盘于 `pipeline/verification/pivot-worklist-<pivot 文件名 stem>.tsv`（4 列：`文件:行` / 命中短语 / 该行内容 / 分类）——Stage 6 核销的权威依据是这份文件本身，reviewer 直接读取盘上 TSV，不是每轮重新跑 scan 凭内存印象判断。
- **逐行核销，不许抽样**：对 TSV **每一行**逐条核验：① 第 4 列分类已回填（历史留档合法 / 现行口吻必改）；② 判为「现行口吻必改」的行，对应文件/行已实际修订为新判据口吻，不再是旧判据措辞。这是确定性清单核对，不是整体印象判断——工单有 N 行，回传时须明确 N 行各自的处理状态，不得凭抽样撞见几行就下结论（这正是此前四轮评审各剥一层的病灶）。
- **未核销 → 不得 APPROVED**：TSV 中存在第 4 列为空、或「现行口吻必改」未实际修订的行 → Stage 6 verdict 不得为 `APPROVED`，至少 `NEEDS REVISION`；未核销行比例高、或涉及报告核心结论/标题/摘要层 → `REJECTED`。
- 扣分/定级细则见 [review-rubric.md](../assets/review-rubric.md)「作废集核销」。

## 对抗审阅流程

reviewer 发现问题后：
1. reviewer 产出审阅报告（含 verdict + 问题清单 + 修改建议）
2. 原作者（harvester/analyst）可在修订中辩护
3. reviewer 必须回应辩护内容后重新裁决（不能忽略辩护）
4. revision_count 达到上限 → escalate 给 Lead

---

**关联文件**：[pipeline.md](./pipeline.md) · reviewer 角色定义见 deep-research 插件的 research-reviewer subagent
