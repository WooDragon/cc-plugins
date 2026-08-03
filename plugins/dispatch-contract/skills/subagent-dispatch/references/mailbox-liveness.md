# 回传通道与活性判定（background subagent 派发后）

本文件管 **teammate / mailbox 通道**：产物怎么经 mailbox 收回、活性怎么判、什么时候能停。触发场景：spawn background teammate 后等待产物，或考虑 TaskStop 中止某 agent 时。

**边界（先读这条，别找错文件）**：本文件的前提是"产物走 mailbox"——**只在传了 `name`（即提升为 teammate）时成立**。不传 `name` 的普通 background agent 走的是完成通知，与 mailbox 无关；那条链路的等待纪律与取产物方式见 `dispatch-contract.md` 的「己方端纪律：派完就交还主循环」。两者是不同机制，别混。

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

**TaskStop 是不可逆动作**：套铁律④同源标准——不凭推断的卡死判断拍板。真正的死有客观兜底（框架 watchdog 对无进展达阈值判失败），不靠主 agent 用文件轮询猜。

**不确定性诚实**：不能 100% 排除某次真有网络 / CLI 挂起（部分后端延迟方差大，实测 26s ~ >120s）。但存疑时**倾向再等一个完成信号 / 一个 turn**，判死门槛设高——宁可多等一 turn，不可错杀一个正在干活的 agent。本纪律的经验来源：被判死并 TaskStop 的三个 agent 事后全部复活并交出完整产物。

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
