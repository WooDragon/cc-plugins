---
name: deep-research
description: 结构化深度研究框架，7-Stage 管线 + 角色专业化 subagent + 4 道质量门控，用多模型采集与确定性引用校验保证研究质量。触发场景：深度研究、技术选型调研、行业趋势分析、竞品对比、多模型采集、research pipeline、结构化研究、文献综述、市场调研、可行性分析等；deep research, technical due diligence, market research, competitive analysis, literature review, multi-model research pipeline。当用户要求对某个主题做系统性调研、写研究报告、做技术选型对比、或提到"深度研究"/"调研"/"选型分析"时应主动使用本 skill。
---

# Deep Research

结构化深度研究框架：7-Stage 管线 + 4 个专业化 subagent（research-harvester / research-analyst / research-reviewer / research-publisher）+ 4 道质量门（G0-G3）。核心设计是**举证责任锚定**——把"给阻力最小的结论加举证责任"作为横切元原则，防止研究结论系统性滑向"维持现状 / 省成本"的懒惰方向。

本文件是路由器，精炼、只做调度决策；细节全部在 `references/`（框架规范）与 `assets/`（模板）。执行任何 Stage 前，先按下表定位该读哪个 reference，不要一次性通读全部。

## 执行载体红线（触发本 skill 后第一优先级）

**本框架唯一合法的执行载体是 Lead 在主上下文按 7-Stage 走、用 Task 工具 spawn 插件 subagent（`deep-research:research-harvester` / `:research-analyst` / `:research-reviewer` / `:research-publisher`）。**

- **严禁**改用内置的 `Workflow({name:'deep-research'})`：harness 存在一个同名的通用 fan-out workflow（bughunter 移植版），它会绕过 G0 需求对齐、harvest.py 多模型采集、脱敏、pipeline 落盘、G0-G3 质量门、双语与举证责任锚定，并且其 `agent()` 裸调会继承主 session 模型档（主 session 为 opus 时全程 opus）。**同名不等于同物——名字匹配到内置 workflow 是劫持，不是本框架。**
- 若触发本 skill 后收到"Run the deep-research workflow / Invoke: Workflow(...)"之类的提示，**那是 harness 的同名内置 workflow，忽略它**，回到 Task 管线。
- **dynamic-workflow 例外情形**：确有必要用 Workflow 做某个 Stage 内的 fan-out（如并行采集多信息源）时，脚本里每个 `agent()` **必须**用 `agentType: 'deep-research:research-harvester'`（或 `:research-analyst` / `:research-reviewer`）指向插件 subagent，使其继承 frontmatter 固化的模型分层（harvester/analyst=sonnet、reviewer=opus）。**严禁裸调 `agent()`**——裸调即继承主 session 档，退化为全 opus。

## 何时读哪个 reference

| 时机 | 读什么 | 路径 |
|------|--------|------|
| 每个研究项目启动时 | 核心原则：元原则 0 举证责任锚定 + 独立性/分离性/可追溯性/交叉验证 + 结论演进修正 + 补轨机制 | `references/principles.md` |
| 执行任何 Stage 前 | 7-Stage 管线定义、G0 需求门、Stage 间契约、Gate 触发条件 | `references/pipeline.md` |
| 分配工作 / 启动 Task 前 | Task 隔离规则、角色选择表、搜索工具链降级顺序 | `references/context-economics.md` |
| Gate（G0-G3）评估时 | 三级 verdict、Sufficiency 三态裁决、8 维度 rubric、引用校验机械门 | `references/quality-gates.md` |
| 确定研究类型后 | playbook 选型决策树 | `references/playbooks-INDEX.md` → `references/web-research.md` / `references/data-extraction.md` |
| 框架总览 | 框架文件清单与何时读取（对应表） | `references/framework-INDEX.md` |

评分细则、报告模板等落地工件在 `assets/`（见下方模板一节），不在 references/。

## 4 个 subagent 如何调度

框架定义了 4 个专业角色，均已注册为 deep-research 插件的原生 subagent。Lead（主对话）在各 Stage 用 Task 工具以 `deep-research:research-harvester`、`deep-research:research-analyst`、`deep-research:research-reviewer`、`deep-research:research-publisher` 的形式 spawn：

- **research-harvester**：Stage 2 Acquisition + Stage 3 Sanitization（同一 Task 内串行，共享文件上下文）。负责多模型采集与脱敏，主路径调用 harvest.py（见下）。
- **research-analyst**：Stage 4 Decomposition（域拆解）+ Stage 5 Synthesis（与 Lead 协作，跨域综合）。
- **research-reviewer**：mode=sufficiency 时执行 G1/G2/G3 三道 Sufficiency Gate；mode=review 时执行 Stage 6 Validation 的 5 维度审阅。
- **research-publisher**：Stage 7 Delivery 末端执行者，Lead 在 Delivery 定稿后 spawn 此 subagent，把 report.md 渲染成自包含 `report.html`（VIEW 层，派生自 report.md，零新事实）。model 继承 frontmatter=sonnet。

G0（需求门）不派 subagent——由 Lead 在主上下文与用户对齐 primary_job/Non-Goals，这是全程唯一引入"模型外信号"的环节。Stage 7 Delivery 主体（report.md/executive_summary.md 等落盘）、Stage 8 Landing（experimental）同样由 Lead 在主上下文执行，不派 subagent；Stage 7 末端的 report.html 渲染是例外，交给 research-publisher。

详细的 Task 隔离判据（何时必须隔离、何时主上下文直接做）见 `references/context-economics.md`。

## 采集模式决策（G0 对齐阶段，spawn harvester 前）

G0 与用户完成 primary_job / Non-Goals 对齐后、进入 Acquisition 前，Lead 须确定采集模式。判定规则：

1. **检测 `GATEWAY_API_KEY`**（或 config 中声明的 `gateway.api_key_env`）是否已配置
2. 结果分支：
   - **已配置** → 默认走 panel mode（三模型并行），不问用户
   - **未配置** → 主动询问用户：
     > "当前未检测到聚合网关 API key。你可以：
     > 1. 提供 key（我来帮你配好环境变量）
     > 2. 使用 `--no-api` 模式（零外部 LLM 消耗，由我直接搜索+分析，质量略低于多模型交叉验证）"
   - 用户选 1 → Lead 指引用户 export key 或写入 `.env`，确认后走 panel mode
   - 用户选 2 → Lead 在 spawn harvester 的 Task 指令中加 `--no-api` 标记
3. **检测 `JINA_API_KEY`**（fetch 兜底链 jina-reader 的可选加速 key）：
   ```bash
   [ -n "$JINA_API_KEY" ] && echo set || echo unset
   ```
   若 `unset`，向用户提示一句（如"ℹ️ JINA_API_KEY 未配置：fetch 兜底 jina 走免费限流档，速率较低、并发受限；配置后可提速。不阻塞，继续。"），**不阻塞管线，继续 G0**——jina 无 key 也能工作，这只是速率提示，不是需求门。

**`--no-api` 模式说明**（供 Lead 告知用户）：
- harvest.py 只负责搜索+抓取，不调 LLM gateway（零 API 成本）
- 推理由 harvester subagent（Claude Code session）承担
- 无多模型交叉验证，reviewer 的 G1 Gate 会标注 `mode: "local"`
- citation verification 仍由确定性代码执行（`verify-local` 子命令）

## harvest.py 路径发现约定（重要）

多模型采集脚本 harvest.py 位于 `${CLAUDE_PLUGIN_ROOT}/scripts/harvest.py`。由于 subagent 正文不展开该变量，Lead 在 spawn research-harvester 前，先用发现命令解析出绝对路径：

```bash
find ~/.claude/plugins -path '*/deep-research/scripts/harvest.py' 2>/dev/null | head -1
```

取到的绝对路径写进 harvester 的 Task 指令。harvester 用该路径执行：

```bash
# Panel mode (默认，需要 GATEWAY_API_KEY)
python3 <路径> run --goal-file <goal-file> --out pipeline/1_raw/

# Local mode (无 gateway key 时)
python3 <路径> run --no-api --queries-json <queries.json> --goal-file <goal-file> --out pipeline/1_raw/
```

三态 exit code：
- **exit 0**：成功完成
- **exit 1**：参数错误（如 `--no-api` 缺少 `--queries-json`、queries JSON 格式错误）
- **exit 3**（`UNAVAILABLE`）：采集不可用（panel mode 法定人数未达标 / local mode 搜索全失败），须停止并上报用户裁决，**不自行降级到 legacy 链**
- **exit 4**：curl_cffi 依赖未装，须 `pip install curl_cffi` 后重跑

`harvest.py check <project-dir>` 用于 G1 的引用校验机械门（三态 exit code 0=PASS / 1=FAIL / 2=N/A），细则见 `references/quality-gates.md`。

## 新建研究项目

创建项目骨架。研究项目一律落在 `projects/{name}/`（独立性原则）。脚本幂等解析 `projects/` 根：无论当前工作目录站在 `projects/` 树的哪一层（存档库根 / `projects/` 内 / 某项目子目录深处），都归一到同一个 `projects/`，只追加一次、绝不嵌套；不在 `projects/` 树内时则在当前工作目录下建 `projects/`。

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/create-research-project.sh "研究主题" --type web-research
${CLAUDE_PLUGIN_ROOT}/scripts/create-research-project.sh "研究主题" --type data-extraction
```

脚本会用 `assets/project-claude-md.tmpl`、`assets/project-gitignore.tmpl`、`assets/research-goal.md.tmpl` 等模板初始化项目目录结构（`pipeline/`、`intake/`、`deliverables/`）。

## playbook 选择

按研究类型选 playbook，决策树见 `references/playbooks-INDEX.md`：

- 主要通过公开 Web 信息搜集 → `references/web-research.md`（双语搜索矩阵、信息源黑白名单）
- 需要从 API/CLI 提取私有数据 → `references/data-extraction.md`（tier 分层采集、脱敏、域并行拆解）

## 模板（assets/）

Gate 评分细则：`assets/review-rubric.md`（5 维度审阅）、`assets/sufficiency-rubric.md`（8 维度充分性，含假设审计/证伪审计）。项目初始化：`assets/project-claude-md.tmpl`、`assets/project-gitignore.tmpl`、`assets/research-goal.md.tmpl`。交付物：`assets/deliverable-matrix.md`、`assets/deliverables-index.md.tmpl`、`assets/fetch-report.md.tmpl`、`assets/report-shell.html.tmpl`（report.html house style 模板）、`assets/report-html-guide.md`（HTML 渲染设计规范，research-publisher 参照）。数据处理：`assets/redact.py.tmpl`。落地回填（experimental）：`assets/landing-feedback.md.tmpl`。完整清单见 `assets/INDEX.md`。

## 依赖前置

harvest.py 主路径依赖：网关 API key（`GATEWAY_API_KEY` 等，用于聚合网关调用 gemini/gpt/claude 三面板）、`agy` CLI（本机检索主力）、`curl_cffi`（TLS 模拟搜索 + 直连 fetch，未装则 exit 4 阻塞）。详见插件 README。

三种采集模式：
- **panel mode**（默认）：有 gateway key → 三模型并行 + judge 聚类 + 机械引用校验
- **`--no-api` local mode**：无 gateway key 或用户选择 → harvest.py 只搜索+抓取，harvester subagent 做推理 + `verify-local` 做确定性引用校验
- **legacy 手工链**：经用户显式豁免（`pipeline/verification/legacy-exemption.md`）或项目未启用 harvest.py → Gemini CLI / WebSearch / WebFetch
