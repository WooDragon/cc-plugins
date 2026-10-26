# web-search

Web search skill for Claude Code with a **probe-gated** escalation ladder. It tells Claude which engine to use for which kind of lookup, and ships scripts that decide at runtime what is actually installed before trying it.

A **skill + scripts plugin** (no hooks). The skill carries the methodology; the scripts carry the executable logic, so the search path is testable instead of living in prose.

## Installation

```bash
# From marketplace
claude plugin marketplace add WooDragon/cc-plugins
claude plugin install web-search@cc-plugins
```

## What problem it solves

A naive ladder retries a missing CLI. If `agy` is not installed, "failed, retry twice" still spawns three 130-second timeouts before anything else runs — 6.5 minutes spent proving a binary does not exist. This plugin probes first and **skips an absent level entirely**:

```
[skip] agy: binary not found
```

Three platform-specific traps make a naive `command -v` check wrong, and the probe handles each:

| Trap | Why `command -v` is not enough | Probe response |
|---|---|---|
| Windows `timeout.exe` shares its name with POSIX `timeout` but waits for a keypress | Name match proves nothing, and the wrong one hangs Git Bash | Require a `coreutils` `--version` banner; fall back to `gtimeout` |
| Windows `WindowsApps\python.exe` is a store alias that prints nothing and exits 0 | Exit status alone accepts the broken stub | Run `--version` and require the output to start with `Python 3` |
| Empty output with a clean exit (agy 429) | A zero exit status is not success | Check payload for `SEARCH_FAILED` as well as the status |

## Escalation ladder

`agy → grok → builtin WebSearch → DuckDuckGo html`

A level is skipped when the probe cannot see it and failed only on non-zero exit, empty output, or `SEARCH_FAILED`. The entry point is `skills/web-search/scripts/search.sh`.

| Exit code | Meaning | Caller action |
|---|---|---|
| `0` | Results on stdout | Use them |
| `1` | Whole chain failed | Treat as no result |
| `3` | Builtin WebSearch handoff | Run the host tool, then re-enter the script with `WEB_SEARCH_BUILTIN_UNAVAILABLE=1` to reach the DuckDuckGo fallback |

`3` is a handoff, not a failure. The builtin `WebSearch` tool is a Claude Code host tool that a bash script cannot call, so the script returns control to the caller. Skipping the re-entry makes the last level unreachable.

## Platform support

| Level | macOS | Linux | Windows (Git Bash) |
|---|---|---|---|
| `agy` | If installed | If installed | If installed |
| `grok` | If installed | If installed | If installed |
| Builtin WebSearch | Yes | Yes | Yes |
| DuckDuckGo html | Needs `curl` + Python 3 | Needs `curl` + Python 3 | Needs Git Bash `curl` + a real Python 3, not the `WindowsApps` stub |

The DuckDuckGo level requests with a desktop **Linux** Chrome user agent. A macOS user agent is refused outright with HTTP 403 — the block is on that UA string, not on the client machine. The request also carries `Accept`, `Accept-Language`, and `Referer: https://duckduckgo.com/` headers as one matched set.

DuckDuckGo serves CAPTCHA interstitials (HTTP 202) intermittently on identical parameters; four identical requests measured 200, 202, 200, 200. The level retries a 202 or a 000 once with a short backoff, and treats HTTP 403 as a deterministic refusal that a retry cannot fix. This intermittent rate limiting is an inherent limitation of the last-resort fallback.

## Community research mode

`search.sh "<query>" --community` targets X/Twitter discussion only, through grok with no fallback. **Experimental.** The 3 X search tools plus `web_search` and `open_page` are all required — narrowing the tool set makes grok bypass it and call the local `agy` instead. Returned x.com URLs check out, but the summary points may be second-hand search-snippet synthesis rather than the original post; verify the post text before citing a point as a conclusion.

Without grok, the mode reports unavailable and exits non-zero. It does not fall through to the four-level ladder — none of those levels can search X, so falling through would return results of the wrong kind.

## Skill

`skills/web-search/SKILL.md` carries the isolation rule (searches run in a subagent, never in the main context), the mode-selection table, per-level constraints with their measured reasons, the content-farm blocklist, result-handling rules (agy URLs need a `WebFetch` re-check; count is not quality), and the probe semantics section.

## Tests

```bash
npx --yes bats plugins/web-search/tests/
```

`probe.bats` locks the platform traps: a fake `timeout` without a coreutils banner, a silent exit-0 python stub, a fake `agy` alone, and the full eight-key matrix. `search.bats` locks the ladder: zero calls for an absent binary, three attempts for a real failure, escalation after exhaustion, `SEARCH_FAILED` at exit 0, the exit-3 handoff, and DuckDuckGo parse and failure paths.
