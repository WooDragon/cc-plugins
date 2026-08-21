#!/usr/bin/env bash
# Runtime-owned built-in agent types are the only dispatch shapes whose model
# is selected by the runtime rather than by a registered agent definition.

# normalize_agent_type VALUE
# Canonicalizes a dispatch type for every consumer. An absent, null-decoded, or
# empty value follows Claude Code's general-purpose runtime default.
normalize_agent_type() {
  local agent_type="${1:-general-purpose}"
  [ -n "$agent_type" ] || agent_type="general-purpose"
  printf '%s' "$agent_type" | tr '[:upper:]' '[:lower:]'
}

is_runtime_model_agent() {
  local normalized_type
  normalized_type=$(normalize_agent_type "$1")

  case "$normalized_type" in
    general-purpose|claude|explore|plan|claude-code-guide|statusline-setup)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}
