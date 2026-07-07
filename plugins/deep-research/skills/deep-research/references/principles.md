# 研究框架核心原则

本文件定义 v3 研究框架的 1 个横切元原则 + 6 个强制性原则。所有角色（harvester / analyst / reviewer / Lead）在执行任何 Stage 时必须遵守。

> 原则 1-4 是 v3 初始铁律；原则 5-6（结论演进与修正 / 补轨机制）由「框架演进调研」落地，把研究从单向漏斗扩展为螺旋闭环——落地实测、结论失效、子轨裂变都是研究的一等公民。元原则 0（举证责任锚定）由 Track I 复盘（#16）落地，补上「目标层 / 前提层 / 候选集层」的对抗机制——原有机制全在「论证层」，地基歪了对抗越强夯得越实。

---

## 元原则 0：举证责任锚定（Burden-of-Proof Anchoring）

> **这不是第 7 条并列原则，是横切元原则**：原则 1-6 约束「数据怎么流、结论怎么修正、补轨怎么开」（对象级）；本元原则约束「执行原则 1-6 时的 judgment 必须回链根本目标」——它是**约束 judgment 的 judgment**，横切所有 Stage 与 Gate。

**病灶**（#16 确诊）：研究管线的全部对抗机制（reviewer 5 维度、G3 双环/反驳搜索、plan-review）都运作在**论证层**（审推理是否自洽），没有任何机制在**目标层 / 前提层 / 候选集层**。后果是结论系统性滑向「省成本 / 维持现状 / 好收敛」的阻力最小方向（status quo bias），并把这种偏向包装成「严谨 / 高效 / 聚焦」。Track I（ctags vs tree-sitter）第一版结论「维持现状」全程绿灯通过，靠用户两次外部介入才 180° 翻盘——翻盘证据恰恰来自被「聪明省掉」的实测步骤。

**一句话**：**给阻力最小的结论加举证责任。**

### 三条不变式

**① 目标锚**：每个 project 在 G0 与**用户**对齐一个 `primary_job`（一句话 JTBD）+ Non-Goals（显式写「什么不能当判据」），落盘到 `intake/requirements/research-goal.md`。这是全程唯一价值基准，也是唯一引入「模型外信号」的环节。落点见 [quality-gates.md](./quality-gates.md) G0。

**② 判据回链**：任何评判判据必须能 cite `research-goal.md` 的**具体小节标题或原句文本**（不用行号——行号随编辑漂移），cite 不上即判据无效。这是**机械裁决**，不是让 reviewer 主观重判前提——同模型 reviewer 与主 session 共享同一套偏见，主观审前提只会重演病灶（多 agent 同模型辩论放大而非纠正偏差）。落点见 [quality-gates.md](./quality-gates.md) G3 维度 8（证伪审计）。

**③ 证伪不可省 + 对称举证**：用未验证假设省掉验证该假设的步骤是**红线**——被省掉的恰恰是唯一能证伪当前假设的环节。现状方案**不享有「默认正确」信用**，其信用**只在「已做证伪」或「已显式记录豁免理由」时成立**。
- **豁免出口**（防矫枉过正）：证伪步骤可被「确证无法证伪 / 成本不对称且已显式记录」豁免——豁免要记录，但不强制执行。这不是「为反现状而惩罚现状」：回链得上 `primary_job` 的现状结论本就不该被额外惩罚，惩罚的是「用未验证假设省掉验证步骤」这个偷懒动作，不是某个结论方向。
- 候选集层：选型类研究（N 个互斥方案择一）的候选集 < 3 或未达饱和，不许进入评判。落点见 [quality-gates.md](./quality-gates.md) G1 候选集完备性。

> **good simple vs bad simple**：本元原则专门狙击「把坏的简单（偷懒 / 不验证 / 维持现状）伪装成好的简单（good taste 式消除特殊情况）」。好品味是消除真特殊情况后的简洁；坏的简单是用没验证的假设省掉验证该假设的步骤，还以实用主义之名背书。

---

## 1. 独立性原则

- 每个研究主题**必须**创建独立项目目录（`projects/{project_name}/`）
- 禁止跨项目共享 pipeline 数据或中间产物
- 项目级 CLAUDE.md 声明该项目的特殊约束（如脱敏豁免字段、信息源白名单扩展）
- 归档项目移至 `archive/`，恢复时移回 `projects/`

## 2. 分离性原则

pipeline 分层是数据流的唯一合法路径，禁止跳层：

```
pipeline/1_raw/        → 原始采集数据（harvester 写入）
pipeline/2_cleaned/    → 脱敏后数据（harvester 写入，下游只读）
pipeline/3_structured/ → 域拆解产物（analyst 写入）
pipeline/4_extracted/  → 洞察提取产物（analyst 写入）
deliverables/          → 最终交付物（draft/ + final/）
```

**不可变性分层原则**（改自原「单向只读」铁律，借数据工程 Medallion / Event Sourcing / Kappa 分层不可变）：

- `pipeline/`（尤其 `1_raw`/`2_cleaned`）是**不可变研究快照**：一旦写入即冻结，禁止任何修改。这是真正的铁律——正向数据流（低编号 → 高编号）是唯一写入路径。
- `deliverables/` 是**可演进派生层**：从 pipeline 事实推导的视图。当落地实测推翻已交付结论时**允许修正**。
- 修正机制走 **Correction Record**（见原则 5）：追加补偿文档而非覆盖原文。修正流是 deliverables 层的独立合法路径，**不算「反向」**——它不回写 pipeline，只在派生层叠加新视图。
- analyst 禁止直接读 `1_raw/`，必须读 `2_cleaned/`；下游角色对 pipeline 上游只有读权限。

> **为何不是「禁止反向」**：旧铁律把 pipeline 与 deliverables 混为一条单向链，导致落地回填看似违规。分层后矛盾消解：pipeline 冻结是铁律，deliverables 可重算是常态，回填是正常重算而非违规。详见「框架演进调研」结论 1。

## 3. 可追溯性原则

所有信息源必须记录以下元数据：

| 字段 | 说明 | 必填 |
|------|------|------|
| source_url | 原始链接 | 是 |
| fetch_time | 获取时间（ISO 8601） | 是 |
| credibility | 可靠性评分（1-5） | 是 |
| source_type | 类型（academic/official/media/community/report/internal） | 是 |
| language | 语言（zh/en/other） | 是 |
| ttl | 信息时效性预估 | 否 |

**credibility 机读 rubric**（消除「打分随缘」）：

| 分值 | 定义 |
|------|------|
| 5 | T1 官方一手（官方文档 / 官方仓库 / 一手数据） |
| 4 | T1 二手 / 学术论文（转述权威源、经同行评审论文） |
| 3 | T2 权威媒体 / 高票社区（InfoQ、Stack Overflow 高赞回答等） |
| 2 | 可验证个人博客（作者身份可查证，但非机构背书） |
| 1 | 不可验证（匿名 / 来源不明） |

`source_type = internal` 用于本地内部材料（经 `harvest.py` 的 `read_local` 工具采集自 `intake/local_sources/`，harvest.py 路径见 SKILL.md 的路径发现约定），对应 `source_url` 写作 `local://<相对路径>`。

**落盘命名规范**：`YYYYMMDD_HHMMSS_{source}_{description}.{ext}`

**信息源分级**：

- **T1 优先源**：官方文档、GitHub 仓库、知名学术期刊（ACM/IEEE/arXiv）、顶级技术博客（Google/Microsoft/Meta）、权威行业报告（Gartner/IDC/McKinsey）
- **T2 可用源**：InfoQ、Stack Overflow、Reddit、HackerNews、知名技术博主
- **T3 屏蔽源**：CSDN、百度云、腾讯云、华为云、阿里云、火山引擎、稀土掘金、未经验证的个人博客

## 4. 交叉验证原则

- 关键事实**必须**通过至少 2 个独立源验证
- 中英文双语搜索是强制要求，不是可选项
- 每个核心概念必须用中英文分别搜索，建立术语对照表
- 交叉验证记录格式（`excerpt` 为逐字摘录，保证可比对溯源）：

```
事实: {具体事实描述}
源1: {URL} (credibility: X, language: zh/en, excerpt: "{逐字摘录}")
源2: {URL} (credibility: X, language: zh/en, excerpt: "{逐字摘录}")
一致性: 一致 / 有差异（说明差异点）
```

> **共识 ≠ 正确**：多源重合度是参考信号，不是真值判据——三源一致可能共享同一上游谣言，单源观点也可能是唯一说对的。[quality-gates.md](./quality-gates.md) G3 证伪审计不因多源重合而放松审查。

- 中英文信息出现矛盾时，必须在分析中标注并说明可能原因（地域差异、时间差异、翻译失真）
- 单一信息源引用不得超过 3 次（防止单源偏见）

## 5. 结论演进与修正原则

研究是螺旋不是漏斗。已交付结论会被落地实测推翻，框架必须支持「结论失效」而非假装结论永久正确。本原则借 ADR superseded / RFC 7322 Obsoletes-Updates。

### Correction Record（结论修正记录）

落地实测推翻某条已交付结论时，在 `deliverables/` 追加 `correction-YYYYMMDD-{slug}.md`，**不覆盖原文**。必填字段：

| 字段 | 说明 |
|------|------|
| 被修正结论 | 引用（文件 + 章节） |
| 推翻依据 | 落地实测数据 / 新来源（须可追溯） |
| 修正类型 | `Obsoletes`（完全推翻）/ `Updates`（部分修订）— 借 RFC 7322 |
| 新结论 | 修正后的判断 |
| 下游影响范围 | 哪些其他结论依赖同一原始数据，需一并审视 |

> Correction Record 是 deliverables 层的合法追加，不回写 pipeline。它消费的是不可变的 pipeline 快照 + 落地新事实。

### 结论失效标注协议

被推翻的结论文档**不删除**，加 front matter 状态机 + 文件头 SUPERSEDED block：

```yaml
---
status: active | superseded | partially-superseded | deprecated
superseded-by: <相对路径>   # superseded / partially-superseded 时必填
authority: PRIMARY | CURRENT | HISTORICAL
last-updated: YYYY-MM-DD
---
```

SUPERSEDED block（置于文件头正文）必含：替代文档链接 + 失效时间 + 失效原因 + **保留价值**（哪些部分仍有效、作为什么推理底稿）。

- **触发时机**：新结论被**接受**（非被提议）时才标旧结论失效（借 AWS ADR 流程）。
- **双向链接**：旧文档指向新文档，新文档也回链旧文档，不只是单向。

### deliverables 多文档权威规范

当 `deliverables/final/` 含多个文档时，**必须**有 `INDEX.md` 声明文档间权威关系，否则读者无法判断哪份是当前权威、哪份已过期。借 Diátaxis（分离 Reference 类与 Explanation 类）。

INDEX.md 权威关系表必含列：

| 文件 | 主题 | 状态 | 权威级别 | 替代关系 |

权威级别四态（与上方 front matter `authority` 字段一致）：

- **PRIMARY**：唯一权威入口，读者从此进入。
- **CURRENT**：有效但非唯一，需配合 PRIMARY 一起读。
- **HISTORICAL**：已被推翻，保留作推理底稿，不作为当前结论。
- **VIEW**：展示视图（如 report.html），派生自 PRIMARY，随 PRIMARY 重算，非独立权威，不参与 supersede 链。读者读 PRIMARY 获取权威结论，VIEW 仅作阅读体验增强。

模板见 [deliverables-index.md.tmpl](../assets/deliverables-index.md.tmpl)。

### Landing delta 四分类（Stage 8 入口，experimental）

> ⚠ **EXPERIMENTAL（Stage 8）**：本节为 track_h 草案（#11）落地，待 ≥1 真实项目字面复制验证后转 stable。验证记录见 #11。

Stage 8 Landing（[pipeline.md](./pipeline.md) Stage 8）对照「设计预期 vs 落地实际」逐条 delta 归四类，**作为本原则 Correction Record 与原则 6 补轨机制的统一上游入口**——四分类不是新机制，而是把已有 stable 路径按 delta 性质分流：

| delta 类 | 触发动作 | 落点 |
|---------|---------|------|
| ① 被验证正确 | 标注稳定，无动作 | — |
| ② 被推翻 | Correction Record（独立文件） | 本原则 §Correction Record |
| ③ 暴露留白 | 注册补轨 handoff | 原则 6 补轨登记表 |
| ④ 正向 emergent | 反推设计约束是否过保守，喂回下轮设计假设 | 无文件落点（上行信号） |

第④类填行业盲区：主流复盘框架有系统性「正向偏盲」，把意外收获混进「what went well」大桶，丢失「超预期发现能否反推设计太保守」的上行信号，故必须独立成类。每条 delta 须文字化（写「设计预测 vs 实践发现」的自然语言对照，verbal feedback 优于打分）。

## 6. 补轨机制原则

一个 project = **1 主轨 + 0..N 补轨**。落地或综合阶段发现的新角度，不另起 project（共享主线上下文，是 context-economics 的胜利），而在同一项目内开补轨。借 GPT Researcher 树形 Deep Research 的上下文继承 + Co-STORM Mind Map。

- **命名**：`track_{x}_{slug}` 前缀贯穿 pipeline 各层（如 `track_f1_*` / `track_g2_*`），与主轨产物区分。
- **独立门控**：每条补轨独立触发 G1/G2/G3，与主轨同标准。
- **独立子目标**：补轨深挖的是与主轨**不同的子问题**，因此有**自己的 goal 文本**（如 `intake/requirements/supplement-goal-{slug}.md`），不复用主轨 canonical `research-goal.md`。harvest.py 采集补轨用 `--goal-file <补轨goal> --project-dir <项目根> --out pipeline/1_raw/track_{x}_{slug}/`：`goal_file_sha256` 锚定到补轨自己的 goal（记入该补轨 `track_<out>.json`），主轨 `research-goal.md` 与 `harvest-verify.json` 分毫不动；补轨 goal 须在项目目录内，使审计锚定到项目内产物。（主轨仍强制 canonical goal-file，防审计撒谎。）
- **父子关系**：补轨以「原始结论节点」为父，落地 delta 为展开触发——补轨是对某条主轨结论的深挖或反驳，不是无根的新主题。
- **登记**：补轨登记到项目 CLAUDE.md 的「补轨登记表」，靠文档而非人工记忆（借 Co-STORM Mind Map 维护知识空白图谱）。
- **Landing handoff（Stage 8, experimental）**：Stage 8 Landing 识别的③暴露留白，按 SRE action-item 闭环登记为补轨——录入登记表 → 标注 owner + 触发 delta + 研究目标 → 追踪是否走完 G1/G2/G3 → 限量只注册高价值补轨（防灌水稀释主线）。这是本原则在落地反馈侧的延伸入口，见 [Landing delta 四分类](#landing-delta-四分类stage-8-入口experimental)。

> 与原则 1「独立性」的边界：完全无关的新主题仍须另起 project；补轨仅用于「同一主线下、由落地/综合裂变出的子角度」。判据是是否共享主线上下文。

---

**关联文件**：[pipeline.md](./pipeline.md) · [context-economics.md](./context-economics.md) · [quality-gates.md](./quality-gates.md)
