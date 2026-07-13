# deep-research

Deep research framework for Claude Code — drives structured, multi-stage research through a **7-Stage pipeline**, four **role-specialized subagents** (harvester / analyst / reviewer / publisher), **4 quality gates**, and a multi-model harvesting engine with deterministic citation verification.

The framework treats the main session as a **Lead** that orchestrates the pipeline: it dispatches采集 to `research-harvester`, decomposition/synthesis to `research-analyst`, sufficiency/quality review to `research-reviewer`, and final HTML rendering to `research-publisher`, gating each stage transition (G0–G3). A `SubagentStop` hook mechanically verifies any `GATE_VERDICT: G1 PASS` claim against the harvest engine's citation journal — fail-open on anything uncertain, block only on a proven false PASS.

## Installation

```bash
claude plugin add deep-research@WooDragon-cc-plugins
```

## Prerequisites

The methodology (skill + subagents) works out of the box. The **multi-model harvest engine** (`scripts/harvest.py`) needs external credentials — without them the framework still runs via the legacy manual search chain (see the skill's `references/context-economics.md`).

| Dependency | Needed for | How |
|------------|-----------|-----|
| `GATEWAY_API_KEY` (env) | harvest.py panel models (gemini/gpt/claude via your OpenAI-compatible gateway) **and the primary `gemini-grounding` search backend** | Set gateway `base_url` + key in `scripts/harvest.config.json` / env |
| `curl_cffi` (Python, optional) | `curl-cffi` fetch backend (direct free fetch) | `pip3 install --user curl_cffi` — else harvest.py exits 4 with install hint |
| `TAVILY_API_KEY` / `JINA_API_KEY` (env, optional) | tavily/jina search & fetch fallbacks | Set as env vars if used |
| `grok` CLI (optional, `grok login`) | `grok-4.5` panel model + `grok-x` social search backend | Install locally + authenticate; if absent, `grok-*` panel models and `grok-x` social backends are dropped/skipped and the pipeline still completes |
| Python 3 | harvest.py + gate_check.py (stdlib only) | System Python 3 |

harvest.py **never silently degrades**: if multi-model harvesting is unavailable it exits 3 (`UNAVAILABLE`) and blocks — recovery is either fixing the setup and re-running, or an explicit user-signed `legacy-exemption.md`. An incomplete study masquerading as complete is worse than a visible failure.

## Components

```
deep-research/
├── skills/deep-research/       # SKILL.md router + references/ (framework docs) + assets/ (templates)
├── agents/                     # 4 native subagents
│   ├── research-harvester.md   # Stage 2-3: acquisition + sanitization
│   ├── research-analyst.md     # Stage 4-5: decomposition + synthesis
│   ├── research-reviewer.md    # G1/G2/G3 sufficiency + Validation review
│   └── research-publisher.md   # Stage 7: renders the approved report to self-contained HTML
├── scripts/
│   ├── harvest.py              # multi-model harvest + deterministic citation verification
│   ├── harvest.config.json     # gateway / panel models / search & fetch & social_search backend chains
│   ├── harvest_search/social.py     # independent search_social tool chain (grok-x / X-Twitter)
│   ├── harvest_clients/grok_cli.py  # grok-4.5 panel client (local grok CLI, two-phase tool-use fake)
│   ├── harvest_clients/grok_exec.py # shared grok CLI subprocess exec + JSON salvage (leaf module)
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

Invoke the `deep-research` skill (it auto-triggers on research-type tasks). The Lead then walks the 7 stages, spawning subagents as `deep-research:research-harvester` / `:research-analyst` / `:research-reviewer` / `:research-publisher`.

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
| `test_harvest.py` | multi-model harvest, citation verification, SSRF guard, exit-code semantics |
| `test_gate_check.py` | SubagentStop gate: PASS-claim verification, project-dir location, fail-open behavior |

## Version History

- **v1.14.0** — Two additions, both built on a shared leaf module (`harvest_clients/grok_exec.py`, subprocess exec + JSON salvage for the local `grok` CLI): (1) **`grok-4.5` panel model** via `harvest_clients/grok_cli.py` — grok has no gateway HTTP endpoint, so `GrokCliClient` fakes `run_worker`'s two-phase tool-use contract on top of a single-shot CLI call (phase 1: grok researches + drafts findings, its claimed URLs come back as synthetic `fetch` tool_calls; phase 2: findings are filtered down to only the URLs that phase 2's independent re-fetch actually verified). The citation-verifiability rule stays intact — grok's own say-so is never trusted, every URL is independently re-fetched through the existing fetch/journal machinery. (2) **Independent social search** — a new `search_social` tool backed by its own `social_search_backends` chain (type `grok-x`, X/Twitter search via the same `grok` CLI), pulled out of the web `do_search` first-success chain so a social-search failure never blocks web search or vice versa; domain filtering is hard-restricted to X/Twitter hosts. Both features degrade gracefully when the `grok` CLI isn't installed: `grok-*` panel models are dropped from the roster, `grok-x` social backends are skipped, and the pipeline still completes rather than failing. A legacy `x-search` config key is auto-migrated in-memory into `social_search_backends` for backward compatibility.
- **v1.1.5** — Real grounded fallback search: the `gateway-gemini` backend (which asked an OpenAI-compat `/chat/completions` to "list some URLs" and got model-recalled, hallucinated links with no live retrieval) is replaced by `gemini-grounding`, which hits the gateway's Gemini-native `/v1beta/models/<model>:generateContent` endpoint with the built-in `google_search` tool. Grounding chunks carry redirect-wrapped real source URLs, resolved to true landing pages (302 `Location` read **without following**, connecting only to the fixed `vertexaisearch.cloud.google.com` host — a hallucinated/injected `uri` is rejected before any byte leaves the process) before entering the citation-verifiable pipeline. This also fixes the fake backend permanently masking the real tavily/duckduckgo backends behind it in `do_search`'s first-hit-wins loop.
- **v1.1.3** — Model refresh: panel `claude-sonnet-4-6` → `claude-sonnet-5`; fallback `gateway-gemini` search backend `gemini-2.5-flash` → `gemini-3.5-flash` (plus the mirrored default in `harvest.py`, doc examples, and test fixture). The `startswith("claude")` dispatch keeps `claude-sonnet-5` on the Anthropic-native `/messages` path (prompt caching intact).
- **v1.1.2** — `create-research-project.sh` scaffolds into `projects/` idempotently: a path-segment `case` resolves the single `projects/` root no matter where cwd sits in the tree, so it appends exactly once and never nests. Fixed two stale `framework/*.md` references in `assets/` templates (→ skill `references/`).
- **v1.0.0** — Initial release: extracted from the standalone research framework v3 into a distributable plugin; 3 roles converted to native subagents; harvest.py + gate_check.py path-decoupled from the framework repo.

