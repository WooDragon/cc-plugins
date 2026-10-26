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
| Empty output with a clean exit (agy 429) | A zero exit status is not success | Check for an exact `SEARCH_FAILED` line as well as the status |

## Escalation ladder

`agy → grok → builtin WebSearch → DuckDuckGo html`

A level is skipped when the probe cannot see it and failed only on non-zero exit, empty output, or a line exactly equal to `SEARCH_FAILED`. Substrings in normal result text are not failure markers. The entry point is `skills/web-search/scripts/search.sh`.

| Exit code | Meaning | Caller action |
|---|---|---|
| `0` | Results on stdout | Use them |
| `1` | Whole chain failed | Treat as no result |
| `3` | Builtin WebSearch handoff | Run the host tool, then re-enter the script with `WEB_SEARCH_BUILTIN_UNAVAILABLE=1` to reach the DuckDuckGo fallback |

`3` is a handoff, not a failure. The builtin `WebSearch` tool is a Claude Code host tool that a bash script cannot call, so the script returns control to the caller. Re-entry goes directly to DuckDuckGo without calling agy or grok again. Community mode remains independent of this flag. Use `search.sh -- "<query>"` for option-looking queries; options end at `--`.

## Platform support

| Level | macOS | Linux | Windows (Git Bash) |
|---|---|---|---|
| `agy` | If installed | If installed | If installed |
| `grok` | If installed | If installed | If installed |
| Builtin WebSearch | Yes | Yes | Yes |
| DuckDuckGo html | Needs `curl` + Python 3 | Needs `curl` + Python 3 | Needs Git Bash `curl` + a real Python 3, not the `WindowsApps` stub |

The DuckDuckGo level requests with a desktop **Linux** Chrome user agent. A macOS user agent is refused outright with HTTP 403 — the block is on that UA string, not on the client machine. The request also carries `Accept`, `Accept-Language`, and `Referer: https://duckduckgo.com/` headers as one matched set.

DuckDuckGo serves CAPTCHA interstitials (HTTP 202) intermittently on identical parameters; four identical requests measured 200, 202, 200, 200. The level retries a 202 or a 000 once with a short backoff, and treats HTTP 403 as a deterministic refusal that a retry cannot fix. This intermittent rate limiting is an inherent limitation of the last-resort fallback.

The fallback uses Python standard-library HTMLParser to associate titles, links, and optional snippets within each result container. It decodes only the DDG redirect wrapper, preserves percent-encoding in direct URLs, emits only http/https URLs, and normalizes field whitespace. Parser failure is an exit status, not a scan of result text. `CURL_CMD` accepts one executable path, including paths with spaces; probing and execution use that same executable, without eval or command concatenation.

With default timeouts, allow about 399s for all agy attempts, 599s including grok, and 53s for a separate DDG re-entry. Add GNU timeout termination grace (5s per invocation), scheduling margin, and a separate budget for host WebSearch. Without GNU timeout, agy/grok run directly with no CLI hard deadline; a warning goes to stderr. Curl always receives `--max-time` for each DDG request.

## Community research mode

`search.sh "<query>" --community` targets X/Twitter discussion only, through grok with no fallback. **Experimental.** Both general and community modes use the confirmed CLI allowlist `web_search,web_fetch`. The community prompt restricts search to `site:x.com` and real post URLs. The CLI does not recognize `open_page` or the old `x_keyword_search`, `x_semantic_search`, and `x_thread_fetch` names. The no-shell prompt, subagent restriction, and turn limits remain in place; the allowlist is not a security sandbox. Returned x.com URLs check out, but the summary points may be second-hand search-snippet synthesis rather than the original post; verify the post text before citing a point as a conclusion.

Without grok, the mode reports unavailable and exits non-zero. It does not fall through to the four-level ladder — none of those levels can search X, so falling through would return results of the wrong kind.

## Skill

`skills/web-search/SKILL.md` carries the isolation rule (searches run in a subagent, never in the main context), the mode-selection table, per-level constraints with their measured reasons, the content-farm blocklist, result-handling rules (agy URLs need a `WebFetch` re-check; count is not quality), and the probe semantics section.

## Tests

```bash
WEB_SEARCH_TEST_BASH=/bin/bash bats plugins/web-search/tests/
WEB_SEARCH_TEST_BASH="$(command -v bash)" bats plugins/web-search/tests/
```

`probe.bats` locks the platform traps: a fake `timeout` without a coreutils banner, a silent exit-0 python stub, a fake `agy` alone, and the full eight-key matrix. `search.bats` locks the ladder: zero calls for an absent binary, three attempts for a real failure, escalation after exhaustion, `SEARCH_FAILED` at exit 0, the exit-3 handoff, and DuckDuckGo parse and failure paths.

The test sandbox exposes only explicitly resolved base utilities and per-test capability fixtures. Python is linked only for parser cases, with an explicit skip if unavailable. `WEB_SEARCH_TEST_BASH` selects the interpreter for the tested entry points and fixture shebangs, not just the Bats launcher. Windows timeout/Python stubs, MINGW/MSYS simulation, and executable paths with spaces remain covered; these simulations are not a real Windows host test.
