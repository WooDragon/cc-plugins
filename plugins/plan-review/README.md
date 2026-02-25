# plan-review

Adversarial red-team review of implementation plans via cross-model consultation.

When Claude calls `ExitPlanMode`, this plugin intercepts the call and sends the plan to a review engine (Gemini or Claude) for adversarial scrutiny. The reviewer can APPROVE, raise CONCERNS, or REJECT. On non-approval, feedback is returned to Claude for revision or rebuttal. After max rounds without consensus, the plan passes through for user arbitration.

## Installation

```bash
# From marketplace
claude plugin add plan-review@WooDragon-cc-plugins

# Development mode
claude --plugin-dir ~/.claude/dev-plugins/plan-review
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `REVIEW_ENGINE` | `gemini` | Review engine: `gemini` or `claude` |
| `REVIEW_DISABLED` | `0` | Set `1` to bypass entirely |
| `REVIEW_DRY_RUN` | `0` | Set `1` to skip engine call (synthetic APPROVE) |
| `REVIEW_MAX_ROUNDS` | `3` | Max consultation rounds before escalation |
| `GEMINI_MODEL` | `gemini-3-pro-preview` | Gemini model ID |
| `CLAUDE_MODEL` | `opus` | Claude model (when `REVIEW_ENGINE=claude`) |

Legacy variables (`GEMINI_REVIEW_OFF`, `GEMINI_DRY_RUN`, `GEMINI_MAX_REVIEWS`) are supported via fallback mapping.

## Consultation Flow

```
ExitPlanMode → hook intercepts → engine reviews
  ├─ APPROVE → allow through
  ├─ CONCERNS/REJECT → deny + feedback → Claude revises → re-submit
  └─ max rounds reached → allow through (user decides)
```

## Engine Isolation (Claude)

When `REVIEW_ENGINE=claude`, the script spawns `claude -p` with triple isolation:

1. **`PLAN_REVIEW_RUNNING=1`** — recursive guard; subprocess bails immediately if set
2. **`--setting-sources local`** — loads only `settings.local.json`, no project/user hooks
3. **`--tools ""`** — no tool calls = no PreToolUse events = no hook re-entry

`unset CLAUDECODE` and `unset CLAUDE_CODE_ENTRYPOINT` prevent the subprocess from inheriting parent's internal state. This is implementation-dependent but necessary: user authenticates via OAuth (`claude login`), no `ANTHROPIC_API_KEY` available, making `claude -p` the only viable invocation path.

## Fault Tolerance

- **jq missing** → allow (can't parse input)
- **Engine CLI missing** → allow + stderr warning
- **Engine call fails** → allow + stderr warning
- **Empty response** → allow
- **Malformed verdict** → fail-closed as CONCERNS
- **Log directory unwritable** → logs to `/dev/null`, core logic unaffected

## Privacy Notice

This plugin sends the following data to the configured review engine (Gemini API or Anthropic API):

- **Global CLAUDE.md** — first 3KB of `~/.claude/CLAUDE.md`
- **Project CLAUDE.md** — first 8KB of `$CWD/CLAUDE.md`
- **Recent conversation** — last 3 user messages from the session transcript
- **Plan content** — the full implementation plan under review

This context is necessary for meaningful adversarial review. If your CLAUDE.md or conversations contain sensitive information (internal hostnames, credentials, business logic), be aware that this data will be sent to the external API.
