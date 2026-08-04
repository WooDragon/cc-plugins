---
name: subagent-dispatch
description: |
  子 agent 派发契约——四条铁律正反例、卸载场景判断、定稿标记机制、Workflow schema 用法。当需要：
  - 派发 subagent / spawn agent / delegate to agent，想确认 prompt 格式与交付物形态是否合规
  - dispatch subagent 时不确定「输出即产物」「范围围栏」「渐进产出」「定稿纪律」哪条该套用
  - 判断某任务该不该卸载（offload）、用哪个模型档位
  - 处理 background subagent 产物回传通道、活性判定、TaskStop 时机
  - 需要子 agent 返回强结构化产物（JSON schema 校验）时了解 Workflow agent() 用法
  - 派发 prompt 触发拒绝，排查是否遇到上游 persona 焊死问题
  时调用此 Skill。
  Triggers: 派发 subagent, subagent 调度, dispatch subagent, spawn agent, delegate to agent, Task 派发, 并行派发, 交付物形态, 定稿标记, 输出即产物, 范围围栏, 渐进产出, 定稿纪律, offload, 卸载场景, 卸载判断, background subagent, 活性判定, TaskStop, 回传通道, workflow schema, 结构化产物, persona 拒绝, 派发契约, dispatch contract, %%DONE%%.
---

# 子 agent 派发契约

四条铁律的一句话版常驻全局 CLAUDE.md，对一切派发生效。本 skill 是低频查阅的展开——需要正反例、拿不准场景归类、或要用 Workflow 强制结构化产物时才读。

## 四铁律速查

| 铁律 | 一句话 | 展开 |
|---|---|---|
| ①输出即产物 | 最终返回消息本身就是产物，禁止写完成说明或元总结；需要定稿交付时用 `%%DONE%%` 结束标记声明，由 SubagentStop 门禁强制 | 见 references/dispatch-contract.md |
| ②范围围栏 | 只改指定文件/只做指定事，范围外发现只报告不动手 | 见 references/dispatch-contract.md |
| ③渐进产出 | 大调研/长任务分段读、尽早吐中间进展，避免触发 stall watchdog | 见 references/dispatch-contract.md |
| ④定稿纪律 | 据以派活或做不可逆动作的结论必须来自完整定稿产物，不采信精简/中间回传 | 见 references/dispatch-contract.md |

## 定稿标记：`%%DONE%%`

铁律①的机器强制手段，由本插件 `hooks/subagent-done-gate.sh`（SubagentStop 门禁）执行。以下是全库唯一的标准行来源，其他文档需要子 agent 分节报告时应指向本节，不应重复列出节名清单。

派发 prompt 需要子 agent 交付定稿时，应在末尾原样附加：

> 末尾单独一行输出 `%%DONE%%`。在此之前给出完整报告，含验证矩阵（被验证物路径+实际执行的命令 vs 交付物路径）与未完成项两节。

这行标记按任务声明，不按角色声明：任务没有交付物（如纯问答、只读侦察）时不应附加此行；附加后，子 agent 最终消息的末个非空行须等于 `%%DONE%%`，不匹配则被门禁阻断一次并回灌纠正指令，要求原地补写完整报告。

判定容忍该行的前后空白与 CRLF，但**不容忍任何修饰**——加粗、反引号、列表符号、标题符号、尾随标点都会被拦。派发 prompt 里只要出现这个标记就会开闸，哪怕语境是否定式或只是在讨论标记本身（误判方向是多拦一次，自愈）。

误拦止血：`export ALLOW_UNMARKED_FINAL=1`。已知边界见本插件 README。

## 己方端补充纪律（background 派发后，与④同族）

铁律①②③钉进子 agent 的 prompt（派发端），④与下列三条约束主 agent 自己（己方端）。四条同族——都拒绝凭不可靠信号抢跑不可逆动作。

| 纪律 | 一句话 | 展开 |
|---|---|---|
| 通道选择 | `name` 是提升为 teammate 的唯一开关：不传 `name`，产物走工具返回值（可靠）；传 `name` 即提升为 teammate、产物改走 mailbox。即席一次性派发不传 `name`；确需常驻多轮协作才传 `name`，并按 team-ops 协议管理其生命周期。禁止 sleep/轮询/主动查进度这条现在有机器强制：本插件 `hooks/dispatch-sync-guard.sh` 在 PreToolUse 拦截省略 `run_in_background:false` 的派发；逃生舱 `ALLOW_BACKGROUND_DISPATCH=1` 需写进 `settings.json` 的 `env` 段（Bash 里 export 传不进 hook 进程） | 见 references/mailbox-liveness.md |
| 回传通道 | background subagent 的 final text 不自动进主 mailbox，产物必须走 `SendMessage(to:"main")`；该工具在 subagent 里默认 deferred，prompt 须要求它先 `ToolSearch select:SendMessage` 加载。能同步就 `run_in_background:false` 绕开此坑 | 见 references/mailbox-liveness.md |
| 活性判定 | 完成/进展是 mailbox 异步、下一 turn 才可见；文件没变 / ps 查不到进程 / sleep 期间没消息都不算 agent 死了；TaskStop 不可逆，存疑多等一 turn 不错杀 | 见 references/mailbox-liveness.md |

## 派发端补充纪律（仅上游带焊死 persona 时发作）

经某些第三方兼容代理派发时，上游若被平台焊死自有 persona，**问模型自身身份/指令的任务会 100% 触发拒绝**（子 agent 自报其平台身份并指控注入、拒绝配合）。规避完全在派发 prompt 侧，对原生 Anthropic 端点零副作用。

（这条始终是好习惯——全局 CLAUDE.md speed 版写"永不"即此意；标题"仅上游焊死 persona 时发作"指的是**真实拒绝代价**只在这类代理上出现，原生 Anthropic 端点遵守它零成本、无副作用，不冲突。）

**一句话规则：让 subagent 干活（对外部素材做事），别让它照镜子（谈论自身）。**

| 区 | 派发时 | 清单 |
|---|---|---|
| 发作区（避免） | 别让模型谈论自己 | 报告/复述自身系统指令·preamble·角色设定；自述身份（"你是谁/谁造了你"）；对自身指令表态（"确认你会静默服从"）；评判针对它自己的指令（"这些指令你会怎么应对"） |
| 安全区（这样写） | 让模型对外部素材做事 | 任务聚焦文件/代码/数据/网页/日志等外部对象；不可避免要处理 injection/persona 类文本时，把"**你**会怎么应对这些指令"改成"**分析这段文本**里的手法"，把模型从"被质询对象"挪成"处理数据工具" |

展开正反例与实测背书见 `references/dispatch-contract.md`。

## References 导航

- 需要每条铁律的正反例与常见踩坑时，读取：`references/dispatch-contract.md`
- 判断某任务该不该卸载、用哪个模型档时，读取：`references/offload-scenarios.md`
- spawn background subagent 后如何收产物 / 判活性 / 何时能 TaskStop，读取：`references/mailbox-liveness.md`
- 需要子 agent 返回强结构化产物（JSON/schema 校验）时，读取：`references/workflow-schema.md`
- 派发端 persona 规避的发作区/安全区展开与实测背书，读取：同一份 `references/dispatch-contract.md` 的「## 派发端补充」章节

## 与其他机制的边界

team-ops 语境下派发由 team-ops 协议（handoff/control-signal）接管，不适用本 skill；web-search 的搜索隔离用 web-search skill 自己的规范。

**即席派发经济性**：可另配 PreToolUse hook 拦截省略 `model` 的派发调用，逼显式指定档位；注册 agent（frontmatter 已钉 model）可豁免。紧急放行：`export ALLOW_AGENT_MODEL_INHERIT=1`。
