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
| [plan-review](./plugins/plan-review/) | Adversarial plan review via cross-model consultation (Gemini/Claude) |
| [doc-gate](./plugins/doc-gate/) | Document editing governance — skill gate + lexical recall advisory + link graph tools |
| [ppt-press](./plugins/ppt-press/) | PPT toolkit — editorial magazine × e-ink web presentation skills |
| [code-search](./plugins/code-search/) | Code search & symbol navigation — pick the right tool by search intent |

## Skills

| Skill | Plugin | Description |
|-------|--------|-------------|
| [ppt-create](./plugins/ppt-press/skills/ppt-create/) | ppt-press | Generate editorial magazine × e-ink web presentations (Astro) |
| [ppt-deploy](./plugins/ppt-press/skills/ppt-deploy/) | ppt-press | Build, test, and deploy PPT decks to AWS Amplify |
| [ppt-manage](./plugins/ppt-press/skills/ppt-manage/) | ppt-press | List, search, and retrieve PPT deck URLs |
| [doc-maintenance](./plugins/doc-gate/skills/doc-maintenance/) | doc-gate | Document maintenance workflow with pre/post-flight checks |
| [code-search](./plugins/code-search/skills/code-search/) | code-search | Pick the right search tool (ast-grep/grep/glob) by intent |
