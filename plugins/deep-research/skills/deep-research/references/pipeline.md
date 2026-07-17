# 研究管线定义（7 Stage + Stage 8 experimental）

本文件定义 v3 管线的 7 个 stable Stage、1 个 experimental Stage（Stage 8 Landing）、Stage 间契约和 Gate 触发条件。

---

## Stage 总览

```
Sources → ❰G0❱ → [harvester] Acquisition → ❰G1❱
  → [harvester] Sanitization
  → [analyst] Decomposition → ❰G2❱
  → [analyst+Lead(manifest 裁决)] Synthesis → ❰G3❱
  → [reviewer] Validation
  → [Lead(spec)+analyst(生成)+reviewer(语义核验)] Delivery → [publisher] report.html
  ⋯⋯ → [Lead(对比指令)+analyst(执行)] Landing & Feedback（Stage 8, experimental, 仅落地后触发）
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
| 输入目录 | `pipeline/3_structured/` + `pipeline/2_cleaned/`（只读，analyst 读取） |
| 输出目录 | `pipeline/4_extracted/` |
| 产物 | 洞察报告 + deliverables 草稿 |

绝对规则下 Lead 禁读 `pipeline/3_structured`/`2_cleaned` 全文。执行分两轮：

- **第一轮**：analyst 读 `3_structured` 全文，同时产出完整草稿落盘 `deliverables/draft/`，并回传 Lead 一份 **synthesis-manifest**（每条洞察 = `{claim_id, 一句话结论, 支撑文件路径+行号指针, 冲突/取舍待决项}`，schema 见下「Stage 间契约」）。
- **Lead 裁决**：Lead 只读 manifest（几百 token），不读全文，在此基础上做不可委托的连贯思考和战略判断，产出定向修正指令。
- **第二轮**：analyst 只读**自己的草稿 + Lead 的定向修正指令**，不重读 `3_structured`（消灭重读，替代 teammate 保温机制），据此改稿。

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

### decision-pivot 作废集核销（cc-plugins#126 / [research#48](https://github.com/WooDragon/research/issues/48)，存在 pivot 时适用于 Stage 6）

判据锚点变更（`intake/requirements/decision-pivot-*.md`，模板 [decision-pivot.md.tmpl](../assets/decision-pivot.md.tmpl)）不是补充采集，是**推翻主 track 部分判据前提**的锚点变更；旧判据一旦被废止，交付物里残留的旧判据口吻若不核销，会误导读者。此前的核销方式是 Stage 6 审阅「抽样撞见」——四轮外部评审各剥一层才收敛（PR #46 的实测教训）。根因是工件残缺：只声明新裁决的 pivot 文件缺「被作废判据的枚举」，dirty set 无法机械计算。现改为工件契约补全 + 确定性扫描：

1. **pivot 落盘**：Lead 与用户对齐决策变更后，按模板产出 `decision-pivot-N.md`，**必须**填写「废止短语清单」段——枚举旧判据在交付物里的现行口吻关键短语。
2. **`pivot_scan.py --check-signoff`**：跑 `python3 <scripts/pivot_scan.py 绝对路径> --check-signoff <pivot.md>` 校验「废止短语清单」段非空 + signed_off 段「废止短语清单已列全」勾选项已打勾。三类 FAIL——缺「废止短语清单」段、段存在但清单为空、signoff 勾选项未打勾——exit 1 时判定一致：**本 pivot 不生效**，阻断进入后续传播核销与 Stage 6（不触发下游任何管线动作——不进 supplement 补采、不进 Stage 6 核销）。这是「废止短语清单」作为必填段的强制力落点：补全清单并勾选后重跑直至 exit 0，方可继续。
3. **`pivot_scan.py --scan` 出工单**：check-signoff 通过后跑 `python3 <scripts/pivot_scan.py 绝对路径> --scan <pivot.md> --root <project_dir>`，对 `deliverables/**` 下的 `.md` 文件 + 项目根 `CLAUDE.md`/`README.md` 做确定性 grep（`intake/requirements/**`、`pipeline/**`、`deliverables/**` 下的非 `.md` 文件如 `report.html` 显式不扫，理由见脚本 docstring），产出逐命中工单（`文件:行` + 命中短语 + 该行内容 + 待填分类）。
4. **工单二分类走 haiku 档**：每条命中判断「历史留档合法」（如附录留档、Correction Record 里刻意保留的旧结论）还是「现行口吻必改」（正文仍以旧判据口吻陈述、误导读者）——这是确定性 grep 命中后的规则化分类，不涉及生成或深度理解，按上下文经济学派 haiku 档执行（[research#48](https://github.com/WooDragon/research/issues/48) 原文：「haiku 档即可」）。
5. **修订落笔走 sonnet 档**：「现行口吻必改」项的实际改写——理解上下文、把措辞改写到吻合新判据——是生产落地活，不给 haiku，仍按 sonnet 档执行（analyst 承接）。
6. **Stage 6 逐项核销**：reviewer 在 Validation 审阅时，对工单的**每一条命中**逐项核验分类已判定 + 「现行口吻必改」项已实际修订，取代此前的抽样撞见——细则见 [quality-gates.md](./quality-gates.md)「作废集核销检查」与 `assets/review-rubric.md`。

### Stage 7: Delivery（Lead 出 spec + analyst 生成 + reviewer 语义核验）

| 项 | 说明 |
|---|---|
| 执行者 | Lead session（出 spec）+ research-analyst（Task subagent，生成落盘）+ research-reviewer（Task subagent，语义核验） |
| 输入 | 审阅通过的产物 + `pipeline/4_extracted/` |
| 输出目录 | `deliverables/final/` |
| 产物 | report.md + executive_summary.md + 附录 + report.html（见下 HTML 渲染子步骤） |

绝对规则下 Lead 不读 `4_extracted` 全文、不亲自落盘 final 文档。执行分三步：

- **Lead 出 spec**：Lead 产出 **report-spec**（`{报告大纲, 每节裁决要点, 引用指针}`，schema 见下「Stage 间契约」），全在主上下文完成，不含 `4_extracted` 全文。
- **analyst 生成**：Lead spawn `deep-research:research-analyst`，按 spec + 盘上 `4_extracted` 渲染 `deliverables/final/report.md`、`executive_summary.md`，回传 `{落盘路径, 机械门 receipt}`。Lead 不亲读生成内容。
- **reviewer 语义核验**：生成落盘后，Lead spawn 轻量 `deep-research:research-reviewer`（mode=review 既有能力）对 report.md/report.html 做 no-new-facts 语义核验，回传 verdict receipt（含 FAIL 分支的问题定位字段，见下「Stage 间契约」receipt schema）。Lead 不亲读审阅报告全文，只据 receipt 裁决。这一步补上「Lead 视觉核验兜底」在绝对规则下的断裂——原先靠 Lead 亲眼看一遍成品的安全网，现由 reviewer 语义核验替代。

**HTML 渲染子步骤**：Delivery 定稿（report.md 等已落盘 `deliverables/final/`）后，report.md → report.html 是**确定性变换**，由插件内置的 `scripts/render.py` 执行（stdlib-only，零时间戳/零随机，同一份 report.md 渲染任意次都 byte-identical），不再由 publisher agent 现场生成 HTML（ADR：[research#47](https://github.com/WooDragon/research/issues/47) / [cc-plugins#125](https://github.com/WooDragon/cc-plugins/issues/125)）。流程分两步：

1. **可选的一次性标注**：analyst（生成 report.md 时顺手标注）或 Lead 按需 spawn `deep-research:research-publisher`（现职责已收缩为「视觉注释建议者」），在 report.md 中产出/调整 `<!-- ds:xxx -->` 注释行（词汇表见 `assets/report-html-guide.md`）——这是判断活，一次性，不产生 HTML。不标注也完全可以，render.py 的默认映射（`##`/`###`→section、表格→table-wrap、列表→ul/ol、blockquote→callout）本身就是合格产物。
2. **确定性渲染**：Lead 用发现命令解析出 `render.py` 绝对路径（沿用 SKILL.md 的 harvest.py 路径发现模式：`find ~/.claude/plugins -path '*/deep-research/scripts/render.py' 2>/dev/null | sort -V | tail -1`——多插件版本缓存（marketplace cache 下 `deep-research/<version>/`）共存时须钉最新版本，否则 byte-identical 复渲门可能对陈旧 render.py 误判），执行 `python3 <render.py 绝对路径> deliverables/final/report.md`（成功写出同目录 `report.html`；失败 exit 1 并打印 fail-loud 错误，需修正 report.md 或 ds: 标注后复渲，不静默降级）。

**delivery 门（两态，重渲即校验，零新增机制）**：
- **首渲**（`report.html` 尚未纳入版本控制）：`render.py` 成功 + `[ -s deliverables/final/report.html ]`（非空）+ `git add deliverables/final/report.html` 建立基线
- **复渲**（`report.html` 已纳管）：`render.py deliverables/final/report.md && git diff --exit-code deliverables/final/report.html` —— report.md 改了而 report.html 没有对应重渲，diff 非空即 FAIL，html/md 漂移不可能静默通过。

### Stage 8: Landing & Feedback（Lead 出对比指令 + analyst 执行，experimental）

> ⚠ **EXPERIMENTAL（Stage 8）**：本阶段为 track_h 草案（#11）落地，待 ≥1 真实项目字面复制验证后转 stable。验证通过去标记升 stable；暴露问题走 Correction Record 修正（原则 5）。验证记录见 #11。

| 项 | 说明 |
|---|---|
| 执行者 | **research-analyst**（Task subagent，落地实测后自评回写执行者；归属复用 analyst——已具 Write、已读 deliverables 语义，landing 性质同 Synthesis） |
| 触发点 | 已交付结论被真实落地、产生「设计预期 vs 落地实际」的 delta 之后（与主管线异步，非每个项目必经） |
| 输入 | Lead 的 delta 对比指令 + 已交付结论（`deliverables/final/`）+ 落地环境实测反馈 |
| 输出目录 | `deliverables/final/`（追加，不覆盖原文） |
| 产物 | landing 回填文档（五段结构，见模板）+ 按需触发的 Correction Record / 补轨 handoff |

绝对规则下 Lead 不读 `deliverables/final/` 全文。Lead 出**对比指令**（落地实测反馈 + 需要对照哪些已交付结论），spawn analyst 执行「读 final + 落地反馈 → 产 delta 对比」。analyst 回传 Lead 一份 **delta receipt**（`{delta 四分类标签, 每 delta 一句话结论, 支撑指针, 触发的下游动作, 落盘路径}`，schema 见下「Stage 间契约」），Lead 只持 receipt 做四分类分流裁决，不亲读回填文档全文。Correction Record、补轨 handoff 均由 analyst 落盘。

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
8. **主 session 只持指针**：Lead（主 session，`agent_id` 为空）对 `pipeline/**` 和 `deliverables/**` 下的文件只允许持有路径指针，禁止读取其内容（Read 工具 + Bash cat 类读取）。所有内容读取/生成/审阅由 subagent 在隔离上下文完成，回传 Lead 的只有 manifest/receipt/spec/delta-receipt（路径 + 结构化裁决摘要），永不含全文。物理焊死靠 PreToolUse `read_guard` hook。详见 [adr-main-session-cost-fix.md](../../../docs/adr-main-session-cost-fix.md)。

### manifest / receipt / spec / delta-receipt 产物定义

上一条契约催生的四类 Lead-subagent 间结构化传递产物，长在现有 PRIMARY/VIEW/派生层概念之上，不是新分层，只是数据流的传递格式约定：

| 产物 | 产生者 → 消费者 | 结构 | 用于哪个 Stage |
|---|---|---|---|
| **synthesis-manifest** | analyst → Lead | `{claim_id, 一句话结论, 支撑文件路径+行号指针, 冲突/取舍待决项}`（每条洞察一条，几百 token） | Stage 5 Synthesis 第一轮 |
| **receipt**（Gate/审阅通用） | reviewer → Lead | `GATE_VERDICT` 独立成行 + 项目路径 + `verdict` + 维度评分表 + 报告路径；FAIL 分支必含 `{问题/幻觉原文摘录, 所在文件+段落指针, 错误原因, 达标所需具体改进}` | G1/G2/G3、Stage 6 Validation、Stage 7 语义核验 |
| **report-spec** | Lead → analyst（Stage 7 writer） | `{报告大纲, 每节裁决要点, 引用指针}`，全在主上下文产出，不含 `4_extracted` 全文 | Stage 7 Delivery |
| **delta receipt** | analyst → Lead | `{delta 四分类标签, 每 delta 一句话结论, 支撑指针, 触发的下游动作(Correction Record/补轨 handoff/无), 落盘路径}` | Stage 8 Landing |

**关联文件**：[principles.md](./principles.md) · [quality-gates.md](./quality-gates.md) · 角色定义见 deep-research 插件的 research-harvester / research-analyst / research-reviewer / research-publisher subagent
