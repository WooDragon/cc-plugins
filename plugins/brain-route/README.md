# brain-route

Routing reminder for Claude Code — prompts consideration of second-brain (cross-project memory) vs local project memory when writing project memory `.md` files.

When Claude writes or edits a file under `*/memory/*.md` (excluding `MEMORY.md` itself, which is an index file) and the content looks like a cross-project engineering lesson, the hook denies once and surfaces a reminder to consider routing the content to second-brain via the `brain-recall` skill instead of the local file. The hook performs no deduplication and makes no network requests — pure local string matching, millisecond-scale. It is a soft reminder, not a hard gate: retrying the same write after the reminder always passes.

## Installation

```bash
# From marketplace
claude plugin add brain-route@WooDragon-cc-plugins
```

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

Only fires on paths matching `*/memory/*.md`, excluding `MEMORY.md` (index file, not a memory entry).

### Content Judge

Scores content against a fixed signal-word list (`worktree`, `hook`, `门禁`, `printf`, `subagent`, `commit`, `fail-open`, `逃生舱`, `夹具`, `假绿`, `payload`, `timeout`, `并行`, `git`, `bats`, `pathspec`, `index`). Fires only when the count of distinct matched words reaches `BRAIN_ROUTE_MIN_HITS` (default 2). This is intentionally conservative — a missed reminder costs nothing, a spurious deny costs a retry.

### Marker Protocol

Per-file, per-session marker in `$BRAIN_ROUTE_GATE_DIR` (falls back to `$SKILL_GATE_DIR`, default `/tmp/claude-reviews`):

| Marker | Created by | Checked by | Purpose |
|--------|-----------|------------|---------|
| `.brain-route-{session}-{file_hash}` | brain-route-gate.sh | brain-route-gate.sh | Per-file deny-once (retry passes silently) |

Markers auto-expire after `BRAIN_ROUTE_STALE_MIN` minutes (default 120).

## Environment Variables

| Variable | Default | Description |
|----------|---------|--------------|
| `BRAIN_ROUTE_DISABLED` | `0` | `1` disables the hook (kill switch) |
| `BRAIN_ROUTE_GATE_DIR` | _(empty)_ | Marker directory override; falls back to `SKILL_GATE_DIR`, then `/tmp/claude-reviews` |
| `BRAIN_ROUTE_STALE_MIN` | `120` | Marker expiry in minutes |
| `BRAIN_ROUTE_MIN_HITS` | `2` | Minimum distinct signal-word hits required to trigger the reminder |

## Tests

```bash
bats plugins/brain-route/tests/
```

| Suite | Tests | Coverage |
|-------|-------|----------|
| `brain-route-gate.bats` | 11 | Path filter, MEMORY.md exclusion, content threshold, per-file marker, kill switch, jq-missing fail-open, malformed stdin fail-open, Edit tool field, missing session_id |

## Version History

- **v1.0.0** — Initial release: soft routing reminder for `*/memory/*.md` writes, signal-word content judge, per-file-per-session marker, fail-open on all anomalies, zero network calls
