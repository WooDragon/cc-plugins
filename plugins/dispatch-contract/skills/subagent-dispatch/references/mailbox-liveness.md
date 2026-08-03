# 回传通道与活性判定（background subagent 派发后）

本文件管"派发之后"：产物怎么收回、活性怎么判、什么时候能停。与 dispatch-contract.md（派发前怎么写 prompt）互补。触发场景：spawn background subagent / teammate 后等待产物，或考虑 TaskStop 中止某 agent 时。

来源：一次真实事故——三个 background subagent 被误判卡死并 TaskStop，事后全部复活并发来完整产物。根因是「回传通道断裂」+「等待模型错误」两个叠加，非 agent 真死。

## 解法优先级：能同步就同步

派发一个「需要拿结果才能往下走」的任务，优先级从高到低：

1. **同步派发（默认首选）**：`run_in_background: false` 或普通 Agent 调用。子 agent 的最终文本直接作为 tool result 返回，不经 mailbox、不碰 SendMessage deferred 问题，最干净。呼应等待纪律——需要结果才能推进就同步拿返回值，别 spawn 后盲等。
2. **异步 background teammate**：必须并行 / 长驻时才用。产物只能靠 `SendMessage(to:"main")` 异步回传（见下节通道补丁），下一个 turn 才可见。
3. **环境级配置（兜底，不主推）**：见文末二进制实证节。

## 回传通道补丁（铁律①在 background 场景的落法）

**现象**：background subagent 的最终文本**不会自动进主 agent 的 mailbox**。它与主对话唯一的回传通道是 `SendMessage(to:"main")`。子 agent 若把结论当普通 final text 输出，那些字主 agent 永远收不到——表现为"agent 回到 idle 却没给结论"。

**加重因素（实证）**：`SendMessage` 在 subagent 上下文里**默认是 deferred 工具**——名字在、schema 未加载，必须先 `ToolSearch select:SendMessage` 把 schema 拉进来才能调用。子 agent 不必然知道要先加载，于是产物默默烂在它自己的 final text 里。

**证据**（一次真实 subagent session jsonl）：一个 in_process_teammate 的工具调用序列是 `ToolSearch{query:"select:SendMessage"}` → 29 秒后 → `SendMessage{to:"main", ...完整结论}`；SendMessage 全程只调 1 次，且必须由 ToolSearch 先行加载。

**派发 prompt 必须钉死（异步 teammate 场景）**：
> 你的产物必须通过 `SendMessage(to:"main")` 回传，你的最终文本不会自动进主对话。若你的工具列表里没有 SendMessage，先调 `ToolSearch` 查询 `select:SendMessage` 把它加载进来，再用它回传。

**对比**：同步派发（run_in_background:false / 普通 Agent）不需要这条——final text 即 tool result。通道补丁只对异步 background teammate 生效。

## 活性判定与等待纪律（己方端，与铁律④同族）

铁律④管"信息完不完整"，本纪律管"等待模型对不对、存活判定站不站得住"。两者同属己方端决策纪律：都拒绝凭不可靠信号抢跑不可逆动作。

**机制对齐**：background agent / teammate 的完成与进展是**事件驱动、经 mailbox 异步回传、下一个 turn 才可见**，不是同步 tool result。用文件轮询（Bash sleep + git diff/grep 看文件变没变）去等这个事件驱动机制，时序错位——会把"本 turn 没收到消息 + 文件暂未变"误读成卡死。

**判死无效证据清单**（以下单独或组合都**不能**当"agent 死了"的证据）：
- **文件暂时没变**：agent 可能在读文件、在思考、在两个 tool call 之间。
- **`ps` 查不到某些 CLI 后端进程**：in_process teammate 是进程内 agent，不一定表现为独立 OS 进程，尤其思考或 tool call 间隙。拿这个当"没在干活"是误读。
- **sleep 期间没收到消息**：完成 / 进展通知进的是 mailbox，主 agent 只在下一个 turn 才看得到；sleep 盲等期间必然"没消息"，这是机制常态，不是死亡信号。

**正确等待手段**：
- 需要结果才能往下走 → 用同步派发（解法优先级 #1），别 spawn 后轮询。
- 必须异步 → 依赖完成通知 / mailbox 事件被下一 turn 唤醒，**不要中途凭文件状态抢跑 TaskStop**。
- **派完就结束本轮**，把主循环交还空闲态等唤起。别用 `sleep` 占着主循环——除了浪费墙上时间，它还会让通知走进下节那条会被吃掉的路径。

**上游官方立场（2.1.220 二进制内 Agent 工具描述原文，非社区转述）**：

> Agents run in the background by default. When an agent runs in the background, you will be automatically notified when it completes — do NOT sleep, poll, or proactively check on its progress. Continue with other work or respond to the user instead.

Bash 工具描述同版原文：

> Foreground `sleep` is blocked; use Monitor with an until-loop to wait on a condition.

拦截文案另写明 `Do not chain shorter sleeps to work around this block.`。即"sleep 等 subagent"本就是上游明令禁止的用法，本纪律与其同向，不是本地独创。

注：该拦截并非在所有环境都实际生效（本地 2.1.220 实测 `sleep 3` 仍放行），所以它拦不住你，**纪律仍须自觉遵守**。

**TaskStop 是不可逆动作**：套铁律④同源标准——不凭推断的卡死判断拍板。真正的死有客观兜底（框架 watchdog 对无进展达阈值判失败），不靠主 agent 用文件轮询猜。

**不确定性诚实**：不能 100% 排除某次真有网络 / CLI 挂起（部分后端延迟方差大，实测 26s ~ >120s）。但存疑时**倾向再等一个完成信号 / 一个 turn**，判死门槛设高——宁可多等一 turn，不可错杀一个正在干活的 agent。本纪律的经验来源：被判死并 TaskStop 的三个 agent 事后全部复活并交出完整产物。

## 完成通知会被"中途折叠"吃掉（机制级，解释为什么优先级 #1 是同步）

这是"能同步就同步"的**机制层理由**，也是上节"派完就结束本轮"的根据。本地 2.1.220 实测 + 二进制代码互证。

**机制**：完成通知先入命令队列，消费分两条路——

| 主循环状态 | 队列动作 | 结果 |
|---|---|---|
| 空闲 | `dequeue` | 落成真正的 `user` 消息，模型必定看见 |
| 正在跑工具（mid-turn） | **`remove`** | 只落一条 `attachment/queued_command`，`origin` 兜底为 `{kind:"task-notification"}` 并打 `isMeta:true`，随后从队列移除 |

二进制里这段是 query 主循环在每批工具结果后做的 mid-turn fold：`registerFoldInFlight(dn)` → 渲染 attachment → `messageQueue.remove(Jr)`。

**实测数据**（本地 383 个 session 全量扫描，仅统计 subagent 通知）：

| 通知到达时主循环 | 送达 | 丢失 | 丢失率 |
|---|---|---|---|
| 有工具在飞 | 11 | 139 | **92.7%** |
| 空闲 | 690 | 91 | 11.7% |

按通知正文哈希精确配对 `remove` 事件（不靠代理指标）：内容出现在 `remove` 里的 430 例丢失率 **95.3%**，未出现的 1124 例 23.4%。

**在飞工具排名**：`TaskOutput` 80、`Bash` 35（其中 `sleep` 26）、`AskUserQuestion` 18、`Agent` 5。

**按后果分类**（关键区分，别一刀切）：
- **良性**：`TaskOutput` 那 80 例中 75 例是在轮询它自己等的那个 task，其中 70 例产物经 tool_result 正常回来了——通知被吃但产物没丢。
- **有害**：`Bash`(35，sleep 占 26)、`AskUserQuestion`(18)、`TaskOutput` 轮询别的 task(5)、`Agent`(5)、`TaskStop`(1)。这些丢了就是净丢失。

**没有恢复通道**：`remove` 是终态。实测 28 例"丢失后用 `SendMessage` 续跑该 agent"，那条通知仍未送达（SendMessage 开的是新一轮，不补发旧通知）。兜底只能读 transcript（见下节）。

**推论（这才是纪律的根据）**：
1. 同步派发（`run_in_background:false`）的产物走 tool_result，**根本不进这个队列**——没有通知，就没有丢通知。这是从根上消除问题，不是打补丁。
2. `AskUserQuestion` 期间到达的通知会丢（18 例全丢）。派完后台 agent 后**不要紧接着抛问题给用户等答复**。
3. 别用 `TaskOutput` 取产物：官方文档已标其弃用（替代方案是 `Read` 任务输出文件路径），且上游有未修 bug——对 local_agent 调 `TaskOutput(block=true)` 会把整个 JSONL transcript 灌进上下文。

**未验证边界（诚实标注）**：折叠出的 `isMeta:true` attachment 究竟是完全不进 API 请求，还是进了但被模型当背景噪声忽略——未能区分，需抓主循环真实请求体才能定。对上述纪律无影响（后果一样：模型不知情），但对上游是两个不同修法。

## 别把"没收到通知"当成"agent 零产出"

上一节的直接推论，独立成节因为它是**汇报正确性**问题，不只是效率问题。

通知丢失时，主 agent 的上下文里确实没有产物——于是容易得出"这几路等于零产出"并据此向用户汇报。这是**基于错误前提的正向汇报**，比空等更糟：用户若不追问就会接受这个错误结论。已知踩过两次。

**汇报前自查**（不读 `.output`，避免撑爆上下文）：

```bash
# 末条 assistant 文本即该 subagent 的最终产物
python3 - <<'PY'
import json,sys
p="<项目>/<session-id>/subagents/agent-<agentId>.jsonl"   # ~/.claude/projects/ 下
last=None
for line in open(p):
    try: d=json.loads(line)
    except: continue
    if d.get("type")!="assistant": continue
    c=(d.get("message") or {}).get("content") or []
    t="".join(b.get("text","") for b in c if isinstance(b,dict) and b.get("type")=="text")
    if t.strip(): last=t
print(last[:2000] if last else "(no assistant text)")
PY
```

要求「渐进产出」的 subagent 会分多段输出，末段可能只是报告尾部——需要全文时拼接全部 assistant 段落，别只取末段。

**该措施的代价**：产物未经框架侧收尾校验，且绕过了工具描述"不要读 `.output`"的契约（这里只提末条 text、不 `Read` 整个文件，属可控折中）。**不应固化为常规取产物手段**——常规路径是同步派发。

## 二进制实证（deferred 机制，标确定性）

以下从本地测试环境 claude-code 二进制（native 打包）裸字节 grep 挖出，是实现代码而非社区转述，作"为什么配置关不掉内置工具"的佐证。社区（部分后端搜索）曾回传若干 issue 号 / URL，因无法验证、按铁律④丢弃，只采信下列一手证据。

**`ENABLE_TOOL_SEARCH` 环境变量真实存在**，取值语义：
- `true` / `false`：强制开 / 关 tool search
- `auto` / `auto:N`：按阈值自动触发，N 为 0-100 百分比（`Math.max(0,Math.min(100,r))` 夹取；非法值报 `expected auto:N where N is a number`）
- 内部映射：`=0 → 全 search 模式`，`=100 → standard（预载不 defer）`

**工具是否 defer 的判定函数**（minified 原型，去混淆后）：
```js
function shouldDefer(e){
  if(e.alwaysLoad===true) return false;    // alwaysLoad → 永不 defer
  if(builtinAllowlist.includes(e.name)) return false; // 内置白名单 → 永不 defer
  if(e.isMcp===true) return true;          // MCP 工具 → 默认 defer
  // ... 若干 e.name===X 内置工具硬豁免分支（含 fork subagent 条件）
}
```

**`alwaysLoad` 是 MCP server 级配置项**（schema：`alwaysLoad: boolean, "When true, all tools from this server are always [loaded]"`），经 `--mcp-config` 生效——**只作用于 MCP 工具**。

**结论（推断，高置信）**：`alwaysLoad` 与大部分 ENABLE_TOOL_SEARCH 逻辑针对 MCP 工具（`isMcp===true`）。SendMessage / TaskStop 是内置 team 工具（非 MCP），走内置白名单与 `e.name===X` 硬分支——**用户侧无法用 alwaysLoad 单独让它不 defer**。`ENABLE_TOOL_SEARCH=false`（或 `=100`）理论上让所有工具预载（可能含 team 工具），但那是 session 级环境变量、有 context 占用代价、且 subagent 继承性未在本地测试环境验证——**不如 prompt 显式先 ToolSearch 精确、无副作用**。故首选行为纪律，非配置开关。
