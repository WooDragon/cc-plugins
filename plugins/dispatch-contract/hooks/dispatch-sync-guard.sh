#!/usr/bin/env bash
# PreToolUse hook (matcher: Agent, Task): block subagent dispatch calls that
# omit run_in_background:false, because the omission silently selects the
# background delivery channel — and that channel drops completion
# notifications with a measured 92.7% loss rate when the main loop is mid-tool
# at delivery time, with no resend and no recovery path (SendMessage does not
# replay lost notifications). See feedback-notification-lost-midturn-fold.md.
#
# Judgment source: fields carried by the dispatch call itself. This hook does
# NOT read any session state, transcript, or prior turn — only tool_name and
# tool_input from the PreToolUse payload on stdin.
#
# Decision chain (strict order, each step fail-opens before the next runs):
#   1. stdin empty                                      -> exit 0
#   2. no jq on PATH                                    -> exit 0
#   3. `jq .` fails to parse (malformed JSON)            -> exit 0
#   4. ALLOW_BACKGROUND_DISPATCH=1                       -> exit 0 (escape hatch)
#   5. tool_name not in {Agent, Task}                    -> exit 0
#   6. CLAUDE_CODE_DISABLE_BACKGROUND_TASKS is set        -> exit 0
#   7. agent_id field present and non-blank              -> exit 0
#   8. tool_input.name present and non-blank              -> exit 0
#   9. tool_input.run_in_background boolean false         -> exit 0
#  10. otherwise                                          -> exit 2 (BLOCK)
#
# Step 3 must run before ANY field extraction. If a malformed payload were
# allowed past this point, every `jq -r` field pull below would fail closed
# to empty/null, which would never satisfy step 9's "== false" pass condition
# and would fall straight into step 10 — turning a parse failure into a false
# BLOCK, which breaks the fail-open contract this whole chain is built on.
# Written as `jq . >/dev/null 2>&1 || exit 0`. Every individual field
# extraction below still carries its own `|| exit 0` (same shape as the
# sibling subagent-done-gate.sh hook) — this is deliberate double coverage:
# the upfront check catches wholesale malformed payloads, the per-line
# `|| exit 0` catches a single unexpected field shape that upfront parsing
# alone wouldn't surface (e.g. tool_input not being an object).
#
# Step 6 reasons about CLAUDE_CODE_DISABLE_BACKGROUND_TASKS, not step 9's
# boolean check: when this env var is truthy, Agent's own inputSchema omits
# the run_in_background field entirely — every dispatch is synchronous by
# construction and the field simply does not exist on the wire. Judging
# "omission" in that world would misfire on literally every call, so this
# step checks "the var is set and non-blank", not "the var equals 1" — the
# switch is Claude Code's own, and its semantics belong to Claude Code, not
# to this hook.
#
# Step 7 (agent_id exemption) is intentionally strict: agent_id is an
# OPTIONAL field. `jq -r '.agent_id // empty'` is NOT enough here — a
# genuinely-absent field and a field present-but-blank would collapse to the
# same empty string, and a plain root-thread dispatch (field absent) must NOT
# be treated the same as an empty string sent by a teammate. This hook first
# confirms the field is actually present with `jq -e 'has("agent_id") and
# .agent_id != null'`, THEN extracts and blank-trims the value — the same
# "distinguish field-absent from present-but-blank" shape used for
# last_assistant_message in subagent-done-gate.sh; copied deliberately.
# Reason this exemption exists at all: Agent.call() in the shipped runtime
# contains `if(C && o===true) throw` where C=!!teammateContext — a teammate
# context is PHYSICALLY forbidden from requesting background dispatch. When
# agent_id is present (i.e. we are inside a teammate context) and
# run_in_background is omitted, the runtime was never going to go background
# regardless of what this hook does — notification loss risk is zero, so
# blocking it would be a pure false positive.
#
# Step 8 is the team-ops lifeline. DO NOT REMOVE THIS STEP. A non-empty
# tool_input.name is the ONLY entry point Lead has for starting a teammate —
# empirically there is no standalone TeamCreate tool (the binary contains
# exactly 3 occurrences of the string "TeamCreate": two are copies of the
# `$Yr` constant-pool set literal, one is `$Yr`'s own JS definition; `$Yr` is
# read only by UI rendering and dynamic tool-pool accounting, never touched by
# hook dispatch). Starting a teammate goes through Agent.call()'s
# `if(b&&i&&!L&&!s&&!a)` branch -> `cvd()` -> `Fko()` ->
# `taskRegistry.register`, and tool_name for that call is `Agent`. Removing
# this step would block Lead from ever starting a teammate.
#
# Step 9 accepts ONLY the JSON boolean `false` — the string `"false"` does
# NOT qualify and falls through to BLOCK. Checked with
# `jq -e '.tool_input.run_in_background == false'`.
#
# Known failure mode (documented, not patched): the Agent inputSchema omits
# run_in_background whenever `DT()||TSe()` is true. Step 6 only catches the
# DT() half (the env var). TSe() is NOT caught — it gates on a server-side
# rollout flag (tengu_copper_fox) whose on-disk cache and live runtime value
# have been observed to disagree, so this hook has no reliable way to judge
# it from the PreToolUse payload alone. This is deliberately left unguarded:
# when TSe() is true the field is omitted BECAUSE the background channel does
# not exist in that runtime, which means the notification-loss risk this hook
# exists to prevent is already zero — misfiring here means blocking a
# harmless call. The failure direction is "false positive with an escape
# hatch," never "silent miss that lets the drop recur."
set -u

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

jq . >/dev/null 2>&1 <<< "$INPUT" || exit 0

[[ "${ALLOW_BACKGROUND_DISPATCH:-}" == "1" ]] && exit 0

TOOL_NAME=$(jq -r '.tool_name // empty' <<< "$INPUT" 2>/dev/null) || exit 0
case "$TOOL_NAME" in
  Agent|Task) ;;
  *) exit 0 ;;
esac

[ -n "${CLAUDE_CODE_DISABLE_BACKGROUND_TASKS:-}" ] && exit 0

# agent_id exemption: distinguish field-absent from present-but-blank.
if jq -e 'has("agent_id") and .agent_id != null' <<< "$INPUT" >/dev/null 2>&1; then
  AGENT_ID=$(jq -r '.agent_id' <<< "$INPUT" 2>/dev/null) || exit 0
  [[ -n "${AGENT_ID// /}" ]] && exit 0
fi

# team-ops lifeline: non-empty tool_input.name means this dispatch is
# starting a teammate. DO NOT REMOVE.
NAME=$(jq -r '.tool_input.name // empty' <<< "$INPUT" 2>/dev/null) || exit 0
[[ -n "${NAME// /}" ]] && exit 0

jq -e '.tool_input.run_in_background == false' <<< "$INPUT" >/dev/null 2>&1 && exit 0

printf '[dispatch-sync-guard] 省略 run_in_background 即选择后台通道：完成通知在主循环正跑工具时到达会被丢弃，实测丢失率 92.7%%，且无补发、无恢复通道（SendMessage 续跑不补发旧通知）。\n' >&2
printf '[dispatch-sync-guard] 需要产物才能往下走 → 加 run_in_background:false 重派，产物走 tool_result，根本不进那个会被折叠吃掉的队列。真要后台并行 → 派完立刻结束本轮交还主循环，禁止 sleep/轮询/紧接 AskUserQuestion。\n' >&2
printf '[dispatch-sync-guard] 确需后台：在 ~/.claude/settings.json 的 env 段加 "ALLOW_BACKGROUND_DISPATCH":"1"（Bash 里 export 传不进 hook 进程）。\n' >&2
printf '[dispatch-sync-guard] 若本机所有派发都被本门禁拦下，是 fork-subagent 特性（tengu_copper_fox）已开启、run_in_background 从 schema 中移除所致。此时后台通道本不存在，拦截为误伤：按上一行加 .env 开关放行即可。\n' >&2
exit 2
