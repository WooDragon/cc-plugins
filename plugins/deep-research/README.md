# deep-research

Deep research framework for Claude Code — drives structured, multi-stage research through a **7-Stage pipeline**, three **role-specialized subagents** (harvester / analyst / reviewer), **4 quality gates**, and a multi-model harvesting engine with deterministic citation verification.

The framework treats the main session as a **Lead** that orchestrates the pipeline: it dispatches采集 to `research-harvester`, decomposition/synthesis to `research-analyst`, and sufficiency/quality review to `research-reviewer`, gating each stage transition (G0–G3). A `SubagentStop` hook mechanically verifies any `GATE_VERDICT: G1 PASS` claim against the harvest engine's citation journal — fail-open on anything uncertain, block only on a proven false PASS.

## Installation

```bash
claude plugin add deep-research@WooDragon-cc-plugins
```

## Prerequisites

The methodology (skill + subagents) works out of the box. The **multi-model harvest engine** (`scripts/harvest.py`) needs external credentials — without them the framework still runs via the legacy manual search chain (see the skill's `references/context-economics.md`).

| Dependency | Needed for | How |
|------------|-----------|-----|
| `GATEWAY_API_KEY` (env) | harvest.py panel models (gemini/gpt/claude via your OpenAI-compatible gateway) | Set gateway `base_url` + key in `scripts/harvest.config.json` / env |
| `agy` CLI | primary search backend | Install per your `agy` setup |
| `curl_cffi` (Python, optional) | `curl-cffi` fetch backend (direct free fetch) | `pip3 install --user curl_cffi` — else harvest.py exits 4 with install hint |
| `TAVILY_API_KEY` / `JINA_API_KEY` (env, optional) | tavily/jina search & fetch fallbacks | Set as env vars if used |
| Python 3 | harvest.py + gate_check.py (stdlib only) | System Python 3 |

harvest.py **never silently degrades**: if multi-model harvesting is unavailable it exits 3 (`UNAVAILABLE`) and blocks — recovery is either fixing the setup and re-running, or an explicit user-signed `legacy-exemption.md`. An incomplete study masquerading as complete is worse than a visible failure.

## Components

```
deep-research/
├── skills/deep-research/       # SKILL.md router + references/ (framework docs) + assets/ (templates)
├── agents/                     # 3 native subagents
│   ├── research-harvester.md   # Stage 2-3: acquisition + sanitization
│   ├── research-analyst.md     # Stage 4-5: decomposition + synthesis
│   └── research-reviewer.md    # G1/G2/G3 sufficiency + Validation review
├── scripts/
│   ├── harvest.py              # multi-model harvest + deterministic citation verification
│   ├── harvest.config.json     # gateway / panel models / search & fetch backend chains
│   └── create-research-project.sh   # scaffold a research project in the current directory
└── hooks/
    ├── hooks.json              # SubagentStop → gate_check.py
    └── gate_check.py           # mechanical G1 citation-verification gate (fail-open)
```

## Usage

### Create a research project

Run from the directory where you want the project (e.g. your research archive repo):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/create-research-project.sh" "研究主题" --type web-research
```

This scaffolds `pipeline/{1_raw,2_cleaned,3_structured,4_extracted}` + `intake/` + `deliverables/` + a project `CLAUDE.md` and a safety `.gitignore` (raw/cleaned data is git-ignored by default).

### Run the pipeline

Invoke the `deep-research` skill (it auto-triggers on research-type tasks). The Lead then walks the 7 stages, spawning subagents as `deep-research:research-harvester` / `:research-analyst` / `:research-reviewer`.

### Harvest path discovery (how the Lead feeds harvest.py to the harvester)

`harvest.py` lives at `${CLAUDE_PLUGIN_ROOT}/scripts/harvest.py`, but that variable is not expanded inside subagent prompt bodies. Before spawning `research-harvester`, the Lead resolves the absolute path and passes it in the Task instruction:

```bash
find ~/.claude/plugins -path '*/deep-research/scripts/harvest.py' 2>/dev/null | head -1
```

## The Framework

| Layer | Where | What |
|-------|-------|------|
| Principles | `references/principles.md` | Meta-principle 0 (burden-of-proof anchoring) + 6 mandatory principles |
| Pipeline | `references/pipeline.md` | 7 stable stages + experimental Stage 8 (Landing) + inter-stage contracts + gate triggers |
| Quality gates | `references/quality-gates.md` | G0 requirement gate, 3-tier verdict, sufficiency tri-state, 8-dimension rubric |
| Context economics | `references/context-economics.md` | Task-isolation rules, role selection, search tool chain |
| Playbooks | `references/playbooks-INDEX.md` | `web-research` / `data-extraction` execution manuals |
| Templates | `assets/` | project CLAUDE.md, research-goal, fetch-report, rubrics, redact scaffold |

## Tests

```bash
python3 -m pytest plugins/deep-research/tests/
```

| Suite | Coverage |
|-------|----------|
| `test_harvest.py` | multi-model harvest, citation verification, consensus labels, SSRF guard, exit-code semantics |
| `test_gate_check.py` | SubagentStop gate: PASS-claim verification, project-dir location, fail-open behavior |

## Version History

- **v1.1.2** — `create-research-project.sh` scaffolds into `projects/` idempotently: a path-segment `case` resolves the single `projects/` root no matter where cwd sits in the tree, so it appends exactly once and never nests. Fixed two stale `framework/*.md` references in `assets/` templates (→ skill `references/`).
- **v1.0.0** — Initial release: extracted from the standalone research framework v3 into a distributable plugin; 3 roles converted to native subagents; harvest.py + gate_check.py path-decoupled from the framework repo.

