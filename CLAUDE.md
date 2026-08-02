# cc-plugins

WooDragon 的 Claude Code 插件 + 技能包 marketplace。

## 插件清单

| 类型 | 名称 | 说明 |
|------|------|------|
| Plugin | plan-review | 对抗性审阅（Gemini/Claude/Codex） |
| Plugin | ppt-press（4 skills） | PPT 全生命周期（init/create/deploy/manage） |
| Plugin | doc-gate（1 skill + 3 hooks + 2 tools） | 文档编辑门禁 + 词法召回 |
| Plugin | code-search（1 skill） | 代码搜索与符号导航方法论（纯 skill，零 hook） |
| Plugin | deep-research（1 skill + 4 agents + 1 hook） | 7-Stage 深度研究管线 + 多模型采集引擎 + 引用验证门禁 |
| Plugin | guardrails（2 hooks） | 代码规模提示（信息性）+ git push 防手滑（拦截误推 main/master，非防绕过安全边界） |
| Plugin | pr-review（1 skill + 2 scripts） | 已开 PR 的 AI 评审：grok 本地同步评审（默认，含多轮对抗复评的 session 状态管理）+ Copilot bot 异步评审（可选） |
| Plugin | dispatch-contract（1 skill + 1 hook） | 子 agent 派发契约：四条派发铁律 + `%%DONE%%` 定稿门禁（SubagentStop） |

## 版本变更铁律

插件代码（scripts/、skills/、hooks/）发生功能性变更（bug fix、feature、breaking change）时，必须同步更新两处版本号：

1. `plugins/<name>/.claude-plugin/plugin.json` → `"version"`
2. `.claude-plugin/marketplace.json` → 对应插件条目的 `"version"`

两处不一致视为提交不完整，禁止 push。纯文档、纯测试、纯 refactor（不改外部行为）的变更不要求 bump。

## 项目结构

```
.claude-plugin/marketplace.json   # marketplace 元数据（插件注册、版本）
plugins/
  plan-review/                    # 对抗性审阅插件
    .claude-plugin/plugin.json    # 插件元数据
    hooks/hooks.json              # PreToolUse + PreCompact hook 声明
    scripts/
      plan-review.sh             # 编排器：守卫→计数→双安全阀→预检→prompt 组装→重试驱动→verdict 分支
      lib/
        common.sh                # 日志三件套 + backfill_engine_err + allow_with_reason + plan_hash + DELTA_REVIEW_RULES（delta 审阅规则单一来源）+ clamp_head_bytes / clamp_tail_bytes（UTF-8 安全字节截断）
        plan-source.sh           # transcript 反查三重安全门 + 提取链 + RESOLVE_REASON 三态文案
        verdict.sh               # verdict 提取 + APPROVE/CONCERNS/REJECT 三种反馈渲染
        manifest.sh              # Manifest 检测三函数 + MANIFEST_EXAMPLE + JSON 序列化
        engines/                 # 引擎三钩子接口（engine_probe/engine_invoke/engine_extract）
          agy.sh                 # gemini 引擎（默认，agy CLI，含 JSON 文本切片 + conversation 复用）
          claude.sh              # REVIEW_ENGINE=claude
          codex.sh               # REVIEW_ENGINE=codex（含 engine_err_filter 隐私过滤钩子）
          rest.sh                # REST SSE 降级通道（rest_ 前缀独立函数，不实现三钩子）
      assets/
        review-system-prompt.md  # SYSTEM_INSTRUCTIONS 提示词正文（纯数据）
      dispatch-check.sh          # Layer 2 hook（Agent/Task 调度参数强制）
      precompact-review.sh       # PreCompact hook（compaction 恢复）
    tests/                        # BDD 测试套件（bats-core；用例计数属动态指标，权威版本见 MEMORY.md 层）
      plan-review.bats            # 主测试套件（含 Dispatch Manifest、codex 引擎、轮间记忆）
      dispatch-check.bats         # Layer 2 hook 测试
      test_helper/
        common-setup.bash         # 测试基础设施（mock、断言）
  doc-gate/                       # 文档编辑门禁 + 词法召回插件
    .claude-plugin/plugin.json   # 插件元数据（声明 skills + hooks）
    hooks/hooks.json             # PreToolUse: Edit(skill-gate+recall-gate), Write(同), Skill(marker)
    scripts/
      skill-gate.sh              # 硬门禁（.md 编辑前检查 doc-maintenance marker）
      skill-marker.sh            # 标记脚本（Skill 调用时写 marker）
      recall-gate.sh             # 软门禁（BM25 召回 + 孤儿检测 + 出链验证，deny-once-per-file）
    tools/
      _doc_gate_common.py        # 共享模块：排除名单 + 链接图谱原语单一来源（recall-gate/docs-graph 共用）
      recall-gate.py             # BM25 + 链接图谱合并引擎（单趟扫描，零依赖）
      docs-graph.py              # 链接图谱独立 CLI（7 子命令：check/backlinks/links/orphans/hubs/related/export）
    skills/
      doc-maintenance/SKILL.md   # 文档维护工作流
    tests/                       # BDD 测试套件（skill-gate + skill-marker）
      skill-gate.bats            # 54 个测试用例
      skill-marker.bats          # 13 个测试用例
      test_helper/
        common-setup.bash        # 测试基础设施
  ppt-press/                     # PPT 发布系统插件（skills-only，预留 hooks）
    .claude-plugin/plugin.json   # 插件元数据（声明 skills 路径）
    skills/
      ppt-init/                  # 从零 scaffold 完整框架
        SKILL.md
      ppt-create/                # 内容生产（~85KB，含 references + assets）
        SKILL.md                 # 工作流：需求澄清 → 创建 → 填充 → 自检 → 预览
        references/              # 5 个参考文档
        assets/template.astro    # 新 Deck Astro 模板
      ppt-deploy/                # 构建+测试+部署
        SKILL.md
      ppt-manage/                # 检索管理
        SKILL.md
  code-search/                   # 代码搜索方法论插件（纯 skill，零 hook）
    .claude-plugin/plugin.json   # 插件元数据（纯 skill）
    skills/
      code-search/SKILL.md       # 工具决策树 + 按意图策略 + 组合技巧 + 上下文经济
    README.md                    # 面向安装者说明
  deep-research/                 # 深度研究管线插件
    .claude-plugin/plugin.json   # 插件元数据（声明 skill + 4 个 native subagent）
    agents/                      # 4 个原生 subagent 角色定义
      research-harvester.md      # Stage 2-3：采集 + 净化
      research-analyst.md        # Stage 4-5：分解 + 综合
      research-reviewer.md       # G1/G2/G3 充分性 + Validation 评审
      research-publisher.md      # Stage 7：定稿渲染为自包含 HTML
    scripts/
      harvest.py                 # 多模型采集编排 + 确定性引用验证（+ harvest_safety/harvest_search/harvest_fetch/harvest_clients 子包）
      create-research-project.sh # 研究项目 scaffold 脚本
    hooks/hooks.json             # SubagentStop → gate_check.py（G1 引用验证机械门禁，fail-open）
    docs/
      main-session-isolation-contracts.md # 主 session 隔离契约（read_guard 判定规格 + receipt/manifest/delta schema，运行时唯一事实源）
    skills/deep-research/        # SKILL.md 路由器 + references/（框架文档）+ assets/（模板）
    tests/                       # pytest 套件（harvest + gate_check）
  pr-review/                     # 已开 PR 的 AI 评审插件（纯 skill，零 hook）
    .claude-plugin/plugin.json   # 插件元数据（纯 skill）
    skills/pr-review/
      SKILL.md                   # 后端选择 + 执行分工 + grok 多轮复评流程
      scripts/grok-review.sh     # grok CLI 本地同步评审（session 落盘 + 增量 diff + 工作区身份钉死）
      scripts/copilot-review.sh  # gh 触发 Copilot bot（request / rerequest / status）
      references/grok-review.md  # grok 后端参数、机制、故障排查
      references/copilot-review.md # Copilot 后端三条路径（REST 首触 / GraphQL 重触 / 状态查询）
    tests/grok-review.bats       # 60 个测试用例（stub grok/gh/uuidgen，git 用真实临时仓库）
    README.md                    # 面向安装者说明
  dispatch-contract/             # 子 agent 派发契约插件（1 skill + 1 hook）
    .claude-plugin/plugin.json   # 插件元数据（声明 skill + SubagentStop hook）
    hooks/hooks.json             # SubagentStop → subagent-done-gate.sh（%%DONE%% 定稿门禁，fail-open）
    hooks/subagent-done-gate.sh  # 门禁脚本：末行精确匹配 %%DONE%%，不匹配则 deny 并回灌纠正指令
    skills/subagent-dispatch/
      SKILL.md                   # 四铁律速查 + %%DONE%% 契约 + 己方端 / 派发端补充纪律
      references/dispatch-contract.md   # 四铁律正反例、persona 规避发作区/安全区展开
      references/offload-scenarios.md   # 卸载场景判断 + 模型档位选择
      references/mailbox-liveness.md    # background subagent 产物回传 + 活性判定 + TaskStop 时机
      references/workflow-schema.md     # Workflow agent() 强结构化产物 + JSON schema 用法
    tests/
      subagent-done-gate.bats    # 26 个测试用例（门禁行为全覆盖）
      test_helper/
        common-setup.bash        # 测试基础设施
```

## 环境变量

详细变量表（默认值、用途、生效条件）下沉到各插件自己的 README，此处只做路由，避免与下游权威版本重复漂移：

| 插件 | 变量前缀/名称 | 权威文档 |
|------|--------------|----------|
| plan-review | `REVIEW_*`、`AGY_MODEL`、`CLAUDE_MODEL`、`GEMINI_MODEL`、`CODEX_BIN`、`CODEX_MODEL`、`DISPATCH_CHECK_DISABLED` | [plugins/plan-review/README.md](plugins/plan-review/README.md#environment-variables) |
| doc-gate | `SKILL_GATE_*`、`RECALL_GATE_*` | [plugins/doc-gate/README.md](plugins/doc-gate/README.md#environment-variables) |
| deep-research | `GATEWAY_API_KEY`、`TAVILY_API_KEY`、`JINA_API_KEY`（可选凭证） | [plugins/deep-research/README.md](plugins/deep-research/README.md#prerequisites) |
| pr-review | `GROK_MODEL`、`GROK_EFFORT`、`XDG_STATE_HOME`（session 落盘根） | [plugins/pr-review/README.md](plugins/pr-review/README.md#prerequisites) |

敏感变量（如 `REVIEW_API_KEY`）配置在 `~/.claude/settings.json` 的 `"env"` 字段中。Claude Code 启动时自动注入到所有 hook 进程环境，无需污染 shell profile。`~/.claude/settings.local.json` 不是合法的用户级配置路径，env 字段在此处不生效。

## Dispatch Manifest 格式（v1.0.34）

含 Agent/Task 调度关键词的 plan 必须包含 `## Dispatch Manifest` 表格：

```markdown
## Dispatch Manifest
| step | agent_type | model | depends_on | parallel_with |
|------|-----------|-------|------------|---------------|
| 1    | -         | -     | -          | -             |
| 2    | worker    | sonnet| 1          | -             |
```

主上下文执行的 step：`agent_type` / `model` 填 `-`。Agent step 两列都必须填。

## Doc-Gate 文档编辑门禁

双层门禁：硬门禁（skill-gate）+ 软门禁（recall-gate）。

**硬门禁（skill-gate）**：Edit/Write `.md` 文件时检查 session 级 marker，无 marker 则 deny 并提示调用 doc-maintenance skill。CLAUDE.md 按层级分两级强度：全局 `~/.claude/CLAUDE.md` 最严（无条件门禁 + 通用化四判据全过），项目级普通强度。

**软门禁（recall-gate）**：首次编辑某 .md 文件时执行三维分析，deny-once-per-file（重试即通过）：
- **内容维度**：BM25 词法召回，表面已有文档可能与待写内容重叠
- **结构维度**：孤儿检测（backlinks），标记无入链文件（最易产生重复）
- **完整性维度**：出链验证，检查内容引用的文件是否存在

recall-gate 内含 double-deny guard：skill-gate 启用且 marker 不存在时跳过（避免双重拒绝）。`SKILL_GATE_DISABLED=1` 时 recall-gate 独立运行。

**独立工具**：`tools/docs-graph.py` 提供链接图谱查询（断链检测、反向引用、孤儿文档、枢纽文档、2 跳邻域、JSON 导出）。

## Skills

### PPT 技能包

四个 skill 覆盖 PPT 全生命周期：

| Skill | 职责 | 大小 |
|-------|------|------|
| `ppt-init` | 从零 scaffold 完整 Astro 框架项目 | ~4KB |
| `ppt-create` | 内容生产：需求澄清 → 大纲 → Astro 页面 → 自检 | ~85KB（含 5 references + 1 asset） |
| `ppt-deploy` | 构建验证 → 批量 Playwright 测试 → Amplify 部署 | ~4KB |
| `ppt-manage` | deck 列表检索 / 搜索 / URL 复制 | ~2KB |

### 代码搜索技能

`code-search` skill 注入代码检索执行层方法论，让 Claude 按「症状」选对工具，不漏触发、不滥用 grep：

| 症状 | 工具 |
|------|------|
| 找符号定义 / 跳转到定义 | **ctags**（建索引 + readtags 查） |
| 找 AST 结构形状（import / 调用形态 / 组件定义 / try-catch） | **ast-grep**（`run -p`） |
| 找 caller / 纯文本 | **grep**（1-2 跳够） |
| grep/ctags 扛不住的精确调用图 | **LSP/SCIP**（gopls / rust-analyzer） |

含反模式纠偏（禁 grep 找定义）、ctags 命令模板与坑、升级信号。与全局 CLAUDE.md「代码检索」路由一致。触发靠 description 语义匹配，不用 hook——搜代码无可判定的 tool-level 信号，高频动作门禁会破坏工作流。

### Plugin vs Skill

| 维度 | Plugin | Skill |
|------|--------|-------|
| 机制 | Hook 拦截（`hooks.json` + 脚本） | 知识注入（`SKILL.md` + references） |
| 发现 | `.claude-plugin/` 目录 | `skills/<name>/SKILL.md` 目录 |
| 执行 | 脚本自动执行 | AI 读取并遵循 |
| 安装 | `claude plugin add` | `npx skills add` |

## 历史记录

开发踩坑记录已归档至 GitHub Issues：

- [#8 初期插件开发陷阱](https://github.com/WooDragon/cc-plugins/issues/8) — Marketplace 命名、hooks 重复加载、版本双写、KV Cache 原则
- [#9 Hook 可靠性与诊断改进 (v1.0.12~v1.0.15)](https://github.com/WooDragon/cc-plugins/issues/9) — Compaction 绕过、入口诊断日志、set-e 静默退出、进程残留
- [#10 Gemini Capacity & REST 降级体系演进 (v1.0.16~v1.0.27)](https://github.com/WooDragon/cc-plugins/issues/10) — Skills 注入、REST 降级、capacity fast-break、降级持久化
- [#11 审阅质量增强 & Hook Timeout 修正 (v1.0.28~v1.0.32)](https://github.com/WooDragon/cc-plugins/issues/11) — Execution topology、造轮子检测、hook timeout 认知修正
- [#12 Dispatch Manifest 双层防御 (v1.0.34)](https://github.com/WooDragon/cc-plugins/issues/12) — Layer 1 manifest 表格强制 + dispatch JSON 落地、Layer 2 Agent/Task 参数校验
- [#18 CC 2.1.x 契约变更 & transcript 反查恢复 (v1.0.37~v1.0.40)](https://github.com/WooDragon/cc-plugins/issues/18) — fail-closed hookEventName 修复、payload 诊断 dump、plan 移至 out-of-band 文件、transcript_path 反查 + 三重安全门（FIFO/软链接/路径遍历）
- [#19 CLAUDE.md 强制门禁 & 全局/项目级分级 (v1.0.3)](https://github.com/WooDragon/cc-plugins/issues/19) — basename 豁免收缩（CLAUDE/README/CONTRIBUTING 纳入门禁）、全局 `~/.claude/CLAUDE.md` 大小写不敏感识别 + 无条件门禁（绕过位置排除）、deny 消息分级 + `skill-not-invoked-global` 日志、doc-maintenance 通用化原则章节、放弃 `DOC_GATE_FORCE_INCLUDE` 改用零配置内建规则
- [#24 去重维护规范 & dedup 工具 YAGNI 决策 (v1.4.0)](https://github.com/WooDragon/cc-plugins/issues/24) — 实证研判（两库 103 篇 md 双轮扫描，真债仅 0.4%）毙掉 dedup 工具伪需求降级 backlog，doc-maintenance 补「去重维护」规范（单一来源 / 跨项目共享 / 定期 DEDUP 处置流程），复用现有 orphans/backlinks/check

## 内部设计文档（how/why 去哪找）

各插件的实现细节、设计决策与审阅记录（how/why）**不入本公共仓库**——按上文「公共 vs 私有归属规范」归私有侧。本仓库只含运行时文件（`plugin.json`/`hooks.json`/`scripts`/`skills`/`tests`）与面向安装者的 README（what）。

how/why 文档由维护者保存在私有 docs 层，每插件一份 `<plugin>-internals.md`（plan-review、doc-gate、guardrails 等，含设计理据、迁移史、审阅记录）。**完整清单与索引以下方 `@` 引用展开的私有 CLAUDE.md「文档索引」表为权威单一来源**（此处不复制清单，避免两处漂移）。

> 下方 `@` 路径为维护者机器本地——clone 本公共仓库者不含此私有层，属预期设计（归属规范的私有侧本就不发布）。

@~/.claude/projects/-Users-woodragon-Work-github-cc-plugins/CLAUDE.md
