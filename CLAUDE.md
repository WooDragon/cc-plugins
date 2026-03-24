# cc-plugins

WooDragon 的 Claude Code 插件 marketplace。

## 当前版本

| 插件 | 版本 |
|------|------|
| plan-review | 1.0.28 |

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
      plan-review.bats            # 90 个测试用例
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
| `REVIEW_ENGINE_TIMEOUT` | gemini=`25` / claude=`90` | 引擎调用超时秒数（需系统有 timeout/gtimeout）；按引擎分流：Gemini 25s 抑制内部 retry 放大，Claude 90s 保证完整 review 输出 |
| `REVIEW_API_URL` | _(空)_ | REST API 降级 base URL（OpenAI 兼容格式，如 `https://proxy.example.com`） |
| `REVIEW_API_KEY` | _(空)_ | REST API 降级 auth key（Bearer token） |
| `REVIEW_REST_TIMEOUT` | `115` | REST fallback curl 超时秒数（等于 HOOK_BUDGET；钳制逻辑自动截断到 remaining-3，降级路径下 REST 获得完整预算） |
| `REVIEW_HOOK_BUDGET` | `115` | hook 总时间预算秒数（框架 120s 限制 - 5s 余量），控制 retry loop 和 REST timeout 钳制 |
| `REVIEW_CAPACITY_DELAY` | `25` | 检测到 MODEL_CAPACITY_EXHAUSTED 后等待秒数（REST 配置时跳过此延迟直接 break） |
| `REVIEW_ENGINE_DEGRADE_TTL` | `3600` | Gemini 降级状态 TTL 秒数；capacity exhaustion 后后续 hook 在 TTL 内直接跳过 CLI 走 REST |

敏感变量（`REVIEW_API_KEY`）配置在 `~/.claude/settings.json` 的 `"env"` 字段中。Claude Code 启动时自动注入到所有 hook 进程环境，无需污染 shell profile。`~/.claude/settings.local.json` 不是合法的用户级配置路径，env 字段在此处不生效。

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
| `REVIEW_HOOK_BUDGET` | `115` | hook 总时间预算秒数 |

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

**问题二（模型别名）**：脚本曾显式指定 `gemini-3.1-pro-preview`，后改回 `gemini-3-pro-preview`（别名）——两者在 Gemini CLI 内部等价，别名更简短且与官方文档一致。

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

**修复一（隔离 Gemini home）**：在 `$HOME/.claude/.gemini-hook-home/` 创建持久化 home，auth 文件通过 symlink 指向真实 `~/.gemini/`（保持凭证自动同步）。settings.json 通过 `jq '. + {"skills":{"enabled":false}}'` 从真实配置 merge 生成（保留完整 auth 结构，每次调用自动同步 auth 类型变更）。调用前注入 `GEMINI_CLI_HOME="$_HOOK_GEMINI"`，无 skills 目录 → 零注入。

**修复二（ENGINE_TIMEOUT 25s）**：默认值从 45 降为 25，将 CLI 内部 retry 机会从 3-4 次压缩到 1-2 次。全路径时序验证：attempt1(25s) + REVIEW_CAPACITY_DELAY(25s) + attempt2(25s) = 75s，在 120s hook timeout 内有 45s 安全余量。需要更慢响应的场景可用 `REVIEW_ENGINE_TIMEOUT=45` 覆盖。

**已同步改动**：REVIEW_CAPACITY_DELAY 检测逻辑（检测新增日志字节中的 RESOURCE_EXHAUSTED|MODEL_CAPACITY，命中时等待 25s）亦在本版本随以上两项一起 commit。

### CLI 优先 + REST API 降级（v1.0.18）

**问题**：`cloudcode-pa.googleapis.com`（Code Assist 免费层）持续 429，CLI 三层 retry 叠加后最多 60 次 API 调用仍失败。用户有自定义 API proxy（OpenAI-compatible），走不同 capacity 池。

**修复**：retry loop 结束后、fail-open 之前插入 REST API 降级路径。零侵入现有逻辑。

**降级条件**：CLI 产出空 `REVIEW` **且** `REVIEW_API_URL` + `REVIEW_API_KEY` 均非空。任一为空则跳过，保持原 fail-open 行为。

**API 格式**（OpenAI-compatible）：
- Endpoint：`${REVIEW_API_URL}/v1/chat/completions`
- Auth：`Authorization: Bearer ${REVIEW_API_KEY}`
- Body：`{ model, messages: [{role: "system", content: SYSTEM_INSTRUCTIONS}, {role: "user", content: PROMPT_FILE}], max_tokens: 16000, temperature: 0.1 }`
- Response 提取：`.choices[0].message.content`

**设计约束**：
- CLI 模式下 PROMPT_FILE 已含 SYSTEM_INSTRUCTIONS 前缀（Gemini 引擎），REST fallback 将 SYSTEM_INSTRUCTIONS 独立传入 system message，PROMPT_FILE 全文作 user message。system 中重复无害——system 位置的权重正确，user 中的副本只是略多 token
- `REQ_FILE`（请求体临时文件）由 `_cleanup()` 统一管理，SIGTERM 时自动清理
- curl 以 background + wait 模式运行，复用 `ENGINE_PID` 追踪和 `TIMEOUT_CMD` 超时包裹
- 回滚 v1.0.17 工作区的 prompt 压缩实验（SYSTEM_INSTRUCTIONS、GLOBAL_MD cap、PROJECT_MD cap、USER_REQ 恢复原值）——REST 降级解决 capacity 问题后，prompt 压缩不再必要

**新增测试**（6 个）：CLI fails + API configured → REST succeeds；CLI fails + API not configured → fail-open；CLI fails + REST fails → fail-open；CLI succeeds → REST not called；curl exit 127 → fail-open；response parsing 提取 choices[0].message.content。

### Capacity Fast-Break + REST 时间窗口（v1.0.18 后续）

**问题**：120s hook timeout 与 Gemini capacity 耗尽时序冲突。全路径耗时：attempt1(25s) + capacity wait(25s) + attempt2(25s) = 75s；REST 只剩 45s，而 curl 需要 ~50s → 被框架杀死。

**修复（Capacity Fast-Break）**：在 capacity 检测分支增加判断：若 `REVIEW_API_URL` + `REVIEW_API_KEY` 均已配置，立即 `break` 跳出 retry loop，跳过剩余 capacity 等待和第二次 CLI 尝试，让 REST 获得 ~110s 窗口。无 REST 配置时行为不变（仍等待并重试）。

**独立 REST 超时**：引入 `REVIEW_REST_TIMEOUT`（默认 60s），与引擎 `REVIEW_ENGINE_TIMEOUT`（25s）分离。REST API 通常需要更长超时（thinking 模型 token 生成慢）。

**max_tokens 截断修复**：REST 请求 `max_tokens` 从 4000 提升至 16000。Thinking 模型的 reasoning tokens 会消耗 token budget，4000 不足以完整输出详细 review 意见。

**新增测试**（2 个）：capacity + REST configured → fast break + REST used；capacity + no REST → retries CLI（第二次成功）。全套 82/82 pass。

### Retry Loop Time-Budget Guard + REST Timeout Clamping（v1.0.23）

**问题一（Retry loop 超框架限制）**：当 `REVIEW_ENGINE_TIMEOUT` 设置 >55s 时（如 Gemini 正常响应 ~60s 需要 70s），两次完整 attempt 耗时必定超出框架 120s 限制。路径：A1 timeout(70s) + sleep(2s) + A2 timeout(70s) = 142s > 120s，框架 SIGTERM 杀死脚本，REST fallback 永远不可达。

**问题二（REST 承诺无法兑现的超时）**：即使 budget guard 让 REST 有机会执行，REST 仍以 `REVIEW_REST_TIMEOUT=90` 做 timeout 包裹。若剩余时间 <90s，框架 SIGTERM 在 curl 完成前杀死脚本，诊断日志不会写入。

**修复**：统一使用 `HOOK_BUDGET - SECONDS` 剩余预算模型（`HOOK_BUDGET` 默认 115 = 120 框架限制 - 5s 余量）：

1. **Retry loop budget guard**：第 2 次迭代前检查 `remaining < ENGINE_TIMEOUT`，不够则 `break` 跳出 retry loop，让 REST fallback 有充足时间窗口
2. **REST timeout clamping**：`min(REVIEW_REST_TIMEOUT, remaining - 3)` 确保 curl 在框架 SIGTERM 前自行超时退出。3s margin 留给 jq 提取 + log_decision 写入

**时序验证**（ENGINE_TIMEOUT=70s 场景）：A1: 70s + 2s → budget 43<70 → break → REST(min(90,40)=40s) → 总耗时 ~115s，框架限制内。

**新增测试**（4 个）：budget exhausted + REST → skip retry → REST fires；budget sufficient → normal retry；budget exhausted + no REST → fail-open；REST timeout clamped to remaining budget。全套 90/90 pass。

### Gemini 降级状态持久化 + 失败明确拒绝（v1.0.24）

**问题一（时间窗口不足）**：`REVIEW_ENGINE_TIMEOUT=70` 时，Gemini CLI 消耗 70s 才触发 capacity-fast-break，剩余预算 45s，REST 被钳制到 42s，而服务端实际耗时 47s → curl 被杀 → http=000 fail-open。

**问题二（静默 fail-open 无法重试）**：所有引擎都失败时，旧实现静默 allow 并打印 `[WARNING]`，Claude 认为审阅已跳过并继续。实际上引擎只是暂时不可用，Claude 应能选择重试。

**修复一（降级状态持久化）**：

- 降级文件：`$COUNTER_DIR/.gemini-degraded`（无 session suffix，跨 hook 持久）
- 写入时机：capacity-fast-break 触发时（Gemini + REST 均配置）
- 跳过条件：下次 hook 进入时，`_gemini_skip_cli=1`，retry loop 第 1 次迭代立即 break
- TTL：`REVIEW_ENGINE_DEGRADE_TTL`（默认 3600s）；过期后降级无效，正常走 Gemini
- 效果：REST 获得完整 ~115s 预算，而不是 capacity 等待耗尽后的残余 45s

**修复二（fail-deny 替代 fail-open）**：

- `_fail_reason` 变量追踪所有引擎失败原因（CLI 失败 / capacity exhausted / REST http 状态）
- 所有引擎失败 + `_fail_reason` 非空 → `deny` 并推送失败原因给 Claude，Claude 可告知用户并重试
- `_fail_reason` 为空（理论路径，引擎压根未被调用）→ 保留旧 `allow_with_reason("[WARNING]...")` 兜底

**新增测试**（7 个，#91-97）：fresh degraded → skip CLI + REST used；expired degraded → Gemini called；fresh degraded + no REST → Gemini called；capacity-fast-break → degraded file written；regular failure → no degrade；capacity + REST fails → deny with reason；degraded + REST fails → deny with combined reason。全套 97/97 pass。

### Gemini 全失败场景降级扩展（v1.0.25）

**问题**：v1.0.24 的降级文件仅在 `RESOURCE_EXHAUSTED|MODEL_CAPACITY` 时写入。实际上 Gemini 可因 ECONNRESET、timeout（exit 124）等非 capacity 原因失败，这些场景不写降级文件，下次 hook 仍浪费整个 ENGINE_TIMEOUT 在必然失败的 CLI 调用上。

**修复**：在 REST fallback 入口（`REVIEW` 为空 + REST 已配置）写降级文件，条件为 Gemini 实际被调用过（`_gemini_skip_cli=0`）且文件尚未存在（避免 capacity-fast-break 路径重复写）。覆盖所有失败模式：timeout、网络断连、空响应。

**新增测试**（1 个，#98）：普通失败 + REST 配置 → REST 入口写降级文件。全套 98/98 pass。

### 降级文件过期后 TTL 不刷新（v1.0.27）

**问题**：`REVIEW_ENGINE_DEGRADE_TTL` 到期后，降级文件仍然存在（只是过期），`_gemini_skip_cli=0` → Gemini 重新被调用 → exit 124（70s）→ REST fallback 入口。此处写降级文件的条件含 `! -f "$DEGRADE_FILE"`——文件存在则跳过写入，**时间戳不刷新**。下次 hook 再进来：文件还是那个过期的旧时间戳 → 再次跑 Gemini 70s → REST 仅剩 ~40s（被 clamp）→ 000 循环。

**修复**：移除 REST fallback 入口处的 `! -f "$DEGRADE_FILE"` 条件，让每次 Gemini 失败都无条件刷新时间戳。`capacity-fast-break` 路径在 REST 入口前已写文件，重复写只是将时间戳更新几毫秒，完全无害。

**新增测试**（2 个，#99-100）：
- #99：过期降级文件 + Gemini 失败 + REST 成功 → 时间戳被刷新（核心 bug 复现 + 验证修复）
- #100：capacity-fast-break 路径 + REST 成功 → 双写无害（时间戳仍在 10s 内）

全套 100/100 pass。

### REST 超时默认值提升（v1.0.26）

**问题**：`REVIEW_REST_TIMEOUT` 默认 90s，但降级路径下 HOOK_BUDGET 剩余约 113s，钳制逻辑 `min(90, 113-3)=90` 让 90s 成为软上限——剩余 23s 预算白白浪费。

**修复**：将 `REVIEW_REST_TIMEOUT` 默认值从 90 提升至 115（等于 `HOOK_BUDGET`）。钳制逻辑 `min(REVIEW_REST_TIMEOUT, remaining-3)` 全权决定实际超时：

- 降级路径（Gemini 完全跳过，SECONDS≈2）：`min(115, 110)=110s`（提升 22s）
- capacity-fast-break 路径（1 次 CLI 25s，SECONDS≈27）：`min(115, 85)=85s`（vs 旧 85s，持平）
- 正常双 retry 路径（2 次 CLI 52s+，SECONDS≈54）：`min(115, 58)=58s`（vs 旧 58s，持平）

非降级路径由钳制机制天然保护，无需额外改动。
