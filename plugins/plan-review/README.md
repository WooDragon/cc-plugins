# plan-review

Adversarial red-team review of implementation plans via cross-model consultation.

When Claude calls `ExitPlanMode`, this plugin intercepts the call and sends the plan to a review engine (Gemini, Claude, or Codex) for adversarial scrutiny. The reviewer can APPROVE, raise CONCERNS, or REJECT. On non-approval, feedback is returned to Claude for revision or rebuttal. After max rounds without consensus, the plan passes through for user arbitration.

## Installation

```bash
# From marketplace
claude plugin add plan-review@WooDragon-cc-plugins

# Development mode
claude --plugin-dir ~/.claude/dev-plugins/plan-review
```

## Environment Variables

### `plan-review.sh` (ExitPlanMode adversarial review)

| Variable | Default | Description |
|----------|---------|-------------|
| `REVIEW_ENGINE` | `gemini` | Review engine: `gemini` (default, routed through the local `agy` CLI), `claude` (`claude -p` subprocess), or `codex` (`codex exec` subprocess) |
| `AGY_MODEL` | `Gemini 3.1 Pro (High)` | Model id passed to the `agy` CLI when `REVIEW_ENGINE=gemini` |
| `CLAUDE_MODEL` | `opus` | Claude model when `REVIEW_ENGINE=claude` |
| `CODEX_BIN` | _(empty)_ | Path to the `codex` binary. Default: `codex` as resolved on `PATH`. Set this when codex is not on `PATH` |
| `CODEX_MODEL` | _(empty)_ | Model id passed to `codex exec` when `REVIEW_ENGINE=codex`. Empty means inherit whatever `~/.codex/config.toml` specifies |
| `GEMINI_MODEL` | `gemini-3.1-pro-preview` | Model id used only by the REST fallback payload (not the `agy` CLI path) |
| `REVIEW_DISABLED` | `0` | Set `1` to bypass entirely |
| `REVIEW_DRY_RUN` | `0` | Set `1` to skip engine call (synthetic APPROVE) |
| `REVIEW_MAX_ROUNDS` | `3` | Max non-Critical consultation rounds (CONCERNS accumulation) before escalation |
| `REVIEW_MAX_TOTAL_ROUNDS` | `20` | Absolute global ceiling (including REJECT rounds); hard-blocks once reached |
| `REVIEW_ENGINE_TIMEOUT` | `595` | Engine call timeout in seconds (requires `timeout`/`gtimeout` on `PATH`) |
| `REVIEW_API_URL` | _(empty)_ | REST API fallback base URL (OpenAI-compatible), used when the CLI path fails |
| `REVIEW_API_KEY` | _(empty)_ | REST API fallback bearer token |
| `REVIEW_REST_TIMEOUT` | `115` | REST fallback curl timeout in seconds (clamped to `remaining-3` by the budget logic) |
| `REVIEW_REST_STALL_TIMEOUT` | `90` | REST SSE stream stall watchdog (`curl --speed-time`), tuned to tolerate legitimate reasoning-model TTFT |
| `REVIEW_HOOK_BUDGET` | `595` | Total hook time budget in seconds (600s hook timeout minus 5s margin); governs the retry loop and REST timeout clamping |
| `REVIEW_CAPACITY_DELAY` | `25` | Wait time after detecting `MODEL_CAPACITY_EXHAUSTED` (skipped — breaks immediately to REST — when REST is configured) |
| `REVIEW_ENGINE_DEGRADE_TTL` | `600` | TTL in seconds for the Gemini degrade state; subsequent hooks within the TTL skip the CLI and go straight to REST. Shortened from 3600 in v1.2.0 — agy 429 probing is cheap (~26s median) and multi-round session reuse lowers 429 frequency, so a shorter cooldown recovers agy faster without thrashing |

Legacy variables (`GEMINI_REVIEW_OFF`, `GEMINI_DRY_RUN`, `GEMINI_MAX_REVIEWS`) are supported via fallback mapping.

### `dispatch-check.sh` (Layer 2 — Agent/Task dispatch enforcement)

| Variable | Default | Description |
|----------|---------|-------------|
| `DISPATCH_CHECK_DISABLED` | `0` | Set `1` to disable the Layer 2 dispatch-parameter check (kill switch) |

## Consultation Flow

```
ExitPlanMode → hook intercepts → engine reviews
  ├─ APPROVE → ack-deny: present review + re-call ExitPlanMode → allow (user's native go/no-go)
  ├─ CONCERNS/REJECT → deny + feedback → Claude revises → re-submit
  └─ max rounds reached → allow through (user decides)
```

An engine APPROVE is **not** authorization to start work — it only clears the plan
for the user's native ExitPlanMode decision. The ack-deny message instructs Claude to
present the review and re-call ExitPlanMode (unchanged); only the user's native approval
on that second call permits execution.

## Review Criteria

Nine criteria — authoritative text lives in `SYSTEM_INSTRUCTIONS` inside `scripts/plan-review.sh`.

| # | Criterion | Focus |
|---|-----------|-------|
| 1 | **Correctness** | Does the plan actually solve the stated problem? |
| 2 | **Completeness** | Missing steps, edge cases, error handling? |
| 3 | **Simplicity** | Is there a simpler approach? Unnecessary complexity? |
| 4 | **Safety** | Security risks, data loss, backwards-compatibility breaks? |
| 5 | **Testability** | Test strategy presence; test pyramid completeness; e2e selector cascade (evidence-gated); deletion completeness for exported symbols |
| 6 | **Architecture fit** | Consistent with project patterns? |
| 7 | **Execution topology** | Each step annotated with execution location and scheduling order? |
| 8 | **Reuse over reinvention** | Using existing dependencies before building custom? |
| 9 | **Dispatch Manifest** | Agent/Task steps declare `agent_type`, `model`, `depends_on`, `parallel_with`? |

Criterion #5 (Testability) is evidence-gated: e2e selector audits only trigger if the plan or project context reveals e2e coverage (Playwright, Cypress, `*.spec.ts`, `e2e/` directory).

## Engine Isolation (Claude)

When `REVIEW_ENGINE=claude`, the script spawns `claude -p` with triple isolation:

1. **`PLAN_REVIEW_RUNNING=1`** — recursive guard; subprocess bails immediately if set
2. **`--setting-sources local`** — loads only `settings.local.json`, no project/user hooks
3. **`--tools ""`** — no tool calls = no PreToolUse events = no hook re-entry

`unset CLAUDECODE` and `unset CLAUDE_CODE_ENTRYPOINT` prevent the subprocess from inheriting parent's internal state. This is implementation-dependent but necessary: user authenticates via OAuth (`claude login`), no `ANTHROPIC_API_KEY` available, making `claude -p` the only viable invocation path.

## Engine Isolation (Codex)

When `REVIEW_ENGINE=codex`, the script spawns `codex exec` with a parallel set of isolation flags:

1. **`-s read-only`** — sandbox policy; the reviewer process cannot write to disk
2. **`-C <fresh empty temp dir>`** — the working root is a throwaway empty directory, not the user's project, so the reviewer does not read project source
3. **`--ephemeral`** — no session files persisted to disk
4. **`--skip-git-repo-check`** — required because the isolated temp dir is not a git repo

The prompt is fed via stdin (no `ARG_MAX` limit, unlike the agy path which needs a 256KB guard), and the final message is captured via `-o <file>`.

**Tool-surface caveat**: the four flags above constrain the file scope the reviewer sees; they do not disable codex's agent tool surface. Whether MCP servers or web search remain available to the reviewer follows the user's own `~/.codex/config.toml`. This differs from the `claude` engine, where `--tools ""` removes the tool surface outright. The plugin leaves codex's tool configuration to the user rather than overriding it — silently rewriting a user's engine config is the worse trade. Users who require a text-only reviewer should disable those tools in their codex configuration.

**stderr handling**: `codex exec` echoes the entire prompt to stderr. Because of this, codex's stderr is deliberately **not** appended to the plan-review log (unlike the other engines) — doing so would duplicate the full prompt into the log file. On a failed call, only a filtered diagnostic is written to the log: the banner plus trailing `warning:`/`ERROR:` lines, with any line matching the prompt stripped out, truncated to 500 chars.

## Session Reuse (agy, v1.2.0)

When `REVIEW_ENGINE=gemini` (agy CLI), a multi-round consultation reuses one agy server-side conversation instead of resending the full static prompt every round:

- **First round** builds a fresh conversation and captures the `conversation_id` agy assigns (via `--output-format json`).
- **Subsequent rounds** resume it with `--conversation <id>`, sending only the volatile tail (current plan + round framing). The static prefix (system instructions + project/global context) already lives in agy's session history, so the provider serves it from prompt cache.

This lowers 429 frequency and quota consumption on multi-round negotiations. The conversation reference is session-scoped and torn down when the review cycle ends (approve / escalate / no-plan / global valve), on any non-zero agy exit (capacity, timeout, resume-rejected, network), when a response cannot be parsed, or when the plan changes after an approval. Extraction/reuse failures fall through to a plain agy call or REST — never a new blocking path.

**agy invocation contract**: since v1.2.0 the agy CLI is always called with `--output-format json`, and the review body is text-sliced out of the (not-well-formed) JSON `response` field. This depends on agy's envelope carrying `conversation_id` and `response` keys. If a future agy build changes that envelope shape, extraction fails closed (empty review → retry / REST fallback), so a shape change degrades gracefully rather than mis-parsing — but it does mean the agy path is coupled to this envelope. The `claude` engine path and the REST fallback are unchanged. With no env config, the review decision logic behaves as before; the observable deltas are the JSON invocation, multi-round session reuse, and the shorter degrade cooldown (600s).

## Fault Tolerance

- **jq missing** → allow (can't parse input)
- **Engine CLI missing** → allow + stderr warning
- **Engine call fails** → allow + stderr warning
- **Empty response** → allow
- **Malformed verdict** → fail-closed as CONCERNS
- **Log directory unwritable** → logs to `/dev/null`, core logic unaffected

## Privacy Notice

This plugin sends the following data to the configured review engine — the Gemini API, the Anthropic API, or, when `REVIEW_ENGINE=codex`, whichever provider the user's `~/.codex/config.toml` selects:

- **Global CLAUDE.md** — first 3KB of `~/.claude/CLAUDE.md`
- **Project CLAUDE.md** — first 8KB of `$CWD/CLAUDE.md`
- **Recent conversation** — last 3 user messages from the session transcript
- **Plan content** — the full implementation plan under review

This context is necessary for meaningful adversarial review. If your CLAUDE.md or conversations contain sensitive information (internal hostnames, credentials, business logic), be aware that this data will be sent to the external API.
