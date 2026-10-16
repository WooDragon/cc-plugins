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
# SubagentStart has no teammate/name flag. RULE1 therefore describes the
# channel conditionally without guessing Team identity or its dispatcher.
# Team's existing artifact and control-signal protocol owns its routing.
#
# Every type receives the current-delivery boundary in RULE2. Read-only
# types (Explore, Plan — case insensitive) have Edit/Write disabled by the
# platform, so only other types receive the additional file-edit reminder.
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
# common rules plus the file-scope reminder. This fallback does not infer
# Team identity or choose a dispatcher.
set -u

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

jq . >/dev/null 2>&1 <<< "$INPUT" || exit 0

[[ "${ALLOW_NO_RULES_INJECT:-}" == "1" ]] && exit 0

AGENT_TYPE=$(jq -r '.agent_type // empty' <<< "$INPUT" 2>/dev/null) || exit 0
AGENT_TYPE_LC=$(printf '%s' "$AGENT_TYPE" | tr '[:upper:]' '[:lower:]')

RULE1='[dispatch-contract] 铁律①输出即产物：最终消息本身就是产物，禁止写完成说明或元总结。若为 named teammate，按实际 dispatcher 与约定回传通道交付；Team 按既有正式产物与控制信号协议回传，不统一向 main 发送全文。'
RULE2='[dispatch-contract] 铁律②范围围栏：一个实例默认一个当前交付；后续独立交付默认新实例，不因亲和 resume（用户显式授权复用除外）。未完成交付的原授权内调查、纠错和复测继续原执行；不凭 final、失败或 idle 判完成。只做指定事，范围外只报告不擅动。'
EDIT_SCOPE='只改指定文件。'
RULE3='[dispatch-contract] 铁律③渐进产出：长任务分段读、尽早吐中间进展。'
# 条件式：只在派发 prompt 确实要求了 %%DONE%% 时才有意义，但这个 hook 读不到
# 派发 prompt 内容（SubagentStart payload 没有该字段），所以措辞本身就是条件式
# 的——"若派发 prompt 要求了……"——不判断，把判断留给读到这句话的 agent 自己。
# 这条注入到全部 agent_type（含 explore|plan 只读支），因为只读 agent 同样会被
# subagent-done-gate 的判据（读派发 prompt 是否含 MARK）纳入判断，不该只有非
# 只读支才知道这条契约存在。
#
# 字面量：本行文本刻意含 %%DONE%% 的字面拼写，不是变量插值——若未来改用变量
# 拼接要三思，见 subagent-done-gate.sh 里「PROMPT_SRC 过滤 attachment 记录」
# 那段注释：这行字面量落进 transcript 后，若被门禁的两行读取窗口误读到，会让
# 每个 subagent 都被判成「派发方要求了标记」，是那段过滤逻辑存在的直接原因。
RULE4='[dispatch-contract] 铁律④定稿标记：若派发 prompt 要求了 %%DONE%%，在最终消息末尾单独一行输出该标记，不加粗、不代码块、不列表符。'
POINTER='[dispatch-contract] 详规见 Skill(subagent-dispatch)。'

case "$AGENT_TYPE_LC" in
  explore|plan)
    CONTEXT=$(printf '%s\n%s\n%s\n%s\n%s' "$RULE1" "$RULE2" "$RULE3" "$RULE4" "$POINTER")
    ;;
  *)
    CONTEXT=$(printf '%s\n%s%s\n%s\n%s\n%s' "$RULE1" "$RULE2" "$EDIT_SCOPE" "$RULE3" "$RULE4" "$POINTER")
    ;;
esac

jq -n \
  --arg ctx "$CONTEXT" \
  '{hookSpecificOutput:{hookEventName:"SubagentStart",additionalContext:$ctx}}' 2>/dev/null || exit 0
