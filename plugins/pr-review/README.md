# pr-review

AI code review for **already-opened GitHub PRs**, with two interchangeable backends: a local grok CLI review (default) and a GitHub Copilot bot review (optional).

A **pure skill plugin** (no hooks) bundling one skill, two reference docs, and two executable scripts.

> Scope boundary: this plugin reviews a PR *by number*. For an uncommitted working diff, use `/code-review` instead.

## Installation

```bash
# From marketplace
claude plugin add pr-review@cc-plugins
```

## Backends

| | **grok** (default) | **copilot** (optional) |
|---|---|---|
| Mechanism | Local `grok` CLI, synchronous | `gh` triggers the GitHub Copilot bot, asynchronous |
| Output | Printed to your terminal — posts nothing to the PR | Posted back as a review on the PR |
| Latency | Immediate | Minutes; must be polled |
| Cost | Cheap; `--effort` is tunable (default `high`) | Expensive — usually left off |
| Multi-round | Yes — adversarial follow-up over a persisted session | No |
| Use when | Local self-review before asking for human eyes | Wrapping up a complex project, when a native bot review record on the PR is wanted |
| Script | `skills/pr-review/scripts/grok-review.sh` | `skills/pr-review/scripts/copilot-review.sh` |
| Reference | `skills/pr-review/references/grok-review.md` | `skills/pr-review/references/copilot-review.md` |

## Quick usage

Normally you don't invoke anything by hand — say "评审 PR 123" / "grok review this PR" and the skill activates. The scripts are also directly runnable:

```bash
REVIEW="${CLAUDE_PLUGIN_ROOT}/skills/pr-review/scripts/grok-review.sh"

gh pr checkout 123        # cwd must be the PR's own repo worktree
"$REVIEW" 123             # round 1: full review, opens a session
# ...judge the findings, fix code, commit (do NOT amend the round-1 tip)
"$REVIEW" 123 --followup "已修复 XX，请复核"   # round 2+: same session, incremental diff only
```

```bash
COPILOT="${CLAUDE_PLUGIN_ROOT}/skills/pr-review/scripts/copilot-review.sh"

"$COPILOT" request   123   # first request
"$COPILOT" rerequest 123   # re-request (REST dedupes; the script goes through GraphQL)
"$COPILOT" status    123   # poll request / result state
```

## Adversarial multi-round follow-up (grok)

Round 1 sends the full PR diff and opens a grok session, whose UUID is persisted to `${XDG_STATE_HOME:-$HOME/.local/state}/pr-review/<owner>__<name>__<PR>.session` (mode 600, GC'd after 30 days). Each follow-up round resumes that session and sends **only** the review instruction plus the diff since the last round — the full diff is never re-sent. Loop until grok says LGTM.

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
| copilot | `gh` (authenticated), Copilot code review enabled on the repo |

`GROK_MODEL` (default `grok-4.5`) and `GROK_EFFORT` (default `high`) override the model and reasoning effort. Supported effort values are exactly `none`, `minimal`, `low`, `medium`, and `high`; `xhigh` is not supported. On a follow-up round, persisted session values win unless the flag is given explicitly. If a persisted legacy session records `xhigh`, the script migrates that value to `high` once before the review runs.

## Tests

```bash
bats plugins/pr-review/tests/grok-review.bats
```

66 cases covering argument parsing, session state files, path construction, fail-fast semantics, directory permissions, GC, effort validation and migration, and the secret-file heuristics. External commands (`grok`, `gh`, `uuidgen`) are stubbed; `git` is real, against a per-test temp repo.
