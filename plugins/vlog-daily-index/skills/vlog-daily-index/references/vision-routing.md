# 纯视觉原生路由

纯视觉逐帧识图走 `model` 路由时，代码白名单为 Luna、Haiku、DeepSeek 三个模型家族；走 `agent` 路由时，合同只记录 agent 类型，实际模型与档位由该 agent 的 frontmatter 决定，不受此白名单约束。日级语义与专门地理继续 `gpt-6.1-sol / high`，ROOT 终审。纯视觉例外优先于通用编排的视觉审查默认。禁止静默改派 Sol/旗舰、隐藏 API 调模型或用宿主名称猜可用模型。

## 两条路由，一个声明来源

视觉派发有两条互斥的路由，由**本次 run 声明的视觉角色**（`config.model_roles.vision`）决定走哪条。代码不按宿主名分支，只认快照内容与这个声明值。

| 路由 | 什么时候走 | 合同产物 | 理由 |
|---|---|---|---|
| `model` | 原生工具**以模型名派发**（Codex 的 `collaboration.spawn_agent`） | `{'model': ..., 'reasoning_effort': ...}` | 模型与档位由本合同逐包控制 |
| `agent` | 原生工具**以 agent 类型派发**（Claude Code 的 `Agent`） | `{'subagent_type': ...}` | agent frontmatter 自己钉死 model/effort，合同不得覆盖 |

判断方式只有一条：**该目标 id 是否属于三个允许模型家族**。是模型 → `model` 路由；等于声明的视觉角色 → `agent` 路由。既不是允许模型、也不是声明角色 → 拒绝。这条规则消除歧义：同一个 id 不可能同时被两条路由接受。

`config.model_roles.vision` 的既有取值不需要改动：Codex 侧仍是历史字面量 `Luna`（由 `vision.ROLE_FAMILIES` 映射到 luna 家族），Claude Code 侧是 `vlog-daily-index:vlog-vision`。不要在 `init` 或迁移里改写这个键。

## 快照

每次主 session 派新包前，根据**当前真实原生工具**的模型枚举、模型级推理支持及子 Agent 图像读取能力，保存本地 `native_vision_capabilities_v1` JSON。来源必须注明当前 session 标识、工具名和可核对的能力证据；不要从旧 run、其他宿主、产品宣传或模型自报补造支持。`parameters` 只填该工具实际可传的参数与取值（允许键：`model`、`reasoning_effort`、`fork_turns`、`subagent_type`）；`models` 按主 session 的声明顺序列出。可选的 `preferred_model` 记录原生工具或会话的默认模型偏好，只在本 run 未声明视觉角色时生效；用户当前的明确选择不写进快照，走显式 `--model`。公开仓库不保存实际会话快照。

### Codex（模型路由）

```json
{
  "schema": "native_vision_capabilities_v1",
  "source": {
    "kind": "current_session_native_tool",
    "session_id": "CURRENT_SESSION_ID",
    "tool": "collaboration.spawn_agent",
    "evidence": "CURRENT_TOOL_MODEL_ENUM_AND_MODEL_EFFORT_SUPPORT; CURRENT_WORKER_IMAGE_READING_CAPABILITY"
  },
  "parameters": {
    "model": ["gpt-6-luna"],
    "reasoning_effort": ["low", "medium", "high", "xhigh", "max"],
    "fork_turns": ["none", "all"]
  },
  "models": [
    {
      "id": "gpt-6-luna",
      "family": "luna",
      "native_model": "gpt-6-luna",
      "image_input": true,
      "reasoning_efforts": ["low", "medium", "high", "xhigh", "max"]
    }
  ]
}
```

### Claude Code（agent 路由）

agent 路由只派发 `subagent_type`；`models` 里的 agent 条目就是可派发的 agent 类型，不写 `native_model`/`reasoning_efforts`（写了会被拒，因为那等于和 frontmatter 争夺控制权）。

```json
{
  "schema": "native_vision_capabilities_v1",
  "source": {
    "kind": "current_session_native_tool",
    "session_id": "CURRENT_SESSION_ID",
    "tool": "Agent",
    "evidence": "Agent tool subagent_type enum; vlog-vision frontmatter image-reading capability"
  },
  "parameters": {
    "subagent_type": ["vlog-daily-index:vlog-vision"]
  },
  "models": [
    {"id": "vlog-daily-index:vlog-vision", "image_input": true}
  ]
}
```

`Agent` 工具另有可选的 `model` 参数。若快照同时声明了它和一个 Haiku 模型条目，且用户显式 `--model` 选中该模型，合同走 `model` 路由，只输出 `{'model': ...}`、不带 `subagent_type`：派发的是通用 agent，`vlog-vision` frontmatter 的 `tools: Read, Write` 白名单不再适用，ROOT 须在派发 prompt 中限定只读图片、只写包内 `result_path`。未显式 `--model` 时，声明的视觉角色始终走 `agent` 路由。

以上仅演示两种工具形状；替换会话证据后使用，不把示例当探测结果。当前原生模型枚举仅有 OpenAI 型号时，不能凭配置增加 Haiku/DeepSeek。

## 选择顺序

1. 显式 `--model`（用户当前的明确选择，记为 `explicit_model`）
2. 声明的视觉角色
3. 快照 `preferred_model`（仅限未声明视觉角色的 run）
4. `models` 中首个合格项

不暗设提供商质量排名。第 1、2、3 步指定的目标不可用时**失败**，不换另一个模型：显式请求不合格就报错；本 run 声明了视觉角色而该角色不合格（agent 无图像能力、Luna 缺 medium）或不在快照中，同样报错，不退到别的家族、另一条路由或 `preferred_model`。`preferred_model` 只是会话默认，不能压过本 run 的声明角色；用户要换模型只能显式 `--model`。只有第 4 步——**既无声明角色、也无 `preferred_model` 的 run**——才按广告顺序取首个合格项。

`Luna` 是家族映射字面量，不是 agent 名：即使快照的 `subagent_type` 里出现 `Luna`，也不会走 agent 路由，因此不能借 agent 通道绕过 Luna 的 medium 约束。反向同理，agent 名不能通过 `model` 参数派发。

## 逐模型判定

`id` 是真实模型身份；`native_model` 是原生工具接受的精确模型值。两者必须属于同一允许家族；Haiku 可使用工具明确支持的 `haiku` 原生别名（`id` 仍注明具体 Claude Haiku 身份）。DeepSeek 必须实际支持该原生通道的图像输入；文本 DeepSeek、未知图像能力或仅有其他通道 API 均不能作为视觉能力。

判定按**首个实际原因**返回，不随后续字段覆盖：家族 → 图像能力 → 可在 `model` 参数中选择 → id/原生值身份一致 → 模型级档位被工具支持 → Luna 必须有 medium → 默认档位合法。排障信息因此指向真正的坏字段。

Luna 只能 medium，必须有模型级与工具级 medium 支持。Haiku/DeepSeek 没有推理参数时省略 `reasoning_efforts`，合同不添加 `reasoning_effort`；若工具支持，则列出模型实际允许值，可用 `default_reasoning_effort` 或显式参数选择。agent 路由不接受 `--reasoning-effort`，档位由 frontmatter 承载。工具未暴露的参数不填；`fork_turns` 支持 `none` 时才写入隔离请求。

代码验证 ID/家族和快照内部一致性，无法独立证明外部工具声明为真：合同记录 `capability_verification=harness_supplied_snapshot`、`runtime_verification=unverified`。快照与请求不证明实际运行模型。

## 命令

```text
vision-queue --state RUN_STATE --available-workers ACTUAL_FREE --reserve-sol 1 --native-capabilities CURRENT_SESSION_CAPABILITIES_JSON
vision-queue --state RUN_STATE --available-workers ACTUAL_FREE --reserve-sol 1 --claim-worker UNIQUE_WORKER --native-capabilities CURRENT_SESSION_CAPABILITIES_JSON
vision-queue --state RUN_STATE --available-workers ACTUAL_FREE --reserve-sol 1 --release PACKAGE_ID
```

**新 claim 必须提供能力快照。** 缺能力、无可用白名单模型或 agent、图像输入不明确、模型/档位不符，都会在释放和写入 claim **之前**拒绝——坏路由不改动任何状态。只查看队列、或只显式释放已确认结束的旧 claim，不要求快照。

队列返回值与每个 `assigned[].dispatch_contract` 记录同一选择，claim 保存请求模型/档位、原生工具参数、选择原因及快照。ROOT 读 `route` 与 `native_spawn_parameters` 按原生工具实际调用；不默默继承主控、不由 Python spawn。

旧 claim（含缺路由字段、历史 Luna low/high）可读取且不补造证明。复用成功视觉/ASR；升级不改旧包、不全量重跑。已确认 worker 结束或原生派发失败后才显式 release，不能因等待时间自动重派。Claude Code 侧 agent 路由本次仅做合成适配；仍需在真实会话验证 `subagent_type` 解析与图像读取，不能宣称完整跨宿主流水线已实测。
