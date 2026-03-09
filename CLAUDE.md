# cc-plugins

WooDragon 的 Claude Code 插件 marketplace。

## 当前版本

| 插件 | 版本 |
|------|------|
| plan-review | 1.0.16 |

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
      plan-review.bats            # 70 个测试用例
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
| `REVIEW_ENGINE_TIMEOUT` | `25` | 引擎调用超时秒数（需系统有 timeout/gtimeout） |

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

### Conversation Compaction 恢复机制（v1.0.12）

**问题**：当 plan mode 中触发 conversation compaction 时，Claude Code 框架直接退出 plan mode，不调用 ExitPlanMode，导致 PreToolUse:ExitPlanMode hook 被完全绕过，review 不触发。

**根因确认方式**：查看 `plan-review.log`——compaction 后无任何 log 条目（连 session_id guard 的 silent exit 都没有），说明 ExitPlanMode 根本没被调用。

**修复**：添加 `PreCompact` hook（`scripts/precompact-review.sh`），在 compaction 前向 Claude 注入 `systemMessage`：

```json
{"continue": true, "systemMessage": "⚠️ PLAN REVIEW IN PROGRESS — 必须通过 ExitPlanMode 继续 review..."}
```

`systemMessage` 随 compaction 内容一起被保留，告知 Claude 恢复后必须调用 ExitPlanMode 而非直接展示 plan。

**session_id 诊断改进**：`plan-review.sh` 的 session_id guard 由静默 `exit 0` 改为写日志后退出，方便排查 compaction 导致 session_id 丢失的场景（应在日志中留下 `session=MISSING` 记录）。

### 入口诊断日志与引擎超时（v1.0.13）

**问题**：hook 间歇性不触发 review，但无法区分两种故障模式——框架未调用 hook vs. 引擎挂死被 120s timeout 杀死。所有日志在 guard 之后才写，guard 层的 silent exit 0 与"框架没调用"产生完全相同的观测空白。

**修复**：

1. **统一变量提取**：`TOOL_NAME` 和 `SESSION_ID` 通过单次 jq 调用提取（`@tsv`），上移到所有 guard 之前。消除冗余 jq fork，全程复用。

2. **入口日志 `log_entry()`**：在所有 guard 之前无条件写入 `ENTRY tool=... session=... pid=...`。每个 guard 退出前额外写 `guard=<reason>` 标记。

3. **引擎超时包裹**：检测 `timeout`（GNU/Homebrew）或 `gtimeout`（coreutils），为引擎调用添加 `timeout -k 5 $ENGINE_TIMEOUT` 前缀。无 timeout 命令时静默降级（行为与 v1.0.12 一致）。超时返回 exit 124，被现有 retry 逻辑自动处理。

**诊断流程**：
- 有 ENTRY 行 + 有 decision 行 → hook 正常执行
- 有 ENTRY 行 + 有 guard 行 → hook 被 guard 拦截（看原因）
- 有 ENTRY 行 + 无后续行 → hook 被 120s timeout 杀死（确认引擎问题）
- 无 ENTRY 行 → 框架未调用 hook（报 Claude Code bug）

### 测试隔离变量（仅测试使用）

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `REVIEW_LOG_DIR` | `$HOME/.claude/logs` | 日志目录 |
| `REVIEW_COUNTER_DIR` | `/tmp/claude-reviews` | counter 文件目录 |
| `REVIEW_PLAN_DIR` | `$HOME/.claude/plans` | plan 文件 fallback 目录 |
| `REVIEW_RETRY_DELAY` | `2` | 引擎重试间隔秒数 |
| `REVIEW_ENGINE_TIMEOUT` | `25` | 引擎调用超时秒数 |

生产环境不设置这些变量，脚本 fallback 到默认路径。测试通过注入临时目录实现完全隔离。

### set -e + read 在 log_entry() 前静默退出（v1.0.14）

**问题**：v1.0.13 将字段提取上移到所有 guard 之前。当 `INPUT` 为空或非法 JSON 时，`jq` 失败 → 进程替换产生 EOF → `read` 返回 1 → `set -euo pipefail` 在 `log_entry()` 调用前静默退出。结果零 ENTRY 行，与"框架未调用 hook"观测完全相同，导致误诊。

**修复**：预初始化变量（防 `set -u`）+ `|| true` 屏蔽 `read` 非零退出（防 `set -e`）：

```bash
TOOL_NAME="" SESSION_ID=""
read -r TOOL_NAME SESSION_ID < <(...) || true
```

行为语义：jq 失败时变量保持空字符串，脚本继续执行 → `log_entry` 正常写 ENTRY → tool-name guard 拦截 → `exit 0`。

**新增测试**：`run_hook_raw_stdin()` 辅助函数（绕过 `${INPUT:-default}` fallback）+ 测试 #71-74 覆盖空/非法 stdin 场景。

### 引擎进程残留管理 + 默认模型固定（v1.0.15）

**问题一（进程残留）**：引擎调用用 command substitution `$(timeout ... gemini ...)` — bash 被 SIGTERM（框架 120s 超时）杀死后，`timeout + gemini` 子进程变成孤儿，最多再跑 45s（`timeout` 到期才 kill gemini）。

**问题二（模型别名）**：脚本默认 `gemini-3-pro-preview`，Gemini CLI 内部将其解析为 `gemini-3.1-pro-preview`，但错误信息暴露实际 model ID，排查时产生歧义。改为显式指定 `gemini-3.1-pro-preview`。

**修复（进程残留）**：引擎调用从 command substitution 改为 background + wait 模式，显式追踪 `ENGINE_PID`，扩展 trap 覆盖 EXIT/INT/TERM/HUP：

```bash
_cleanup() {
  rm -f "$PROMPT_FILE" "${ENGINE_OUT:-}"
  [ -z "${ENGINE_PID:-}" ] || kill "$ENGINE_PID" 2>/dev/null || true
}
trap '_cleanup' EXIT
trap '_cleanup; exit 130' INT TERM HUP
```

引擎调用：
```bash
${TIMEOUT_CMD:+$TIMEOUT_CMD -k 5 $ENGINE_TIMEOUT} gemini -m "$GEMINI_MODEL" \
  < "$PROMPT_FILE" > "$ENGINE_OUT" 2>>"$LOG_FILE" &
ENGINE_PID=$!
wait "$ENGINE_PID" 2>/dev/null || engine_exit=$?
ENGINE_PID=""
```

**效果**：框架 SIGTERM 触发 `_cleanup`，gemini 被立即 kill，不再有孤儿进程。

### Gemini Skills 注入 + 429 Capacity 耗尽（v1.0.16）

**根因一（Skills 注入）**：Gemini CLI 从 `~/.agents/skills/` 和 `~/.gemini/skills/` 加载 SKILL.md 文件作为额外系统 prompt。prompt 已达 15-30KB，skills 再注入 10-30KB，大幅增加 token 量，加重 MODEL_CAPACITY_EXHAUSTED 概率。

**根因二（内部 retry 放大）**：Gemini CLI 遇到 429 会用 backoff 自动 retry 3-4 次。45s 超时窗口内可积累 4-5 次 CLI 内部重试，加上脚本层 2 次重试，总计 6-8 次 API calls 在 ~90s 内打到 capacity-limited 服务端。

**修复一（隔离 Gemini home）**：在 `$HOME/.claude/.gemini-hook-home/` 创建持久化 home，settings.json 写 `{"selectedAuthType":"oauth-personal","skills":{"enabled":false}}`，auth 文件通过 symlink 指向真实 `~/.gemini/`（保持凭证自动同步）。调用前注入 `GEMINI_CLI_HOME="$_HOOK_GEMINI"`，无 skills 目录 → 零注入。

**修复二（ENGINE_TIMEOUT 25s）**：默认值从 45 降为 25，将 CLI 内部 retry 机会从 3-4 次压缩到 1-2 次。全路径时序验证：attempt1(25s) + REVIEW_CAPACITY_DELAY(25s) + attempt2(25s) = 75s，在 120s hook timeout 内有 45s 安全余量。需要更慢响应的场景可用 `REVIEW_ENGINE_TIMEOUT=45` 覆盖。

**已同步改动**：REVIEW_CAPACITY_DELAY 检测逻辑（检测新增日志字节中的 RESOURCE_EXHAUSTED|MODEL_CAPACITY，命中时等待 25s）亦在本版本随以上两项一起 commit。
