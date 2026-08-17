# Claude 后端：本地评审 GitHub PR

本地 `claude` CLI（`claude -p` 非交互模式）同步评审已开的 PR，评审结果直接打印到终端——不发 PR 评论、不触碰远程状态。与 grok 后端是并列的同构后端：CLI 参数形态完全一致，仅底层调用的 LLM CLI 不同。

> 与 grok 后端共享同一套 diff 组装 / 敏感文件过滤 / 工作区身份钉死逻辑（见 `lib/pr-review-common.sh`），行为细节一律见 [grok-review.md](grok-review.md) 对应章节，本文档不重复展开；本文档只讲 claude 后端特有的部分：CLI 参数形态的两处不同、隔离旗标原理、会话续接机制、state 文件路径。

**要求**：`claude` CLI 已装并登录，`gh` CLI 已装并认证。

## 快速用法

```bash
# 首轮：全量评审，建 session
scripts/claude-review.sh <PR> [--repo owner/name] [--model M] [--effort E]

# 复核轮：续接同一 session，只发复核指令 + 本轮增量 diff
scripts/claude-review.sh <PR> --followup "<复核指令>" [--since <ref>] [--session <UUID>] \
                              [--repo owner/name] [--model M] [--effort E]
```

不带 `--repo` 时自动用当前仓库。首轮与复核轮是两条独立路径，机制与 grok 后端一致（见 [grok-review.md](grok-review.md)「多轮 session 复用」）。

## 与 grok 后端的两处不同

CLI 参数形态（`<PR> [--repo] [--model] [--effort] [--followup] [--since] [--session] [--allow-divergent-base]`）与 grok-review.sh 完全一致，只有 MODEL/EFFORT 默认值与合法集合不同：

| 参数 | claude 后端 | grok 后端（对照） |
|---|---|---|
| `--model M` | `claude-opus-5`（`CLAUDE_REVIEW_MODEL` 覆盖） | `grok-4.6`（`GROK_MODEL` 覆盖） |
| `--effort E` | 合法值严格为 `low/medium/high/xhigh/max`，默认 `medium`（`CLAUDE_REVIEW_EFFORT` 覆盖） | 合法值严格为 `none/minimal/low/medium/high`，默认 `high`（`GROK_EFFORT` 覆盖） |

环境变量命名刻意加 `_REVIEW_` 前缀（`CLAUDE_REVIEW_MODEL`/`CLAUDE_REVIEW_EFFORT`），避免与 `plugins/plan-review` 已占用的 `CLAUDE_MODEL` 撞名——两个插件不同域，不共享同一个全局变量。claude 后端没有 grok 那样的 `xhigh` 历史迁移包袱（`none`/`minimal`/`xhigh` 在各自后端里的合法性互斥，勿混用）。

## 隔离旗标原理

首轮与复核轮调用 `claude -p` 前，脚本都会：

```bash
unset CLAUDECODE
unset CLAUDE_CODE_ENTRYPOINT
unset_provider_routing_env   # lib/pr-review-common.sh：9 个 ANTHROPIC_*/CLAUDE_AGENT_API_BASE_URL
                              # + 5 个 CLAUDE_CODE_MESSAGING_*/SESSION/GATEWAY_MODEL_DISCOVERY，
                              # 两处调用点共用，单一事实源
claude -p --model "$MODEL" --effort "$EFFORT" \
  --setting-sources "" --tools "" --disable-slash-commands \
  --safe-mode --strict-mcp-config \
  --system-prompt "$RULES或$RULES_FOLLOWUP" \
  --session-id "$SID"   # 首轮；复核轮改用 --resume "$SID"
```

- **`unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT`**：防止在当前 Claude Code 会话内部拉起 `claude -p` 子进程时递归加载 hook/plugin。复用 `plugins/plan-review/scripts/lib/engines/claude.sh` 已验证过的隔离手法。
- **`unset_provider_routing_env`**（`lib/pr-review-common.sh`，两处调用点共用的单一函数，不再各自手抄一份清单）：清理两组变量。第一组是 `ANTHROPIC_*`/`CLAUDE_AGENT_API_BASE_URL`（`ANTHROPIC_API_KEY`/`ANTHROPIC_BASE_URL`/`ANTHROPIC_API_BASE_URL`/`CLAUDE_AGENT_API_BASE_URL`/`ANTHROPIC_AUTH_TOKEN`/`ANTHROPIC_DEFAULT_OPUS_MODEL`/`ANTHROPIC_DEFAULT_SONNET_MODEL`/`ANTHROPIC_DEFAULT_HAIKU_MODEL`/`ANTHROPIC_SMALL_FAST_MODEL`）：当前会话若经外部 wrapper 脚本（`~/.claude/scripts/claude-wrapper.sh` 的 grok 分支）路由到 grok 网关，这组变量会被注入进程环境；不清理的话它们会被子进程原样继承，claude 子进程名义上切到了 claude 后端，实际请求仍会打到 grok 网关——`resolve-backend.sh` 的自动路由判断（见上文）就此完全落空。第二组是 `CLAUDE_CODE_MESSAGING_SOCKET`/`CLAUDE_CODE_MESSAGING_TOKEN`/`CLAUDE_CODE_SESSION_ID`/`CLAUDE_CODE_CHILD_SESSION`/`CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY`：前四个是当前会话自身的 team-messaging/IPC 状态，`CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY` 是 wrapper 的 grok 分支额外注入的网关发现开关，不清理同样会被子进程原样继承。
- **`--setting-sources "" --tools "" --disable-slash-commands`**：子进程不读任何 settings、无任何工具（比 grok 的 `--sandbox read-only` 更强——grok 还能靠 `--cwd` 读工作区文件，claude 这条路径下连"读"都不允许，全部上下文只能靠 prompt-file 里的文本喂给它）、禁用 slash 命令。因此 claude 后端不需要传等价的 `--cwd`/sandbox 参数；BASE_SHA/CWD 身份钉死逻辑仍然保留（`build_full_prompt`/`build_incremental_prompt` 共用 lib），但那是为了"从哪个 git 仓库取 diff 文本"服务的，与 claude 进程本身能不能碰文件系统是两回事。
- **`--setting-sources` 必须传空字符串 `""`，不能传 `"local"`**：这不是措辞选择，是安全修复。已用真实 `claude` CLI 复现：`claude-review.sh` 的运行前提是 cwd 已 `gh pr checkout <PR>`，即 cwd 是**外部贡献者可控的不可信工作区**；若该工作区里放了一个 `.claude/settings.local.json` 定义 SessionStart hook，`--setting-sources local` 会让这个 hook 真实执行——`--tools ""` 对此完全挡不住，因为 hook 触发和工具调用是两条独立的机制，前者不受 `--tools` 约束。这意味着一个恶意 PR 只需提交 `.claude/settings.local.json` 挂一个后门 hook，评审者一跑 `claude-review.sh` 就会执行攻击者指定的任意命令。改成 `--setting-sources ""` 后该 hook 不会触发，claude 照常按 prompt-file 里的文本工作——这是当前唯一安全的取值，任何"图方便"传回 `local` 都会重新打开这个口子。
- **`--safe-mode --strict-mcp-config`**：关闭比 `--setting-sources ""` 覆盖面更广的一整类通道——`--safe-mode` 一次性禁用 CLAUDE.md/skills/plugins/hooks/MCP servers/自定义命令与 agent/output styles/workflows/主题/键位绑定；`--strict-mcp-config` 双保险，即使显式传了 `--mcp-config` 也只信那份显式清单。动机：`.mcp.json`（项目级 MCP server 自动发现）是独立于 `--setting-sources` 的通道，未受信 PR checkout 根目录放一个恶意 `.mcp.json` 可以在"连接 MCP server"这一步就执行任意命令——这个执行发生在 `--tools ""` 能不能约束后续工具调用之前，`--tools ""` 完全挡不住。
- **不加 `--no-session-persistence`**：这是与 `plan-review` 插件的 claude engine 的关键差异，容易被后续维护者直接抄错——`--no-session-persistence` 会导致会话不落盘、`--resume` 完全失效，与本脚本要的多轮对抗复评需求矛盾。

## 会话续接机制

首轮 `gen_uuid` 生成 SID，`claude -p --session-id "$SID" ...` 建会话；复核轮 `claude -p --resume "$SID" ...` 续接。已用真实 `claude` CLI 验证过：`--session-id` 起会话、`--resume` 续接确实能跨进程记住上下文。

**会话失效判定**：`--resume` 传入不存在/已失效的 SID 时，stderr 精确文案为 `No conversation found with session ID: <uuid>`，exit=1。脚本的 `SESSION_INVALID_RE='No conversation found'` 据此判定，命中即 Fail Fast 提示重开首轮——语义对齐 grok 后端 `SESSION_INVALID_RE` 的设计（见 [grok-review.md](grok-review.md)「Fail Fast：复核轮无法续接时不降级」）。

## state 文件路径

```
${XDG_STATE_HOME:-$HOME/.local/state}/pr-review/<owner>__<name>__<PR>.claude.session
```

后缀是 `.claude.session`（grok 后端是 `.session`），两者互不覆盖——同一 PR 可以分别有 grok 和 claude 两条独立评审 session，互不干扰。KV 字段、权限（目录 `chmod 700`）、写入时机（成功返回后才落盘）、30 天 GC 策略均与 grok 后端一致（GC 的 `*.session` glob 对 `foo.claude.session` 同样命中，两种后缀共用同一套清理逻辑，见 [grok-review.md](grok-review.md)「session 状态文件」）。

## 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| 未找到 claude CLI | 安装并 `claude login` |
| `PR #<n> 无活跃 session。请先跑一次首轮：claude-review.sh <n>` | 首次调用就带了 `--followup`，或状态文件已被 30 天 GC 清理、或本轮 `--repo`/所在目录解析出的仓库与首轮不同 |
| `PR #<n> 的 session 已失效/丢失，上下文不可恢复——请重开首轮评审` | claude 返回 `No conversation found with session ID: ...`，session 已不可恢复；重新跑首轮开始新一轮评审 |
| 非零 effort/model 报错 | 确认 `--effort` 取值属 `low/medium/high/xhigh/max`、未误用 grok 专属的 `none`/`minimal` |
| 其余（BASE_SHA 不可达、工作区身份钉死、敏感文件告警等） | 与 grok 后端共用同一套 lib 逻辑，故障排查表见 [grok-review.md](grok-review.md)「故障排查」 |
