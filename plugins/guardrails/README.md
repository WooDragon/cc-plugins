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

Guards against `git push` (and compound commands containing one, split on `&&`, `||`, `;`, newline) that target a protected branch — exact branch name (bare, `+`-prefixed force shorthand, or full `refs/heads/` path), refspec (`:main`, `:refs/heads/main`), or `--all`/`--mirror`. On a hit: `exit 2` + explanatory `stderr`, blocking that tool call. All other cases (parse ambiguity, missing fields, non-matching branch) fail open with `exit 0`.

Before matching, the command is normalized to strip leading invocation-prefix tokens — environment-variable assignments (`GIT_DIR=... git push`), `sudo`/`env` and their own flags (`sudo -E git push`, `env git push`) — so these collapse to a bare `git ... push ...` before pattern matching runs. The detection regex itself recognizes long options (`git --no-pager push`, `git --git-dir=.git push`) and an optional full/relative path prefix on the `git` binary (`/usr/bin/git push`).

This is a **slip-catcher, not a security boundary** — it is pattern-matching over the literal command text, not a real shell parser, so it stops the common accidental-push shapes without attempting to be adversarially unevadable. See "Known limitations" below for what it does not cover.

Environment variables:

| Var | Default | Purpose |
|---|---|---|
| `PROTECTED_BRANCHES` | `main master` | space-separated branch names to guard (e.g. `PROTECTED_BRANCHES="trunk develop"`) |
| `ALLOW_PUSH_MAIN` | `0` | bypass switch (`1` allows a push to a protected branch); temporary, for genuine emergencies — not a standing override. Name retained for backward compatibility even though `PROTECTED_BRANCHES` generalized the guarded set beyond `main`. |

**Known limitations (guards against slips, not against deliberate evasion).** [#118](https://github.com/WooDragon/cc-plugins/issues/118) closed the previously-tracked gaps (long options, `sudo -E`, `env`, `GIT_DIR=` prefix, full binary path, hard-coded `main`/`master`) — the remaining items below are accepted, still-open gaps:

- **Nested shells bypass detection entirely** — `bash -c 'git push origin main'`, `(git push origin main)` — since the hook only pattern-matches the literal command string, not commands executed inside a spawned sub-shell.
- **`sudo -u user git push ...`** is not recognized: the prefix stripper only skips *flag* tokens after `sudo`/`env`, so a non-flag argument like a username still breaks normalization.
- **False positive**: a remote literally named `main` (e.g. `git push main HEAD:feature`) is not distinguished from the `main` *branch* and may be flagged even though no protected branch is being pushed to. Use `ALLOW_PUSH_MAIN=1` to push through this case.
- **`PROTECTED_BRANCHES` values containing regex metacharacters** have undefined matching behavior, since the list is spliced directly into the detection regex's alternation.

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

See "Known limitations" above and [#118](https://github.com/WooDragon/cc-plugins/issues/118) for the remaining tracked follow-up work (nested-shell detection, `sudo -u user` recognition).
