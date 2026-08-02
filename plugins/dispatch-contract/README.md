# dispatch-contract

Subagent dispatch contract enforcement for Claude Code — a `%%DONE%%` finalization gate plus a methodology skill for reliable subagent delegation.

The plugin has two parts: a **SubagentStop hook** that enforces the `%%DONE%%` finalization marker when it is declared in the dispatch prompt, and a **`subagent-dispatch` skill** that inlines the four dispatch rules, offload-scenario guidance, and background-subagent patterns on demand.

## Installation

```bash
# From marketplace
claude plugin add dispatch-contract@WooDragon-cc-plugins
```

## Architecture

```
SubagentStop
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

This plugin registers exactly one hook, on `SubagentStop`. There is no dispatch-side
hook: deciding whether a given task needs a deliverable is a semantic judgment, and a
keyword guess would misfire often enough to be ignored. The skill closes that gap
instead.

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
```

26 test cases covering: core judgment (marker required/not required in the dispatch prompt), `fork-context-ref` transcript shape, in-band signaling defence (a subagent cannot open its own gate), whitespace and CRLF tolerance, decoration variants that must still block (bold, backticks, trailing punctuation), blank final message treated as an empty deliverable rather than fail-open, fail-open paths (missing fields, `last_assistant_message` null, invalid JSON, empty stdin, absent transcript path, `stop_hook_active`), hostile paths (`HOME` unset, FIFO must not hang), and the kill switch.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ALLOW_UNMARKED_FINAL` | _(unset)_ | `1` disables the gate entirely |
