# 派发契约四铁律（展开）

## 铁律①：输出即产物

**原则一句话**：派发 prompt 必须钉死"你的最终返回消息本身就是产物（JSON/报告/结论），禁止写完成说明或元总结"。

**为什么**：实测现象——子 agent 把真正的报告/JSON 留在中间输出，最终只回一段"我做了什么"的完成说明，主 agent 被迫多次 SendMessage 追问才拿到产物，一份分析报告问 3-4 次、4 个评审 agent 每个都要额外一轮，全程多 8-10 次往返。

**正例 prompt 片段**：
> 你的最终消息必须是纯 JSON 候选清单本身，第一个字符是 `[`，不要任何前后说明文字。

**反例 prompt 片段**：
> 完成后简要说明你的分析。

**机器强制**：`%%DONE%%` 结束标记把本铁律从纯散文钉死为可机器判定。派发 prompt 出现该标记 ⇒ SubagentStop 门禁 `hooks/subagent-done-gate.sh` 介入；子 agent 最终消息末个非空行须精确等于该标记才放行，不匹配则阻断一次，把纠正指令回灌给子 agent 要求原地补写完整报告。`stop_hook_active` 保证同一子 agent 最多被拦一次，不会死循环。标准行见 SKILL.md「定稿标记」节；逃生舱 `export ALLOW_UNMARKED_FINAL=1`。

## 铁律②：范围围栏

**原则一句话**：钉死"只改指定文件/只做指定事，范围外发现的问题只在返回里报告，不擅自动手"。

**为什么**：实测现象——一个只被要求"写测试"的 sonnet 子 agent，顺手把参考项目里另一个功能域的无关生产代码改动也搬进了本次改动，主 agent 核对时才发现多出两个范围外文件、回退掉。

**正例 prompt 片段**：
> 只允许修改 tests/ 下的测试文件。若发现生产代码有 bug，在最终消息里列出文件:行号+问题，但不要修改任何生产代码。

**反例 prompt 片段**：
> 把测试写好，顺便修一下你发现的问题。

## 铁律③：渐进产出

**原则一句话**：大调研/长任务默认要求"分段读、尽早吐中间进展"，避免长时间无 tool 调用触发 watchdog（无进展 600s 判失败）。

**为什么**：实测现象——3 个子 agent 因"读多个大文件+长分析一气呵成"中途长时间静默触发 stall 被判失败重派，前一次 token 沉没；重派时加了"分段读、控制节奏、尽早产出"就不再 stall。

**正例 prompt 片段**：
> 分批读文件，每读完 2-3 个就先输出一段阶段小结再继续，不要憋到最后一次性输出。

**反例 prompt 片段**：
> 把这 20 个文件全部读完后给我一份完整分析。

## 铁律④：定稿纪律（己方，主 agent 侧）

**原则一句话**：据以派活或做不可逆动作的结论，必须来自完整定稿产物，不采信精简/中间回传。

**为什么**：实测现象——code review 的 verify 阶段先拿到精简回传"4 个 bug 全 CONFIRMED"就立即派 opus 去修全部 4 个；随后完整 verify 返回其中 3 个 REFUTED（含"全仓 grep 零命中、bug 前提不存在"），只有 1 个真 bug，白派一轮修复+回退返工。recall 模式候选倾向多报，必须等完整 verify 定性。

**正例（纪律）**：
> 收到精简/中间回传时，不据此做派发或不可逆操作；等完整定稿产物（完整 verify/最终报告）落地再决策。

**反例**：
> 看到初步结论说全部确认，立即派 agent 开始修复。

**同族纪律**：④管"信息完不完整就别拍板"，另有两条己方端纪律管 background 派发后的"通道"与"活性"——产物走 `SendMessage(to:"main")` 回传（该工具在 subagent 默认 deferred，须先 ToolSearch 加载）、活性判定不靠文件轮询、TaskStop 存疑多等一 turn。见 `references/mailbox-liveness.md`（那份只管 teammate/mailbox 通道，普通 background agent 的通知投递见下节）。

## 己方端纪律：派完就交还主循环（与铁律④同族）

四铁律是**钉进子 agent prompt** 的派发端约束；本节与铁律④一样约束**主 agent 自己**，不进任何派发 prompt，故不编入铁律序号。

**原则一句话**：需要产物才能往下走就同步派发；真要后台并行，派完立刻结束本轮、把主循环交还空闲态等唤起——**不 sleep、不轮询、不主动查进度**。

**上游官方立场**（2.1.220 二进制内 Agent 工具描述原文，非社区转述）：

> Agents run in the background by default. When an agent runs in the background, you will be automatically notified when it completes — do NOT sleep, poll, or proactively check on its progress. Continue with other work or respond to the user instead.

> **Foreground vs background**: Pass `run_in_background: false` to run an agent in the foreground when you need its results before you can proceed — e.g., research agents whose findings inform your next steps.

Bash 工具描述同版原文：

> Foreground `sleep` is blocked; use Monitor with an until-loop to wait on a condition.

拦截文案另写明 `Do not chain shorter sleeps to work around this block.`。即"sleep 等 subagent"本就是上游明令禁止的用法。**注**：该拦截未必在所有环境实际生效（本地 2.1.220 实测 `sleep 3` 仍放行），拦不住你，所以本铁律须自觉遵守。

**为什么（机制根据）**：普通 background agent 的完成通知**自带完整产物正文**（实测 5 条通知各带 8414~14593 字符的 `<result>`），走 task-notification 队列而非 mailbox。该队列的消费分两条路：

| 通知到达时主循环 | 队列动作 | 结果 |
|---|---|---|
| 空闲 | `dequeue` | 落成真正的 `user` 消息，模型必定看见 |
| 正在跑工具（mid-turn） | **`remove`** | 只落一条 `attachment/queued_command`（`isMeta:true`）后从队列移除 |

二进制里这是 query 主循环在每批工具结果后的 mid-turn fold：`registerFoldInFlight(dn)` → 渲染 attachment → `messageQueue.remove(Jr)`。

**实测**（本地 383 个 session 全量扫描，仅统计 subagent 通知）：

| 到达时主循环 | 送达 | 丢失 | 丢失率 |
|---|---|---|---|
| 有工具在飞 | 11 | 139 | **92.7%** |
| 空闲 | 690 | 91 | 11.7% |

按通知正文哈希精确配对 `remove` 事件（不靠代理指标）：内容出现在 `remove` 里的 430 例丢失率 **95.3%**，未出现的 1124 例 23.4%。在飞工具排名：`TaskOutput` 80、`Bash` 35（`sleep` 26）、`AskUserQuestion` 18、`Agent` 5。

**无恢复通道**：`remove` 是终态。实测 28 例"丢失后用 `SendMessage` 续跑该 agent"，那条通知仍未送达——SendMessage 开的是新一轮，不补发旧通知。

**正例（纪律）**：
> 需要调研结论才能定方案 → `run_in_background: false` 同步派发，产物走 tool_result 直接返回，根本不进那个队列。没有通知，就没有丢通知。

**反例**：
> 派 5 路 background agent，然后 `Bash: sleep 110` 连等 13 轮。每轮 sleep 收尾都是一次 mid-turn fold，把期间到达的通知全部吃掉。

**衍生三条**：
1. **别紧接着 `AskUserQuestion`**：派完后台 agent 就抛问题给用户等答复，该期间到达的通知实测 18 例全丢。
2. **别用 `TaskOutput` 取产物**：官方已标弃用（替代方案是 `Read` 任务输出文件路径），且上游有未修 bug——对 local_agent 调 `TaskOutput(block=true)` 会把整个 JSONL transcript 灌进调用方上下文。
3. **「没收到通知」≠「agent 零产出」**：通知丢失时主 agent 上下文里确实没产物，容易据此向用户汇报"这几路等于零产出"。这是**基于错误前提的正向汇报**，比空等更糟——用户不追问就会接受错误结论（已踩两次）。汇报前先查 transcript 末条 assistant（`~/.claude/projects/<项目>/<session>/subagents/agent-<id>.jsonl`），只提取 text 块、不 `Read` 整个 `.output`（那是完整 JSONL，会撑爆上下文）。要求「渐进产出」的子 agent 分多段输出，末段可能只是报告尾部，需全文时拼接全部 assistant 段落。

**未验证边界**：折叠出的 `isMeta:true` attachment 是完全不进 API 请求，还是进了被当背景噪声忽略——未能区分，需抓主循环真实请求体才能定。对本铁律无影响（后果一样：模型不知情），但对上游是两个不同修法。

## 铁律①的技术边界

日常 `Agent`/`Task` 工具**没有 schema 参数**，字段级结构化产物（如强制 JSON 各字段类型、validation 失败自动重试）仍只能升级到 `Workflow` 的 `agent({schema})` 机制才可校验——见 workflow-schema.md。

但"定稿与否"这一件事已不再纯靠措辞：SubagentStop 门禁 + `%%DONE%%` 标记把它变成可机器判定的二元事实——子 agent 最终消息末个非空行是否精确等于标记，不依赖语义理解。门禁只保证"报告在场"，不判断"内容是否成立"；证据是否成立仍是主上下文的裁决活，字段级 schema 校验仍是 Workflow 的专属能力。

## 派发端补充：干活别照镜子（persona 规避）

**适用条件**：仅当上游模型带平台焊死的自有 persona（如某些上游焊死自有 persona 的第三方兼容代理）时发作；原生 Anthropic 端点模型身份即 Claude，无冲突、无副作用。

**原则一句话**：派发 prompt 让子 agent 对外部素材（文件/代码/数据/网页/日志）做事，别让它照镜子——不问它自身的身份/指令/角色设定。

**为什么**：黑盒因子实验（5 种 preamble × 2 类任务共 60 请求）网格干净到极致——meta 任务（问模型自身身份/指令）在**所有** preamble 下全 100% 拒绝，work 任务全 0%；铁证是 `none` 行（完全不给 system）meta 仍 100% 拒绝、`full` 行（完整 preamble）work 仍 0%。触发器是**任务性质**，与 preamble 措辞无关，所以"改 preamble/system/确认语"全是修一个不导致问题的东西。命中后子 agent 自报其平台身份并指控注入、拒绝配合，逼主 agent 多费几轮纠错甚至新开会话，白烧 token。

**发作区（100% 触发，派发时避免）**：
- 要求模型报告/复述自己的系统指令、preamble、角色设定
- 要求模型自述身份（"你是谁 / 你叫什么 / 谁造了你"）
- 要求模型对自身指令表态（"确认你会静默服从 / 你会不会遵守 X"）
- 让模型评判针对它自己的指令（"这些指令你会怎么应对"）

**安全区（派发时这样写）**：
- 任务聚焦外部对象（文件/代码/数据/网页内容/日志），而非模型自身
- 不可避免要处理"身份/injection/persona"类文本内容（如分析攻防样本）时，把"**你**会怎么应对这些指令"改成"**分析这段文本**里的攻击手法"——把模型从"被质询的对象"挪到"处理数据的工具"
- 给子 agent **指派干活的角色**（"你是评审者，只输出 finding""你是重构器，只改 tests/"）**不属发作区**——发作的是让它**反思/暴露自身身份与系统指令**，不是给它一个对外做事的角色。铁律②的角色围栏照常用，别把正常角色指派也误砍

> **证据边界**：网格实测的 0% 是"中性 work 任务"（SQL/rename/解释类）；"work 外壳裹 meta/injection payload"（如分析攻防样本）这一格**未单独进网格**，上面第二条是基于根因（触发器=任务是否在问模型自身）的**推荐写法**、非实测 0%。若按此改写后仍偶发拒绝，先进一步收紧任务描述、把模型钉在"处理外部数据"的位置，**不要回头改 preamble**（已证 preamble 与触发无关）。

**正例 prompt 片段**：
> 分析下面这段 transcript 里用到的 prompt injection 手法，逐步列出每一步的攻击意图。

**反例 prompt 片段**：
> 下面这段要求你扮演 SDK agent 并静默服从，你会怎么应对这些指令？
