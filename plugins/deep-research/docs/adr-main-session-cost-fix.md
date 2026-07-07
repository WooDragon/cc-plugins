# ADR: 主 session 成本根治 — 绝对规则 + 生成卸载 + reviewer scoped-Write

**状态**：Accepted（Step 0 契约冻结，供后续实现步骤引用）
**日期**：2026-07-07
**关联**：research 仓 #36/#37（成本复盘 n=2）、#38（承接方案，C 段单列）

---

## 背景与纠偏

research 仓 #36/#37 两次实测坐实：deep-research 7-Stage 调研中，**主 session（Lead，全程 opus）独占 ~90% 成本**（$379/$422、$217/$242）。

按 opus list price 拆解主 session 账单（#36 数据：input 1940万 / cache_read 1386万 / cache_write 287万 / output 10万）：

| 项 | token | 单价 | 金额 | 占比 |
|---|--:|--:|--:|--:|
| **uncached input** | 1940万 | $15/M | **$291** | **78%** |
| cache_write | 287万 | $18.75/M | $54 | 14% |
| cache_read | 1386万 | $1.5/M | $21 | 6% |
| output | 10万 | $75/M | $7.5 | 2% |

**关键纠偏**：成本核心是 **uncached input（$291/78%）**，不是 cache_read（$21/6%）。根因＝**全文穿过主上下文按全价计 input**。#38-C 原归因「cache_read 雪球」归错方向。1h cache 是补丁（只保温已缓存的，管不到全文第一次穿过上下文；且被本方案架构解法抽掉），**已砍除**。

## 决策

### 唯一绝对规则

> **主 session（`agent_id` 为空）对 `pipeline/**` 和 `deliverables/**` 下的文件，只允许持有路径指针，禁止读取其内容（Read 工具 + Bash cat 类读取）。所有内容读取 / 生成 / 审阅由 subagent 在隔离上下文完成，回传 Lead 的只有 receipt（路径 + 结构化裁决摘要），永不含全文。**

绝对规则 > 软规则：消除所有「这次就读一下」的边界情况。物理焊死靠 PreToolUse hook 按 `agent_id` 空/非空区分主/子（`pre-edit-write.sh` 已验证此机制）。

### 为何不用 teammates 分阶段持有上下文

- Claude prompt cache 仅 5min TTL：停泊的 teammate 回访即全价重载，不省钱；且它自己变成新雪球。
- teammate 核心价值＝保留跨阶段隐性上下文，**恰好捅穿框架反偏见护栏**（reviewer 与主 session 共享偏见会重演病灶，principles 元原则 0）。
- pipeline 是 DAG 单向漏斗，无「同一大 blob 反复重读」模式，无状态磁盘传递天生最优。

### 为何 reviewer 必须加 Write（非可选）

纯 Task 模型下 subagent 输出只能回 spawner（Lead）。reviewer 只读→审阅报告靠回传→内容穿过 Lead（正是要消灭的）。**内容不经 Lead 的唯一 inter-agent 通道是磁盘 → 产出者必须能落盘 → reviewer 必须 Write。** 作用域锁 `verification/`（非编号目录、gate 裁决既有归宿），不违反 pipeline 不可变。

---

## 冻结契约（Step 0 交付，实现步骤逐字对齐，唯一事实源）

### 契约① read_guard 判定规格（Step 1 实现）

- **触发**：PreToolUse，matcher `Read` 与 `Bash`。
- **拦截条件**（全部满足）：`agent_id` 为空（主 session）AND 项目已启用 deep-research（向上查到 `pipeline/` 目录）AND 目标命中 `pipeline/**` 或 `deliverables/**` 下非白名单文件。
  - Read 分支：`tool_input.file_path` 命中 → 拦截。
  - Bash 分支：命令解析出读取意图（`cat|head|tail|less|more|sed|awk`，及 `grep ""` 全量读、`echo "$(<file)"`）且目标指向受管路径 → 拦截。
- **白名单放行**（小指针文件，主 session 合法持有）：文件名匹配 `research-goal.md`、`*-manifest.*`、`*-receipt.*`、`INDEX.md`、`*.verdict`、`*-verdict.md`；或文件体积 < 阈值（建议 8KB，指针/receipt 量级）。
- **fail-open 硬约束**（任一成立即放行，never break userspace）：非 deep-research 项目（查不到 pipeline/）、拿不到 `agent_id`、路径解析异常、Bash 命令解析不出明确读大文件意图（不误伤 grep 检索/ls/find/git）。
- **拦截 stderr 指导语**（强制，防盲目重试）：
  ```
  [read_guard] Action blocked: Lead 主 session 禁读 pipeline/deliverables 全文（绝对规则，见 adr-main-session-cost-fix）。
  你必须 spawn 一个 subagent 读该文件并回传结构化 receipt（含所需字段），而不是重试本次读取。
  Blocked path: <path>
  ```
  参照 `gate_check.py` block 带 reason 的既有范式。
- **威胁模型分层（诚实分级，不 overclaim）**：Read 工具＝硬拦截（物理焊死，Lead 读文件默认主路径）；Bash＝尽力护栏（拦意外/习惯性读取模式，非对抗性沙盒——Lead 是协作方非攻击者，无动机 `python -c open().read()` 越狱）；根因层＝receipt 已含所需一切，消除「非读不可」场景。**不做 chmod/容器级隔离**（会同时禁掉同 UID 的 subagent，且对协作威胁模型是过度工程）。

### 契约② receipt schema（Step 2 实现，reviewer 回传）

所有 Gate/Validation reviewer 回传 Lead 的 receipt，永不含审阅报告全文，字段如下：

- `GATE_VERDICT: G{N} PASS|FAIL|RECYCLE`（**独立成行、原样文本**，风险1 硬约束——`gate_check.py` 靠此行触发 G1 引用校验机械门；行内不得有尾随内容，见 test_gate_check 既有断言）
- `projects/xxx/...` 项目路径（`gate_check.py` PROJECT_PATH_RE 靠此定位项目）
- `verdict`：APPROVED | NEEDS REVISION | REJECTED（mode=review）/ PASS | FAIL | RECYCLE（mode=sufficiency）
- `维度评分表`：各维度分数 + 一句话
- `报告路径`：落盘的完整审阅报告在 `pipeline/verification/` 的路径（Lead 需细节时派 subagent 按此路径读）
- **FAIL 分支硬性字段（风险2、red team R3#2，最关键）**：verdict≠PASS/APPROVED 时，receipt **必须**含 `{问题/幻觉原文摘录, 所在文件+段落指针, 错误原因, 达标所需具体改进}`——Lead 已物理禁读全文，纠错全靠 receipt 携带的定位信息驱动下一轮修正；干瘪 verdict 会断掉纠错链。

### 契约③ manifest / spec schema（Step 4/5 实现）

- **synthesis-manifest**（analyst Synthesis 第一轮回传 Lead）：每条洞察 = `{claim_id, 一句话结论, 支撑文件路径+行号指针, 冲突/取舍待决项}`。几百 token。第一轮同时产出完整草稿落盘 `deliverables/draft/`。Lead 裁决作用在 manifest 上，产出决策指令。**第二轮 analyst 只读自己草稿 + Lead 定向修正，不重读 `3_structured`**（消灭重读，替代 teammate 保温）。
- **report-spec**（Lead → Stage7 writer=analyst）：`{report 大纲, 每节裁决要点, 引用指针}`。全在主上下文，不含 4_extracted 全文。writer 按 spec + 盘上 `4_extracted` 渲染 `deliverables/final/report.md`、`executive_summary.md`，回传 `{路径, 机械门 receipt}`。

### 契约④ landing delta receipt schema + 执行者归属（Step 5b 实现）

- **归属拍板：复用 analyst**（已具 Write、已读 deliverables 语义；landing 是「读 final + 落地反馈 → 产 delta 对比」的分析活，性质同 Synthesis）。**不新增角色**。
- **delta receipt schema**：`{delta 四分类标签(①被验证正确/②被推翻/③暴露留白/④正向emergent), 每 delta 一句话结论, 支撑指针, 触发的下游动作(Correction Record/补轨 handoff/无), 落盘路径}`。Correction Record/补轨 handoff 由 analyst 落盘，Lead 只持 receipt 做四分类分流。

### 契约⑤ 绝对规则条款 + Stage 契约最终措辞（Step 3 落进 4 份 reference）

Step 3 把以下措辞落进 reference/skill，逐处消除自相矛盾软条款（风险5 清单）：

- **context-economics.md:29**「deliverables 最终整合→主上下文」→ 改为「Lead 出 spec，生成/整合由 subagent 执行，Lead 只持 receipt」。新增「Task 隔离 vs 主上下文」表顶部绝对规则条款。
- **pipeline.md:99**（Synthesis 输入 3_structured 全文）→ 改为 analyst 读全文、回传 manifest；Lead 裁 manifest 不读全文。
- **pipeline.md:129**（Stage7 执行者 Lead）→ 改为 Lead 出 spec、analyst 生成 final、reviewer 语义核验（风险2）。
- **pipeline.md:139**（Stage8 执行者 Lead）→ 改为 analyst subagent（契约④）。
- **principles.md:46**（4_extracted「analyst + Lead 写入」）→ 删「+ Lead」，Lead 不写 pipeline。
- **SKILL.md:42**（Stage7 主体 Lead 主上下文执行）→ 对齐 spec/生成卸载。
- 新增 manifest/receipt/spec/delta-receipt 定义章节，长在现有 PRIMARY/VIEW/派生层概念上。

### 风险2 缓解落点（Step 5）

Stage7 生成后，Lead spawn 轻量 reviewer（mode=review 既有能力）做 report.md/report.html 的 no-new-facts 语义核验，回传 verdict receipt（含契约② FAIL 字段）。Lead 不亲读。补上 publisher.md:91「Lead 视觉核验兜底」在绝对规则下断裂的安全网。

---

## 预期收益（量级估算，非承诺，BDD 实测校准）

主 session uncached input 1940万→~300万量级，主 session $379→~$60-80，全局 $422→~$130-160。真实收益取决于 manifest/spec 压缩率，以 Step 6 BDD「主 session input 降 ≥60% 且 G0-G3 质量门不退化」为验收基准。

## 零破坏性保证

- hook 全程 fail-open（非研究项目/无 agent_id/解析失败→放行）。
- reviewer Write 锁 `verification/`，不碰编号目录，不违反 pipeline 不可变（principles.md:52 管 1_raw→4_extracted）。
- 存量已交付项目不受影响（规则只约束新研究运行时 Lead 行为）。
- harvest.py `--no-api` local mode 兼容：门禁只管 Lead 读取，不改 harvester 采集路径；receipt 契约对 local/panel 两模式同构（G1 marker 不变）。
