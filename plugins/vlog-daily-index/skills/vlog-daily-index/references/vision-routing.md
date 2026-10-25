# 纯视觉原生路由

纯视觉逐帧识图的代码白名单为 Luna、Haiku、DeepSeek；日级语义与专门地理继续 `gpt-6.1-sol / high`，ROOT 终审。纯视觉例外优先于通用编排的视觉审查默认。禁止静默改派 Sol/旗舰、隐藏 API 调模型或用宿主名称猜可用模型。

每次主 session 派新包前，根据**当前真实原生工具**的模型枚举、模型级推理支持及子 Agent 图像读取能力，保存本地 `native_vision_capabilities_v1` JSON。来源必须注明当前 session 标识、工具名和可核对的能力证据；不要从旧 run、其他宿主、产品宣传或模型自报补造支持。`parameters` 只填该工具实际可传的参数及取值；`models` 按主 session 的声明顺序列出。公开仓库不保存实际会话快照。

以下仅演示当前 Codex 工具可支持的 Luna 路由；替换会话证据后使用，不把示例当探测结果。当前原生模型枚举仅有 OpenAI 型号时，不能凭配置增加 Haiku/DeepSeek：

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

`id` 是真实模型身份；`native_model` 是原生工具接受的精确模型值。两者必须属于同一允许家族；Haiku 可使用工具明确支持的 `haiku` 原生别名（`id` 仍注明具体 Claude Haiku 身份）。DeepSeek 必须实际支持该原生通道的图像输入；文本 DeepSeek、未知图像能力或仅有其他通道 API 均不能作为视觉能力。代码验证 ID/家族和快照内部一致性，无法独立证明外部工具声明为真。

默认先选显式 `--model`，其次选快照 `preferred_model`，最后选 `models` 中首个合格模型，不暗设提供商质量排名。显式请求/偏好不可用时失败，不换另一个模型。Luna 只能 medium，必须有模型级与工具级 medium 支持。Haiku/DeepSeek 没有推理参数时省略 `reasoning_efforts`，合同不添加 `reasoning_effort`；若工具支持，则列出模型实际允许值，可用 `default_reasoning_effort` 或显式参数选择。工具未暴露的参数不填；`fork_turns` 支持 `none` 时才写入隔离请求。

```text
vision-queue --state RUN_STATE --available-workers ACTUAL_FREE --reserve-sol 1 --native-capabilities CURRENT_SESSION_CAPABILITIES_JSON
vision-queue --state RUN_STATE --available-workers ACTUAL_FREE --reserve-sol 1 --claim-worker UNIQUE_WORKER --native-capabilities CURRENT_SESSION_CAPABILITIES_JSON
```

新 claim 必须提供能力快照；缺能力、无可用白名单模型、图像输入不明确或模型/档位不符，在释放/写入 claim 前拒绝。只查看队列或显式释放旧 claim 不要求新能力。队列及每个 `assigned[].dispatch_contract` 返回同一选择，claim 保存请求模型/档位、原生工具参数、选择原因及快照。ROOT 读取 `native_tool` 与 `native_spawn_parameters`，按原生工具实际调用；不默默继承主控、不由 Python spawn。快照记录 `capability_verification=harness_supplied_snapshot`，实际执行模型仍为 `runtime_verification=unverified`，不能把请求记录或模型自报当运行时证明。

旧 claim（含缺路由字段、历史 Luna low/high）可读取且不补造证明。复用成功视觉/ASR；升级不改旧包、不全量重跑。已确认 worker 结束或原生派发失败后才显式 release，不能因等待时间自动重派。其他宿主本次仅验证能力合同的合成适配；仍需在真实宿主验证原生工具与图像能力，不能宣称完整跨宿主流水线已实测。
