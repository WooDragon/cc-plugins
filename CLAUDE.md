# cc-plugins

WooDragon 的 Claude Code 插件 + 技能包 marketplace。

## 插件清单

| 类型 | 名称 | 说明 |
|------|------|------|
| Plugin | plan-review | 对抗性审阅（Gemini/Claude） |
| Plugin | ppt-press（3 skills） | PPT 全生命周期 |
| Plugin | doc-gate（1 skill + 2 hooks） | 文档编辑门禁 |

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
  doc-gate/                       # 文档编辑门禁插件（skill + hooks 打包）
    .claude-plugin/plugin.json   # 插件元数据（声明 skills + hooks）
    hooks/hooks.json             # PreToolUse: Edit, Write, Skill
    scripts/
      skill-gate.sh              # 门禁脚本（.md 编辑前检查 marker）
      skill-marker.sh            # 标记脚本（Skill 调用时写 marker）
    skills/
      doc-maintenance/SKILL.md   # 文档维护工作流（从全局 skill 迁入）
    tests/                       # BDD 测试套件
      skill-gate.bats            # 50 个测试用例
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

敏感变量（`REVIEW_API_KEY`）配置在 `~/.claude/settings.json` 的 `"env"` 字段中。Claude Code 启动时自动注入到所有 hook 进程环境，无需污染 shell profile。`~/.claude/settings.local.json` 不是合法的用户级配置路径，env 字段在此处不生效。

旧变量 `GEMINI_REVIEW_OFF`、`GEMINI_DRY_RUN`、`GEMINI_MAX_REVIEWS` 通过脚本内 fallback 继续生效。

### 测试隔离变量（仅测试使用）

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `REVIEW_LOG_DIR` | `$HOME/.claude/logs` | 日志目录 |
| `REVIEW_COUNTER_DIR` | `/tmp/claude-reviews` | counter 文件目录 |
| `REVIEW_PLAN_DIR` | `$HOME/.claude/plans` | plan 文件 fallback 目录 |
| `REVIEW_RETRY_DELAY` | `2` | 引擎重试间隔秒数 |
| `REVIEW_ENGINE_TIMEOUT` | `25` | 引擎调用超时秒数 |
| `REVIEW_HOOK_BUDGET` | `115` | hook 总时间预算秒数 |

生产环境不设置这些变量，脚本 fallback 到默认路径。测试通过注入临时目录实现完全隔离。

## Dispatch Manifest 强制规范（v1.0.34）

### Layer 1（生成期，plan-review.sh）

含以下任一关键词（大小写不敏感）的 plan 被视为含 Agent/Task 调度，必须包含 `## Dispatch Manifest` 表格：

```
Task(  |  subagent_type  |  agent_type  |  Plan agent  |  Explore agent  |  worker agent  |  dev agent
```

**Manifest 表格格式**：
```markdown
## Dispatch Manifest
| step | agent_type | model | depends_on | parallel_with |
|------|-----------|-------|------------|---------------|
| 1    | -         | -     | -          | -             |
| 2    | worker    | sonnet| 1          | -             |
```

- 主上下文执行的 step：`agent_type` / `model` 填 `-`
- Agent step：两列都必须填，否则视为 [Critical]（REJECT）
- 缺 manifest 表格本身：[Major]（CONCERNS，受 MAX_ROUNDS 安全阀约束；到达上限后 escalate to user）

APPROVE 时将 manifest 落地为 `$REVIEW_COUNTER_DIR/.dispatch-{session_id}.json`（tmpfs，OS 重启自动清理）。

### Layer 2（执行期，dispatch-check.sh）

当 dispatch JSON 存在时，拦截 `PreToolUse:Agent` 和 `PreToolUse:Task`，要求 Agent 调用显式传：
- `subagent_type`（非空字符串）
- `model`（非空字符串）

两者都提供 → silent allow。缺任一 → deny + manifest 取值预览。

**Dispatch JSON 落地路径**：`/tmp/claude-reviews/.dispatch-{session_id}.json`（与 `.review-count-*` 同目录）

**Stale 清理**：mmin > 30 时自动删除（plan-review.sh APPROVE 路径写入前 + dispatch-check.sh 每次触发时各执行一次 opportunistic 全局清理）

**关闭开关**：`DISPATCH_CHECK_DISABLED=1`

**fail-open 铁律**：任何异常路径（jq 缺失、JSON 损坏、session 为空、文件 IO 失败）一律 silent allow，不阻塞用户工作流。

## 架构设计

### Plan 内容提取链（CC 2.1.x 契约适配，v1.0.40）

ExitPlanMode 的 hook stdin 在不同 CC 版本传递 plan 的方式不同，脚本按优先级三级提取：

1. `tool_input.plan`（旧契约，内联）
2. `tool_input.planFilePath`（过渡兼容）
3. **transcript 反查**（CC 2.1.x 新契约）：plan 内容移至 out-of-band 文件（`~/.claude/plans/<slug>.md`），路径仅存于 transcript 的 `attachment.type=="plan_mode"` 记录里，**不进 hook payload**。但 hook stdin 带 `transcript_path`，`resolve_plan_from_transcript()` 据此流式提取最新 planFilePath。

**三重安全门**（反查路径读取前，任一不过即拒绝并 fail-closed）：
- `[ -f ]` 常规文件强制 —— 防 FIFO/设备文件阻塞读挂死耗尽 600s hook 预算
- `[ -h ]` 拒绝软链接 + `cd -P` 解析父目录物理路径后再校验 —— 防 plans 目录内软链接穿透白名单读取敏感文件（exfil）
- 白名单前缀 `${REVIEW_PLAN_DIR:-~/.claude/plans}` + 拒绝 `..`

`RESOLVE_REASON` 全局变量路由三态错误信息（resolved-but-missing / 非法路径 / 全空）。**helper 直接设全局变量**（非 `echo`+`$(...)`），因命令替换的子 shell 会丢弃 RESOLVE_REASON。诊断 dump（v1.0.39）保留作为未来契约变更探针。

### 严重性分级与磋商终止机制

Prompt 定义三级严重性（Critical/Major/Minor），与 Verdict 强绑定：REJECT=Critical、CONCERNS=Major、APPROVE=Minor-only-or-clean。脚本通过 Verdict tag 路由，不扫正文（消除假阳性）。

**计数器格式**：`ATTEMPT:TOTAL`（冒号分隔），向后兼容旧格式单数字。REJECT 轮次将 ATTEMPT 重置为 0（让后续非 Critical 磋商重新从零计数）并递增 TOTAL；CONCERNS 轮次两者均递增。

**双安全阀**：
- 非 Critical 安全阀（ATTEMPT >= MAX_ROUNDS）→ allow + "ESCALATED" 理由 + 清理计数器
- 全局安全阀（TOTAL >= MAX_TOTAL_ROUNDS）→ deny + "HARD STOP" 硬拦截 + 保留计数器作为 tombstone

**状态清理铁律**：只有 allow 路径（APPROVE ack-round、非 Critical 安全阀放行）才可删除计数器。deny 路径绝不清理。

### APPROVE Ack-Round 机制

APPROVE 不再静默放行——`allow` 决策的 `permissionDecisionReason` 在 Claude Code 框架中对用户不可见，导致用户无法确认审阅是否执行。

**Ack-deny + Ack-round 两步模式**：
1. 引擎返回 APPROVE → hook 写入 marker 文件（`.review-approved-{session_id}`），emit `deny` 并将审阅摘要推送给 Claude
2. Claude 向用户展示审阅结果后再次调用 ExitPlanMode → hook 检测到 marker，emit `allow` 并清理 marker + counter

**设计约束**：
- Ack-round 检查位于 counter 读取之后、双安全阀之前——已审批的 plan 即使 counter 已达上限也不会被阻断
- Ack-deny 不递增任何计数器（它是审批确认，不是磋商轮次）
- Marker 文件与 counter 在 ack-round 的 allow 路径中原子清理
- 额外开销：一次无引擎调用的 round-trip（~100ms），相对 10-30s 的审阅延迟可忽略

## Doc-Gate 文档编辑门禁（v1.0.0，CLAUDE.md 治理 v1.0.3）

Skill + Hook 打包插件：doc-maintenance skill 提供文档维护工作流，PreToolUse hook 强制执行。

**机制**：Edit/Write `.md` 文件时，hook 检查 session 级 marker。无 marker → deny 并提示调用 doc-maintenance skill；skill 调用后 marker 写入，后续 .md 编辑直接放行。

**CLAUDE.md 强制门禁与分级（v1.0.3，issue #19）**：任何 CLAUDE.md 都走门禁（不再豁免），按层级分两级强度：
- **全局** `~/.claude/CLAUDE.md`：最高强度。脚本大小写不敏感识别（macOS/APFS 不区分大小写），**无条件门禁**——绕过所有位置排除（路径 + 临时目录），deny 消息含「最高强度」提示 + 日志 reason `skill-not-invoked-global`；doc-maintenance 套用最严「全局 CLAUDE.md 通用化原则」（跨域/稳定/鲁棒/只放原则四判据全过）。
- **项目级** `<project>/CLAUDE.md`：普通强度走标准门禁，四判据作参考。

**排除名单**（不触发门禁）：
- Basename：`MEMORY.md`（工具自维护）、`SKILL.md`/`CHANGELOG.md`/`LICENSE.md`（特殊格式/非散文，不适用文档维护原则）。`CLAUDE.md`/`README.md`/`CONTRIBUTING.md` 已移出——现为受治理文档
- Path：`*/.claude/*`、`*/.claude-plugin/*`、`*/node_modules/*`、`*/.git/*`（全局 `~/.claude/CLAUDE.md` 例外，见上）
- 临时目录：`/tmp/*`、`/var/tmp/*`、`/var/folders/*`（macOS）、`/private/tmp/*`（macOS）

**Marker 生命周期**：session 级，120min stale 清理（兼做上下文刷新——长 session 后强制重新加载 skill）。

**Fail-open**：jq 缺失、JSON 损坏、session 为空、GATE_DIR 不可写等异常一律静默放行。

**已知边界**：Bash tool 可通过 `sed`/`echo >` 绕过 Edit/Write 管道。CLAUDE.md "Shell 交互工具原则"提供外层约束。

## Skills

PPT Skills 打包在 `plugins/ppt-press/` 插件内，通过 `plugin.json` 的 `skills` 字段声明路径，被 `npx skills add` 发现。

### PPT 技能包

三个 skill 覆盖 PPT 全生命周期：

| Skill | 职责 | 大小 |
|-------|------|------|
| `ppt-create` | 内容生产：需求澄清 → 大纲 → Astro 页面 → 自检 | ~85KB（含 5 references + 1 asset） |
| `ppt-deploy` | 构建验证 → 批量 Playwright 测试 → Amplify 部署 | ~4KB |
| `ppt-manage` | deck 列表检索 / 搜索 / URL 复制 | ~2KB |

### 安装

```bash
npx skills add WooDragon/cc-plugins -g
npx skills ls -g | grep ppt
```

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
