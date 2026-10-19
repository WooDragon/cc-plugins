#!/usr/bin/env bash
# A completed tool return is not a business-success verdict. Remind its caller
# without parsing the report, inspecting caller identity, or retaining state.
command -v jq >/dev/null 2>&1 || exit 0

context='以下用于判断下一步，不需要逐项作答。
这是用户要求的吗？这是必要的吗？有什么实际可达的证据？省略它会导致当前哪项验收失败？
已有证据对最终状态仍然有效，就复用。
不要仅为了满足本 Skill，再增加一轮最终审计。'

# Slurp validates the entire input before emitting anything, including rejecting
# multiple JSON values. Buffer stdout so parse/runtime failures stay silent.
output=$(jq -cs --arg context "$context" '
  select(length == 1) | .[0]
  | select(type == "object")
  | select(.hook_event_name == "PostToolUse")
  | select(.tool_name == "Agent" or .tool_name == "Task")
  | select(.tool_response | type == "object")
  | select(.tool_response.status == "completed")
  | {hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $context}}
' 2>/dev/null) || exit 0

[ -n "$output" ] || exit 0
printf '%s\n' "$output"
