#!/usr/bin/env bash
# Runtime-owned built-in agent types are the only dispatch shapes whose model
# is selected by the runtime rather than by a registered agent definition.

is_runtime_model_agent() {
  # Bash 3.2 has no ${value,,}; keep normalization aligned with the existing
  # capability guard's tr-based type handling.
  local normalized_type
  normalized_type=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')

  case "$normalized_type" in
    general-purpose|claude|explore|plan|claude-code-guide|statusline-setup)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}
