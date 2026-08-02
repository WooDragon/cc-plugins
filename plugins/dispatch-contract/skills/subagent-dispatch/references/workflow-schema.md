# Workflow schema 强制结构化产物

**场景**：铁律①在日常 Agent 只能靠 prompt 约束，子 agent 仍可能不照做。当需要机器可校验的结构化产物时，用 Workflow 的 `agent()` 带 schema 选项——子 agent 被强制调用 StructuredOutput 工具，返回经 JSON Schema 校验的对象，校验失败自动重试。

**用法要点**：`agent(prompt, {schema: <JSON Schema>})` 返回校验后的对象而非文本；不带 schema 时返回子 agent 最终文本字符串。

**边界（重要）**：这是 Workflow 编排专属能力，**日常 `Agent`/`Task` 工具没有 schema 参数**。不要把"用 schema 强制"写进日常派发预期——日常派发的铁律①落点是 prompt 措辞。

**何时升级到 Workflow**：单次派发用不上；当任务需要多 agent 编排 + 强结构化产物汇总（如 N 个评审 agent 各返回结构化 findings 再合并）时才值得用 Workflow。
