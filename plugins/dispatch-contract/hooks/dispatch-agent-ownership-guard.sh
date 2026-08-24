#!/usr/bin/env bash
# PreToolUse hook (Agent|Task): enforce model ownership across three classes:
# runtime-owned built-ins require an explicit model, model-optional Plan follows
# the parent session when omitted or null, and named registered types own model
# selection in their definitions. Missing subagent_type follows the runtime's
# general-purpose default.
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
  normalize_agent_type is_runtime_model_agent is_model_optional_agent || exit 0

# gate_preamble validates JSON and extracts fields, but model-field ownership
# depends on distinguishing absent, null, blank, and nonblank values. Its
# field extractor intentionally collapses those states, so inspect raw input.
if ! jq -e '.tool_input | type == "object"' <<<"$GATE_INPUT" >/dev/null 2>&1; then
  printf '[GATE-DEGRADE] dispatch-agent-ownership-guard: tool_input extract failed\n' >&2
  exit 0
fi

ownership_reject() {
  printf '[dispatch-agent-ownership-guard] 逃生舱：在 ~/.claude/settings.json 的 env 段设置 "ALLOW_AGENT_MODEL_INHERIT": "1"（Bash 内 export 对 hook 进程不生效，仅可作直接调用本脚本时的同进程调试用；临时开启后须销账关闭，长期常开会致门禁全局失效）。\n' >&2
  exit 2
}

TYPE=$(normalize_agent_type "$subagent_type")

if is_runtime_model_agent "$TYPE"; then
  if jq -e '.tool_input.model | type == "string" and test("[^[:space:]]")' <<<"$GATE_INPUT" >/dev/null 2>&1; then
    exit 0
  fi

  printf '[dispatch-agent-ownership-guard] 内置 runtime-owned agent(subagent_type=%s) 必须显式带非空、非空白 model：档位不等于任务类型,裸派只能选 model,effort 只能由角色 frontmatter 承载(dev-econ/worker-econ 已钉 haiku+effort:max),裸派 haiku 拿不到该档上限。\n' "$TYPE" >&2
  printf '[dispatch-agent-ownership-guard] 出路:取数→model:haiku;有取舍的落地→model:sonnet 或 dev/worker;已钉死的机械落地→dev-econ/worker-econ 且省略 model(给 runtime-owned 内置钉 haiku 又接写/执行会被 dispatch-capability-guard 判据 C 拦)。\n' >&2
  ownership_reject
fi

if is_model_optional_agent "$TYPE"; then
  if jq -e '(.tool_input | has("model") | not) or (.tool_input.model == null) or (.tool_input.model | (type == "string" and test("[^[:space:]]")))' <<<"$GATE_INPUT" >/dev/null 2>&1; then
    exit 0
  fi

  printf '[dispatch-agent-ownership-guard] model-optional agent(subagent_type=%s) 命中判据：传了空的 model 字段；该类型的 model 由主 session 拥有，省略或 null 表示跟随主 session 档位，空串/纯空白既不是"跟随"也不是有效档位选择。\n' "$TYPE" >&2
  printf '[dispatch-agent-ownership-guard] 出路：删掉 model 字段（或传 null）跟随主 session；确需指定档位则填有效模型名。\n' >&2
  ownership_reject
fi

# Null and omission both mean no caller-side override. Any other present
# value—including "inherit", an empty string, or whitespace—is an explicit
# override and would shadow the registered agent's frontmatter model.
if jq -e '(.tool_input | has("model")) and .tool_input.model != null' <<<"$GATE_INPUT" >/dev/null 2>&1; then
  printf '[dispatch-agent-ownership-guard] 具名注册 agent(subagent_type=%s) 的 model 必须完全省略；model:null 可表示不覆盖，但任何其他字段值都会覆盖注册定义。\n' "$TYPE" >&2
  printf '[dispatch-agent-ownership-guard] 出路：删除 model；若注册 agent 的能力不足，换用合适角色。\n' >&2
  ownership_reject
fi

exit 0
