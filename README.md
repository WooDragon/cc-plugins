# cc-plugins

WooDragon's CC plugin & skill marketplace.

## Installation

**Plugins:**

```bash
claude plugin add WooDragon/cc-plugins
```

**Skills (PPT toolkit):**

```bash
npx skills add WooDragon/cc-plugins -g
```

## Plugins

| Plugin | Description |
|--------|-------------|
| [plan-review](./plugins/plan-review/) | Adversarial red-team review of implementation plans via Gemini/Claude |

## Skills (via ppt-press plugin)

| Skill | Description |
|-------|-------------|
| [ppt-create](./plugins/ppt-press/skills/ppt-create/) | Generate editorial magazine × e-ink web presentations (Astro) |
| [ppt-deploy](./plugins/ppt-press/skills/ppt-deploy/) | Build, test, and deploy PPT decks to AWS Amplify |
| [ppt-manage](./plugins/ppt-press/skills/ppt-manage/) | List, search, and retrieve PPT deck URLs |
