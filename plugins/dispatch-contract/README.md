# dispatch-contract

Subagent dispatch contract enforcement for Claude Code — a `%%DONE%%` finalization gate plus a methodology skill for reliable subagent delegation.

## Version 1.6.0: Breaking Model Contract

Version 1.6.0 makes caller-side `model` ownership explicit. Runtime-owned built-ins must carry a non-empty `model` in an `Agent` or `Task` call. Registered agents must omit `model`; `model: null` is equivalent to omission and preserves the agent frontmatter preset. Any other registered-agent model value is rejected because it overrides that preset. This is a breaking contract for callers that previously supplied a model for a registered agent.

The plugin has seven parts: four **PreToolUse hooks** — one blocks dispatch calls omitting `run_in_background:false`, one enforces model ownership, one blocks dispatch calls whose `subagent_type`/`model` cannot deliver what the prompt asks for, and one blocks a `name`-carrying dispatch (upgrading a one-shot subagent to a teammate) whose `subagent_type` is not a recognized team-ops role — a **SubagentStart hook** that injects the dispatch rules into every spawned subagent, a **SubagentStop hook** that enforces the `%%DONE%%` finalization marker when it is declared in the dispatch prompt, and a **`subagent-dispatch` skill** that inlines the four dispatch rules, offload-scenario guidance, and background-subagent patterns on demand.

## Installation

```bash
# From marketplace
claude plugin add dispatch-contract@WooDragon-cc-plugins
```

## Architecture

```
PreToolUse (matcher: Agent, Task)
  │
  ├─ dispatch-sync-guard.sh (5s timeout)
  │      Blocks a dispatch call that omits run_in_background:false.
  │      Omission selects the background delivery channel, so the product
  │      depends on the completion notification queue; a synchronous dispatch
  │      returns it in the tool_result and never enters that queue.
  │      Passes silently (fail-open) on teammate context
  │      (agent_id present), Lead-starts-a-teammate calls (tool_input.name
  │      present), the CLAUDE_CODE_DISABLE_BACKGROUND_TASKS env var, the
  │      CLAUDE_AUTO_BACKGROUND_TASKS env var handled by its own dedicated
  │      block (see below), and any malformed or missing payload field.
  │
  ├─ dispatch-capability-guard.sh (5s timeout)
  │      Blocks a dispatch call whose subagent_type/model cannot deliver
  │      what the prompt itself asks for — a read-only declaration sent to
  │      a full-privilege agent, or a write/exec-needing task sent to a
  │      read-only agent type or the haiku model tier. See "The Dispatch
  │      Capability Guard" below for the full judgment matrix.
  │
  └─ pre-dispatch-channel-guard.sh (5s timeout)
         Blocks a dispatch call that carries a non-blank tool_input.name
         (upgrading a one-shot subagent to a teammate) whose subagent_type
         does not resolve to a role file in the agents/ roster. Judges only
         the domain dispatch-sync-guard.sh does NOT: a blank/absent name is
         entirely out of scope for this hook and falls straight through —
         see § Two-Domain Split below.

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
         If yes: verifies the subagent's final non-empty line equals %%DONE%% exactly,
         and that the message carries at least one other non-blank line — a message
         consisting of nothing but the marker is an empty delivery, not a report.
         Mismatch → deny once, inject correction directive asking for a complete
         report ending with %%DONE%%.  Blocks at most once per subagent:
         the resumed stop carries stop_hook_active=true and passes unconditionally.
         If no: silent pass-through (fail-open).

skills/subagent-dispatch  (no hook — loaded by description match)
         Auto-loads when the conversation turns to subagent dispatch, so the
         contract is reachable at dispatch time rather than only after a block.
```

This plugin registers six hooks: `PreToolUse` (dispatch-sync-guard,
dispatch-agent-ownership-guard, dispatch-capability-guard,
pre-dispatch-channel-guard), `SubagentStart` (dispatch-rules-inject), and
`SubagentStop` (subagent-done-gate).
There is no dispatch-side hook that guesses whether a given task needs a
`%%DONE%%` deliverable — that judgment is semantic, and a keyword guess would
misfire often enough to be ignored. The skill closes that gap instead.

## The `%%DONE%%` Contract

Declare the contract per task, not per role. When a dispatch prompt requires a finalized
deliverable, append the canonical marker line, copied verbatim from the `定稿标记` section of
`skills/subagent-dispatch/SKILL.md`. That line carries both halves of the ask: give the full
report, *then* end with the marker.

This README deliberately shows no shortened version. A format-only paraphrase such as
`末尾单独一行输出 %%DONE%%。` drops the report half and reads literally as "output nothing but
the marker" — the exact failure the gate now rejects.

The gate has two branches, split on whether the marker arrived at all.

**Marker present** — the last non-blank line equals `%%DONE%%` exactly (not merely contains
it). The subagent has asserted it is finished, and the gate takes that assertion at face value
with one exception: if the marker is the *only* non-blank line, the assertion is literally
empty — zero report — and it is rejected with its own directive. The test is structural (is
there any other non-blank line), so it inspects no wording and maintains no keyword list. A
short-but-real report such as `APPROVED. 无发现。` followed by the marker passes; brevity is
not the offense.

**Marker absent** — the gate blocks only when the body is under `DONE_GATE_BODY_FLOOR` bytes
(default 500). Above the floor it passes and emits a `systemMessage` warning instead.

That asymmetry is deliberate, and it is the fix for
[#183](https://github.com/WooDragon/cc-plugins/issues/183). `SubagentStop` has no ability to
rewrite a final message; exit 2 only *prevents the subagent from stopping*, which forces it to
write another message — and the harness hands the dispatcher the **last** assistant message.
So every block is a wager: if the subagent answers with anything shorter than what it already
wrote, the finished report is silently overwritten.

Measured across 4,761 local subagent transcripts (489 before/after pairs at a block):

| Size of the blocked message | Collapsed (<0.3x) | Healthy rewrite (>1.0x) |
|---|---|---|
| < 800 B | 11 (5%) | 161 (74%) |
| >= 3000 B | 59 (40%) | 37 (25%) |

Blocking a large message is where the damage is. And the thing this contract exists to catch —
`Sent.`, `Done. Report sent to team-lead`, `已完成，详见文件` — is always small. Stratified
sampling of the same corpus: 0-200 B is entirely status notes; 200-500 B is still dominated by
meta-summaries; real deliverables start appearing at 500-900 B; everything above 900 B is a
genuine report. Hence the 500-byte floor.

Both directions of floor error are benign. Too low degrades toward no enforcement — it never
destroys a product. Too high blocks only small reports, where the measured outcome is 74%
healthy rewrite and 5% collapse, and where the block message **echoes the blocked body back
verbatim** so the retry is a copy rather than a feat of memory. That echo is affordable
precisely because it only ever fires below the floor.

**It blocks at most once.** The resumed stop arrives with `stop_hook_active=true`, and the gate passes it unconditionally without re-checking. A subagent that still omits the marker on its second attempt is let through rather than looped — an unbounded retry loop on a subagent that cannot satisfy the check would be worse than an unmarked report.

**Tolerances**: leading/trailing whitespace and CRLF line endings are stripped before comparison, so `  %%DONE%%\r\n` passes.

**Intolerance**: any Markdown decoration fails — `**%%DONE%%**`, `` `%%DONE%%` ``, `- %%DONE%%`, `%%DONE%%.` are all rejected. The marker must arrive as a bare line.

**Do not attach the marker** when the task has no deliverable — pure Q&A, read-only scouting, or status checks should omit it. Overuse causes spurious blocks on tasks that naturally end with an explanation.

**File-deliverable variant**: the marker is not exclusive to the final message — it also marks the terminal line of a *file* deliverable. When a dispatch expects a subagent to land a file (not just report), the recommended pattern is: the subagent appends content to a `.wip` sidecar ending in a bare `%%DONE%%` line, then calls `~/.claude/scripts/promote-wip.sh <target_path>` to validate the terminal marker, strip it, and atomically promote the sidecar to the real target path. Seeing the marker in both the file and the final message on the same task is expected, not duplication — the file's copy is stripped by `promote-wip.sh` and never reaches the promoted artifact; the final message's copy is what this gate checks, and it never reads the file. Full guidance lives in the `定稿标记` section referenced above.

## Fail-Open Behavior

The gate is fail-open by design. It passes silently when:

- The dispatch prompt does not contain `%%DONE%%` — no marker declared, no enforcement.
- Required fields are missing from the hook payload.
- `jq` is not available on the system.
- The transcript file is unreadable or malformed.

There are two active enforcement paths, both requiring the dispatch prompt to contain
`%%DONE%%`: the final message's last non-empty line equals `%%DONE%%` but no other non-empty
line exists (empty assertion), or it does not equal `%%DONE%%` and the body is below
`DONE_GATE_BODY_FLOOR`. Anything else passes — including a marker-less message whose body
clears the floor, which passes with a warning rather than a block.

## Escape Hatch

```bash
export ALLOW_UNMARKED_FINAL=1
```

Set this before starting the Claude Code session to disable the gate globally. Useful when debugging hook behavior or when a subagent legitimately cannot produce the marker.

## Known Boundaries

- The gate only fires at `SubagentStop` — it has no visibility into intermediate tool calls or messages the subagent sends before stopping.
- If the dispatch prompt contains `%%DONE%%` anywhere (even in a negated or illustrative context), the gate activates. Misfire direction is one extra block, which self-heals because the retry passes unconditionally.
- The gate blocks at most once per subagent. If the corrected output still misses the marker, it is let through — the gate does not loop.
- A long final message that is missing the marker is **not** blocked — it passes with a `systemMessage` warning. The marker's absence is reported, not enforced, because enforcing it costs the product 40% of the time. Terminator discipline above the floor is convention, backed by the SubagentStart rules injection rather than by a block.
- The gate reads only the dispatcher-written line(s) of the transcript to decide whether the marker was required, and filters out `attachment` records first — the SubagentStart injector's own text mentions `%%DONE%%`, and without that filter a change in record ordering would make every subagent look like it had been asked for a marker.

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
8. `tool_input.name` is present and non-blank → pass (Lead starting a teammate;
   whether that teammate spawn itself is legitimate is
   pre-dispatch-channel-guard.sh's domain, not this hook's — see
   § Two-Domain Split below).
8b. `CLAUDE_AUTO_BACKGROUND_TASKS` is set (truthy) → block (exit 2). Checked
    after steps 7/8's exemptions (those two shapes deliver through the
    mailbox and are unaffected by auto-backgrounding) and before step 9
    (the very check this variable defeats).
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

Step 8b (`CLAUDE_AUTO_BACKGROUND_TASKS`) exists because a passing step 9 check does
not actually guarantee synchronous delivery when this variable is truthy: the
runtime's synchronous branch sets `autoBackgroundMs: U ? void 0 : oEb() || void 0`,
and `oEb()` returns `120000` under this variable — a synchronous agent still auto-flips
to the background channel after running past 120 seconds. Adding `run_in_background:false`
does not fix this; the only fix is clearing the variable.

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

## The Dispatch Agent Ownership Guard

`dispatch-agent-ownership-guard.sh` runs independently on `PreToolUse` for
`Agent` and `Task`. It fails open with `[GATE-DEGRADE]` when it cannot parse
its judgment data. It exits 2 only for a semantic ownership violation. The
three ownership predicates (runtime-owned / model-optional / everything else
counts as registered) have a single source of truth in
`hooks/lib/agent-kind.sh`; do not copy its type list into another hook or
document. Read
`skills/subagent-dispatch/references/dispatch-contract.md` before changing the
policy, the caller-side model field, or its escape hatch.

The guard has three repairs. Add a non-empty runtime model for a runtime-owned
built-in. For a model-optional built-in, omit `model` or use `null` to follow the
parent session, or provide a valid model name. For a registered-agent call,
remove `model`. Empty and whitespace-only values remain invalid for
model-optional built-ins. If the registered agent cannot do the work, select
another role instead of overriding its model.

## The Dispatch Capability Guard

`dispatch-capability-guard.sh` also runs on `PreToolUse` for `Agent` and `Task`
calls, alongside `dispatch-sync-guard.sh`. Where the sync guard treats the
*delivery channel* (background vs. synchronous), this hook treats *capability
mismatch* — whether the `subagent_type`/`model` a dispatch call names can
actually deliver what its own prompt asks for.

It extracts four signals from the prompt text (and the `model` field):

- **EXEC** — exec intent (run tests/scripts/build/lint). A bare-keyword match
  (migrated verbatim from the user's local `pre-dispatch-readonly-guard.sh`,
  where the same word list was used as an *exemption* — widening it only ever
  widened the pass set, harmless in that direction) is required to sit in an
  imperative/delegation clause; it is demoted back to a non-hit when the
  clause containing the match instead governs a research-frame or negated
  object (`查一下跑测试的脚本在哪`, `分析为什么不要跑测试`, `find where we
  document how to run the tests`) — reusing the same bare list as a
  *rejection* signal flips its safety direction, so false positives there
  now have a real cost.
- **WRITE** — write intent, anchored on a write verb adjacent to a code
  object or a path-shaped token (a bare write verb alone, e.g. 创建一份调研报告,
  is not collected — that produces a report, not code). The English object
  list includes bare defect nouns `bug|bugs|issue|issues|error|errors` so
  that `fix the bug in auth` — no file/code/test noun, only a defect noun —
  still counts as a write object; the Chinese-side object list separately
  gained the same tokens (`bug|issue|error`) since 中文句子里 `bug` 常年以英文
  原词出现且这两条 token 各自独立命中，互不覆盖.
- **RO** — an explicit read-only declaration
- **NEG** — an absolute negation of writing (e.g. 不要修改任何文件)

These fold into one derived predicate:

```
NEEDS_CAP = (EXEC || WRITE) && !RO && !NEG
```

Three independent judgments fire off this signal set, each printing its own
stderr message before a single trailing `exit 2`:

- **Judgment A** (originally migrated verbatim from the user's local
  `pre-dispatch-readonly-guard.sh`; condition since **widened** from `!EXEC`
  alone to `!EXEC && !WRITE_HIT_A`): `!EXEC && !WRITE_HIT_A && (RO || NEG) &&
  subagent_type ∈ {general-purpose, claude}` → block. A read-only declaration
  (or absolute negation) sent to a full-privilege agent, provided the same
  prompt carries no write intent either — Explore's Edit/Write/NotebookEdit
  are physically disabled and would catch the same scope even if the
  declaration were wrong. Fix: redispatch to `Explore`.
- **Judgment B** (new): `NEEDS_CAP && subagent_type ∈ {explore, plan}` →
  block. The task needs write/exec capability, but Explore/Plan have
  Edit/Write/NotebookEdit disabled and Bash limited to a read-only whitelist
  — the dispatch would dead-end after a full round trip. Fix: redispatch to
  `general-purpose` or `dev` (team-ops).
- **Judgment C** (new): `NEEDS_CAP && runtime-owned type && explicit model`
  contains the substring `haiku` (matched as a substring because real values
  look like `claude-haiku-4-5-20251001`, never the bare word) → block.
  Registered agents are outside C because their frontmatter owns model
  selection. Interpreting
  run/test/build output well enough to decide what to do next is a
  judgment-forming action the daily model-tiering rubric excludes from the
  haiku tier. Fix: if the next step is pinned mechanical delivery, redispatch
  to `dev-econ`/`worker-econ` and omit `model` so the registered agent's
  frontmatter carries haiku+effort:max; if the next step still carries an
  unpinned tradeoff, redispatch to `dev`/`worker` and omit `model`; or raise
  the runtime-owned built-in's `model` to `sonnet`.

**Why A's condition had to widen**: the original `pre-dispatch-readonly-guard.sh`
had no WRITE signal at all, so `!EXEC` meant "this task needs nothing beyond
read-only" in that world. Once WRITE was introduced to this hook, a mixed
prompt like `只读查看现有实现，然后修复 main.py` hit `!EXEC` (true) and `RO`
(true) and `WRITE` (true) at the same time. Under the old `!EXEC`-only
condition, A fired and told the caller to redispatch to `Explore` — but
Explore's Edit/Write is physically disabled, so the redispatch could not do
what the prompt asked. That was a dead end the gate itself manufactured, not
a legitimate rejection. Adding `!WRITE_HIT_A` closes it: a prompt carrying
write intent is no longer routed toward an agent that cannot write, regardless
of what RO/NEG also say in the same prompt. `WRITE_HIT_A` is judgment A's own
NEG-scrubbed variant of the WRITE signal (judgment B still uses the raw
`WRITE_HIT`) — without the scrub, a genuine absolute-negation declaration like
`不得不改测试，不修改任何文件` would stop triggering A, because a
write-looking substring sits inside its own already-negated clause.

**Deliberately accepted miss (judgment B's, not A's)**: a mixed prompt like
`调研根因并修复` dispatched straight to `subagent_type=explore` still passes,
because `NEEDS_CAP` folds to 0 whenever `RO_HIT` is 1. This is the same
under-block that existed before this patch too — today's behavior for such
prompts is already "pass", so leaving it is a no-op, not a regression — and it
must not be confused with A's now-fixed dead end above: A's old problem was
that the gate *actively rejected* and then pointed the caller at an agent that
physically could not comply; B's miss is merely passive under-coverage — the
dispatch goes through unexamined, exactly today's baseline. Tightening
`NEEDS_CAP` to ignore RO for mixed prompts was rejected as the fix here too,
for the same over-privilege reason given below.

**Fail-open paths**: empty stdin, missing `jq`, non-JSON payload, or an empty
prompt field all exit 0 silently — except empty stdin and missing `jq`, which
first write `[GATE-DEGRADE]` to stderr (`empty stdin` / `jq unavailable`) so a
grep for gate breakage can find them; the two paths were previously silent
`exit 0` with no stderr trace at all.

**Escape hatch**: `ALLOW_DISPATCH_CAPABILITY_MISMATCH=1` in the `env` block of
`settings.json` (a plain Bash `export` does not reach this hook's process).

**Logging**: unlike this plugin's other hooks, which fail open silently, this
hook writes one of two distinct stderr tags depending on why a check did not
run: `[GATE-BYPASS]` when the escape hatch is open (a human deliberately
disabled the check — not a malfunction), checked first so an open hatch is
never mistaken for broken judgment data; `[GATE-DEGRADE]` when the judgment
data itself could not be read (empty stdin, missing `jq`, malformed JSON).
Collapsing the two into one silent fail-open, as this plugin's sibling hooks
do, would make a grep for real breakage indistinguishable from a session that
simply has the hatch on.

## Two-Domain Split: Sync Guard vs Channel Guard

Both hooks fire on the same `PreToolUse(Agent|Task)` event and inspect the same
`tool_input.name` field, so their input space is split by that one field into two
domains that are disjoint and jointly exhaustive:

| `tool_input.name` | Owning gate | Judgment |
|---|---|---|
| Blank or absent | `dispatch-sync-guard.sh` | Is `run_in_background:false` present? |
| Non-blank | `pre-dispatch-channel-guard.sh` | Does `subagent_type` resolve to a role in the `agents/` roster? |

Each hook exits 0 immediately on the domain it does not own, without inspecting or
describing the other hook's internal judgment — the only thing that crosses the
boundary is a forward-pointing instruction: dropping `name` to escape the channel
guard moves the dispatch into the sync guard's domain, so the re-dispatch must carry
`run_in_background:false` or it simply trades one gate's block for the other's.

## The Dispatch Channel Guard

`pre-dispatch-channel-guard.sh` runs on `PreToolUse` for `Agent` and `Task` calls,
immediately after `dispatch-sync-guard.sh`. It owns the non-blank-`name` domain
described above: passing `name` upgrades a one-shot subagent into a teammate, whose
output then travels through the mailbox (an explicit `SendMessage(to:"main")` from
the subagent side) rather than the tool's return value — miss that step and the
result is silently lost.

Decision chain, each step fail-opening before the next runs. `gate_preamble` checks
the escape hatch before the degrade conditions — a human deliberately opening the
door must not be reported as a malfunction, so `[GATE-BYPASS]` is checked ahead of
`[GATE-DEGRADE]`, not after it:

1. `ALLOW_UNMANAGED_TEAMMATE=1` → pass (escape hatch, `[GATE-BYPASS]`).
2. Empty stdin / `jq` unavailable / parse failure → pass (`[GATE-DEGRADE]`).
3. `tool_name` is not `Agent` or `Task` → pass (`gate_preamble` rc 2, silent).
4. `tool_input.name` is blank or absent → pass (not this hook's domain).
5. `tool_input.subagent_type` resolves to a role file in the `agents/` roster → pass
   (structural exemption — this dispatch is a legitimate team-ops teammate spawn).
6. Otherwise → block (exit 2), three-line stderr with two exits.

**Roster resolution (step 5)** walks the ancestor-directory chain of the dispatching
cwd (`.cwd` field on the hook payload, falling back to `$PWD` when absent), checking
`<D>/.claude/agents/<subagent_type>.md` at each level — `.claude` is a hardcoded path
component. The first hit at any level wins. If `$HOME` is not on that ancestor chain,
`$HOME/.claude/agents/<subagent_type>.md` is checked once more as a final fallback.
This matches the actual runtime resolution behavior (verified against Claude Code
2.1.223): a project that defines its own `<project>/.claude/agents/<type>.md` role is
recognized the same as a user-level role, rather than being misjudged as an unmanaged
teammate because only `~/.claude/agents/` was checked.

If the roster directory (at every level checked) does not contain the requested
`subagent_type`, the dispatch is **blocked**, not passed — a missing roster file is
treated as a possible misconfiguration, not as "this session doesn't use team-ops",
because exit ① (drop `name`, take the sync-guard path) is always reachable without
the escape hatch.

The two exits offered on block are: ① drop `name` and re-dispatch as a one-shot
subagent (see § Two-Domain Split for the follow-on `run_in_background:false`
requirement), or ② name a `subagent_type` from the `agents/` roster (`dev`, `ops`,
`pm`, `redteam`, `worker`) to take the team-ops path, which this gate then passes
structurally. There is no third "lightweight AND teammate" option.

**Escape hatch**: `ALLOW_UNMANAGED_TEAMMATE=1` in `settings.json`'s `env` section —
the same propagation caveat as `ALLOW_BACKGROUND_DISPATCH` applies (`export` in a
Bash tool call does not reach the hook process).

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
bats plugins/dispatch-contract/tests/dispatch-agent-ownership-guard.bats
bats plugins/dispatch-contract/tests/dispatch-capability-guard.bats
bats plugins/dispatch-contract/tests/dispatch-channel-guard.bats
bats plugins/dispatch-contract/tests/gate-composition.bats
bats plugins/dispatch-contract/tests/skill-contract.bats
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

`dispatch-agent-ownership-guard.bats` covers all runtime-owned types, model-optional Plan omission, `null`, valid-model, empty, and whitespace shapes, model field presence states, case normalization, registered-agent `inherit`/empty/whitespace overrides, both `Agent` and `Task`, escape-hatch and fail-open paths, plus Plan-classification mutation and runtime-rejection wording-anchor cases that prove the policy is load-bearing.

`dispatch-capability-guard.bats` covers: signal extraction
(EXEC/WRITE/RO/NEG, including the double-negation and exclusive-write-scope scrub
logic), the `NEEDS_CAP` derived predicate and its deliberately-accepted mixed-prompt
miss, judgments A/B/C individually and in combination (Explore + haiku triggering both
B and C's messages before one `exit 2`), the `[GATE-BYPASS]`/`[GATE-DEGRADE]` tag
split, the escape hatch, and fail-open paths (empty stdin, missing `jq`, malformed
JSON, empty prompt). A later regression batch (`cap #24`–`#45`) pins the four
post-PR fixes above: judgment A's narrowed `!WRITE_HIT_A` exemption on mixed
RO+WRITE prompts (including the double-negation edge case that resurfaced once A
started consulting WRITE), EXEC's research-frame/negation anchoring on both CN
and EN phrasing, the distinct `[GATE-DEGRADE]` wording for empty-stdin and
missing-`jq`, and the EN/CN defect-noun objects pinned by two separate cases
(`cap #42` for the English side, `cap #45` for the Chinese side with no other
`WRITE_OBJ` word present) since the two token tables are matched independently
and a deletion on one side would otherwise pass silently under a shared test.

`dispatch-channel-guard.bats` has 22 test cases covering: the domain split
(blank/absent `name` passes straight through untouched), roster resolution at
each ancestor-directory level plus the `$HOME` fallback, the block/pass matrix
across recognized vs unrecognized `subagent_type` values, the escape hatch,
and fail-open paths (empty stdin, missing `jq`, malformed JSON, `tool_name`
outside `{Agent, Task}`).

`gate-composition.bats` discovers every `PreToolUse` hook this plugin declares
against the `Agent` matcher directly from
`hooks.json` (see `discover_agent_gates` in `test_helper/common-setup.bash`)
and run each against a shared payload, so an outroute one gate's own test
file exercises is also verified not to still get caught by a sibling gate —
see `gate-composition.bats`'s header for the issue-shaped failure mode this
exists to catch mechanically rather than by header comment.

The `skill-contract.bats` suite reads the real
`skills/subagent-dispatch/references/offload-scenarios.md` directly. It locks
the requirement that the main context first have a complete final result
sufficient to support its current decision before applying the re-dispatch
stop condition. It also locks the value of a concrete factual gap or an
independent review dimension, excludes pseudo-independence, keeps dispatch
non-mandatory, and preserves the boundaries for first dispatch, next distinct
work, team-ops, PRs, and plan review.

## Block Response Shape (Deliberate Choice)

All five blocking hooks in this plugin — `dispatch-sync-guard.sh`
(PreToolUse), `dispatch-agent-ownership-guard.sh` (PreToolUse),
`dispatch-capability-guard.sh` (PreToolUse), `pre-dispatch-channel-guard.sh`
(PreToolUse), and `subagent-done-gate.sh` (SubagentStop) — block via `exit 2`
plus a stderr message. Some sibling plugins
in this repo use a different shape instead: `plan-review`'s `dispatch-check.sh`
and `doc-gate`'s `skill-gate.sh` return JSON `permissionDecision: deny`. This
repo does not use one block-response shape across all plugins — `guardrails`'
`git-push-guard.sh` also blocks via `exit 2`. Within this plugin, consistency
across the four blocking hooks takes priority over matching an unrelated
plugin's shape. The two forms are functionally equivalent here. The runtime
routes the `exit 2` stderr text through `blockingError` into the tool result
the model sees. The correction message reaches model context either way.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ALLOW_UNMARKED_FINAL` | _(unset)_ | `1` disables the `%%DONE%%` finalization gate entirely |
| `ALLOW_BACKGROUND_DISPATCH` | _(unset)_ | `1` disables the background-dispatch sync guard entirely — set in `settings.json`'s `env` section, since `export` in a Bash tool call does not reach the hook process |
| `ALLOW_NO_RULES_INJECT` | _(unset)_ | `1` disables the SubagentStart rules injector entirely |
| `ALLOW_UNMANAGED_TEAMMATE` | _(unset)_ | `1` disables the dispatch channel guard entirely — set in `settings.json`'s `env` section, since `export` in a Bash tool call does not reach the hook process |
| `CLAUDE_CODE_FORK_SUBAGENT` | _(unset)_ | `0` disables the fork-subagent feature — restores `run_in_background` to the Agent input schema, the correct fix for step 9b's fork-world block |
| `ALLOW_DISPATCH_CAPABILITY_MISMATCH` | _(unset)_ | `1` disables the dispatch-capability guard entirely — set in `settings.json`'s `env` section, since `export` in a Bash tool call does not reach the hook process |
| `ALLOW_AGENT_MODEL_INHERIT` | _(unset)_ | Emergency-only `1` bypass for diagnosing a model-ownership false positive across all agent classes. Remove it immediately after diagnosis: it disables model ownership validation and is not a supported dispatch mode. |
| `CLAUDE_AUTO_BACKGROUND_TASKS` | _(unset)_ | Truthy value defeats `run_in_background:false`'s synchronous-delivery guarantee past 120s runtime — the sync guard blocks (step 8b) rather than silently misjudge a passing dispatch as safe; clear this variable to fix |
| `DONE_GATE_BODY_FLOOR` | `500` | Byte floor for the marker-absent branch — a final message with no marker and a body below this is blocked; at or above it passes with a `systemMessage` warning. Derivation in `The %%DONE%% Contract` above |
