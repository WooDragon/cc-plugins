# doc-gate

Document editing governance for Claude Code — a stateless entry layer that injects writing-standards judgment into every `.md` edit, plus a stateless exit layer that checks working-tree-wide documentation consistency when a turn ends. Both layers are fail-open — any anomaly silently allows work to continue rather than blocking it. For a dirty-file batch, the exit layer builds body and title BM25 indexes once. It reuses them across recall queries. The runtime remains Python-standard-library-only and requires neither dependencies nor configuration migration.

## Installation

```bash
# From marketplace
claude plugin install doc-gate@cc-plugins
```

## Architecture

```
PostToolUse:Edit|Write (.md files)
  │
  └─ doc-entry.sh
         Zero-deny, zero-state. On every matching edit, injects writing-standards
         judgment criteria (references/writing-standards.md §A, items A1-A13) plus
         trigger conditions anchored in the model's direct knowledge of the edit
         it just made — not on withheld document content, so this doesn't
         self-reference — into model context via additionalContext. CREATE /
         RENAME / ARCHIVE are directly observable; RESTRUCTURE / DEDUP call for
         judgment, a deliberate bias where the cost of a false positive is one
         extra doc-maintenance invocation. Global ~/.claude/CLAUDE.md gets an
         extra generalization-principles segment.

Stop
  │
  ├─ doc-exit.sh
  │      Derives the dirty .md file set from `git status --porcelain=v1 -z`,
  │      filters it through the shared exclusion predicate, and — if anything
  │      remains — hands the batch to doc-exit-report.py. Blocks once per Stop
  │      cycle with exit 2 + stderr when structural findings exist.
  │
  └─ tools/doc-exit-report.py
         Python engine (zero dependencies; builds and reuses body/title BM25
         indexes for the batch). Runs one link-graph pass over the whole repo and reports,
         per dirty file: stale_inlinks, orphan, dangling_refs, broken_outlinks,
         recall.
```

**Why this replaced the old dual PreToolUse gate (v1.7.2 → v2.0.0)**: the previous design (`skill-gate.sh` hard-denying until `doc-maintenance` was invoked, tracked via a `session_id`-keyed marker in `/tmp`) placed all enforcement at the moment content didn't exist yet. At that moment the only checkable signal is a proxy — "was the skill invoked" — while the actual target, "is the doc set self-consistent after the edit", can only be answered afterward. A marker proves the skill was called; it does not prove the workflow was followed. After context compaction the injected standards are long gone but the marker is still alive, so the old gate would silently pass work it could no longer verify.

**Invariant**: documentation-set consistency is a property of the repository's working tree, not of any one agent session. Corollary: whatever can be derived from the artifact should be derived, not asserted. The exit layer reads `git status` — a state that cannot be faked into satisfying the gate except by actually changing the working tree.

### Root Detection

Two independent root-detection paths exist for different consumers, and they must not be conflated:

1. **`tools/docs-graph.py` and `tools/recall-gate.py gate`** — both go through `tools/_doc_gate_common.py`'s `detect_root()`: walk up from the target file looking for the outermost `CLAUDE.md`; fall back to the first `.git` seen during the walk; fall back to `cwd()`. `recall-gate.py`'s `--root` flag (or `RECALL_GATE_ROOT` env var in its CLI wrapper) can override this explicitly.
2. **`scripts/doc-exit.sh`** — uses `git -C "$CWD" rev-parse --show-toplevel` exclusively. On a non-git working directory it exits quietly (`exit 0`) and does **not** fall back to `detect_root()`.

These two are deliberately kept apart, not unified. If the two algorithms disagreed on root, the paths `git status` reports and the paths the link-graph corpus indexes would desync — a worse failure mode than "no check ran", because it would surface as findings pointing at the wrong files rather than as an absence of findings.

### Exclusions

Both hooks skip files that shouldn't be governed, via a single shared predicate:

| Category | Examples |
|----------|---------|
| **Basename** (4) | `MEMORY.md`, `SKILL.md`, `CHANGELOG.md`, `LICENSE.md` (case-insensitive) |
| **Path** (9) | `.claude/*`, `.claude-plugin/*`, `.agents/*`, `node_modules/*`, `.git/*`, `logs/*`, `pipeline/*`, `intake/*`, `deliverables/*` |
| **Temp dirs** | `/tmp/*`, `/var/tmp/*`, `/var/folders/*`, `/private/tmp/*` |
| **Non-.md** | Any file not ending in `.md` (case-insensitive) |

`pipeline/*` covers deep-research's machine-generated intermediate artifacts. `intake/*` covers deep-research's G0 requirement-gate products, which the Lead generates semi-automatically before doc-maintenance is relevant.

`.agents/*` covers the whole team-ops runtime workspace, not just `.agents/directives/*` as an earlier version scoped it (#176). `directives/`, `intel/`, `handoffs/`, and `tasks/` are all protocol intermediate artifacts consumed by protocol machinery, not human readers, and downstream `.gitignore` setups already ignore the directory as a whole. Under the old architecture, the narrower scoping used to deny non-directives roles (e.g. `intel`) that had no `Skill` tool and thus no way to self-invoke doc-maintenance to unlock — and because teammates shared `session_id` with the main session while the marker was keyed by `session_id`, the failure showed up intermittently rather than consistently. Neither the marker nor `session_id` keying exists anymore, but the widened exclusion scope from that era remains correct on its own terms and is kept.

`*/deliverables/*` is excluded from entry-layer governance. Its rationale is independent of the old marker mechanics: deep-research's `deliverables/` is already governed by its own quality system (G1–G3 sufficiency gates plus a Stage 6 validation review), whose scope doesn't overlap with the doc-maintenance workflow this plugin enforces. That reasoning holds regardless of how entry/exit is implemented underneath, so the exclusion carries forward unchanged.

All path exclusions match on path *components* at any nesting depth, not just the project root — `*/deliverables/*` fires equally on `deliverables/final/report.md` and on `projects/x/deliverables/final/report.md`.

Both hooks share this exclusion list from a single source, `scripts/_doc_gate_exclude.sh` — add new exclusions there, not per-script. This list is allowed to **diverge** from the `EXCLUDED_DIRS` list in `tools/_doc_gate_common.py` (used to build the link-graph corpus for BM25/orphan/broken-link analysis): the shared predicate decides which edits trigger entry-layer injection and which dirty files the exit layer inspects, while `EXCLUDED_DIRS` decides which files are indexed as corpus content — different concerns, different audiences. `pipeline/*` and `intake/*` are excluded from both (machine-generated, not real content to recall against). `deliverables/*` is excluded from the shared predicate only — the corpus still indexes it, since deliverables remain real documentation worth surfacing in recall/orphan/broken-link checks even though editing them doesn't trigger entry-layer injection.

**Exception**: `~/.claude/CLAUDE.md` is always governed despite living under `.claude/` — it's the global config with the highest pollution surface, and `doc-entry.sh` bypasses all path exclusions for it (only the basename exclusions still apply).

#### Claude Code auto-memory

The exact Claude Code auto-memory exclusion is `.claude/projects/<project>/memory/` and all descendants, where `<project>` is exactly one directory component. When the Git root is `.claude`, the exit report does not treat this subtree as a report target, BM25 candidate, or link-graph node. In an ordinary repository, this rule does not exclude `memory/`, `docs/memory/`, or `projects/<project>/memory/`. Under a `.claude` Git root, a project's sibling `docs/`, `CLAUDE.md`, and `plans/` paths are not excluded by this rule; the existing `.claude` subdirectory exclusion remains unchanged. Links whose targets are in the excluded memory subtree do not produce dangling-link findings, whether the targets exist or not. A standalone report or recall invocation whose direct target is an excluded memory path returns the existing empty-result schema. The rule does not require the target to exist, read settings, or recognize custom auto-memory directories.

## Exit Gate Analysis

When `doc-exit.sh` fires, `doc-exit-report.py` runs a single link-graph pass and produces up to five finding categories per dirty file:

### stale_inlinks

Documents that link to this dirty file but were themselves not touched this session — their description of it may now be out of date. This is the core finding, and it is **self-terminating**: once those documents are edited too, they enter the dirty set and stop being reported on the next run.

### dangling_refs

Documents that still link to a path that no longer exists in the working tree. This covers the RENAME/ARCHIVE blind spot the old gate had no way to catch.

### broken_outlinks

Markdown links inside the dirty file's own content whose targets don't exist.

### orphan

The dirty file has zero inbound links from other documents. Deliberately **not** reported for files that have been deleted — a deleted file doesn't need inbound links, it needs everyone else to stop linking it, which is `dangling_refs`'s job, not `orphan`'s.

### recall

BM25 lexical recall (English words + Chinese bigrams) plus filename Jaccard similarity, scored against every `.md` file in the repo. Unlike the old recall-gate, the query is the dirty file's **final, on-disk content** — not a fragment of `new_string` captured mid-edit, which was never a reliable proxy for what the file ends up containing.

**`recall` does not participate in the block decision.** It is still computed and still rendered in the report, but it alone never causes `exit 2`. The other four are structural facts about the graph and are each actionable — editing the right file makes them go away. `recall` is a heuristic similarity signal that no edit can make disappear: putting it in the blocking predicate would mean the same recall pair gets flagged every single turn between now and commit, with no action available that satisfies it. A concrete false-positive from testing: root `CLAUDE.md` and `plugins/pr-review/skills/pr-review/references/claude-review.md` scored 0.357 mostly from filename Jaccard (both contain "claude"), with no actual content overlap.

In practice this means: a brand-new file has no inbound links yet, so it trips `orphan`, which drags `recall` along into the same rendered report — new content gets a duplicate-check signal for free. An edit to an already-indexed file that happens to duplicate existing content triggers no structural finding and thus no automatic signal; catching that case is left to periodic manual DEDUP (see `doc-maintenance` skill §5.6).

## docs-graph.py — Link Graph CLI

Standalone CLI for querying the document link graph. Zero dependencies, no persistent state, no hook consumes it directly.

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

`tools/recall-gate.py`'s `gate` subcommand also still exists as an independent CLI (BM25 + link-graph one-off query), but no hook calls it anymore — both entry and exit are wired through `doc-entry.sh` / `doc-exit.sh` / `doc-exit-report.py` instead.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DOC_ENTRY_GATE_DISABLED` | `0` | `1` disables the entry-layer injection (`doc-entry.sh`) |
| `DOC_EXIT_GATE_DISABLED` | `0` | `1` disables the exit-layer check (`doc-exit.sh`) |
| `DOC_EXIT_GATE_THRESHOLD` | `0.30` | Minimum BM25 recall score surfaced in the exit report |
| `DOC_EXIT_GATE_TOP_N` | `5` | Maximum recall results shown per file in the exit report |
| `DOC_EXIT_GATE_BUDGET_SEC` | `25` | Time budget (seconds) for the exit-layer check, in two tiers (see note below) |

`DOC_EXIT_GATE_BUDGET_SEC` covers **two** phases of the exit-layer check, not just recall:

- **Graph-build phase** (`os.walk` over the whole repo + reading every `.md`'s content): if this phase alone exceeds the budget, the check produces **no structural findings at all** — no `stale_inlinks` / `orphan` / `dangling_refs` / `broken_outlinks` for any file — and instead blocks once with a message naming both `DOC_EXIT_GATE_BUDGET_SEC` (raise it) and `DOC_EXIT_GATE_DISABLED` (turn the check off) as the two knobs to use.
- **Recall phase** (BM25 lexical query, runs only after the graph build finishes): if the remaining budget is exhausted here, every dirty file still gets its full structural checks and all of them are still reported — only the BM25 recall suggestion is dropped.

On a repo with a large `.md` corpus (this repo qualifies), lowering the budget can therefore flip the outcome from "all structural findings, no recall" to "no findings at all, just one block" — the two tiers are not interchangeable. The second tier says so in its own message rather than failing quietly, but the knob itself gives no hint that it governs two different behaviours.

There is deliberately **no `DOC_EXIT_GATE_ROOT`**: `doc-exit.sh`'s root is `git rev-parse --show-toplevel`, a single source. Adding an override would reintroduce the exact two-root-detection split described in `Root Detection` above.

`RECALL_GATE_ROOT` still exists, but it only applies to `tools/recall-gate.py gate` as a standalone CLI invocation — no hook reads it. There are no environment variables for that CLI's recall threshold or result count; those are `--threshold` / `--top-n` command-line arguments only (the old `RECALL_GATE_THRESHOLD` / `RECALL_GATE_TOP_N` env vars lived in the now-deleted `recall-gate.sh` hook wrapper, which read them and forwarded them as flags).

## Skill: doc-maintenance

The plugin bundles one skill (`skills/doc-maintenance/SKILL.md`) that provides structured documentation workflows:

- **Pre-flight**: layer validation, naming checks, duplicate detection
- **Execute**: guided by operation-specific checklists (CREATE / MODIFY / RENAME / ARCHIVE / RESTRUCTURE / DEDUP)
- **Post-flight**: index sync, broken link check, stale file cleanup

The skill also enforces graduated CLAUDE.md governance — global `~/.claude/CLAUDE.md` requires all four generalization criteria to pass; project-level CLAUDE.md uses them as guidelines.

The skill also carries a writing-standards reference (`references/writing-standards.md`) — an ambiguity layer (§A, hard constraints) plus a typography layer (§B, mechanical rules deferred to tooling once available). The CREATE/MODIFY checklists in §5.1/§5.2 point straight at that file. `doc-entry.sh`'s injected payload carries the unconditional A1-A13 judgment criteria plus an absolute path to the full reference, without a readable item digest — a digest previously let an agent mistake the summary for the rules and skip the reference entirely (#139).

## Tests

```bash
bats plugins/doc-gate/tests/doc-entry.bats
bats plugins/doc-gate/tests/doc-exit.bats
bats plugins/doc-gate/tests/exclude.bats
python3 -m pytest plugins/doc-gate/tests/ -q
bash plugins/doc-gate/tests/auto-memory-paths.sh plugins/doc-gate/tests/fixtures/auto-memory-paths.json plugins/doc-gate/scripts/_doc_gate_exclude.sh
bash -u plugins/doc-gate/tests/auto-memory-paths.sh plugins/doc-gate/tests/fixtures/auto-memory-paths.json plugins/doc-gate/scripts/_doc_gate_exclude.sh
```

The BM25 unit tests cover reusable body/title indexes, the legacy call interface, candidate ordering, and threshold boundaries.

| Suite | Coverage |
|-------|----------|
| `doc-entry.bats` | Filters, exclusions, injection payload shape, global-CLAUDE.md segment, kill switch, fail-open |
| `doc-exit.bats` | git-status parsing (incl. rename records in either column), stop_hook_active gating, background_tasks mid-flight skip, non-git repo, exclusion filtering, finding rendering, kill switch, robustness (space in path, deleted file), `--dirty-superset-file` transport end-to-end |
| `exclude.bats` | Shared `_doc_gate_exclude.sh` predicate — basename and path exclusions (incl. relative & nested paths), governed paths |
| `test_bm25.py` | Body/title index scoring, legacy list and body-only inputs, sparse postings in query Counter order, one normalization per document, zero-score and self/whitelist boundaries, stable candidate ordering, and pre-rounding thresholds |
| `test_doc_exit_report.py` | `build_report()`: one body/title-index build per batch, stale_inlinks, orphan (including deleted-file suppression), dangling_refs, broken_outlinks, non-blocking recall, budget degradation, and `read_nul_paths_from_file` NUL-not-newline parsing |
| `test_exclude.py` | Shared exclusion predicate parity checks |
| `test_auto_memory.py` | Root-aware exclusion, no reads from `memory/`, link exemptions, standalone empty results, and zero-budget behavior |
| `auto-memory-paths.sh` + `fixtures/auto-memory-paths.json` | Shared Shell/Python auto-memory path matrix, validated with Bash 3.2 and Bash 5 under `-u` |

## Known Boundaries

- **Non-git working directories**: the exit check is entirely inert — `doc-exit.sh` exits quietly the moment `git rev-parse --show-toplevel` fails, with no fallback root-detection path.
- **Mid-session commits**: a `.md` file edited and then `git commit`-ed before the turn ends drops out of `git status` and bypasses the exit check for that turn. Catching this would require session-start-snapshot state, which contradicts the zero-state design premise; the fallback is PR-level review.
- **Files dirty before the session started**: these are checked too, by design — the invariant is about the working tree's current state, not about what this session touched, so the rendered message deliberately says "currently uncommitted" rather than "modified this session."
- **User interrupts / force-kills**: `Stop` doesn't fire on these, so no exit check runs. This is still an improvement over the old architecture, where an interrupt left behind an active marker that falsely proved "the skill was invoked", producing a false-pass; the new architecture just fails to run the check, with no misleading state left behind.
- **Injection payload growth**: `doc-entry.sh`'s payload size is constant per edit (it doesn't grow with edit count), but it is re-injected on every matching edit — a deliberate trade-off, made so the criteria survive context compaction instead of degrading over a long session.
- **`isolation:"worktree"` subagent edits**: changes made inside an isolated worktree are not visible to the parent tree's `git status`. Since the hook process's `cwd` equals the session's `cwd`, whichever worktree is being edited in is the one being checked — coverage isn't lost, it's just scoped to the worktree the edit actually happened in.
- **Duplicate content in already-indexed files**: no automatic signal exists for this case (see `recall` in Exit Gate Analysis above); it's left to periodic manual DEDUP.

## Version History

See [GitHub Issues](https://github.com/WooDragon/cc-plugins/issues) for detailed change logs:

- **v2.0.0** — Behavior-breaking rearchitecture: replaced the dual PreToolUse gate (`skill-gate.sh` hard gate + `recall-gate.sh` soft gate + `skill-marker.sh`) with a PostToolUse entry-injection layer (`doc-entry.sh`) and a Stop exit-judgment layer (`doc-exit.sh` + `doc-exit-report.py`). All `SKILL_GATE_*` and hook-level `RECALL_GATE_*` environment variables removed; the session-scoped marker protocol removed entirely; new `DOC_ENTRY_GATE_*` / `DOC_EXIT_GATE_*` variables introduced. `recall` finding demoted to non-blocking; `dangling_refs` and `stale_inlinks` added as new blocking findings not present under the old architecture.
- **v1.7.2** — `.agents/*` exclusion widened from `.agents/directives/*` — the narrower scope denied other team-ops runtime artifacts (`intel/`, `handoffs/`, `tasks/`), and non-`Skill`-equipped roles like `intel` had no way to self-unlock (#176)
- **v1.7.1** — Removed the writing-standards item digest from both delivery points (SKILL.md §2 table and the `skill-gate.sh` deny message): a readable digest created false satiety, so the model skipped `references/writing-standards.md` and self-checked against rules it never read. Both now carry an unconditional imperative plus the authoritative path only; §5.1/§5.2 checklist pointers go straight to the reference instead of hopping through §2 (#139)
- **v1.7.0** — Writing-standards reference added (`references/writing-standards.md`): an ambiguity layer (§A, STE-inspired hard constraints) and a typography layer (§B, mechanical/tool-deferrable); SKILL.md §5.1/§5.2 checklists gained corresponding checks; `skill-gate.sh` deny messages now inject a condensed summary with an absolute path to the full reference (#136)
- **v1.6.0** — `*/deliverables/*` excluded from the gate (ADR-010 conflict: no legitimate pass-through path under subagent-scoped markers, 100% observed bypass); gate exclusion list intentionally diverges from the recall-gate corpus's `EXCLUDED_DIRS`, which still indexes deliverables (#124)
- **v1.5.0** — Path exclusions collapsed to single source (`_doc_gate_exclude.sh`); added `pipeline/*` exclusion for deep-research intermediate artifacts, `deliverables/*` remains governed
- **v1.2.1** — Root detection: CLAUDE.md co-occurrence anchor for monorepo support (#22)
- **v1.2.0** — Recall gate: BM25 lexical recall + link graph triple-dimension gate
- **v1.0.4** — Deny message discourages env-var bypass
- **v1.0.3** — CLAUDE.md governance + global tiering + team-ops exclusion
