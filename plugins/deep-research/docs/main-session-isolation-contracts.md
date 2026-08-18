# 主 session 隔离契约

**状态**：生效中
**性质**：运行时契约的**唯一事实源**。`hooks/read_guard.py`、`agents/research-reviewer.md`、
`skills/deep-research/references/pipeline.md` 与 `tests/test_read_guard.py` 均以本文为准。
改动本文任何契约字段时，应同步核对这四处。

本文只定义**行为契约（what）**。做出这些决策的理由、否决过的替代方案与成本实测数据属于
维护者的决策记录，不在本文范围。

---

## 绝对规则

> **主 session（`agent_id` 为空）对 `pipeline/**` 和 `deliverables/**` 下的文件，只允许持有
> 路径指针，禁止读取其内容（Read 工具与 Bash cat 类读取）。所有内容读取、生成、审阅由
> subagent 在隔离上下文完成。回传 Lead 的只有 receipt（路径加结构化裁决摘要），永不含全文。**

规则是绝对的而非软性建议，目的是消除"这次就读一下"的边界情况。物理焊死靠 PreToolUse hook
按 `agent_id` 空或非空区分主 session 与 subagent。

## 契约① read_guard 判定规格

实现在 `hooks/read_guard.py`。

- **触发**：PreToolUse，matcher 为 `Read` 与 `Bash`。
- **拦截条件**（三条全部满足才拦截）：`agent_id` 为空（主 session）；项目已启用 deep-research
  （向上查到 `pipeline/` 目录）；目标命中 `pipeline/**` 或 `deliverables/**` 下的非白名单文件。
  - Read 分支：`tool_input.file_path` 命中则拦截。
  - Bash 分支：命令解析出读取意图（`cat|head|tail|less|more|sed|awk`，以及 `grep ""` 全量读、
    `echo "$(<file)"`），且目标指向受管路径，则拦截。
- **白名单放行**（小指针文件，主 session 可合法持有）：文件名匹配 `research-goal.md`、
  `*-manifest.*`、`*-receipt.*`、`INDEX.md`、`*.verdict`、`*-verdict.md`；或文件体积低于阈值
  （8KB，即指针与 receipt 的量级）。边界：`harvest-manifest.json` 命中既有 `*-manifest.*`，按白名单放行。
  `harvest-evidence.jsonl` 与 `*-harvest-evidence.jsonl` 在体积阈值判定之前拒绝，即使远小于 8KiB。
- **fail-open 硬约束**（任一条成立即放行，never break userspace）：非 deep-research 项目
  （查不到 `pipeline/`）；目标非受管路径；命中白名单；路径解析异常；Bash 命令解析不出明确的
  读大文件意图（不误伤 grep 检索、ls、find、git）。**fail-open 落在项目层、路径层与白名单层，
  不落在 `agent_id` 层。**
- **`agent_id` 语义**：非空即 subagent，放行。空、None 或缺失即主 session，走路径判定。
  **不应**把"`agent_id` 缺失"当作技术不确定而 fail-open。主 session 的 PreToolUse 事件本就携带
  空或缺失的 `agent_id`；若对 None 放行，主 session 将永远绕过门禁，绝对规则失效。误判风险的
  兜底在路径层：即便某 subagent 的 `agent_id` 丢失而被当成主 session，也只在"研究项目内、受管
  路径、大文件"三者同时成立时才拦截，且拦截时带明确的 stderr 指引。
- **拦截 stderr 指导语**（强制，防盲目重试）：

  ```
  [read_guard] Action blocked: Lead 主 session 禁读 pipeline/deliverables 全文（绝对规则，见 docs/main-session-isolation-contracts.md）。
  你必须 spawn 一个 subagent 读该文件并回传结构化 receipt（含所需字段），而不是重试本次读取。
  Blocked path: <path>
  ```

  格式对齐 `gate_check.py` 既有的 block 带 reason 范式。
- **威胁模型分层**（诚实分级，不 overclaim）：
  - Read 工具是硬拦截。Lead 读文件默认走此路径，此处物理焊死。
  - Bash 是尽力护栏。它拦意外读取与习惯性读取模式，**不是**对抗性沙盒。Lead 是协作方而非
    攻击者，无动机用 `python -c open().read()` 越狱。
  - 根因层是 receipt 已含所需一切，消除"非读不可"的场景。
  - **不做** chmod 或容器级隔离。这类手段会同时禁掉同 UID 的 subagent，且对协作型威胁模型
    属于过度工程。

## 契约② receipt schema

所有 Gate 与 Validation reviewer 回传 Lead 的 receipt，永不含审阅报告全文。字段如下：

- `GATE_VERDICT: G{N} PASS|FAIL|RECYCLE` —— **独立成行、原样文本**。`gate_check.py` 靠此行触发
  G1 引用校验机械门，因此行内不应有尾随内容（见 `test_gate_check` 既有断言）。
- `projects/xxx/...` 项目路径 —— `gate_check.py` 的 `PROJECT_PATH_RE` 靠此定位项目。
- `verdict` —— mode=review 时取 `APPROVED | NEEDS REVISION | REJECTED`；mode=sufficiency 时取
  `PASS | FAIL | RECYCLE`。
- 维度评分表 —— 各维度分数加一句话。
- 报告路径 —— 落盘的完整审阅报告在 `pipeline/verification/` 下的路径。Lead 需要细节时派
  subagent 按此路径读取。
- **FAIL 分支硬性字段**：`verdict` 非 PASS 且非 APPROVED 时，receipt **必须**含
  `{问题或幻觉的原文摘录, 所在文件加段落指针, 错误原因, 达标所需的具体改进}`。Lead 已物理
  禁读全文，纠错全靠 receipt 携带的定位信息驱动下一轮修正；干瘪的 verdict 会断掉纠错链。

## 契约③ manifest 与 spec schema

- **synthesis-manifest**，由 analyst 在 Synthesis 第一轮回传 Lead。每条洞察的结构为
  `{claim_id, 一句话结论, 支撑文件路径加行号指针, 冲突或取舍待决项}`，量级为几百 token。
  第一轮同时产出完整草稿并落盘 `deliverables/draft/`。Lead 的裁决作用在 manifest 上，产出
  决策指令。**第二轮 analyst 只读自己的草稿加 Lead 的定向修正，不重读 `3_structured`。**
- **report-spec**，由 Lead 交给 Stage 7 的 writer（即 analyst）。结构为
  `{report 大纲, 每节裁决要点, 引用指针}`，全部留在主上下文，不含 `4_extracted` 全文。writer
  按 spec 加盘上的 `4_extracted` 渲染 `deliverables/final/report.md` 与 `executive_summary.md`，
  回传 `{路径, 机械门 receipt}`。

## 契约④ landing delta receipt schema

- **执行者是 analyst**。analyst 已具 Write 权限、已读 deliverables 语义；landing 是"读 final
  加落地反馈，产 delta 对比"的分析活，性质同 Synthesis。此处不新增角色。
- **schema**：`{delta 四分类标签（①被验证正确 / ②被推翻 / ③暴露留白 / ④正向 emergent）,
  每条 delta 一句话结论, 支撑指针, 触发的下游动作（Correction Record / 补轨 handoff / 无）,
  落盘路径}`。Correction Record 与补轨 handoff 由 analyst 落盘；Lead 只持 receipt 做四分类分流。

## Stage 7 语义核验

Stage 7 生成产物后，Lead spawn 轻量 reviewer（mode=review）对 `report.md` 与 `report.html` 做
no-new-facts 语义核验，reviewer 回传 verdict receipt（含契约② 的 FAIL 字段）。Lead 不亲读产物。
这是绝对规则下替代"Lead 视觉核验兜底"的安全网。

## 零破坏性保证

- hook 全程 fail-open：非研究项目、无 `agent_id`、解析失败三种情况均放行。
- reviewer 的 Write 权限锁在 `verification/`，不碰编号目录，不违反 pipeline 不可变
  （`principles.md` 中 pipeline 不可变一节管 `1_raw` 到 `4_extracted`）。
- 存量已交付项目不受影响：规则只约束新研究运行时的 Lead 行为。
- `harvest.py --no-api` local mode 兼容：门禁只管 Lead 读取，不改 harvester 采集路径；receipt
  契约对 local 与 panel 两种模式同构，G1 marker 不变。
