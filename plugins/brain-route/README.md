# brain-route

Routing reminder for Claude Code — prompts consideration of second-brain (cross-project memory) vs local project memory when writing project memory `.md` files. The plugin also packages two second-brain operation skills, `brain-recall` and `brain-curate`.

When Claude writes or edits a file under `*/memory/*.md` (excluding `MEMORY.md` itself, which is an index file) and the content looks like a cross-project engineering lesson, the hook denies once and surfaces a reminder to consider routing the content to second-brain via the `brain-recall` skill instead of the local file. The hook performs no deduplication and makes no network requests — pure local string matching, millisecond-scale. It is a soft reminder, not a hard gate: retrying the same write after the reminder always passes.

## Installation

```bash
# From marketplace
claude plugin add brain-route@WooDragon-cc-plugins
```

## Backend Dependency

The `brain-recall` and `brain-curate` skills require a running second-brain backend instance. The hook does not — it performs no network calls, only local string matching against files already on disk. Installing this plugin without a backend leaves the hook fully functional; only the two skills become unusable.

The backend project is [`WooDragon/second-brain-cloudflare`](https://github.com/WooDragon/second-brain-cloudflare) (MIT, public), a fork of `rahilp/second-brain-cloudflare`. It runs on Cloudflare Workers and uses D1 (SQLite) for storage, Vectorize for the vector index, Workers AI for embedding and LLM inference, and KV for OAuth registrations. All of these fit within the Cloudflare free tier.

The backend requires one secret, `AUTH_TOKEN`. This is the same value the skills expect in `SECOND_BRAIN_TOKEN` — set the backend's `AUTH_TOKEN` and the skill's `SECOND_BRAIN_TOKEN` to the identical string.

Self-hosting steps (commands from the backend repo's `package.json`):

```bash
npm run db:create          # create the D1 database
npm run db:migrate:remote  # apply the schema
npm run vectors:create     # create the Vectorize index (cosine metric)
wrangler secret put AUTH_TOKEN
npm run deploy
```

**Chinese-language (CJK) corpora must use the `downstream` branch.** The `main` branch tracks upstream and embeds with `@cf/baai/bge-small-en-v1.5` (384 dimensions). For CJK content, `main`'s recall measures zero — not merely weak multilingual model performance: the query normalization in `src/recall/distill.ts` strips non-ASCII characters with a `\w`-based regex, so CJK text is emptied out before it ever reaches the embedding call. The `downstream` branch fixes this: it switches the embedding model to `@cf/qwen/qwen3-embedding-0.6b` (1024 dimensions, asymmetric query/document embedding) and fixes CJK tokenization. Deploy `downstream` directly for Chinese-language use.

Index dimensions must match the branch, and each branch's `vectors:create` script already carries the right value — `downstream` creates the index at 1024 dimensions, `main` at 384. Because dimensions are fixed at creation, check out the intended branch before running `npm run vectors:create` — switching later requires recreating the index and re-ingesting every stored vector. The full model-migration procedure (new index, redeploy, re-ingestion) is outside the scope of this README; see the backend repo's own documentation and its `/migration/*` routes.

## Hooks

```
PreToolUse:Write|Edit
  │
  └─ brain-route-gate.sh (5s timeout)
         Soft advisory — on first write of each memory .md file this session,
         scores content against a signal-word list. Deny-once-per-file
         (retry passes). Fail-open on all anomalies.
```

### Path Filter

Only fires on paths matching `*/memory/*.md`, excluding `memory.md` (index file, not a memory entry). Both the path glob and the basename exclusion are case-insensitive (macOS/APFS is case-insensitive by default, so `MEMORY.md` / `Memory.md` / `memory.md` are the same file).

### Content Judge

Scores content against a fixed signal-word list (`worktree`, `门禁`, `printf`, `subagent`, `fail-open`, `逃生舱`, `夹具`, `假绿`, `payload`, `并行`, `bats`, `pathspec`). Fires only when the count of distinct matched words reaches `BRAIN_ROUTE_MIN_HITS` (default 2). ASCII/hyphenated words are matched with a word boundary (not a bare substring), so e.g. `fail-open` won't fire inside an unrelated longer token; CJK words are matched by substring since CJK text has no whitespace word boundaries. Generic single-word ASCII tech vocabulary (`git`, `index`, `commit`, `timeout`, `hook`) is intentionally excluded from the list — those words show up constantly in ordinary project-local notes with no discriminative power on their own. This is intentionally conservative — a missed reminder costs nothing, a spurious deny costs a retry.

### Marker Protocol

Per-file, per-session marker in `$BRAIN_ROUTE_GATE_DIR` (falls back to `$SKILL_GATE_DIR`, default `/tmp/claude-reviews`):

| Marker | Created by | Checked by | Purpose |
|--------|-----------|------------|---------|
| `.brain-route-{session}-{file_hash}` | brain-route-gate.sh | brain-route-gate.sh | Per-file deny-once (retry passes silently) |

Markers auto-expire after `BRAIN_ROUTE_STALE_MIN` minutes (default 120).

## Environment Variables

Two different consumers read environment variables in this plugin: the hook reads its own set, and the two skills read a separate set.

### Hook (`brain-route-gate.sh`)

| Variable | Default | Description |
|----------|---------|--------------|
| `BRAIN_ROUTE_DISABLED` | `0` | `1` disables the hook (kill switch) |
| `BRAIN_ROUTE_GATE_DIR` | _(empty)_ | Marker directory override; falls back to `SKILL_GATE_DIR`, then `/tmp/claude-reviews` |
| `BRAIN_ROUTE_STALE_MIN` | `120` | Marker expiry in minutes |
| `BRAIN_ROUTE_MIN_HITS` | `2` | Minimum distinct signal-word hits required to trigger the reminder |

### Skills (`brain-recall` / `brain-curate`)

| Variable | Default | Description |
|----------|---------|--------------|
| `SECOND_BRAIN_URL` | _(none)_ | REST base of the second-brain instance, e.g. `https://brain.example.com` |
| `SECOND_BRAIN_TOKEN` | _(none)_ | The backend's `AUTH_TOKEN`, used for Bearer authentication |

Both variables must be set in the `env` section of `~/.claude/settings.json`. A Bash `export` does not propagate into the hook process or into new sessions, and `~/.claude/settings.local.json` is not a valid location for user-level `env` configuration.

If either variable is unset, the skill's reference text still reads normally — it is a protocol document, not a live call. The `curl` commands inside the skills use `${SECOND_BRAIN_URL:?...}`, so an unset variable makes the command fail with the variable name in the error message rather than silently sending the request to the wrong endpoint.

## Skills

| Skill | Purpose |
|-------|---------|
| `brain-recall` | Recall and write protocol: query construction, result interpretation, `/capture` writes with `volatility: durable` |
| `brain-curate` | Review and deduplication: duplicate/stale candidate scanning, the manual merge workflow, known gaps |

These skills ship in the same plugin as the hook because the hook's deny message names `brain-recall` as the skill to use instead of a local memory write. If the hook and the skills lived in separate repositories, someone who installed only the plugin would see a prompt pointing at a skill that does not exist for them, and the plugin and its companion protocol could drift out of version sync. Packaging them together keeps that reference self-consistent within the plugin.

Both skills trigger semantically, matched against their frontmatter `description` — neither is invoked by a hook.

## Tests

```bash
bats plugins/brain-route/tests/
```

| Suite | Tests | Coverage |
|-------|-------|----------|
| `brain-route-gate.bats` | see `grep -c '@test' tests/brain-route-gate.bats` | Path filter, memory.md exclusion (case-insensitive), content threshold, signal-word false-positive/true-positive cases, per-file marker, kill switch, jq-missing fail-open, malformed stdin fail-open, Edit tool field, missing session_id |
| `skills-packaging.bats` | see `grep -c '@test' tests/skills-packaging.bats` | Structural assertions: skill files exist, endpoints are env-derived with no hardcoded domain, the skill name referenced in the hook's deny message resolves to a real skill, `plugin.json` and `marketplace.json` versions agree |

Note: the explicit `command -v jq` check in Phase 2 is a redundant safety net — the script's outer catch-all (`_main 2>/dev/null || true`) already fail-opens on a missing jq, so no output-based assertion can distinguish the explicit check being present from it being absent.

## Version History

- **v1.1.0** — Moved the `brain-recall` and `brain-curate` skills into this plugin. Backend endpoint configuration in both skills switched to environment injection (`SECOND_BRAIN_URL` / `SECOND_BRAIN_TOKEN`) instead of a hardcoded domain. README gained the Backend Dependency and Skills sections.
- **v1.0.0** — Initial release: soft routing reminder for `*/memory/*.md` writes, signal-word content judge, per-file-per-session marker, fail-open on all anomalies, zero network calls
