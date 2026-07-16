# guardrails

Two independent, fail-open guardrail hooks for Claude Code: an informational **code size gate** and a hard **git push protection** gate. Pure-hook plugin — no skills.

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

Blocks `git push` (and compound commands containing one, split on `&&`, `||`, `;`, newline) that target `main` or `master` — exact branch name, refspec (`:main`, `:refs/heads/main`), or `--all`/`--mirror`. On a hit: `exit 2` + explanatory `stderr`, hard-blocking the tool call. All other cases (parse ambiguity, missing fields, non-matching branch) fail open with `exit 0`.

**Known limitation (v1.0.0): protected branch names are hard-coded to `main`/`master`.** Repositories using `trunk`, `develop`, or other default-branch conventions are **not currently protected** by this hook — pushes to those branches pass through untouched. Generalizing this to a configurable branch list (`PROTECTED_BRANCHES` env var) is a planned follow-up, not yet implemented.

Bypass: `export ALLOW_PUSH_MAIN=1` (temporary, intended for genuine emergencies — not a standing override).

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

- Generalize `git-push-guard.sh`'s hard-coded `main`/`master` to a `PROTECTED_BRANCHES` environment variable, so repos with `trunk`/`develop`-style default branches are covered.
