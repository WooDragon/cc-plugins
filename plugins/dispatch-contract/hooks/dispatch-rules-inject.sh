#!/usr/bin/env bash
# SubagentStart hook (matcher: *): inject the dispatch rules directly into
# the subagent's OWN context, so enforcement does not depend on whether the
# dispatching prompt happened to spell them out. This is a belt-and-suspenders
# complement to the dispatch-side prompt convention documented in the
# subagent-dispatch skill — the skill only helps when the dispatcher
# remembers to write the rules; this hook makes the rules land regardless.
#
# Output shape (stdout, must be the only stdout write in the whole script):
#   {"hookSpecificOutput":{"hookEventName":"SubagentStart","additionalContext":"<rules text>"}}
#
# Injected text is deliberately terse — SubagentStart fires once per spawned
# subagent, and with N-way parallel dispatch the same block gets paid for N
# times in aggregate context; full positive/negative examples belong in the
# skill, not in every subagent's startup context.
#
# RULE1 carries a teammate-channel branch (not just "output is the artifact")
# because this hook can only read `.agent_type` from the SubagentStart
# payload — there is no teammate/name flag in that payload, so the hook has
# no way to tell a plain subagent dispatch from a named-teammate dispatch and
# branch the wording accordingly. The rule is written to cover both cases in
# one sentence instead: for a plain dispatch the final message already reaches
# the dispatcher; for a teammate dispatch it does not, and a SendMessage(to:
# "main") call is required to actually deliver it.
#
# Tiering by agent_type: read-only agent types (Explore, Plan — case
# insensitive) have Edit/Write physically disabled by the platform, so
# injecting rule ②'s "only touch the files you were told to" wording would
# be a no-op admonition about a constraint that already can't be violated.
# Those types get rules ① and ③ plus the skill pointer only; every other
# agent_type gets all three rules.
#
# stdout purity (hard constraint — this hook's payload is parsed as JSON by
# the harness, any stray byte on stdout corrupts it):
#   - every non-payload message in this script goes to stderr (>&2)
#   - every intermediate command that could write to stdout is redirected to
#     /dev/null explicitly
#   - the JSON payload is built with `jq -n`, never hand-assembled string
#     concatenation — the rules text below contains no user-controlled bytes
#     today, but constructing it any other way would be one edit away from a
#     quoting bug corrupting the emitted JSON
#   - the ONE stdout write happens in a single statement at the very end of
#     the script; every earlier exit path is `exit 0` with no stdout write at
#     all — on any fail-open path this hook would rather inject nothing than
#     emit a half-formed JSON object
#
# Escape hatch: ALLOW_NO_RULES_INJECT=1 -> silent exit 0, no injection.
#
# Fail-open conditions (exit 0, stdout empty): empty stdin, no jq, `jq .`
# parse failure, missing/blank agent_type field is NOT fail-open by itself —
# agent_type absent is treated as "not a known read-only type" and gets the
# full three-rule injection, since the safer default when we can't identify
# the type is to inject the file-scope reminder rather than omit it.
set -u

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

jq . >/dev/null 2>&1 <<< "$INPUT" || exit 0

[[ "${ALLOW_NO_RULES_INJECT:-}" == "1" ]] && exit 0

AGENT_TYPE=$(jq -r '.agent_type // empty' <<< "$INPUT" 2>/dev/null) || exit 0
AGENT_TYPE_LC=$(printf '%s' "$AGENT_TYPE" | tr '[:upper:]' '[:lower:]')

RULE1='[dispatch-contract] 铁律①输出即产物：最终消息本身就是产物，禁止写完成说明或元总结。若你被赋了 name（teammate），最终消息不会自动回到派发方，须再用 SendMessage(to:"main") 送出同一份产物。'
RULE2='[dispatch-contract] 铁律②范围围栏：只改指定文件/只做指定事，范围外只报告不擅动。'
RULE3='[dispatch-contract] 铁律③渐进产出：长任务分段读、尽早吐中间进展。'
POINTER='[dispatch-contract] 详规见 Skill(subagent-dispatch)。'

case "$AGENT_TYPE_LC" in
  explore|plan)
    CONTEXT=$(printf '%s\n%s\n%s' "$RULE1" "$RULE3" "$POINTER")
    ;;
  *)
    CONTEXT=$(printf '%s\n%s\n%s\n%s' "$RULE1" "$RULE2" "$RULE3" "$POINTER")
    ;;
esac

jq -n \
  --arg ctx "$CONTEXT" \
  '{hookSpecificOutput:{hookEventName:"SubagentStart",additionalContext:$ctx}}' 2>/dev/null || exit 0
