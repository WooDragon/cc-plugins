# dispatch-contract

Subagent dispatch contract enforcement for Claude Code — a `%%DONE%%` finalization gate plus a methodology skill for reliable subagent delegation.

The plugin has four parts: a **PreToolUse hook** that blocks dispatch calls omitting `run_in_background:false`, a **SubagentStart hook** that injects the dispatch rules into every spawned subagent, a **SubagentStop hook** that enforces the `%%DONE%%` finalization marker when it is declared in the dispatch prompt, and a **`subagent-dispatch` skill** that inlines the four dispatch rules, offload-scenario guidance, and background-subagent patterns on demand.

## Installation

```bash
# From marketplace
claude plugin add dispatch-contract@WooDragon-cc-plugins
```

## Architecture

```
PreToolUse (matcher: Agent, Task)
  │
  └─ dispatch-sync-guard.sh (5s timeout)
         Blocks a dispatch call that omits run_in_background:false.
         Omission selects the background delivery channel, and that channel
         drops completion notifications at a measured 92.7% loss rate with
         no resend path. Passes silently (fail-open) on teammate context
         (agent_id present), Lead-starts-a-teammate calls (tool_input.name
         present), the CLAUDE_CODE_DISABLE_BACKGROUND_TASKS env var, and any
         malformed or missing payload field.

SubagentStart (matcher: *)
  │
  └─ dispatch-rules-inject.sh (5s timeout)
         Injects the three dispatch rules — output-is-deliverable, scope
         fence, incremental progress — into the spawned subagent's own
         context via additionalContext, regardless of whether the dispatch
         prompt stated them. Read-only agent types (Explore, Plan) receive
         only the output-is-deliverable and incremental-progress rules; the
         scope-fence rule is a no-op for agent types whose Edit/Write tools
         are already disabled by the platform.

SubagentStop (matcher: *)
  │
  └─ subagent-done-gate.sh (10s timeout)
         Checks whether the dispatch prompt contained %%DONE%%.
         If yes: verifies the subagent's final non-empty line equals %%DONE%% exactly.
         Mismatch → deny once, inject correction directive asking for a complete
         report ending with %%DONE%%.  Blocks at most once per subagent:
         the resumed stop carries stop_hook_active=true and passes unconditionally.
         If no: silent pass-through (fail-open).

skills/subagent-dispatch  (no hook — loaded by description match)
         Auto-loads when the conversation turns to subagent dispatch, so the
         contract is reachable at dispatch time rather than only after a block.
```

This plugin registers three hooks: `PreToolUse` (dispatch-sync-guard),
`SubagentStart` (dispatch-rules-inject), and `SubagentStop` (subagent-done-gate).
There is no dispatch-side hook that guesses whether a given task needs a
`%%DONE%%` deliverable — that judgment is semantic, and a keyword guess would
misfire often enough to be ignored. The skill closes that gap instead.

## The `%%DONE%%` Contract

Declare the contract per task, not per role. When a dispatch prompt requires a finalized deliverable, append a line asking for the marker — at minimum:

> 末尾单独一行输出 `%%DONE%%`。

The gate enforces only that marker line. What else a finalized report must contain is a
convention rather than something a hook can check, so the canonical wording — which also
asks for a verification matrix and an unfinished-items section — lives in one place:
the `定稿标记` section of `skills/subagent-dispatch/SKILL.md`. Copy it from there rather
than from this README, which shows only the gate-enforced minimum.

The subagent's final non-empty line must then be exactly `%%DONE%%` — not contain it, but equal it. If the check fails, the gate blocks the SubagentStop event and sends a correction directive back into the subagent, asking it to complete the report and end with the marker.

**It blocks at most once.** The resumed stop arrives with `stop_hook_active=true`, and the gate passes it unconditionally without re-checking. A subagent that still omits the marker on its second attempt is let through rather than looped — an unbounded retry loop on a subagent that cannot satisfy the check would be worse than an unmarked report.

**Tolerances**: leading/trailing whitespace and CRLF line endings are stripped before comparison, so `  %%DONE%%\r\n` passes.

**Intolerance**: any Markdown decoration fails — `**%%DONE%%**`, `` `%%DONE%%` ``, `- %%DONE%%`, `%%DONE%%.` are all rejected. The marker must arrive as a bare line.

**Do not attach the marker** when the task has no deliverable — pure Q&A, read-only scouting, or status checks should omit it. Overuse causes spurious blocks on tasks that naturally end with an explanation.

**File-deliverable variant**: the marker is not exclusive to the final message — it also marks the terminal line of a *file* deliverable. When a dispatch expects a subagent to land a file (not just report), the recommended pattern is: the subagent appends content to a `.wip` sidecar ending in a bare `%%DONE%%` line, then calls `scripts/promote-wip.sh <target_path>` (project-relative to `~/.claude`, no team-ops dependency) to validate the terminal marker, strip it, and atomically promote the sidecar to the real target path. Seeing the marker in both the file and the final message on the same task is expected, not duplication — the file's copy is stripped by `promote-wip.sh` and never reaches the promoted artifact; the final message's copy is what this gate checks, and it never reads the file. Full guidance lives in the `定稿标记` section referenced above.

## Fail-Open Behavior

The gate is fail-open by design. It passes silently when:

- The dispatch prompt does not contain `%%DONE%%` — no marker declared, no enforcement.
- Required fields are missing from the hook payload.
- `jq` is not available on the system.
- The transcript file is unreadable or malformed.

The only active enforcement path is: dispatch prompt contains `%%DONE%%` AND subagent final non-empty line does not equal `%%DONE%%`.

## Escape Hatch

```bash
export ALLOW_UNMARKED_FINAL=1
```

Set this before starting the Claude Code session to disable the gate globally. Useful when debugging hook behavior or when a subagent legitimately cannot produce the marker.

## Known Boundaries

- The gate only fires at `SubagentStop` — it has no visibility into intermediate tool calls or messages the subagent sends before stopping.
- If the dispatch prompt contains `%%DONE%%` anywhere (even in a negated or illustrative context), the gate activates. Misfire direction is one extra block, which self-heals because the retry passes unconditionally.
- The gate blocks at most once per subagent. If the corrected output still misses the marker, it is let through — the gate does not loop.

## The Background-Dispatch Sync Guard

`dispatch-sync-guard.sh` runs on `PreToolUse` for `Agent` and `Task` calls. It reads
only the fields carried by the dispatch call itself — never session state or prior
turns — and applies this decision chain, each step fail-opening before the next runs:

1. Empty stdin → pass.
2. `jq` unavailable → pass.
3. `jq .` fails to parse the payload → pass.
4. `ALLOW_BACKGROUND_DISPATCH=1` → pass (escape hatch).
5. `tool_name` is not `Agent` or `Task` → pass.
6. `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS` is set → pass.
7. `agent_id` is present and non-blank → pass (teammate context).
8. `tool_input.name` is present and non-blank → pass (Lead starting a teammate).
9. `tool_input.run_in_background` is the JSON boolean `false` → pass.
9b. `run_in_background` field absent → block (exit 2), fork-aware stderr (4 lines).
10. Otherwise (field present but not `false`, e.g. `true` or a non-boolean) →
    block (exit 2), generic stderr (3 lines).

Step 6 checks whether `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS` is set, not whether
`run_in_background` is present, because Agent's own input schema omits the
`run_in_background` field entirely when this variable is truthy — every dispatch is
synchronous by construction in that mode, and judging the omission as a violation
would misfire on every call.

Step 7 distinguishes a genuinely-absent `agent_id` field from a field that is present
but blank, using the same field-presence check pattern as `subagent-done-gate.sh`'s
handling of `last_assistant_message`. The distinction matters because a teammate
context is physically forbidden from requesting background dispatch by the runtime
itself; when `agent_id` is present, background dispatch was never going to happen
regardless of this hook, so blocking it would be a false positive.

Step 8 is load-bearing for team-ops: a non-empty `tool_input.name` is the only entry
point for starting a teammate. Removing this step would block Lead from starting any
teammate.

**Fork world (step 9b)**: the Agent input schema also drops `run_in_background`
entirely when the `fork-subagent` feature (server-side rollout flag, internally named
`tengu_copper_fox`) is active, independent of `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`.
In that mode the runtime forces every dispatch onto the background channel — it does
not remove the channel, it removes the ability to opt out of it. The hook detects this
state structurally, from field absence combined with step 6's env var being unset, and
blocks (exit 2) with a fork-aware stderr message rather than passing — the message
leads with the generic "you probably just forgot the field" advice first, then covers
the fork-world case as the second, less common possibility. The fix is
`CLAUDE_CODE_FORK_SUBAGENT=0` in `settings.json`'s `env` section, which restarts Claude
Code with the fork feature off, restores `run_in_background` to the schema, and makes
synchronous dispatch requestable again. `ALLOW_BACKGROUND_DISPATCH=1` does not fix this
case — it silences the guard everywhere, including runtimes where the background
channel is real and the guard is protecting against an actual notification-loss risk.

## The SubagentStart Rules Injector

`dispatch-rules-inject.sh` runs on `SubagentStart` for every spawned subagent
(`matcher: "*"`). It writes `additionalContext` carrying the three dispatch rules
(output-is-deliverable, scope fence, incremental progress) plus a pointer to the
`subagent-dispatch` skill, so the rules reach the subagent even when the dispatching
prompt omitted them.

Agent types with Edit/Write disabled by the platform (`Explore`, `Plan`, matched
case-insensitively) receive only the output-is-deliverable and incremental-progress
rules — the scope-fence rule's file-boundary wording would be a no-op reminder for a
type that cannot write files at all.

The hook writes stdout exactly once, in a single statement at the end of the script.
Every fail-open path (empty stdin, no `jq`, unparsable JSON,
`ALLOW_NO_RULES_INJECT=1`) exits before that statement with no stdout output at all —
a half-formed JSON payload on stdout would corrupt the harness's parse of the hook
output, so an empty stdout is the safe default on any early exit.

## `subagent-dispatch` Skill

The bundled skill covers:

| Topic | Reference |
|-------|-----------|
| Four dispatch rules with positive/negative examples | `references/dispatch-contract.md` |
| When to offload and which model tier to use | `references/offload-scenarios.md` |
| Background subagent product retrieval, liveness, TaskStop timing | `references/mailbox-liveness.md` |
| Workflow `agent()` for strongly-typed structured outputs | `references/workflow-schema.md` |

The skill triggers on dispatch-related requests: "派发 subagent", "dispatch subagent", "delegate to agent", "offload", "%%DONE%%", and related terms. It does not use a hook — code dispatch has no deterministic tool-level signal, so the skill loads by description-match instead.

## Running Tests

```bash
# Requires bats-core
bats plugins/dispatch-contract/tests/subagent-done-gate.bats
bats plugins/dispatch-contract/tests/dispatch-sync-guard.bats
```

`subagent-done-gate.bats` has 26 test cases covering: core judgment (marker
required/not required in the dispatch prompt), `fork-context-ref` transcript shape,
in-band signaling defence (a subagent cannot open its own gate), whitespace and CRLF
tolerance, decoration variants that must still block (bold, backticks, trailing
punctuation), blank final message treated as an empty deliverable rather than
fail-open, fail-open paths (missing fields, `last_assistant_message` null, invalid
JSON, empty stdin, absent transcript path, `stop_hook_active`), hostile paths (`HOME`
unset, FIFO must not hang), and the kill switch.

`dispatch-sync-guard.bats` covers both new hooks: the sync-guard's pass/block matrix
(explicit `false`, omission, explicit `true`, string `"false"`, `tool_name` outside
`{Agent, Task}`, the `agent_id` and `tool_input.name` exemptions including an
empty-string `agent_id` that must still block, the two escape hatches, and three
malformed-stdin shapes), plus the rules-injector's JSON-shape checks (normal
`agent_type` gets all three rules, `Explore` omits the scope-fence rule, empty stdin
and `ALLOW_NO_RULES_INJECT=1` both leave stdout fully empty).

## Block Response Shape (Deliberate Choice)

Both hooks in this plugin — `dispatch-sync-guard.sh` (PreToolUse) and
`subagent-done-gate.sh` (SubagentStop) — block via `exit 2` plus a stderr
message. Some sibling plugins in this repo use a different shape instead:
`plan-review`'s `dispatch-check.sh` and `doc-gate`'s `skill-gate.sh` return
JSON `permissionDecision: deny`. This repo does not use one block-response
shape across all plugins — `guardrails`' `git-push-guard.sh` also blocks via
`exit 2`. Within this plugin, consistency with the sibling
`subagent-done-gate.sh` hook takes priority over matching an unrelated
plugin's shape. The two forms are functionally equivalent here. The runtime
routes the `exit 2` stderr text through `blockingError` into the tool result
the model sees. The correction message reaches model context either way.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ALLOW_UNMARKED_FINAL` | _(unset)_ | `1` disables the `%%DONE%%` finalization gate entirely |
| `ALLOW_BACKGROUND_DISPATCH` | _(unset)_ | `1` disables the background-dispatch sync guard entirely — set in `settings.json`'s `env` section, since `export` in a Bash tool call does not reach the hook process |
| `ALLOW_NO_RULES_INJECT` | _(unset)_ | `1` disables the SubagentStart rules injector entirely |
| `CLAUDE_CODE_FORK_SUBAGENT` | _(unset)_ | `0` disables the fork-subagent feature — restores `run_in_background` to the Agent input schema, the correct fix for step 9b's fork-world block |
