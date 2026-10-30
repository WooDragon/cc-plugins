# code-search

Code search & symbol navigation skill for Claude Code — teaches Claude to pick the right tool by search intent instead of reflexively running `grep -r`.

A **pure skill plugin** (no hooks, no scripts). It injects a code-search methodology so any "find this in the codebase" task routes to the right tool with the right strategy.

## Installation

```bash
# From marketplace
claude plugin marketplace add WooDragon/cc-plugins
claude plugin install code-search@cc-plugins
```

## What it does

| Symptom | Tool |
|---------|------|
| Locate an exact name in a known file | **grep**, then read the relevant source; no index required |
| Disambiguate symbol definitions, kinds, or multiline declarations | **ctags** on candidate files, then **readtags** |
| Navigate repeatedly across files | Reuse a task-local **ctags** index |
| Find code matching an **AST structure shape** (imports, calls, JSX nodes, try/catch) | **ast-grep** (`ast-grep run -p`) |
| Find **callers** / reference candidates / plain text | **grep**, then verify the source |
| Resolve precise type-dependent relationships | **LSP/SCIP** (gopls, rust-analyzer, SCIP) |

The skill includes source examples for TSX structure matching and ctags/readtags navigation. It distinguishes TypeScript, TSX, and JavaScript/JSX parsers and keeps index generation and lookup on the same tags path.

An index provides navigation hints; current source is authoritative. `git ls-files` lists tracked files by default: it can omit untracked source and include tracked generated files. Index filters and stale tags can also omit relevant symbols.

Return only the paths, locations, or source needed for the question. Narrow excessive results before expanding output. Empty results do not prove absence, and local, filtered, or truncated results do not prove completeness. Offload unpredictable, broad exploration to a sub-agent when the environment supports isolation; this is not evidence of measured net token savings.

## Triggering

Activation is semantic: the skill's `description` covers code-search and symbol-navigation tasks. Claude uses that description to decide when to load the skill; no hook or manual invocation is required.

**Why no hook?** There's no decidable signal for "this tool call is a code search" — searches run through Grep, Glob, Bash (`grep`/`rg`/`ast-grep`/`find`), and Read interchangeably, and a PreToolUse matcher only sees the tool name, not intent. Gating a high-frequency action would also wreck the workflow. Semantic matching hands the judgment to the model that already reads the description every turn.

## Skill: code-search

The plugin bundles one skill (`skills/code-search/SKILL.md`) covering the tool decision tree, intent-based strategy, combination techniques, context economy, and anti-patterns.
