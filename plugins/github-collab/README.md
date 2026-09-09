# github-collab

GitHub maintainer/collaborator workflow skill for Claude Code — teaches Claude how each role actually works once a repository is set up as "maintainer owns main and issues, collaborators can only open PRs and issues, not merge code."

A **pure skill plugin** (no hooks, no scripts). It injects two role-specific workflows plus a friction-point lookup table, so both sides of a maintainer/collaborator repo get concrete next steps instead of generic Git advice.

## Installation

```bash
# From marketplace
claude plugin marketplace add WooDragon/cc-plugins
claude plugin install github-collab@cc-plugins
```

## What it does

| Role | What the skill covers |
|------|------------------------|
| **Maintainer** | Assigning issues at the right granularity, triaging incoming PRs (CI first, then code), delegating first-pass review to AI while owning the accept/reject call, `Request changes` vs. comment, merging with squash + delete-branch, and the `--admin` bypass needed to merge your own PR (GitHub forbids self-approval) |
| **Collaborator** | Claiming an issue, same-repo branch vs. fork (token scope and first-time-contributor gotchas), what a PR description should contain, diagnosing your own CI failures, responding to review comments line by line, and why `BLOCKED` / `REVIEW_REQUIRED` is expected — not a permission bug |
| **Friction lookup** | A symptom → root cause → who-fixes-it table for the ways a PR gets stuck: red CI, a check stuck pending forever, unresolved review threads, a stale branch, unmatched CODEOWNERS |
| **Repo setup (appendix only)** | Personal-account permission granularity vs. organizations, a copy-pasteable branch protection payload, and four traps: `enforce_admins` deadlock on single-maintainer repos, conditional-job required checks that never resolve, CODEOWNERS needing to land on the default branch first, and the `paths-ignore` vs. required-check tradeoff |

It deliberately points to the `pr-review` skill for AI review backends/commands rather than duplicating them, and does not cover GitHub Enterprise org migration runbooks or non-GitHub platforms (CODEOWNERS, `enforce_admins`, and required status checks are GitHub-specific concepts).

## Triggering

Activation is purely semantic — the skill's `description` covers both roles' phrasing: "how do I handle a collaborator's PR" / "how do I assign work to a collaborator" as well as "how do I open a PR against this repo" / "how do I respond to review feedback" / "my PR shows BLOCKED and won't merge". No hook, no manual invocation required.

**Why no hook?** None of the steps in either workflow — opening a branch, pushing a PR, responding to review — produces a decidable tool-level signal. A `PreToolUse` matcher sees the tool name, not the intent, and gating high-frequency Bash/git calls would cost more than it catches. Semantic matching leaves the judgment to the model that reads the description every turn.

## Skill: github-collab

The plugin bundles one skill (`skills/github-collab/SKILL.md`) covering role boundaries, the maintainer's event-ordered workflow, the collaborator's event-ordered workflow, a friction-point lookup table, and a one-time repo-setup appendix.
