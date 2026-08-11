#!/usr/bin/env bash
# PreToolUse hook (Agent|Task): enforce channel/protocol match for Agent/Task
# dispatch. Passing `name` upgrades a one-shot subagent into a teammate:
# its output stops being the tool's return value and instead must travel
# through the mailbox via an explicit SendMessage(to:"main") call from the
# subagent side (that tool is deferred by default in subagent context and
# needs an explicit `ToolSearch select:SendMessage` first) — miss either
# step and the result is silently lost.
#
# Judgment uses only facts carried by the dispatch call itself — no session or
# team state is inspected. PreToolUse payloads carry no team_name/teammate_name
# (verified empirically), so those are NOT the exemption signal.
#
# Two dispatch shapes, opposite verdicts (claude-config 仓的 issue 173):
#   name + subagent_type in the agents/ roster → team-ops teammate  → exempt
#   name + general-purpose / no subagent_type  → unmanaged teammate → block
#
# Why the roster is the signal, and why session markers are not: team-ops
# mandates spawn BEFORE the first TaskCreate (skills/team-ops/references/
# quality-grade.md:42-43 step 1 TeamCreate, step 2 TaskCreate; orchestrator-
# core.md:53 "第一个动作必须是 TeamCreate + spawn"), while team-lead-marker is
# only written by the TaskCreated hook (task-created.sh:44-51). So at the very
# first teammate spawn the marker is guaranteed absent — not a narrow startup
# window but the protocol's normal order, i.e. the marker is missing exactly
# when the exemption is needed. pre-edit-write.sh:16-17 records the same gap as
# an accepted limitation because it guards file writes, where arriving late is
# harmless; this guard fires precisely at that instant, so it cannot rely on it.
#
# The `agent_id` leg of that same three-state check is dead code here: a Lead is
# the main session (agent_id empty), and a teammate spawning a teammate is
# physically refused upstream ("Teammates cannot spawn other teammates — the
# team roster is flat"). Exempting it would misjudge nothing and rescue nothing.
#
# The roster is resolved by walking the ancestor-directory chain of the
# dispatching cwd (see § Roster resolution below), so a project-level
# `<project>/.claude/agents/<type>.md` is recognized the same as a
# user-level `~/.claude/agents/<type>.md` — hardcoding only the latter
# path misjudges any project that defines its own agent roles.
#
# Empirically confirmed (claude-config 仓的 issue 149): there is no standalone
# `TeamCreate` tool to route teammate spawning through — reverse-engineering
# the CC binary found the string only inside a UI-layer constant pool, never
# as a tool definition. `name` on the Agent tool IS the sole entry point:
# `Agent.call()`'s `if(b&&i&&...)` branch -> `cvd()` -> `Fko()` registers an
# in-process teammate. So this guard isn't steering a bypass of some other
# proper channel — it's flagging a real fork in the road where passing
# `name` has a consequence (mailbox-only output) worth surfacing before it
# happens, which is also why it keeps an escape hatch rather than hard-block.
#
# Coupling with ENABLE_TOOL_SEARCH (claude-config 仓的 issue 164), previously
# implicit and written down nowhere: half of the failure mode above — that
# SendMessage is deferred in subagent context and needs an explicit
# `ToolSearch select:SendMessage` first — only exists while tool-search is on.
# settings.json currently sets ENABLE_TOOL_SEARCH=false, under which
# teammates were empirically observed calling SendMessage directly
# (ToolSearch zero times) and returning text fine. The mailbox-only routing
# of a named dispatch is unaffected either way, so this guard still has a
# job; but if ENABLE_TOOL_SEARCH ever returns to auto:*/true, the deferred-tool
# hazard comes back and the warning gets sharper, not weaker. Do not read the
# current `false` as a reason to relax this guard.
#
# Fail-open: parse errors, missing fields, non-target tool, no name, roster hit.
#
# The two exits offered on rejection are BOTH reachable without the escape
# hatch, and the message must keep them that way: dropping `name` takes the
# one-shot path, and naming a roster subagent_type takes the team-ops path via
# the structural exemption above. There is deliberately no "lightweight AND
# teammate" third option — a task that wants the tool return value simply has no
# business being a teammate — so the hatch is for a misjudgment by THIS gate
# only, never a route for that shape. Wording that presents it as the team-ops
# route (as this message did before the claude-config 仓的 issue 173 exemption
# landed) is what turned it
# into a permanently-on setting in settings.json, killing the gate for months
# and losing three subagent deliverables (claude-config 仓的 issue 164). Hence
# the message states the write-off duty inline.
#
# Escape hatch: set "ALLOW_UNMANAGED_TEAMMATE": "1" in the `env` block of
# ~/.claude/settings.json (hook runs in a process spawned by the CC main
# process; a plain `export` in a Bash tool call in the main session does NOT
# propagate to it). `export` only works as a same-process debugging aid when
# invoking this script directly.
#
# Domain boundary on exit ①: a blank/absent tool_input.name is not this
# gate's domain at all — it belongs to dispatch-sync-guard.sh (this plugin),
# whose judgment is run_in_background:false. See the plugin README for the
# full name-empty/name-non-empty split. What DOES carry over here is a
# forward-pointing instruction, not a description of the other gate's
# internals: dropping `name` to take exit ① means the re-dispatch enters that
# other gate's domain, and must carry run_in_background:false to pass it.
#
# ---------------------------------------------------------------------------
# Roster resolution (ancestor-chain walk)
# ---------------------------------------------------------------------------
# Runtime fact (2.1.223, empirically verified): the roster file for a given
# subagent_type is NOT looked up solely at ~/.claude/agents/<type>.md. The
# resolver walks the ancestor directory chain of the dispatching cwd, and at
# each level checks <D>/.claude/agents/<type>.md — the first hit wins. If
# $HOME is not on that ancestor chain (e.g. dispatching from a path outside
# the home directory), $HOME/.claude/agents/<type>.md is checked separately
# as a final fallback. `.claude` is a hardcoded path component at every level,
# not a variable.
#
# cwd source: the top-level `.cwd` field of the hook payload, NOT $PWD — the
# hook process's own working directory need not match the dispatching
# session's cwd. pre-edit-write.sh (this repo's sibling hook) establishes the
# same convention with `(.cwd // "")`, and its test
# ~/.claude/hooks/tests/test-pre-edit-write-cwd.sh specifically covers the
# "hook process PWD differs from payload.cwd" scenario. `.cwd` missing or
# blank falls back to $PWD.
#
# gate_preamble only extracts fields under .tool_input — cwd lives at the
# payload's top level, so it is pulled directly from $GATE_INPUT (the raw
# payload gate_preamble stashes there) rather than added to gate_preamble's
# field list.

set -euo pipefail

. "${BASH_SOURCE[0]%/*}/lib/gate.sh"
gate_preamble dispatch-channel-guard ALLOW_UNMANAGED_TEAMMATE name subagent_type || exit 0

[ -z "$name" ] && exit 0
[[ "$name" =~ ^[[:space:]]*$ ]] && exit 0

# Structural exemption: subagent_type names a role in the agents/ roster,
# resolved by walking the ancestor-directory chain of the dispatching cwd.
# Charset check first — subagent_type reaches us as untrusted input and is
# interpolated into a path, so anything with `/` or `..` must never get there.
if [ -n "$subagent_type" ] \
   && [[ "$subagent_type" =~ ^[A-Za-z0-9][-A-Za-z0-9_]{0,31}$ ]]; then

  PAYLOAD_CWD=$(jq -r '.cwd // empty' <<<"$GATE_INPUT" 2>/dev/null || true)
  [ -z "$PAYLOAD_CWD" ] && PAYLOAD_CWD="$PWD"

  ROSTER_HIT=""
  D="$PAYLOAD_CWD"
  while :; do
    if [ -f "${D}/.claude/agents/${subagent_type}.md" ]; then
      ROSTER_HIT="1"
      break
    fi
    PARENT="$(dirname -- "$D")"
    [ "$PARENT" = "$D" ] && break   # reached the filesystem root
    D="$PARENT"
  done

  # $HOME fallback only when it is not already on the ancestor chain just
  # walked above (avoids a redundant second stat when it is).
  if [ -z "$ROSTER_HIT" ] && [ -n "${HOME:-}" ]; then
    case "$PAYLOAD_CWD" in
      "$HOME"|"$HOME"/*) ;;  # already covered by the walk above
      *)
        [ -f "${HOME}/.claude/agents/${subagent_type}.md" ] && ROSTER_HIT="1"
        ;;
    esac
  fi

  [ -n "$ROSTER_HIT" ] && exit 0
fi

printf '[dispatch-channel-guard] name="%s" 把一次性 subagent 提升为 teammate，产物改走 mailbox，需子 agent 显式 SendMessage(to:"main") 回传，漏发即静默丢失。背景见 skills/subagent-dispatch/references/mailbox-liveness.md。\n' "$name" >&2
printf '[dispatch-channel-guard] 两条出路，按任务性质二选一：① 轻量一次性任务——去掉 name 重派，产物走工具返回值（可靠）；注意去掉 name 后 dispatch-sync-guard 的 name 豁免同时失效，该次派发需显式带 run_in_background:false。② 确需常驻多轮协作——按 team-ops 协议起 teammate，subagent_type 取 agents/ 名册内角色（dev/ops/pm/redteam/worker），本门禁结构性放行，不需要设任何 env。中间不设第三档。\n' >&2
printf '[dispatch-channel-guard] mailbox 到达时刻绑定派发方空闲：SendMessage 不是即时投递，派发方主循环有工具在飞时消息会积压，直到派发方停下来才 flush，实测积压约 5 分钟且时长不可预测。teammate 通道因此不适合"拿到产物才能往下走"的同步决策——延迟到决策点之后等价于丢失；需要即时产物就走出路①。\n' >&2
printf '[dispatch-channel-guard] 逃生舱只用于本门禁误判，不是「既要轻量又要 teammate」的第三条路——那种任务属出路①，去掉 name 即可：在 ~/.claude/settings.json 的 env 段设置 "ALLOW_UNMANAGED_TEAMMATE": "1"，临时开启后须销账关闭（历史上它被长期常开致本门禁全局失效、丢失三份 subagent 产物，claude-config 仓的 issue 164）。Bash 内 export 对 hook 进程不生效，仅可作直接调用本脚本时的同进程调试用。\n' >&2
exit 2
