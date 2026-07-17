# 上下文经济学

上下文是子弹，打完就死。本文件定义何时用 Task subagent 隔离、何时在主上下文执行、如何分配角色。

---

## 唯一绝对规则

> **主 session（`agent_id` 为空）对 `pipeline/**` 和 `deliverables/**` 下的文件，只允许持有路径指针，禁止读取其内容（Read 工具 + Bash cat 类读取）。所有内容读取 / 生成 / 审阅由 subagent 在隔离上下文完成，回传 Lead 的只有 receipt（路径 + 结构化裁决摘要），永不含全文。**

绝对规则 > 软规则：消除所有「这次就读一下」的边界情况。物理焊死靠 PreToolUse `read_guard` hook 按 `agent_id` 空/非空区分主/子 session（fail-open：非 deep-research 项目/拿不到 agent_id/解析异常时放行，不误伤主 session 正常操作）。下表「Task 隔离 vs 主上下文」的划分全部服从此绝对规则——主上下文执行的场景只意味着调度/裁决在主上下文，不意味着 Lead 可读 pipeline/deliverables 全文。

## Task 隔离 vs 主上下文

### 必须 Task 隔离的场景

| 场景 | 原因 |
|------|------|
| 目标不明确的探索式检索 | 上下文消耗不可预测 |
| 需要多轮 Web 搜索的信息搜集 | 搜索结果体积大且不确定 |
| 大文件理解与分析（非简单编辑） | 长文本吞噬主上下文 |
| 测试执行与长输出解析 | 输出体积不可控 |
| 依赖影响分析 | 需要遍历大量文件 |
| harvester 的全部采集+脱敏工作 | 原始数据体积大 |
| reviewer 的审阅工作 | 审阅报告独立于主流程 |

### 主上下文执行的场景

| 场景 | 原因 |
|------|------|
| 精确可控的定向操作 | 消耗可预测 |
| 1-2 次可完成的简单搜索 | 不值得隔离开销 |
| Lead 的战略决策和综合判断 | 需要完整上下文连贯思考 |
| Stage 间调度和 Gate 裁决 | 调度逻辑必须在主上下文 |
| deliverables 最终整合：Lead 出 spec，生成/整合由 subagent 执行，Lead 只持 receipt | 绝对规则——Lead 禁读 pipeline/deliverables 全文，整合决策与整合执行分离 |

> **补充**：Lead 只持指针 / receipt / manifest，禁读 `pipeline/**`、`deliverables/**` 全文；需要内容时必须派 subagent 读取并提炼回传结构化摘要，不得自行 Read/cat。

### 反模式（禁止）

- 主上下文直接执行搜索（必须通过 Task 隔离）
- 目标已知时无意义隔离
- 需要用户实时交互的环节放入 Task

## 上下文亲和性打包

**核心规则**：共享同一批文件或背景知识的子任务**必须**打包到同一 Task，消除重复加载损耗。

- 拆分维度优先按「文件集/模块边界」而非「动作类型」
- 只有文件集完全不重叠时才拆为多个并行 Task
- 仅并行信息源不重叠的独立任务；存在数据依赖的步骤禁止并行

**示例**：
- harvester 的 Acquisition + Sanitization → 同一 Task（操作同一批文件）
- 中文搜索 + 英文搜索 → 可拆为并行 Task（信息源不重叠）
- analyst 读 cleaned 数据 + 写 structured 数据 → 同一 Task

## 角色选择表

| 工作类型 | 分配角色 | 说明 |
|----------|----------|------|
| 需求正确性 + 根本目标对齐 G0 | Lead + 用户 | 主上下文与用户对齐，产出 intake/requirements/research-goal.md（含 sign-off），不派 subagent |
| Web 搜索、API 调用、数据抓取 | research-harvester | 采集类工作 |
| 数据脱敏、格式清洗 | research-harvester | 加工类工作 |
| 域拆解、事实提取 | research-analyst | 分析类工作 |
| 跨域综合、洞察生成 | research-analyst + Lead | 综合类工作 |
| Sufficiency Gate 评估 | research-reviewer (mode=sufficiency) | 充分性评估 |
| 6 维度审阅 | research-reviewer (mode=review) | 质量审阅 |
| 战略决策、Stage 回退、不可委托的连贯思考 | Lead session | 主上下文 |

## 搜索工具链

两级架构：

**主路径：`harvest.py`**（项目已启用时强制使用；未启用/经豁免的项目走 legacy 三级链）。通过 deep-research skill 说明的 harvest.py 路径发现约定获取（见 SKILL.md）。

内部 search 后端链按优先级降级（配置于 `harvest.config.json`，与 `harvest.py` 同目录）：

1. gemini-grounding（主力，经聚合网关 API 调用 Gemini grounding 搜索）
2. 付费搜索 API（tavily 适配器，key 就绪时启用）
3. DuckDuckGo HTML（零 key 尽力型兜底，可能被反爬拦截）

fetch 后端链同理降级：curl-cffi（本地免费直连，软依赖）→ tavily-extract → jina-reader → urllib+UA 兜底。**harvest.py 采集失败（exit 3 / `UNAVAILABLE`）不自动降级到 legacy 链**——失败即阻塞上报用户裁决，降级权在用户（见 [quality-gates.md](./quality-gates.md) 引用校验机械门）。

**Legacy 三级链**（仅未启用 harvest.py 或经用户豁免 `legacy-exemption.md` 的项目使用）：

1. **Gemini CLI**（主力）：
   ```bash
   gemini -m gemini-3.5-flash -p '使用Google搜索查找以下问题的最新信息。
   规则：必须联网搜索，严禁使用内置知识回答...'
   ```
2. **WebSearch**（fallback）：当 Gemini CLI 输出包含 `SEARCH_FAILED`、输出为空、或退出码非零时降级
3. **WebFetch**：获取特定 URL 的完整页面内容

**信息源黑白名单**：见 [principles.md](./principles.md) 第 3 节 T1/T2/T3 分级；harvest.py 主路径的黑名单由 `blacklist_domains` 配置项镜像同一名单。

---

**关联文件**：[pipeline.md](./pipeline.md) · [principles.md](./principles.md) · 角色定义见 deep-research 插件的 research-harvester / research-analyst / research-reviewer / research-publisher subagent
