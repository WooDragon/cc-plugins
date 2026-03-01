# cc-plugins

WooDragon 的 Claude Code 插件 marketplace。

## 当前版本

| 插件 | 版本 |
|------|------|
| plan-review | 1.0.11 |

## 项目结构

```
.claude-plugin/marketplace.json   # marketplace 元数据（插件注册、版本）
plugins/
  plan-review/                    # 对抗性审阅插件
    .claude-plugin/plugin.json    # 插件元数据
    hooks/hooks.json              # PreToolUse hook 声明
    scripts/plan-review.sh        # 核心脚本
    tests/                        # BDD 测试套件（bats-core）
      plan-review.bats            # 56 个测试用例
      test_helper/
        common-setup.bash         # 测试基础设施（mock、断言）
```

## 开发踩坑记录

### Marketplace 命名限制

marketplace name 禁止包含 `claude`、`anthropic`、`official` 等关键词（反冒充机制）。最初用 `claude-plugins` 被拒，改为 `cc-plugins` 通过。

### hooks 声明重复加载

`hooks/hooks.json` 是框架约定路径，会被自动加载。若在 `plugin.json` 中再声明 `"hooks": "./hooks/hooks.json"`，会触发 `Duplicate hooks file detected` 错误。plugin.json 的 hooks 字段仅用于声明**非约定路径**的额外 hook 文件。

### 版本号双写对齐

插件版本号存在于两处：`marketplace.json` 的 plugins 条目和插件自身的 `plugin.json`。bump 版本时必须两处同步修改，否则 `claude plugin update` 检测不到新版本。

### Prompt 构造的 KV Cache 友好原则

调用 LLM API 时，prompt 内容的排列顺序直接影响 KV cache 命中率（prefix matching 机制）。plan-review 插件遵循以下分层策略：

**分层模型（从前缀到尾部）**：
1. **Static layer** — 角色定义、评审标准、输出格式等跨调用完全不变的指令。Claude 引擎走 `--system-prompt`（独立 cache 通道），Gemini 引擎作为 prompt 文件前缀
2. **Session-stable layer** — GLOBAL_MD、PROJECT_MD、USER_REQ 等同一会话内跨轮次不变的上下文
3. **Volatile layer** — PLAN、ROUND_CONTEXT 等每轮可能变化的内容，严格排在最末

**核心约束**：
- 静态内容禁止被动态内容切断——任何 static 块出现在 dynamic 块之后都是 cache 失效点
- 支持 system prompt 分离的引擎（Claude）将全部静态指令放入 system prompt
- 多轮磋商场景中，易变内容（轮次号、修改后的 plan）在 prompt 最末尾，保护前面 ~11KB session-stable 前缀的 cache 命中

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `REVIEW_ENGINE` | `gemini` | 审阅引擎：`gemini` 或 `claude` |
| `REVIEW_DISABLED` | `0` | `1` 全局关闭 |
| `REVIEW_DRY_RUN` | `0` | `1` 跳过引擎调用 |
| `REVIEW_MAX_ROUNDS` | `3` | 非 Critical 最大磋商轮次（CONCERNS 累计） |
| `REVIEW_MAX_TOTAL_ROUNDS` | `20` | 全局绝对上限（含 REJECT 轮次），到达后硬拦截 |

旧变量 `GEMINI_REVIEW_OFF`、`GEMINI_DRY_RUN`、`GEMINI_MAX_REVIEWS` 通过脚本内 fallback 继续生效。

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

### 测试隔离变量（仅测试使用）

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `REVIEW_LOG_DIR` | `$HOME/.claude/logs` | 日志目录 |
| `REVIEW_COUNTER_DIR` | `/tmp/claude-reviews` | counter 文件目录 |
| `REVIEW_PLAN_DIR` | `$HOME/.claude/plans` | plan 文件 fallback 目录 |
| `REVIEW_RETRY_DELAY` | `2` | 引擎重试间隔秒数 |

生产环境不设置这些变量，脚本 fallback 到默认路径。测试通过注入临时目录实现完全隔离。
