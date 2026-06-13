# doc-gate

Document editing governance for Claude Code — enforces structured documentation workflows through a dual-layer gate system plus standalone link graph tooling.

When Claude attempts to edit a `.md` file, the plugin intercepts the operation at two layers: a **hard gate** (skill-gate) ensures the doc-maintenance workflow was loaded, and a **soft gate** (recall-gate) surfaces related documents, orphan signals, and broken outlinks before the edit proceeds. Both gates are fail-open — any anomaly silently allows the edit rather than blocking work.

## Installation

```bash
# From marketplace
claude plugin add doc-gate@WooDragon-cc-plugins
```

## Architecture

```
PreToolUse:Edit/Write
  │
  ├─ [1] skill-gate.sh (5s timeout)
  │      Hard gate — denies unless doc-maintenance skill was invoked this session.
  │      Global ~/.claude/CLAUDE.md gets highest-strength messaging.
  │
  ├─ [2] recall-gate.sh (10s timeout)
  │      Soft gate — on first edit of each .md file, invokes recall-gate.py
  │      for BM25 recall + link graph analysis. Deny-once-per-file (retry passes).
  │      Contains double-deny guard: skips if skill-gate already denied.
  │
  └─ recall-gate.py
         Python engine (zero dependencies). Performs:
         - BM25 lexical recall against all .md files in the repo
         - Orphan detection (no inbound links)
         - Broken outlink verification

PreToolUse:Skill
  │
  └─ skill-marker.sh (5s timeout)
         Records session-scoped marker when doc-maintenance is invoked.
         Never blocks. skill-gate.sh checks this marker.
```

### Root Detection

Both `recall-gate.py` and `docs-graph.py` auto-detect the project root via `detect_root()`:

1. **`RECALL_GATE_ROOT` env var** — explicit override (recall-gate only)
2. **Walk-up for `CLAUDE.md`** — from the edited file upward, with co-occurrence constraint:
   - `CLAUDE.md` found, no `.git` seen below → accept (non-git project root)
   - `CLAUDE.md` + `.git` in the same directory → accept (monorepo root)
   - `CLAUDE.md` without `.git`, but `.git` seen below → skip (workspace marker, not a project root)
3. **Innermost `.git`** — first `.git` recorded during walk-up, used as safe fallback
4. **`cwd()`** — final fallback

This supports monorepo with independent sub-repos: place `CLAUDE.md` at the monorepo root alongside `.git` to enable cross-repo recall. Without `CLAUDE.md`, behavior degrades to the innermost git repo (safe, backward-compatible).

### Marker Protocol

Gates communicate through session-scoped marker files in `$SKILL_GATE_DIR` (default `/tmp/claude-reviews`):

| Marker | Created by | Checked by | Purpose |
|--------|-----------|------------|---------|
| `.skill-gate-{session}-doc-maintenance` | skill-marker.sh | skill-gate.sh | Proves doc-maintenance skill was invoked |
| `.recall-gate-{session}-{file_hash}` | recall-gate.sh | recall-gate.sh | Per-file deny-once (retry passes silently) |

Markers auto-expire after `SKILL_GATE_STALE_MIN` / `RECALL_GATE_STALE_MIN` minutes (default 120). This doubles as a context refresh mechanism — after 2 hours, the gates re-fire to surface fresh analysis.

### Exclusions

Both gates skip files that shouldn't be governed:

| Category | Examples |
|----------|---------|
| **Basename** | `MEMORY.md`, `SKILL.md`, `CHANGELOG.md`, `LICENSE.md` (case-insensitive) |
| **Path** | `.claude/*`, `.claude-plugin/*`, `.agents/directives/*`, `node_modules/*`, `.git/*` |
| **Temp dirs** | `/tmp/*`, `/var/tmp/*`, `/var/folders/*`, `/private/tmp/*` |
| **Non-.md** | Any file not ending in `.md` (case-insensitive) |

**Exception**: `~/.claude/CLAUDE.md` is always gated despite living under `.claude/` — it's the global config with the highest pollution surface.

## Recall Gate Analysis

When recall-gate fires, it performs three checks in a single pass:

### BM25 Lexical Recall

Tokenizes the content being written (English words + Chinese bigrams), scores against all `.md` files in the repo using BM25 + filename Jaccard similarity. Surfaces the top-N most similar documents to prevent content duplication.

### Orphan Detection

Checks whether the file being edited has zero inbound links from other documents. Flags files that may need to be added to an index or table of contents.

### Broken Outlink Verification

Parses Markdown links in the content being written and verifies that each target file exists. Reports broken references before they're committed.

The deny message combines all three signals into a structured advisory. On retry, the per-file marker allows the edit through silently.

## docs-graph.py — Link Graph CLI

Standalone CLI for querying the document link graph. Zero dependencies, no persistent state.

```bash
# Run from project root (auto-detects root via detect_root)
python3 plugins/doc-gate/tools/docs-graph.py check           # Broken link detection
python3 plugins/doc-gate/tools/docs-graph.py backlinks FILE   # Who links to FILE
python3 plugins/doc-gate/tools/docs-graph.py links FILE       # What FILE links to
python3 plugins/doc-gate/tools/docs-graph.py orphans          # Zero-inlink documents
python3 plugins/doc-gate/tools/docs-graph.py hubs [-n 10]     # Top-N most linked documents
python3 plugins/doc-gate/tools/docs-graph.py related FILE     # 2-hop neighborhood
python3 plugins/doc-gate/tools/docs-graph.py export [--out F] # node_link JSON graph

# Explicit root
python3 docs-graph.py --root /path/to/repo check

# JSON output
python3 docs-graph.py --json orphans
```

Exit codes: `0` = ok, `1` = broken links found (check only), `2` = argument/tool error.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SKILL_GATE_DISABLED` | `0` | `1` disables the hard gate (skill-gate) |
| `SKILL_GATE_DIR` | `/tmp/claude-reviews` | Marker directory (shared with plan-review) |
| `SKILL_GATE_LOG_DIR` | `~/.claude/logs` | Log directory |
| `SKILL_GATE_STALE_MIN` | `120` | Marker expiry in minutes |
| `RECALL_GATE_DISABLED` | `0` | `1` disables the soft gate (recall-gate) |
| `RECALL_GATE_ROOT` | _(auto)_ | Explicit repo root override |
| `RECALL_GATE_THRESHOLD` | `0.30` | Minimum BM25 score for recall results |
| `RECALL_GATE_TOP_N` | `5` | Maximum recall results shown |
| `RECALL_GATE_STALE_MIN` | `120` | Recall marker expiry in minutes |

## Skill: doc-maintenance

The plugin bundles one skill (`skills/doc-maintenance/SKILL.md`) that provides structured documentation workflows:

- **Pre-flight**: layer validation, naming checks, duplicate detection
- **Execute**: guided by operation-specific checklists (CREATE / MODIFY / RENAME / ARCHIVE / RESTRUCTURE)
- **Post-flight**: index sync, broken link check, stale file cleanup

The skill also enforces graduated CLAUDE.md governance — global `~/.claude/CLAUDE.md` requires all four generalization criteria to pass; project-level CLAUDE.md uses them as guidelines.

## Tests

```bash
# In-repo hook tests (skill-gate + skill-marker)
bats plugins/doc-gate/tests/

# Full suite including recall-gate (private path)
bats tests/recall-gate.bats
python3 -m unittest tests/test_recall_gate.py -v
```

| Suite | Tests | Coverage |
|-------|-------|----------|
| `skill-gate.bats` | 54 | Filters, exclusions, gate enforcement, fail-open, CLAUDE.md governance, stale cleanup, e2e |
| `skill-marker.bats` | 13 | Tracked/untracked skills, marker creation, namespacing, kill switch |
| `recall-gate.bats` | 37 | Filters, kill switch, fail-open, markers, double-deny, BM25 integration, orphan, broken outlinks, monorepo root detection, e2e |
| `test_recall_gate.py` | 67 | Tokenization, BM25 scoring, link extraction/resolution, corpus building, orphan/broken checks, cmd_gate output, detect_root |

## Version History

See [GitHub Issues](https://github.com/WooDragon/cc-plugins/issues) for detailed change logs:

- **v1.2.1** — Root detection: CLAUDE.md co-occurrence anchor for monorepo support (#22)
- **v1.2.0** — Recall gate: BM25 lexical recall + link graph triple-dimension gate
- **v1.0.4** — Deny message discourages env-var bypass
- **v1.0.3** — CLAUDE.md governance + global tiering + team-ops exclusion
