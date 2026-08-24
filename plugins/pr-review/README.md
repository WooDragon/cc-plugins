# pr-review

AI code review for **already-opened GitHub PRs**, with three backends: a local grok CLI review, a local claude CLI review, and a GitHub Copilot bot review (optional). grok and claude are automatically routed by a unified entry point (`pr-review.sh`); which one runs by default depends on whether the current session itself is already routed through a grok provider (see [Backends](#backends)).

A **pure skill plugin** (no hooks) bundling one skill, three reference docs, and five executable scripts.

> Scope boundary: this plugin reviews a PR *by number*. For an uncommitted working diff, use `/code-review` instead.

## Installation

```bash
# From marketplace
claude plugin add pr-review@cc-plugins
```

## Backends

| | **grok** | **claude** | **codex** | **copilot** (optional) |
|---|---|---|---|---|
| Mechanism | Local `grok` CLI, synchronous | Local `claude -p` CLI, synchronous | Local `codex exec` CLI, synchronous | `gh` triggers the GitHub Copilot bot, asynchronous |
| Output | Printed to your terminal — posts nothing to the PR | Printed to your terminal — posts nothing to the PR | Printed to your terminal — posts nothing to the PR | Posted back as a review on the PR |
| Latency | Immediate | Immediate | Immediate | Minutes; must be polled |
| Cost | Cheap; `--effort` is tunable (default `high`) | Cheap; `--effort` is tunable (default `medium`) | Cheap; reasoning effort tunable via `-c model_reasoning_effort` (default `high`) | Expensive — usually left off |
| Multi-round | Yes — adversarial follow-up over a persisted session | Yes — adversarial follow-up over a persisted session | Yes — adversarial follow-up over a persisted thread (`codex exec resume`) | No |
| Use when | `pr-review.sh`'s default auto-routed target; also local self-review before asking for human eyes | Auto-routed target when the current session is itself already routed through a grok provider (self-review-by-the-same-model would be low-value); can also be forced manually | A third independent reviewer is wanted, or when both grok and claude are the same family as the code's author; explicit `PR_REVIEW_BACKEND=codex` only — never auto-routed | Wrapping up a complex project, when a native bot review record on the PR is wanted |
| Script | `skills/pr-review/scripts/grok-review.sh` | `skills/pr-review/scripts/claude-review.sh` | `skills/pr-review/scripts/codex-review.sh` | `skills/pr-review/scripts/copilot-review.sh` |
| Reference | `skills/pr-review/references/grok-review.md` | `skills/pr-review/references/claude-review.md` | `skills/pr-review/references/codex-review.md` | `skills/pr-review/references/copilot-review.md` |

`skills/pr-review/scripts/pr-review.sh` is the unified entry point that routes between grok, claude and codex — see `skills/pr-review/scripts/resolve-backend.sh` for the resolution order (`PR_REVIEW_BACKEND` explicit override > auto-detection > default `grok`). codex participates in `pr-review.sh` routing but **does not** participate in auto-selection, only explicit `PR_REVIEW_BACKEND=codex` selects it. copilot is not part of this routing (asynchronous, different CLI parameter shape) — call `copilot-review.sh` directly.

## Quick usage

Normally you don't invoke anything by hand — say "评审 PR 123" / "grok review this PR" / "claude review this PR" and the skill activates. The scripts are also directly runnable:

```bash
REVIEW="${CLAUDE_PLUGIN_ROOT}/skills/pr-review/scripts/pr-review.sh"   # auto-routes grok/claude
[ -x "$REVIEW" ] || { echo "pr-review script path did not resolve" >&2; exit 1; }

gh pr checkout 123        # cwd must be the PR's own repo worktree
"$REVIEW" 123             # round 1: full review, opens a session
# ...judge the findings, fix code, commit (do NOT amend the round-1 tip)
"$REVIEW" 123 --followup "已修复 XX，请复核"   # round 2+: same session, incremental diff only

# Force a specific backend:
PR_REVIEW_BACKEND=claude "$REVIEW" 123
```

```bash
COPILOT="${CLAUDE_PLUGIN_ROOT}/skills/pr-review/scripts/copilot-review.sh"

"$COPILOT" request   123   # first request
"$COPILOT" rerequest 123   # re-request (REST dedupes; the script goes through GraphQL)
"$COPILOT" status    123   # poll request / result state
```

## Adversarial multi-round follow-up (grok)

Round 1 sends the full PR diff and opens a grok session, whose UUID is persisted to `${XDG_STATE_HOME:-$HOME/.local/state}/pr-review/<owner>__<name>__<PR>.session` (mode 600, GC'd after 30 days). Each follow-up round resumes that session and sends **only** the review instruction plus the diff since the last round — the full diff is never re-sent. Loop until the caller's accept list is empty — the review engine is a peer, not an authority, so its `LGTM` is not the exit condition. The orchestration protocol lives in `skills/pr-review/SKILL.md`.

Guardrails baked into the script:

- **Workspace identity pinning** — the session is tied to the `git rev-parse --show-toplevel` path of round 1; a follow-up from an unrelated repo fails fast rather than reviewing the wrong code. Switching worktree/clone means reopening round 1.
- **Baseline fail-fast** — if local `HEAD` ≠ the PR's head at round 1, it refuses to anchor on a wrong baseline (override with `--allow-divergent-base`).
- **No silent session downgrade** — if a follow-up can't resume the session it errors out instead of quietly starting a fresh, amnesiac one.
- **Secret hygiene** — suspicious untracked files (`.env`, `*.pem`, `*secrets*`, …) and oversized untracked blobs are skipped rather than uploaded; `*.example` is exempt, and tracked secrets warn instead of being silently dropped.
- `--sandbox read-only` — grok can read the repo but never writes to it.

## Prerequisites

| Backend | Needs |
|---|---|
| grok | `grok` CLI on `PATH`, `gh` (authenticated), `git` |
| claude | `claude` CLI on `PATH` (logged in), `gh` (authenticated), `git` |
| codex | `codex` CLI on `PATH`, `gh` (authenticated), `git` |
| copilot | `gh` (authenticated), Copilot code review enabled on the repo |

### Environment variables

| Variable | Default | Notes |
|---|---|---|
| `GROK_MODEL` | `grok-4.6` | grok backend model override |
| `GROK_EFFORT` | `high` | grok backend reasoning effort; legal values exactly `none`/`minimal`/`low`/`medium`/`high` (`xhigh` unsupported — a persisted legacy `xhigh` session value is migrated to `high` once before the review runs) |
| `CLAUDE_REVIEW_MODEL` | `claude-opus-5` | claude backend model override |
| `CLAUDE_REVIEW_EFFORT` | `medium` | claude backend reasoning effort; legal values exactly `low`/`medium`/`high`/`xhigh`/`max` |
| `CODEX_REVIEW_MODEL` | `gpt-5.6-luna` | codex backend model override |
| `CODEX_REVIEW_EFFORT` | `medium` | codex backend reasoning effort; legal values exactly `none`/`low`/`medium`/`high`/`xhigh`/`max` |
| `PR_REVIEW_BACKEND` | unset | `grok`/`claude`/`codex`/`copilot` — explicit override for `pr-review.sh`'s auto-routing, takes priority over auto-detection (codex does not participate in auto-detection) |
| `XDG_STATE_HOME` | `$HOME/.local/state` | root of the session state files (`pr-review/<owner>__<name>__<PR>.session` for grok, `.claude.session` for claude, `.codex.session` for codex — independent, never overwrite each other) |

On a follow-up round, persisted session `MODEL`/`EFFORT` values win over env vars unless the CLI flag is given explicitly.

## Tests

```bash
bats plugins/pr-review/tests/grok-review.bats plugins/pr-review/tests/claude-review.bats plugins/pr-review/tests/codex-review.bats plugins/pr-review/tests/resolve-backend.bats plugins/pr-review/tests/skill-contract.bats
```

122 cases total:

- `grok-review.bats` (66) — argument parsing, session state files, path construction, fail-fast semantics, directory permissions, GC, effort validation and migration, and the secret-file heuristics. External commands (`grok`, `gh`, `uuidgen`) are stubbed; `git` is real, against a per-test temp repo.
- `claude-review.bats` (24) — same shape of coverage for the claude backend: isolation flags (`--setting-sources ""`, `--tools ""`, `--safe-mode`, `--strict-mcp-config`, the `unset_provider_routing_env` unset list covering `ANTHROPIC_*`/`CLAUDECODE`/`CLAUDE_CODE_MESSAGING_*`/`CLAUDE_CODE_SESSION_ID`/`CLAUDE_CODE_CHILD_SESSION`/`CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY`) asserted on both first-round and `--resume` follow-up paths, session resume/fail-fast, `.claude.session` state file isolation from grok's `.session`, and shared-lib workspace pinning reuse. `claude` is stubbed.
- `codex-review.bats` (17) — codex backend shape: CLI arg parsing, session state files, thread resume/fail-fast, workspace pinning, effort validation, and secret-file heuristics. `codex exec` is stubbed; `git` is real against a per-test temp repo.
- `resolve-backend.bats` (12) — `PR_REVIEW_BACKEND` pass-through and validation, `ANTHROPIC_DEFAULT_OPUS_MODEL` auto-detection, and `pr-review.sh`'s routing to the resolved backend script (including the `copilot` rejection path).
- `skill-contract.bats` (3) — real-skill Markdown contract checks for repair-subagent ownership, main-session SHA verification and follow-up lifecycle, and the grok two-round example.
