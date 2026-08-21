#!/usr/bin/env bash
# hooks/lib/gate.sh
#
# Shared preamble for PreToolUse(Agent|Task) dispatch guards. Collapses the
# repeated 8-line prologue (escape hatch -> empty-stdin check -> jq probe ->
# tool_name extract -> Agent/Task filter -> field extraction) into one call,
# so degrade visibility ([GATE-DEGRADE] on stderr) becomes a byproduct of the
# call site instead of a discipline each hook has to remember to uphold.
#
# gate_preamble <gate-name> <escape-hatch-var> <field>...
#   rc 0 = judgment data complete; each <field> is set as a global variable
#          in the caller's scope (e.g. field "name" -> $name)
#   rc 1 = degraded (judgment data unavailable); [GATE-DEGRADE] already
#          written to stderr
#   rc 2 = not applicable (tool_name is not Agent/Task); silent by design —
#          this is a normal "not my job" path, not a degrade
#   rc 3 = knowing bypass (escape hatch set to 1); [GATE-BYPASS] on stderr
#
# Why rc 3 exists rather than folding the escape hatch into rc 1: "a human
# deliberately opened this door" and "the gate could not read its own judgment
# data" are opposite conditions. Tagging both [GATE-DEGRADE] would make the very
# signal this lib exists to render trustworthy ambiguous — a grep for degrades
# would surface every session that has the hatch set, drowning real breakage.
# The hatch is not silent either (that was the failure mode recorded as
# claude-config 仓的 issue 164: hatch left on permanently in settings.json,
# gate dead, nobody noticed for months). Loud and distinct beats both silent
# and conflated.
#
# This function never exits — the pass/allow decision stays with the caller.
# Callers uniformly write `gate_preamble ... || exit 0`: rc 1, 2 and 3 all mean
# "let it through", and the difference between them is already expressed on
# stderr, so the call site still doesn't need to branch on it.
#
# Vendored copy: this file is a copy of ~/.claude/hooks/lib/gate.sh, kept here
# because a plugin must be self-contained and cannot `source` a file living
# outside its own tree. The source of truth still has three other hooks
# depending on it (outside this plugin's reach). The two copies' return-code
# contract (rc 0/1/2/3 above) must be kept in sync by hand — there is no
# automated check tying them together.

# gate_require_library <gate-name> <library-path> <required-function>...
#   rc 0 = library sourced and every required helper is defined
#   rc 1 = library unavailable or a required helper is missing; a
#          [GATE-DEGRADE] marker is written to stderr
#
# Loading a dependency is part of forming judgment data, so this helper keeps
# the failure contract in one place for every consumer. It deliberately uses
# only Bash builtins and never exits the caller.
gate_require_library() {
  local gate="$1" library="$2"; shift 2
  local library_name="${library##*/}"

  if ! . "$library"; then
    printf '[GATE-DEGRADE] %s: %s unavailable\n' "$gate" "$library_name" >&2
    return 1
  fi

  local required
  for required in "$@"; do
    if ! declare -F "$required" >/dev/null 2>&1; then
      printf '[GATE-DEGRADE] %s: %s lacks required helpers\n' "$gate" "$library_name" >&2
      return 1
    fi
  done
  return 0
}

gate_preamble() {
  local gate="$1" hatch="$2"; shift 2
  GATE_INPUT=$(cat)

  # Knowing bypass is checked before the degrade conditions: when the operator
  # has opened the door, that is the reason this dispatch is passing, and it must
  # not be reported as a malfunction.
  if [ "${!hatch:-}" = "1" ]; then
    printf '[GATE-BYPASS] %s: escape hatch %s=1\n' "$gate" "$hatch" >&2
    return 3
  fi

  local why=""
  if   [ -z "$GATE_INPUT" ];            then why="empty stdin"
  elif ! command -v jq >/dev/null 2>&1; then why="jq unavailable"
  fi
  [ -n "$why" ] && { printf '[GATE-DEGRADE] %s: %s\n' "$gate" "$why" >&2; return 1; }

  TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$GATE_INPUT" 2>/dev/null) || {
    printf '[GATE-DEGRADE] %s: tool_name extract failed\n' "$gate" >&2; return 1; }
  case "$TOOL_NAME" in Agent|Task) ;; *) return 2 ;; esac

  local f v
  for f in "$@"; do
    v=$(jq -r --arg k "$f" '.tool_input[$k] // empty' <<<"$GATE_INPUT" 2>/dev/null) || {
      printf '[GATE-DEGRADE] %s: %s extract failed\n' "$gate" "$f" >&2; return 1; }
    printf -v "$f" '%s' "$v"
  done
  return 0
}
