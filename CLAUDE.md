# cc-plugins

WooDragon 的 Claude Code 插件 marketplace。

## 当前版本

| 插件 | 版本 |
|------|------|
| plan-review | 1.0.32 |

## 项目结构

```
.claude-plugin/marketplace.json   # marketplace 元数据（插件注册、版本）
plugins/
  plan-review/                    # 对抗性审阅插件
    .claude-plugin/plugin.json    # 插件元数据
    hooks/hooks.json              # PreToolUse + PreCompact hook 声明
    scripts/plan-review.sh        # 核心脚本（ExitPlanMode 拦截）
    scripts/precompact-review.sh  # PreCompact hook（compaction 恢复）
    tests/                        # BDD 测试套件（bats-core）
      plan-review.bats            # 100 个测试用例
      test_helper/
        common-setup.bash         # 测试基础设施（mock、断言）
```

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `REVIEW_ENGINE` | `gemini` | 审阅引擎：`gemini` 或 `claude` |
| `REVIEW_DISABLED` | `0` | `1` 全局关闭 |
| `REVIEW_DRY_RUN` | `0` | `1` 跳过引擎调用 |
| `REVIEW_MAX_ROUNDS` | `3` | 非 Critical 最大磋商轮次（CONCERNS 累计） |
| `REVIEW_MAX_TOTAL_ROUNDS` | `20` | 全局绝对上限（含 REJECT 轮次），到达后硬拦截 |
| `REVIEW_ENGINE_TIMEOUT` | gemini=`115` / claude=`90` | 引擎调用超时秒数（需系统有 timeout/gtimeout）；Gemini 115s 给 CLI 充足响应时间，Claude 90s 保证完整 review 输出 |
| `REVIEW_API_URL` | _(空)_ | REST API 降级 base URL（OpenAI 兼容格式，如 `https://proxy.example.com`） |
| `REVIEW_API_KEY` | _(空)_ | REST API 降级 auth key（Bearer token） |
| `REVIEW_REST_TIMEOUT` | `115` | REST fallback curl 超时秒数（钳制逻辑自动截断到 remaining-3） |
| `REVIEW_HOOK_BUDGET` | `595` | hook 总时间预算秒数（600s hook timeout - 5s 余量），控制 retry loop 和 REST timeout 钳制 |
| `REVIEW_CAPACITY_DELAY` | `25` | 检测到 MODEL_CAPACITY_EXHAUSTED 后等待秒数（REST 配置时跳过此延迟直接 break） |
| `REVIEW_ENGINE_DEGRADE_TTL` | `3600` | Gemini 降级状态 TTL 秒数；capacity exhaustion 后后续 hook 在 TTL 内直接跳过 CLI 走 REST |

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

## 架构设计

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

## 历史记录

开发踩坑记录已归档至 GitHub Issues：

- [#8 初期插件开发陷阱](https://github.com/WooDragon/cc-plugins/issues/8) — Marketplace 命名、hooks 重复加载、版本双写、KV Cache 原则
- [#9 Hook 可靠性与诊断改进 (v1.0.12~v1.0.15)](https://github.com/WooDragon/cc-plugins/issues/9) — Compaction 绕过、入口诊断日志、set-e 静默退出、进程残留
- [#10 Gemini Capacity & REST 降级体系演进 (v1.0.16~v1.0.27)](https://github.com/WooDragon/cc-plugins/issues/10) — Skills 注入、REST 降级、capacity fast-break、降级持久化
- [#11 审阅质量增强 & Hook Timeout 修正 (v1.0.28~v1.0.32)](https://github.com/WooDragon/cc-plugins/issues/11) — Execution topology、造轮子检测、hook timeout 认知修正
