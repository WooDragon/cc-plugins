# Codex 后端：本地评审 GitHub PR

本地 `codex` CLI（`codex exec` 非交互模式）同步评审已开的 PR，评审结果打印到终端——不发 PR 评论、不触碰远程状态。与 grok/claude 后端是并列的同构后端：CLI 参数形态完全一致，仅底层调用的 LLM CLI 不同。

> 与 grok/claude 后端共享同一套 diff 组装 / 敏感文件过滤 / 工作区身份钉死逻辑（见 `lib/pr-review-common.sh`），行为细节一律见 [grok-review.md](grok-review.md) 对应章节，本文档不重复展开；本文档只讲 codex 后端特有的部分：CLI 参数形态的不同、沙盒与旗标原理、会话续接机制、state 文件路径、已知边界。

**要求**：`codex` CLI 已装并登录（本文档基于本机实测的 codex-cli 0.147.0），`gh` CLI 已装并认证。

## 快速用法

```bash
# 首轮：全量评审，建 session
scripts/codex-review.sh <PR> [--repo owner/name] [--model M] [--effort E]

# 复核轮：续接同一 session，只发复核指令 + 本轮增量 diff
scripts/codex-review.sh <PR> --followup "<复核指令>" [--since <ref>] [--session <UUID>] \
                             [--repo owner/name] [--model M] [--effort E]
```

不带 `--repo` 时自动用当前仓库。首轮与复核轮是两条独立路径，机制与 grok/claude 后端一致（见 [grok-review.md](grok-review.md)「多轮 session 复用」）。

上面两行是**参数形态说明**，不是可直接照抄的调用式——agent 调用一律按 [grok-review.md](grok-review.md)「调用形态」两流分文件重定向。

## 与另两后端的不同

CLI 参数形态（`<PR> [--repo] [--model] [--effort] [--followup] [--since] [--session] [--allow-divergent-base]`）与 grok/claude 完全一致，只有 MODEL/EFFORT 默认值与合法集合不同：

| 参数 | codex 后端 | claude 后端（对照） | grok 后端（对照） |
|---|---|---|---|
| `--model M` | `gpt-5.6-luna`（`CODEX_REVIEW_MODEL` 覆盖，实测取自本机 codex 未传 `-m` 时的默认转译模型） | `claude-opus-5`（`CLAUDE_REVIEW_MODEL` 覆盖） | `grok-4.6`（`GROK_MODEL` 覆盖） |
| `--effort E` | 合法值严格为 `none/low/medium/high/xhigh/max`，默认 `medium`（`CODEX_REVIEW_EFFORT` 覆盖） | 合法值严格为 `low/medium/high/xhigh/max`，默认 `medium` | 合法值严格为 `none/minimal/low/medium/high`，默认 `high` |

三后端的 effort 合法集合两两不同（codex 比 claude 多一个 `none`；比 grok 多 `xhigh`/`max`，少 `minimal`），**不可混用判据**——`--effort minimal` 在 grok 合法、在 codex/claude 都非法；`--effort none` 在 codex/grok 合法、在 claude 非法。

环境变量命名同样加 `_REVIEW_` 前缀（`CODEX_REVIEW_MODEL`/`CODEX_REVIEW_EFFORT`），刻意不用裸 `CODEX_MODEL`——那个名字已被 `plugins/plan-review` 的 codex 引擎占用（`plugins/plan-review/scripts/lib/engines/codex.sh`），撞名会导致两个插件的配置互相串味。

**effort 合法集合的实测依据**：codex CLI 没有 `--effort` 旗标，走 `-c model_reasoning_effort=<v>`；传入不受支持的档位时，底层 API 会以 400 响应完整列出合法集合。本机实测传 `minimal`：

```
$ echo 'reply with the single word ok' | codex exec -s read-only -c model_reasoning_effort=minimal -
...
ERROR: {
  "type": "error",
  "error": {
    "type": "invalid_request_error",
    "code": "unsupported_value",
    "message": "Unsupported value: 'minimal' is not supported with the '<model>' model. Supported values are: 'none', 'low', 'medium', 'high', 'xhigh', and 'max'.",
    "param": "reasoning.effort"
  },
  "status": 400
}
```

`high`/`max` 已逐一实测跑通（exit=0，正常输出评审文本），其余档位据 API 报错原文合法集合并列采信。

## 沙盒与旗标原理

首轮与复核轮调用 `codex exec` 前，脚本会：

```bash
codex exec -m "$MODEL" -c model_reasoning_effort="$EFFORT" \
  -s read-only ${CODEX_CWD[@]+"${CODEX_CWD[@]}"} --ignore-rules --color never \
  --json -o "$OUT_FILE" \
  - < "$PROMPT_FILE"          # 首轮
  # 或
  resume "$SID" - < "$PROMPT_FILE"   # 复核轮
```

- **`-s read-only`**：钉死 codex 的沙盒策略为只读，不允许写文件、不允许执行有副作用的命令。
- **`--ignore-rules`**：阻止加载用户或项目 execpolicy `.rules` 文件——被评审仓库（`gh pr checkout` 之后的外部贡献者分支）是不可信来源，不应让它注入 codex 的执行策略。
- **不加 `--ephemeral`**：`--ephemeral` 会让会话不落盘、`resume` 完全失效，与本脚本要的多轮对抗复评需求矛盾——这与 claude 后端「不加 `--no-session-persistence`」是同一类型的取舍，勿抄错。
- **`--color never`**：避免 ANSI 转义序列污染打印到终端 / 落进 `-o` 文件的评审文本。
- **`--json` + `-o "$OUT_FILE"` 组合，而非 `--output-format`**：codex exec 没有 grok 那样的 `--output-format plain` 旗标（本机 `--help` 逐项核对，无此选项）。脚本改用 `--json` 把 stdout 事件流单独重定向捕获（用于首轮解析 `thread_id`、失败时诊断），再用 `-o "$OUT_FILE"` 拿到干净的最终回复文本（不含事件包装、不含 codex 默认人类可读模式会夹带的完整 prompt 回显），成功后 `cat "$OUT_FILE"` 把评审正文打到 stdout。**这不是逐字流式**——codex 进程运行期间用户看不到中间过程，只有整个 turn 完成后才一次性吐出评审正文；grok/claude 两后端是边生成边直接流式打印到终端。这是用 `--json`+`-o` 换取"可靠拿到 thread_id + 干净正文"的代价，是已知的 UX 差异，不是实现疏漏。
- **`-C`（工作目录）比照 grok 的 `--cwd` 做同名安全收紧，而非claude 后端那样完全不传**：`-s read-only` 下 codex 仍具备读取给定目录内文件的能力（不同于 claude 后端的 `--tools ""`——那条路径下 claude 连"读"都不被允许，故 claude 后端从不需要传等价的 `-C`/`--cwd`）。既然 codex 有读文件能力，就必须比照 grok 的做法：只有本地 checkout 精确匹配 `--repo` 的 owner/name 时才传 `-C` 指向该目录，避免"`--repo` 指向别的仓库、却把当前目录暴露给 codex 读"的错配面。任务原始设计意图给出的骨架是无条件传 `-C "$REPO_ROOT"`，脚本落地时做了这层收紧，属实现阶段基于实测能力（read-only 沙盒可读文件）的主动收窄，不是照抄骨架。
- **无 `--system-prompt`/`--rules` 等价旗标**：`codex exec --help` 逐项核对，没有把系统侧规则文案与用户数据分离投递的独立通道（grok 有 `--rules`，claude 有 `--system-prompt`）。脚本退而求其次，把 `RULES`/`RULES_FOLLOWUP` 文案直接拼进 prompt 正文最前面（`wrap_prompt_with_rules`），`DELIM` 包裹不可信数据的边界仍然保留，只是"系统指令"与"用户数据"现在共享同一个输入通道而非物理隔离的两个通道——这是 codex CLI 能力边界决定的、与 grok/claude 的真实差异。
- **不复用 `unset_provider_routing_env`**：该函数清理的是 Claude Code 生态专属变量（`ANTHROPIC_*`/`CLAUDE_AGENT_*`/`CLAUDE_CODE_MESSAGING_*`/`CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY`），服务的是"`claude -p` 子进程可能继承到 grok 网关路由变量"这一 claude 后端专属风险。codex 凭证走独立的 `CODEX_HOME`，不识别、不消费这些变量；也不 `unset CLAUDECODE`/`CLAUDE_CODE_ENTRYPOINT`——那两个变量是 `claude` 二进制自身用来判断"是否在 Claude Code 内部递归启动"的信号，`codex` 二进制不识别、不会据此加载任何 hook/plugin。本机未发现 codex 存在等价的路由变量泄露风险，故未新增清理函数。

## 会话续接机制

首轮 `codex exec ... --json -o "$OUT_FILE" - < "$PROMPT_FILE"` 建会话；codex 自己生成 session/thread id，**脚本不预先生成 SID**（不同于 grok/claude 首轮用 `uuidgen` 预生成 `--session-id`/`-s` 再传给 CLI）。SID 从 `--json` 事件流的首行解析：

```
$ echo 'reply with the single word ok' | codex exec -s read-only --json -o /tmp/x.txt -
{"type":"thread.started","thread_id":"01a01f2b-946c-7e80-90d0-17edec471df7"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"ok"}}
{"type":"turn.completed","usage":{...}}
```

提取表达式（脚本内实际用法）：

```bash
SID=$(jq -r 'select(.type=="thread.started") | .thread_id' "$JSON_LOG" | head -n1)
```

复核轮 `codex exec ... resume "$SID" - < "$PROMPT_FILE"` 续接；已实测验证端到端记忆——首轮告知的秘密词，复核轮 `resume` 后原样答对。

**备选方案 `codex exec resume --last` 未采用**：该子命令按 cwd 过滤最近会话、不接受显式 SID，多 PR/多 worktree 并发评审时无法确定性定位到目标会话；显式解析 `thread_id` 落 state 后按值 `resume` 才是确定性的正确做法。

**会话失效判定**：`resume` 传入不存在/已失效的 SID 时，stderr 精确文案为：

```
Error: thread/resume: thread/resume failed: no rollout found for thread id <uuid> (code -32600)
```

exit=1，且**该文案只出现在 stderr、stdout 为空**（未进入 `turn.started` 阶段，未产出任何 JSON 事件）——已用真实 `codex exec` 分别重定向 stdout/stderr 验证过，与脚本"stdout（`--json` 事件流）和 stderr 分别重定向到独立文件"的设计吻合。脚本的 `SESSION_INVALID_RE='no rollout found for thread'` 据此判定，命中即 Fail Fast 提示重开首轮——语义对齐 grok/claude 两后端的设计（见 [grok-review.md](grok-review.md)「Fail Fast：复核轮无法续接时不降级」）。

## state 文件路径

```
${XDG_STATE_HOME:-$HOME/.local/state}/pr-review/<owner>__<name>__<PR>.codex.session
```

后缀是 `.codex.session`（grok 后端是 `.session`，claude 后端是 `.claude.session`），三者互不覆盖——同一 PR 可以分别有 grok、claude、codex 三条独立评审 session，互不干扰。`state_gc` 的 `*.session` glob 对 `foo.codex.session` 同样命中，三种后缀共用同一套 30 天 GC 逻辑。KV 字段、权限（目录 `chmod 700`）、写入时机（成功返回后才落盘）均与 grok/claude 后端一致，见 [grok-review.md](grok-review.md)「session 状态文件」。

## 已知边界

- **无逐字流式输出**：见上文「沙盒与旗标原理」`--json`+`-o` 一节——评审正文只在整个 turn 完成后一次性打印，长评审等待期间终端无中间进度。
- **无独立系统提示通道**：见上文「沙盒与旗标原理」——`RULES`/`RULES_SECURITY` 只能拼进 prompt 正文，与 grok（`--rules`）、claude（`--system-prompt`）的物理隔离投递不同。
- **`AGENTS.md` 自动加载注入面已消除**：codex CLI 会把被评审仓库（或 `-C` 指向目录）根目录的 `AGENTS.md` 自动加载进指令层——这与 grok/claude 都不同：grok/claude 都不会自动读取被评审仓库里任何"给 AI 看"的特殊文件，仅按脚本显式喂给它们的 prompt 文本工作。`-s read-only` 只挡 codex 因此写文件/跑命令，不挡"读取到 `AGENTS.md` 文案、被其影响评审措辞或判断"这条纯读取的提示词劫持面——PR 作者可借此让评审得出对自己有利的结论。本脚本已用 `-c project_doc_max_bytes=0` 关闭该自动加载。本机 codex-cli 0.147.0 实测坐实（同一 prompt，均含 "Do not run any commands"，`AGENTS.md` 里写 `the internal codename for this repository is ZEBRA47`）：

  | 调用 | 回答 |
  |---|---|
  | 默认（无旗标） | `ZEBRA47` ← 自动加载生效 |
  | `-c project_doc_max_bytes=0` | `UNKNOWN` ← 自动加载被关掉 |

  首轮调用与 `--followup` 复核轮两条路径均已加此旗标（漏一条等于复核轮无保护）。

- **`--strict-config` 的取舍**：脚本同时加了 `--strict-config`——好处是若未来 codex CLI 改名/删除 `project_doc_max_bytes` 这个键，`-c project_doc_max_bytes=0` 会静默变成 no-op（codex 默认对未知配置键不报错，安全旗标形同虚设却毫无提示），加 `--strict-config` 后这种情况会立即报错退出（本机实测：`codex exec --strict-config -c totally_bogus_key_xyz=1` → exit 1，`Error loading config.toml: unknown configuration field ...`；`project_doc_max_bytes` 被其接受，证明该键真实存在）。代价是若调用者的 `~/.codex/config.toml` 里恰好留有陈旧/未知配置键，也会一并触发报错退出——这是刻意取舍：**「安全旗标静默退化」比「配置报错」更糟**，前者会在毫无察觉的情况下让评审重新暴露给提示词注入，后者只是逼你先清理配置文件再继续。

- **残余边界（`project_doc_max_bytes=0` 消除不了、评审这件事本身固有）**：评审任务本身就要求 codex 读被评审仓库的 diff 与文件内容，这些内容仍由 PR 作者控制，仍会进入模型上下文——区别是它们现在只是**普通文件内容**，不再享有 `AGENTS.md` 那种「项目指令」的抬升地位（模型不会像信任系统指令一样信任 diff 里的文本）。这条残余面是"评审外部代码"这件事的固有面，任何后端只要读取被评审代码就存在，不是本旗标的疏漏，也不是 codex 后端独有——grok/claude 后端同样要读未受信的 diff/description，只是它们没有 `AGENTS.md` 自动加载这层额外抬升。

## 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| 未找到 codex CLI | 安装并 `codex login` |
| `PR #<n> 无活跃 session。请先跑一次首轮：codex-review.sh <n>` | 首次调用就带了 `--followup`，或状态文件已被 30 天 GC 清理、或本轮 `--repo`/所在目录解析出的仓库与首轮不同 |
| `PR #<n> 的 session 已失效/丢失，上下文不可恢复——请重开首轮评审` | codex 返回 `no rollout found for thread id ...`，session 已不可恢复；重新跑首轮开始新一轮评审 |
| `codex --json 输出未捕获到 thread_id（疑似 codex CLI 契约变更...）` | 本文档记录的 `{"type":"thread.started","thread_id":"..."}` 契约在新版 codex CLI 里发生了变化，需要重新实测三处 CLI 形态（session id 捕获 / 会话失效文案 / effort 合法集合）并更新脚本与本文档 |
| 非法 effort/model 报错 | 确认 `--effort` 取值属 `none/low/medium/high/xhigh/max`，未误用 grok 专属的 `minimal`（codex 也没有） |
| 其余（BASE_SHA 不可达、工作区身份钉死、敏感文件告警等） | 与 grok/claude 后端共用同一套 lib 逻辑，故障排查表见 [grok-review.md](grok-review.md)「故障排查」 |
