#!/usr/bin/env bash
# PreToolUse hook (Agent|Task): keep model ownership with the runtime for
# built-in types and with registered agent definitions for every other named
# type. Missing subagent_type follows the runtime's general-purpose default.
#
# This guard deliberately does not rely on sibling gates: model ownership is a
# complete judgment over this call's payload and is valid regardless of whether
# another gate later accepts or rejects the dispatch.
#
# Fail-open only covers unavailable judgment data. A model value that violates
# ownership is a semantic error and exits 2.

set -u

. "${BASH_SOURCE[0]%/*}/lib/gate.sh"

gate_preamble dispatch-agent-ownership-guard ALLOW_AGENT_MODEL_INHERIT subagent_type || exit 0

AGENT_KIND_LIB="${BASH_SOURCE[0]%/*}/lib/agent-kind.sh"
gate_require_library dispatch-agent-ownership-guard "$AGENT_KIND_LIB" \
  normalize_agent_type is_runtime_model_agent || exit 0

# gate_preamble validates JSON and extracts fields, but model-field ownership
# depends on distinguishing absent, null, blank, and nonblank values. Its
# field extractor intentionally collapses those states, so inspect raw input.
if ! jq -e '.tool_input | type == "object"' <<<"$GATE_INPUT" >/dev/null 2>&1; then
  printf '[GATE-DEGRADE] dispatch-agent-ownership-guard: tool_input extract failed\n' >&2
  exit 0
fi

TYPE=$(normalize_agent_type "$subagent_type")

if is_runtime_model_agent "$TYPE"; then
  if jq -e '.tool_input.model | type == "string" and test("[^[:space:]]")' <<<"$GATE_INPUT" >/dev/null 2>&1; then
    exit 0
  fi

  printf '[dispatch-agent-ownership-guard] 内置 runtime-owned agent(subagent_type=%s) 必须显式带非空、非空白 model。\n' "$TYPE" >&2
  printf '[dispatch-agent-ownership-guard] 出路：补 runtime model 后重派。\n' >&2
  exit 2
fi

# Null and omission both mean no caller-side override. Any other present
# value—including "inherit", an empty string, or whitespace—is an explicit
# override and would shadow the registered agent's frontmatter model.
if jq -e '(.tool_input | has("model")) and .tool_input.model != null' <<<"$GATE_INPUT" >/dev/null 2>&1; then
  printf '[dispatch-agent-ownership-guard] 具名注册 agent(subagent_type=%s) 的 model 必须完全省略；model:null 可表示不覆盖，但任何其他字段值都会覆盖注册定义。\n' "$TYPE" >&2
  printf '[dispatch-agent-ownership-guard] 出路：删除 model；若注册 agent 的能力不足，换用合适角色。\n' >&2
  exit 2
fi

exit 0
