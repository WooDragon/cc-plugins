#!/usr/bin/env bash
# Dispatch types fall into three model-ownership classes: runtime-owned built-ins
# require an explicit caller-selected model, model-optional Plan follows the
# parent session when omitted or null, and named registered agents own model
# selection in their definitions.

# normalize_agent_type VALUE
# Canonicalizes a dispatch type for every consumer. An absent, null-decoded, or
# empty value follows Claude Code's general-purpose runtime default.
normalize_agent_type() {
  local agent_type="${1:-general-purpose}"
  [ -n "$agent_type" ] || agent_type="general-purpose"
  printf '%s' "$agent_type" | tr '[:upper:]' '[:lower:]'
}

# is_runtime_model_agent VALUE
# Identifies runtime-owned built-ins whose model must be explicitly selected by
# the dispatch caller rather than inherited from a registered agent definition.
is_runtime_model_agent() {
  local normalized_type
  normalized_type=$(normalize_agent_type "$1")

  case "$normalized_type" in
    general-purpose|claude|explore|claude-code-guide|statusline-setup)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# is_model_optional_agent VALUE
# Identifies the built-in Plan type whose model may be omitted or null to follow
# the parent session. CC 2.1.228 defines built-in Plan with model:"inherit".
# Explore also declares inherit, but a separate firstParty branch caps inherit
# at opus (disable with CLAUDE_CODE_DISABLE_EXPLORE_INHERIT_CAP); Plan has no
# corresponding branch, so the runtime's intent for Plan is to follow the parent
# session. Plan authoring is decision work, and following the main session tier
# is therefore the correct tier. Model-optional does not mean unchecked: omission
# and null mean follow, while an explicit empty or whitespace-only string is
# neither follow nor a valid tier selection and must still be rejected.
is_model_optional_agent() {
  local normalized_type
  normalized_type=$(normalize_agent_type "$1")

  case "$normalized_type" in
    plan)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}
