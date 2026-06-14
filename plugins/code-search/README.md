# code-search

Code search & symbol navigation skill for Claude Code — teaches Claude to pick the right tool by search intent instead of reflexively running `grep -r`.

A **pure skill plugin** (no hooks, no scripts). It injects a code-search methodology so any "find this in the codebase" task routes to the right tool with the right strategy.

## Installation

```bash
# From marketplace
claude plugin add code-search@WooDragon-cc-plugins
```

## What it does

| Symptom | Tool |
|---------|------|
| Find a symbol's **definition** / jump to definition | **ctags** (`ctags -R` index → `readtags` lookup) |
| Find code matching an **AST structure shape** (imports, call forms, component defs, try/catch) | **ast-grep** (`ast-grep run -p`) |
| Find **callers** / plain text / strings | **grep** (1–2 hops suffice) |
| Precise call graph when grep/ctags fall short | **LSP/SCIP** (gopls, rust-analyzer, SCIP) |

Plus anti-pattern correction (never grep for definitions), ctags command templates (.tsx langmap, kind filters, dependency exclusion via `git ls-files | ctags -L -`), and context-economy rules (offload large searches to a sub-agent).

## Triggering

Activation is purely semantic — the skill's `description` enumerates code-search scenarios and triggers across Chinese/English keywords and colloquial phrasings ("where is X defined", "who calls X", "全局搜 TODO", "find references"…). No hook, no manual invocation: any code-search / symbol-navigation task surfaces it.

**Why no hook?** There's no decidable signal for "this tool call is a code search" — searches run through Grep, Glob, Bash (`grep`/`rg`/`ast-grep`/`find`), and Read interchangeably, and a PreToolUse matcher only sees the tool name, not intent. Gating a high-frequency action would also wreck the workflow. Semantic matching hands the judgment to the model that already reads the description every turn.

## Skill: code-search

The plugin bundles one skill (`skills/code-search/SKILL.md`) covering the tool decision tree, intent-based strategy, combination techniques, context economy, and anti-patterns.
