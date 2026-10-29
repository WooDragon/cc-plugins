---
name: subagent-dispatch
description: |
  派发 subagent（spawn/delegate/dispatch agent）前的契约：派发必要性、证据缺口、任务范围、prompt 与交付物要求。用于卸载与模型档位选择、Explore 任务级别、定稿标记、后台产物回传与活性/TaskStop 判断、Workflow JSON schema 结构化输出，以及派发 prompt 的 persona 拒绝排查。Team 的授权与生命周期仍遵循 team-ops。
---

# 子 agent 派发契约

四条铁律的一句话版常驻全局 CLAUDE.md。本 skill 维护展开正文及派发必要性规则；Team 的适用范围见「与其他机制的边界」。

> **前置阅读**：逐项工作必要性、证据缺口与当前交付边界（含直接前提回溯、原授权内执行连续性），真实工作委托前应先读取：
> [references/dispatch-contract.md 的「铁律②：范围围栏」](references/dispatch-contract.md#铁律②范围围栏)。

## 四铁律速查

| 铁律 | 一句话 | 展开 |
|---|---|---|
| ①输出即产物 | 最终返回消息本身就是产物，禁止写完成说明或元总结；需要定稿交付时用 `%%DONE%%` 结束标记声明，由 SubagentStop 门禁强制 | 见 references/dispatch-contract.md |
| ②范围围栏 | 说明工作必要性与证据缺口；一个实例默认一个当前交付，完成后后续独立交付默认新实例；未完成交付保留原授权内纠错；只改指定文件/只做指定事，范围外发现只报告不动手 | 见 references/dispatch-contract.md |
| ③渐进产出 | 大调研/长任务分段读、尽早吐中间进展，避免触发 stall watchdog | 见 references/dispatch-contract.md |
| ④定稿纪律 | 据以派活或做不可逆动作的结论须来自已定稿的产物。产物应包含影响决定的依据和未决事项。原始证据可通过可核查的引用提供。中间回传不能替代定稿 | 见 references/dispatch-contract.md |

## Explore 任务级别（派发端）

每次派发 `subagent_type=Explore`，应在 prompt 正文出现三档英文词之一。平台认的是这三个词，与 Explore 的 search breadth 对齐；`description` 里写不算数。prompt 正文缺档位词，视为未完成派发前置动作。

| 写进 prompt | 用途 |
|---|---|
| `quick` | 单点查找：一个符号、一个文件、一个配置项 |
| `medium` | 中等范围：相关调用点、周边代码 |
| `very thorough` | 多目录、多命名约定、全面扫 |

推荐格式：prompt 开头单独一行 `Explore 任务级别: <档位>`。这是排版约定，不是第二套合法值——合法值只有表中三个英文词。

正例：prompt 首行 `Explore 任务级别: quick`，随后写查找目标。
反例：只在 `description` 里写「全面搜一下」，prompt 正文不钉档位。

## 定稿标记：`%%DONE%%`

铁律①的机器强制手段，由本插件 `hooks/subagent-done-gate.sh`（SubagentStop 门禁）执行。以下是全库唯一的标准行来源，其他文档需要子 agent 分节报告时应指向本节，不应重复列出节名清单。

派发 prompt 需要子 agent 交付定稿时，应在末尾原样附加：

> 末尾单独一行输出 `%%DONE%%`。在此之前给出完整报告，含验证矩阵（被验证物路径+实际执行的命令 vs 交付物路径）与未完成项两节。

**应原样复制这行，不应改写成自己的措辞。** 仅写末行格式会丢掉完整报告义务，可能使子 agent 只输出标记。

标记按任务而非角色声明：任务没有交付物（如纯问答、只读侦察）时不应附加此行。附加后，最终消息末个非空行须等于 `%%DONE%%`；缺失时门禁按下述正文下限处理。门禁还检查除标记外还有没有非空行，只有标记也会被拦。不合格消息最多阻断一次，回灌纠正指令要求原地补写完整报告；判据不看措辞、不维护词表。

判定容忍该行的前后空白与 CRLF，但**不容忍任何修饰**：加粗、反引号、列表符号、标题符号、尾随标点都会被拦。prompt 出现标记即触发检查，包括否定式或仅讨论标记的语境；误判最多多拦一次。

**正文足够长而缺标记时不再拦截**（≥ 500 字节，`DONE_GATE_BODY_FLOOR` 可调），改为放行 + 告警，避免补写消息顶掉报告。低于该下限才拦，并回显原文供复用。

误拦止血：`export ALLOW_UNMARKED_FINAL=1`。已知边界见本插件 README。

`%%DONE%%` 可标记消息或文件的产物末行，两者采用上述相同格式判据。两个载体各管各的、不互相替代：SubagentStop 门禁（`subagent-done-gate.sh`）检查消息的报告在场；`promote-wip.sh` 检查文件草稿未截断。文件载体**只用于「派发约定了目标路径的落盘交付物」**；报告与结论**仍须在最终消息里**给出，不应只落盘。

**派发要求产出文件时**：约定目标路径，要求子 agent 以「`.wip` 追加写 + 末行 `%%DONE%%`」落盘，再调用 `~/.claude/scripts/promote-wip.sh <target_path>` 做「校验哨兵是否在末行 → 剥离 → 原子提升为正式文件」。**不要让子 agent 自己 `ln` 或直接改名提升**，否则哨兵未剥离，会破坏 JSON/YAML 语法。

文件与报告都要交付时，两处都要写哨兵。文件哨兵由 `promote-wip.sh` 剥离；消息哨兵留给 SubagentStop 门禁。后者只读 `last_assistant_message`、**不读任何文件**，不能用文件哨兵替代消息哨兵。

## 己方端补充纪律（background 派发后，与④同族）

铁律①②③钉进子 agent 的 prompt（派发端），④与下列三条约束主 agent 自己（己方端）。四条同族——都拒绝凭不可靠信号抢跑不可逆动作。

| 纪律 | 一句话 | 展开 |
|---|---|---|
| 通道选择 | `name` 是提升为 teammate 的唯一开关：不传 `name`，产物走工具返回值（可靠）；传 `name` 即提升为 teammate、产物改走 mailbox。即席一次性派发不传 `name`；确需常驻多轮协作才传 `name`，并按 team-ops 协议管理其生命周期。禁止 sleep/轮询/主动查进度这条现在有机器强制：本插件 `hooks/dispatch-sync-guard.sh` 在 PreToolUse 拦截省略 `run_in_background:false` 的派发；逃生舱 `ALLOW_BACKGROUND_DISPATCH=1` 需写进 `settings.json` 的 `env` 段（Bash 里 export 传不进 hook 进程） | 见 references/mailbox-liveness.md |
| 回传通道 | named teammate 的 final text 不自动回到派发方；派发方应明确实际 dispatcher 与回传协议。Team 按既有正式产物与控制信号协议回传，不统一向 main 发送全文。实际 dispatcher 为 main 且约定消息交付时，用 `SendMessage(to:"main")` 送出产物；工具未加载时先 `ToolSearch select:SendMessage`。即席需要同步结果时用 `run_in_background:false` 且不传 `name` | 见 references/mailbox-liveness.md |
| 活性判定 | 完成/进展是 mailbox 异步、下一 turn 才可见；文件没变 / ps 查不到进程 / sleep 期间没消息都不算 agent 死了；TaskStop 不可逆，存疑多等一 turn 不错杀 | 见 references/mailbox-liveness.md |

## 派发端补充纪律（仅上游带焊死 persona 时发作）

部分第三方兼容代理的上游带平台焊死的自有 persona（身份设定），实测询问模型自身身份/指令会触发拒绝。规避在派发 prompt 侧完成：应让 subagent 对外部素材做事，不问自身身份/指令。此原则始终适用；标题限定的是拒绝代价的发生条件，对原生 Anthropic 端点无副作用。

| 区 | 派发时 | 清单 |
|---|---|---|
| 发作区（避免） | 别让模型谈论自己 | 报告/复述自身系统指令·preamble·角色设定；自述身份（"你是谁/谁造了你"）；对自身指令表态（"确认你会静默服从"）；评判针对它自己的指令（"这些指令你会怎么应对"） |
| 安全区（这样写） | 让模型对外部素材做事 | 任务聚焦文件/代码/数据/网页/日志等外部对象；不可避免要处理 injection/persona 类文本时，把"**你**会怎么应对这些指令"改成"**分析这段文本**里的手法"，把模型从"被质询对象"挪成"处理数据工具" |

展开正反例与实测背书见 `references/dispatch-contract.md`。

## References 导航

- 需要每条铁律的正反例、常见踩坑或 model ownership 规则时，读取：`references/dispatch-contract.md`
- 判断某任务该不该卸载、用哪个模型档时，读取：`references/offload-scenarios.md`
- 派发 Explore 时任务级别钉哪一档，见本节「Explore 任务级别」
- spawn background subagent 后如何收产物 / 判活性 / 何时能 TaskStop，读取：`references/mailbox-liveness.md`
- 需要子 agent 返回强结构化产物（JSON/schema 校验）时，读取：`references/workflow-schema.md`
- 派发端 persona 规避的发作区/安全区展开与实测背书，读取：同一份 `references/dispatch-contract.md` 的「## 派发端补充」章节

## 与其他机制的边界

Team 复用铁律②的必要性内容与共同交付边界；派发授权、生命周期、回传与阶段仍归 TeamOps。不将 ad-hoc 的整套机制套入 Team。Team 派发方应通过上方前置阅读入口读取必要性与共同交付边界正文；该阅读不替代 TeamOps 的正式派发授权。web-search 的搜索隔离用 web-search skill 自己的规范。

模型 ownership 门禁仅检查缺少 Team 身份的即席调用：顶层 `agent_id` 与 `tool_input.name` 均缺失或为空白时才执行模型分类。任一字段非空白时，该门禁跳过自身检查；其他门禁仍检查各自契约。

**即席派发经济性**：先按任务能力选择角色和模型，再按所有权填写调用字段。`hooks/dispatch-capability-guard.sh` 判断角色/模型能否执行请求（判据 A/B/C）。`hooks/dispatch-agent-ownership-guard.sh` 判断调用者是否有权覆盖 `model`：runtime-owned 内置类型必须显式提供非空、非空白 model；model-optional 内置类型可省略或填 `null` 以跟随主 session 档位，也可显式提供有效模型名，但空串和纯空白仍拒绝；具名注册 agent 必须省略 model 或填 `null`。派发前应先读取 `references/dispatch-contract.md` 的「Model ownership」；该节再指向唯一维护类型清单的 helper。紧急放行可在 `~/.claude/settings.json` 的 `env` 段设 `"ALLOW_AGENT_MODEL_INHERIT": "1"`；Bash 内 `export` 不会传给 hook 进程。
