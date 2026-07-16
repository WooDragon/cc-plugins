# guardrails

Four independent, fail-open guardrail hooks for Claude Code: an informational **code size gate**, a **git push guard** that catches accidental direct pushes to `main`/`master`, an **instruction scan** that flags hidden-Unicode payloads in agent instruction files, and a **git import scan** that re-runs that same check after import-shaped git/gh activity mid-session. Pure-hook plugin — no skills.

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
- **Only `sudo`/`env`/`VAR=val` invocation prefixes are normalized.** Other command wrappers pass through undetected — `time git push origin main`, `command git push ...`, `nice git push ...`, and `sudo -u user git push ...` (a non-flag argument like a username after `sudo` also breaks normalization). Recognizing every wrapper is an arms race a slip-catcher does not chase.
- **False positive**: a remote literally named `main` (e.g. `git push main HEAD:feature`) is not distinguished from the `main` *branch* and may be flagged even though no protected branch is being pushed to. Use `ALLOW_PUSH_MAIN=1` to push through this case.
- **`PROTECTED_BRANCHES` values containing regex metacharacters** have undefined matching behavior, since the list is spliced directly into the detection regex's alternation.

### instruction-scan.sh — `SessionStart` (informational)

At session start, recursively scans the session's cwd tree (agent instruction filenames only — `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `.cursorrules`, `.clinerules`, `.windsurfrules`, `.github/copilot-instructions.md`, `.cursor/rules/*.mdc`; excludes `.git`, `node_modules`, `vendor`, `dist`, `web/dist`; maxdepth 6) for hidden Unicode payloads that could smuggle instructions past a human skim-reading the file: zero-width characters (U+200B–U+200D, U+2060–U+2064), bidi-control characters (U+200E–U+200F, U+202A–U+202E, U+2066–U+2069), Unicode tag characters (U+E0000–U+E007F), and a stray U+FEFF anywhere except a legitimate leading BOM (line 1, position 0 — that one is stripped before scanning, not treated as a hit).

Purely informational — emits `additionalContext` only, never blocks anything (a `SessionStart` hook has no way to block a session from starting). Silent when no hits are found.

Environment variables:

| Var | Default | Purpose |
|---|---|---|
| `INSTRUCTION_SCAN_DISABLED` | `0` | kill switch (`1` disables) |
| `MAX_HITS` | `10` | per-file hit cap before truncating the scan and appending an anti-desensitization warning (guards against padding a file with legitimate emoji/zero-width usage to burn the quota and hide a real payload past it) |

### git-import-scan.sh — `PostToolUse: Bash` (informational)

After a Bash command shaped like a git/gh import action (`clone`, `pull`, `fetch`, `merge`, `checkout`, `switch`, `restore`, `rebase`, `reset`, `cherry-pick`, `submodule`, `apply`, `am`, `worktree` — matched as a fast-path literal substring on the command text, gated behind a `git`/`gh` mention first), re-runs the same hidden-Unicode scan as `instruction-scan.sh` over the **current state** of the tool call's cwd. This is deliberately a full re-scan of cwd-as-it-now-stands, not a diff / `git diff` / reflog-based check — diffing was a rejected design here, since it introduces path-offset and reflog-boundary bugs that scanning cwd's current state sidesteps entirely.

Two distinct message shapes:

- **No hidden-char hits, but instruction files exist** → a plain change-notification listing every instruction file currently in cwd, suggesting a manual check of whether the import touched them.
- **At least one hidden-char hit** → the same listing, plus the hidden-Unicode warning block (file/line/codepoint) for the affected files.

Silent when cwd has no instruction files at all, or the command isn't import-shaped.

Environment variables:

| Var | Default | Purpose |
|---|---|---|
| `GIT_IMPORT_SCAN_DISABLED` | `0` | kill switch (`1` disables) |
| `MAX_HITS` | `10` | same per-file truncation cap as `instruction-scan.sh` (shared via `_gate_scan_hidden`) |

**Known limitations (both instruction-scan.sh and git-import-scan.sh):**

1. **`instruction-scan.sh` alerts after the session has already loaded, not before** — it's a `SessionStart` hook, so any hidden payload in a file the agent already ingested at session start has already been read by the time this check runs. Blocking *before* load would require intercepting the read at the syscall/filesystem layer, which is out of scope for a Claude Code hook.
2. **Plain-text (no hidden characters) prompt injection is not detected at all.** Neither hook attempts any semantic judgment of whether instruction-file content is malicious — that's an arms race against an adaptive adversary that a pattern-based hook cannot win. The mitigation here is narrower and durable: surface hidden/invisible characters mechanically, and rely on the change-notification plus human review for everything else.
3. **`git-import-scan.sh`'s fast-path is literal substring matching on the command text, not a real shell parser**, so it has the same class of blind spots as `git-push-guard.sh`: a fully-qualified git binary path, an environment-variable prefix, a nested subshell, or (most notably) **a git alias standing in for the real subcommand** (e.g. `git up` configured as an alias for `git pull`) all short-circuit past the keyword match undetected. The next `SessionStart` still catches anything left behind, since `instruction-scan.sh` scans unconditionally regardless of how the files got there.
4. **The `am` keyword is a substring match, so it over-triggers on unrelated commands containing that substring** — `git blame`, `git commit --amend`, etc. all cause a scan to fire even though no import happened. This is an accepted false-positive: it only costs an extra (cheap, fail-open) scan, never a false negative, and tightening the match (e.g. word-boundary anchoring) would compromise the fast-path's simplicity for a purely cosmetic gain.
5. **`git-import-scan.sh` scans cwd's entire current state, not a diff of what the import actually changed.** The change-notification therefore always lists *every* instruction file present in cwd post-import, including ones untouched by that specific command — this is a deliberate simplicity/correctness tradeoff (see the script's design note), not an oversight.

## Shared library

`scripts/_gate_common.sh` holds the side-effect-free helpers shared across scripts: jq presence probe, JSON field extraction, bypass-flag check, plus (added for `instruction-scan.sh`/`git-import-scan.sh`) the instruction-file enumerator (`_gate_instruction_files`) and the hidden-Unicode scanner (`_gate_scan_hidden`). It intentionally does **not** unify top-level fallback behavior: `code-size.sh`/`instruction-scan.sh`/`git-import-scan.sh` are fully fail-open (`_main 2>/dev/null || true`), while `git-push-guard.sh` fail-opens on parse ambiguity but hard-blocks (`exit 2`) on a confirmed match — the two failure philosophies are opposite and must not be merged.

## Testing

```bash
cd plugins/guardrails
bats tests/*.bats            # default bash
BATS_RUN_BASH=/bin/bash bats tests/*.bats  # bash 3.2 (macOS system bash)
```

Run against both bash 5.x (Homebrew) and bash 3.2 (macOS system `/bin/bash`) — the scripts avoid bash-4+-only syntax, but this is a known macOS pitfall worth re-checking on any future change.

## TODO (future version)

See "Known limitations" above and [#118](https://github.com/WooDragon/cc-plugins/issues/118) for the remaining tracked follow-up work (nested-shell detection, `sudo -u user` recognition).
