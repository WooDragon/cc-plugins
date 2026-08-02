# cc-plugins

WooDragon's CC plugin & skill marketplace.

## Installation

**Plugins:**

```bash
claude plugin add WooDragon/cc-plugins
```

**Skills:**

```bash
npx skills add WooDragon/cc-plugins -g
```

## Plugins

| Plugin | Description |
|--------|-------------|
| [plan-review](./plugins/plan-review/) | Adversarial plan review via cross-model consultation (agy/Claude) |
| [doc-gate](./plugins/doc-gate/) | Document editing governance — skill gate + lexical recall advisory + link graph tools |
| [ppt-press](./plugins/ppt-press/) | Self-contained PPT publishing — scaffold + create + deploy + manage |
| [code-search](./plugins/code-search/) | Code search & symbol navigation — pick the right tool by search intent |
| [deep-research](./plugins/deep-research/) | Deep research framework — 7-Stage pipeline + role-specialized subagents + multi-model harvest & citation-verification gate |
| [pr-review](./plugins/pr-review/) | AI review for open GitHub PRs — grok CLI local synchronous review (default, multi-round follow-up) + Copilot bot asynchronous review (optional) |
| [dispatch-contract](./plugins/dispatch-contract/) | Subagent dispatch contract — four dispatch rules + `%%DONE%%` finalization gate (SubagentStop) |

## Skills

| Skill | Plugin | Description |
|-------|--------|-------------|
| [ppt-init](./plugins/ppt-press/skills/ppt-init/) | ppt-press | Scaffold a new Astro-based PPT framework project from scratch |
| [ppt-create](./plugins/ppt-press/skills/ppt-create/) | ppt-press | Generate editorial magazine × e-ink web presentations (Astro) |
| [ppt-deploy](./plugins/ppt-press/skills/ppt-deploy/) | ppt-press | Build, test, and deploy PPT decks to AWS Amplify |
| [ppt-manage](./plugins/ppt-press/skills/ppt-manage/) | ppt-press | List, search, and retrieve PPT deck URLs |
| [doc-maintenance](./plugins/doc-gate/skills/doc-maintenance/) | doc-gate | Document maintenance workflow with pre/post-flight checks |
| [code-search](./plugins/code-search/skills/code-search/) | code-search | Pick the right search tool (ctags/ast-grep/grep) by intent |
| [deep-research](./plugins/deep-research/skills/deep-research/) | deep-research | Router skill for the 7-stage research pipeline + quality gates |
| [pr-review](./plugins/pr-review/skills/pr-review/) | pr-review | Review an open PR by number — grok (default) or Copilot bot backend |
| [subagent-dispatch](./plugins/dispatch-contract/skills/subagent-dispatch/) | dispatch-contract | Four dispatch rules + `%%DONE%%` finalization contract for subagent delegation |

## Basic Usage

Each plugin's own README has full detail (env vars, architecture, test suites). This is the minimal path to trying each one.

**plan-review** — fully automatic, no invocation needed. Enter plan mode as usual; when Claude calls `ExitPlanMode`, the plugin intercepts the plan for adversarial cross-model review before it reaches you.

**doc-gate** — also automatic. Editing any `.md` file triggers the gate; if `doc-maintenance` hasn't been invoked this session, Claude is prompted to call it first. To use the workflow directly: ask Claude to "创建/更新文档" and it will invoke `doc-maintenance` and follow the pre/post-flight checklist.

```bash
# standalone link-graph queries, no skill invocation needed
python3 plugins/doc-gate/tools/docs-graph.py check
```

**ppt-press** — scaffold → create → deploy, driven entirely through conversation:

```bash
mkdir my-ppt && cd my-ppt
# tell Claude Code: "初始化 PPT 项目"   → ppt-init scaffolds the framework
# tell Claude Code: "帮我做一个关于 XX 的 PPT"  → ppt-create generates the deck
# tell Claude Code: "部署上线"          → ppt-deploy builds, tests, and ships it
```

**code-search** — nothing to invoke; it's a pure methodology skill that activates whenever a request looks like "find X in the codebase" (definition lookup, caller search, AST-shape match).

**deep-research** — scaffold a research project, then let the skill drive the pipeline:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/create-research-project.sh" "研究主题" --type web-research
# then ask Claude Code a research question in that directory — the deep-research skill
# auto-triggers and orchestrates harvester/analyst/reviewer subagents through the 7 stages
```

**pr-review** — check out the PR's branch, then ask Claude Code to "评审 PR 123" / "grok review PR 123". The grok backend prints the review to your terminal and keeps a session so follow-up rounds only send the incremental diff; the Copilot backend is opt-in and posts back onto the PR instead.

**dispatch-contract** — also automatic. When Claude dispatches a subagent and the prompt contains `%%DONE%%`, the SubagentStop gate verifies that the subagent's final non-empty line is exactly that marker. If it isn't, the gate blocks the stop once and injects a correction directive asking the subagent to complete its report and end with `%%DONE%%`. The bundled `subagent-dispatch` skill is invoked when you or Claude asks about subagent delegation; it inlines the four dispatch rules, offload-scenario guidance, and mailbox/liveness patterns directly into the conversation.

```bash
# To require a finalized report, append this line verbatim to your dispatch prompt:
# 末尾单独一行输出 %%DONE%%。
# The gate is fail-open: no %%DONE%% in the prompt → gate stays silent.
export ALLOW_UNMARKED_FINAL=1  # escape hatch if needed
```
