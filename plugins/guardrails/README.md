# guardrails

Two independent, fail-open guardrail hooks for Claude Code: an informational **code size gate** and a **git push guard** that catches accidental direct pushes to `main`/`master`. Pure-hook plugin — no skills.

## Installation

```bash
# From marketplace
claude plugin add guardrails@WooDragon-cc-plugins
```

## Hooks

### code-size.sh — `PostToolUse: Edit|Write` (10s timeout)

After an Edit/Write lands on a whitelisted source file (`.py .ts .tsx .js .jsx .sh .go .rs .c .cpp .h .java .rb`), checks:

- **Dual line-count threshold** — soft (default 500) / hard (default 2000) total lines.
- **Single-function length** (ast-grep, degradable) — default 150 lines, supported for `.py/.go/.rs/.ts/.tsx/.js/.jsx`.

Emits `additionalContext` only when the tier for a given file **increases** relative to a per-session watermark (never re-alerts at steady state; re-arms if the file shrinks back down and later regrows). Purely informational — never blocks, `_main` runs under a top-level `2>/dev/null || true` soft catch-all so any anomaly degrades to silent no-op.

Environment variables:

| Var | Default | Purpose |
|---|---|---|
| `CODE_SIZE_GATE_DISABLED` | `0` | kill switch (`1` disables) |
| `CODE_SIZE_SOFT_LINES` | `500` | soft line-count threshold |
| `CODE_SIZE_HARD_LINES` | `2000` | hard line-count threshold |
| `CODE_SIZE_MAX_FN_LINES` | `150` | single-function length threshold |
| `CODE_SIZE_GATE_DIR` | `/tmp/claude-reviews` | watermark marker directory |
| `CODE_SIZE_GATE_STALE_MIN` | `120` | marker staleness (minutes) before cleanup |

### git-push-guard.sh — `PreToolUse: Bash` (5s timeout)

Guards against `git push` (and compound commands containing one, split on `&&`, `||`, `;`, newline) that target `main` or `master` — exact branch name (bare, `+`-prefixed force shorthand, or full `refs/heads/` path), refspec (`:main`, `:refs/heads/main`), or `--all`/`--mirror`. On a hit: `exit 2` + explanatory `stderr`, blocking that tool call. All other cases (parse ambiguity, missing fields, non-matching branch) fail open with `exit 0`.

This is a **slip-catcher, not a security boundary** — it is pattern-matching over the literal command text, not a real shell parser, so it stops the common accidental-push shapes without attempting to be adversarially unevadable. See "Known limitations" below for what it does not cover.

Bypass: `export ALLOW_PUSH_MAIN=1` (temporary, intended for genuine emergencies — not a standing override).

**Known limitations (guards against slips, not against deliberate evasion).** These are known, accepted gaps — not yet implemented — tracked in [#118](https://github.com/WooDragon/cc-plugins/issues/118):

- **Hard-coded protected branches.** Only `main`/`master` are recognized. Repos using `trunk`, `develop`, or other default-branch conventions are **not protected** — pushes to those branches pass through untouched. Planned fix: a configurable `PROTECTED_BRANCHES` env var.
- **Alternate git invocations bypass detection entirely**, since the hook only pattern-matches the literal command string:
  - Full binary path — `/usr/bin/git push origin main`
  - `sudo -E git push origin main` (only bare `sudo git` is recognized)
  - `env git push origin main`
  - `GIT_DIR=... git push origin main` (env-var prefix before `git`)
  - Nested shells — `bash -c 'git push origin main'`
- **False positive**: a remote literally named `main` (e.g. `git push main HEAD:feature`) is not distinguished from the `main` *branch* and may be flagged even though no protected branch is being pushed to.

## Shared library

`scripts/_gate_common.sh` holds only three side-effect-free helpers shared by both scripts (jq presence probe, JSON field extraction, bypass-flag check). It intentionally does **not** unify top-level fallback behavior: `code-size.sh` is fully fail-open (`_main 2>/dev/null || true`), while `git-push-guard.sh` fail-opens on parse ambiguity but hard-blocks (`exit 2`) on a confirmed match — the two scripts' failure philosophies are opposite and must not be merged.

## Testing

```bash
cd plugins/guardrails
bats tests/code-size.bats tests/git-push-guard.bats            # default bash
BATS_RUN_BASH=/bin/bash bats tests/code-size.bats tests/git-push-guard.bats  # bash 3.2 (macOS system bash)
```

Run against both bash 5.x (Homebrew) and bash 3.2 (macOS system `/bin/bash`) — the scripts avoid bash-4+-only syntax, but this is a known macOS pitfall worth re-checking on any future change.

## TODO (future version)

See "Known limitations" above and [#118](https://github.com/WooDragon/cc-plugins/issues/118) for the tracked follow-up work (evasion-vector hardening, `PROTECTED_BRANCHES` generalization).
