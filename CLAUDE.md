# cc-plugins

WooDragon 的 Claude Code 插件 + 技能包 marketplace。

## 插件清单

| 类型 | 名称 | 说明 |
|------|------|------|
| Plugin | plan-review | 对抗性审阅（Gemini/Claude） |
| Plugin | ppt-press（3 skills） | PPT 全生命周期 |
| Plugin | doc-gate（1 skill + 3 hooks + 2 tools） | 文档编辑门禁 + 词法召回 |

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
    scripts/plan-review.sh        # 核心脚本（ExitPlanMode 拦截 + Layer 1 manifest 检查）
    scripts/dispatch-check.sh     # Layer 2 hook（Agent/Task 调度参数强制）
    scripts/precompact-review.sh  # PreCompact hook（compaction 恢复）
    tests/                        # BDD 测试套件（bats-core）
      plan-review.bats            # 109 个测试用例（含 Dispatch Manifest）
      dispatch-check.bats         # 14 个测试用例（Layer 2 hook）
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
      ppt-create/                # 内容生产（~85KB，含 references + assets）
        SKILL.md                 # 工作流：需求澄清 → 创建 → 填充 → 自检 → 预览
        references/              # 5 个参考文档
        assets/template.astro    # 新 Deck Astro 模板
      ppt-deploy/                # 构建+测试+部署
        SKILL.md
      ppt-manage/                # 检索管理
        SKILL.md
```

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `REVIEW_ENGINE` | `gemini` | 审阅引擎：`gemini` 或 `claude` |
| `REVIEW_DISABLED` | `0` | `1` 全局关闭 |
| `REVIEW_DRY_RUN` | `0` | `1` 跳过引擎调用 |
| `REVIEW_MAX_ROUNDS` | `3` | 非 Critical 最大磋商轮次（CONCERNS 累计） |
| `REVIEW_MAX_TOTAL_ROUNDS` | `20` | 全局绝对上限（含 REJECT 轮次），到达后硬拦截 |
| `REVIEW_ENGINE_TIMEOUT` | `595` | 引擎调用超时秒数（需系统有 timeout/gtimeout），单次 CLI 占满预算，失败后 REST 降级 |
| `REVIEW_API_URL` | _(空)_ | REST API 降级 base URL（OpenAI 兼容格式，如 `https://proxy.example.com`） |
| `REVIEW_API_KEY` | _(空)_ | REST API 降级 auth key（Bearer token） |
| `REVIEW_REST_TIMEOUT` | `115` | REST fallback curl 超时秒数（钳制逻辑自动截断到 remaining-3） |
| `REVIEW_HOOK_BUDGET` | `595` | hook 总时间预算秒数（600s hook timeout - 5s 余量），控制 retry loop 和 REST timeout 钳制 |
| `REVIEW_CAPACITY_DELAY` | `25` | 检测到 MODEL_CAPACITY_EXHAUSTED 后等待秒数（REST 配置时跳过此延迟直接 break） |
| `REVIEW_ENGINE_DEGRADE_TTL` | `3600` | Gemini 降级状态 TTL 秒数；capacity exhaustion 后后续 hook 在 TTL 内直接跳过 CLI 走 REST |
| `DISPATCH_CHECK_DISABLED` | `0` | `1` 关闭 Layer 2 dispatch 强制检查（dispatch-check.sh kill switch） |
| `SKILL_GATE_DISABLED` | `0` | `1` 关闭文档编辑门禁（doc-gate kill switch） |
| `SKILL_GATE_DIR` | `/tmp/claude-reviews` | marker 目录（与 plan-review 共享） |
| `SKILL_GATE_LOG_DIR` | _(空)_ | 日志目录（fallback: `REVIEW_LOG_DIR` 或 `~/.claude/logs`） |
| `SKILL_GATE_STALE_MIN` | `120` | marker stale 清理阈值（分钟），同时作为上下文刷新机制 |
| `RECALL_GATE_DISABLED` | `0` | `1` 关闭词法召回门禁（recall-gate kill switch） |
| `RECALL_GATE_ROOT` | _(空)_ | 显式指定 recall 语料库根目录（覆盖 CLAUDE.md + .git 共现自动检测） |
| `RECALL_GATE_THRESHOLD` | `0.30` | BM25 最低分数阈值（低于此分数的结果不显示） |
| `RECALL_GATE_TOP_N` | `5` | 召回结果最大返回条数 |
| `RECALL_GATE_STALE_MIN` | `120` | recall marker stale 清理阈值（分钟） |

敏感变量（`REVIEW_API_KEY`）配置在 `~/.claude/settings.json` 的 `"env"` 字段中。Claude Code 启动时自动注入到所有 hook 进程环境，无需污染 shell profile。`~/.claude/settings.local.json` 不是合法的用户级配置路径，env 字段在此处不生效。

旧变量 `GEMINI_REVIEW_OFF`、`GEMINI_DRY_RUN`、`GEMINI_MAX_REVIEWS` 通过脚本内 fallback 继续生效。

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

三个 skill 覆盖 PPT 全生命周期：

| Skill | 职责 | 大小 |
|-------|------|------|
| `ppt-create` | 内容生产：需求澄清 → 大纲 → Astro 页面 → 自检 | ~85KB（含 5 references + 1 asset） |
| `ppt-deploy` | 构建验证 → 批量 Playwright 测试 → Amplify 部署 | ~4KB |
| `ppt-manage` | deck 列表检索 / 搜索 / URL 复制 | ~2KB |

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

@~/.claude/projects/-Users-woodragon-Work-github-cc-plugins/CLAUDE.md
