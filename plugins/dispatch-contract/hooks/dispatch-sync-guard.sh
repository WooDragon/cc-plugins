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
#  9b. field absent (fork world)                        -> exit 2 (BLOCK, fork-specific message)
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
# Step 9b (fork world) exists because the Agent inputSchema DROPS
# run_in_background whenever `Lv() || bEe()` is true — Lv() is the env var
# from step 6, bEe() is the fork-subagent feature. Step 6 already exempts the
# Lv() half. The bEe() half is the dangerous one, and an earlier revision of
# this header had its semantics exactly backwards, claiming the field is
# omitted BECAUSE the background channel does not exist and that blocking
# here is therefore a harmless false positive. Reading the shipped runtime
# (2.1.222) shows the opposite. The expression deciding async is:
#
#   let K=Wb(), q=bEe(), U=Lv();
#   Z = z || (o===!0 || V.background===!0 || K || q || !w && o!==!1) && !U;
#
# `q` (i.e. bEe()) is an independent disjunct, so when fork is on, Z is
# unconditionally true and EVERY dispatch takes the async_launched /
# isBackgroundAgent:true branch. Meanwhile zod's `.object()` strips keys not
# in the schema, so passing run_in_background:false does not even reach `o` —
# and even if it did, `q` would still force Z true. Fork world is therefore
# not "no background channel, zero risk"; it is "background forced, sync
# unrequestable" — the worst form of the very thing this hook guards.
#
# That is why step 9b still BLOCKS. What it changes is the WAY OUT. The old
# text pointed at ALLOW_BACKGROUND_DISPATCH=1, which silences this hook in
# every world including the ones where the channel is real and the guard is
# earning its keep. The actionable fix is CLAUDE_CODE_FORK_SUBAGENT=0,
# because the fork gate resolves as:
#
#   function Ax_(){
#     if(Ple())return"disabled";
#     if(tr(env.CLAUDE_CODE_FORK_SUBAGENT))return"env";
#     if($u(env.CLAUDE_CODE_FORK_SUBAGENT))return"disabled";  // <- before rollout
#     if(Sn())return"disabled";
#     if(Qe(wx_,!1))return"gb_rollout";
#     return"disabled" }
#
# The falsy-env branch sits BEFORE the `tengu_copper_fox` rollout check, so
# it overrides the server-side flag. Setting it makes bEe() false, which
# restores the field to the schema and clears `q` from Z — the third state
# (channel present but sync unexpressable) stops existing, and this hook's
# judgment source is never an empty set again. Removing the hazard beats
# muting the alarm, so no fourth env switch is added here: a guard that needs
# another guard to stay honest is a design smell.
#
# Detection is deliberately indirect. The rollout flag's on-disk cache and
# live runtime value have been observed to disagree, so this hook never tries
# to read it. It infers fork world structurally instead: the field is absent
# AND step 6's env var is unset, which leaves bEe() as the only remaining
# explanation for the omission. A dispatcher that simply forgot the field in
# a normal (non-fork) runtime lands here too, and blocking that is correct
# anyway — the failure direction stays "false positive with a way out," never
# "silent miss that lets the drop recur."
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
  # Blank test must cover tabs and newlines, not just spaces: ${var// /} only
  # strips U+0020, so a tab-only or newline-only agent_id would read as
  # "non-blank" and wrongly open the exemption. Same [[:space:]] shape as the
  # sibling pre-dispatch-channel-guard.sh.
  [[ ! "$AGENT_ID" =~ ^[[:space:]]*$ ]] && exit 0
fi

# team-ops lifeline: non-empty tool_input.name means this dispatch is
# starting a teammate. DO NOT REMOVE.
NAME=$(jq -r '.tool_input.name // empty' <<< "$INPUT" 2>/dev/null) || exit 0
# Same [[:space:]] blank test as the agent_id step above — see the comment
# there for why ${var// /} is not sufficient.
[[ ! "$NAME" =~ ^[[:space:]]*$ ]] && exit 0

jq -e '.tool_input.run_in_background == false' <<< "$INPUT" >/dev/null 2>&1 && exit 0

# Fork world (field absent + step 6's env var unset) gets its own message:
# the generic "add run_in_background:false" advice is unfollowable there,
# because the field is not in the schema to begin with.
if ! jq -e '.tool_input | has("run_in_background")' <<< "$INPUT" >/dev/null 2>&1; then
  printf '[dispatch-sync-guard] run_in_background 不在 Agent 的 inputSchema 里,说明 fork-subagent 特性已开启(tengu_copper_fox)。此时后台不是"不存在"而是被强制:运行时里 bEe() 是决定异步的独立析取项,Z 恒真,所有派发都走 async_launched;zod 会剥掉 schema 外的键,硬传 run_in_background:false 也进不去。\n' >&2
  printf '[dispatch-sync-guard] 完成通知在主循环正跑工具时到达会被丢弃,实测丢失率 92.7%%,无补发、无恢复通道 —— 所以这里不放行。\n' >&2
  printf '[dispatch-sync-guard] 解法:在 ~/.claude/settings.json 的 env 段加 "CLAUDE_CODE_FORK_SUBAGENT":"0"(需重启 CC 生效)。该假值分支在运行时里排在 rollout 检查之前,能压过服务端 flag,字段随即回到 schema、同步派发重新可表达。代价仅是放弃 fork 的上下文继承。\n' >&2
  printf '[dispatch-sync-guard] 不要改用 ALLOW_BACKGROUND_DISPATCH=1 绕过 —— 那会让本门禁在所有环境一起失效,包括后台通道真实存在、真正需要它的场景。\n' >&2
  exit 2
fi

printf '[dispatch-sync-guard] run_in_background 被省略、显式设为 true、或传入非布尔值时都会选中后台通道：完成通知在主循环正跑工具时到达会被丢弃，实测丢失率 92.7%%，且无补发、无恢复通道（SendMessage 续跑不补发旧通知）。\n' >&2
printf '[dispatch-sync-guard] 需要产物才能往下走 → 加 run_in_background:false 重派，产物走 tool_result，根本不进那个会被折叠吃掉的队列。真要后台并行 → 派完立刻结束本轮交还主循环，禁止 sleep/轮询/紧接 AskUserQuestion。\n' >&2
printf '[dispatch-sync-guard] 确需后台：在 ~/.claude/settings.json 的 env 段加 "ALLOW_BACKGROUND_DISPATCH":"1"（Bash 里 export 传不进 hook 进程）。\n' >&2
exit 2
