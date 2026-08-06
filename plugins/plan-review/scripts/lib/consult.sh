# lib/consult.sh — engine consultation state machine (CLI retry loop + REST
# fallback), extracted from plan-review.sh's inline "Call review engine"
# section so it can be shared by the hook AND a future out-of-plugin driver
# (second-opinion.sh, PR2) without either one re-implementing the retry /
# degrade / REST-downgrade logic. Sourced (not executed) by plan-review.sh.
#
# Entry point: run_consultation(). Return codes:
#   0 — engine_probe succeeded; $REVIEW holds the result (possibly still
#       empty if every attempt — CLI retries + REST fallback — failed; the
#       caller distinguishes "tried and failed" from "never attempted" via
#       $_fail_reason being non-empty/empty, exactly as before extraction).
#   1 — engine_probe failed (CLI not found). $ENGINE_PROBE_REASON is set by
#       engine_probe() itself. The caller owns the reaction to this (log +
#       HISTORY_FILE cleanup + allow_with_reason) — that is hook policy, not
#       state-machine plumbing, so it deliberately stays out of this file.
#
# Orchestrator globals this file reads (already in scope, same process):
# REVIEW_DISABLED is NOT read here (handled by the caller before invoking
# run_consultation). Reads: REVIEW_ENGINE, REVIEW_ENGINE_TIMEOUT,
# REVIEW_ENGINE_DEGRADE_TTL, REVIEW_API_URL, REVIEW_API_KEY,
# REVIEW_RETRY_DELAY, REVIEW_CAPACITY_DELAY, REVIEW_HOOK_BUDGET, DEGRADE_FILE,
# CONV_FILE, LOG_FILE, ENGINE_CMD, ARTIFACT, ROUND_INDEX. The sourced engine
# (agy/claude/codex) and rest.sh provide engine_probe/engine_invoke/
# engine_extract/rest_invoke/rest_extract.
#
# Weak hooks (declare -F pattern, same spirit as engine_err_filter in
# lib/common.sh's backfill_engine_err — no-op when the caller does not
# define them):
#   consult_on_round_end    — after engine_extract() inside the retry loop,
#                             once this round's native-memory handle state is
#                             final. plan-review.sh defines this to call its
#                             own inject_review_thread(); a driver with no
#                             HISTORY_FILE/round-memory concept leaves it
#                             undefined.
#   consult_on_rest_prepare — immediately before the REST fallback call.
#                             plan-review.sh defines this to call
#                             inject_review_thread force.
#   consult_on_rest_success — after REST produces a non-empty REVIEW.
#                             plan-review.sh defines this to drop CONV_FILE
#                             (see the original call site's rationale — REST
#                             just produced this round's authoritative result,
#                             so agy's own session, if still "live", is now
#                             one round behind).
#
# bash 3.2 compatible: no associative arrays, no ${var^^}, no &>>.

run_consultation() {
  # Portable timeout: timeout (GNU/Homebrew) > gtimeout (coreutils) > none
  TIMEOUT_CMD=""
  if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
  fi
  # Engine-specific timeout defaults:
  # - agy/Claude: 595s = hook timeout budget, one CLI attempt then REST fallback.
  #   Time-budget guard blocks retry (remaining < ENGINE_TIMEOUT), preserving REST budget.
  ENGINE_TIMEOUT="${REVIEW_ENGINE_TIMEOUT:-595}"

  # --- Gemini degraded-state check ---
  # If Gemini was capacity-exhausted recently and REST is configured,
  # skip CLI entirely — gives REST the full ~115s budget.
  REVIEW_ENGINE_DEGRADE_TTL="${REVIEW_ENGINE_DEGRADE_TTL:-600}"
  _gemini_skip_cli=0
  _fail_reason=""
  if [ "$REVIEW_ENGINE" = "gemini" ] && [ -n "${REVIEW_API_URL:-}" ] && [ -n "${REVIEW_API_KEY:-}" ]; then
    if [ -f "$DEGRADE_FILE" ]; then
      degrade_ts=$(cat "$DEGRADE_FILE" 2>/dev/null)
      [[ "$degrade_ts" =~ ^[0-9]+$ ]] || degrade_ts=0
      now_ts=$(date +%s)
      degrade_age=$(( now_ts - degrade_ts ))
      if (( degrade_age < REVIEW_ENGINE_DEGRADE_TTL )); then
        remaining_degrade=$(( REVIEW_ENGINE_DEGRADE_TTL - degrade_age ))
        echo "plan-review: gemini degraded state active (${degrade_age}s ago, TTL=${REVIEW_ENGINE_DEGRADE_TTL}s, ${remaining_degrade}s remaining), skipping CLI → REST fallback" >&2
        log_decision "gemini-degraded skip-cli remaining_degrade=${remaining_degrade}s"
        _gemini_skip_cli=1
        _fail_reason="Gemini: degraded state (${degrade_age}s ago, expires in ${remaining_degrade}s)"
      fi
    fi
  fi

  # --- Engine invocation with retry (2 attempts: 1 initial + 1 retry) ---
  # Background + wait pattern: tracks ENGINE_PID so _cleanup can kill the engine
  # process if the hook script itself is terminated (e.g. hook timeout SIGTERM).
  ENGINE_OUT=$(mktemp)
  ENGINE_STATUS="${ENGINE_OUT}.status"
  # Orchestrator owns the stderr CHANNEL for every engine (agy/claude/codex
  # alike) — allocated unconditionally here, not codex-private. Each engine
  # redirects its own invocation's stderr into it (2>"$ENGINE_ERR") and
  # declares, via $ENGINE_ERR_POLICY (set in its engine_probe()), what the
  # orchestrator is allowed to do with the CONTENT: "verbatim" (agy/claude)
  # backfills it into LOG_FILE unconditionally; "filtered" (codex) only logs
  # a privacy-filtered excerpt on failure, via the engine's own
  # engine_err_filter() hook — see backfill_engine_err() in lib/common.sh.
  ENGINE_ERR="${ENGINE_OUT}.err"
  REVIEW=""
  HOOK_BUDGET="${REVIEW_HOOK_BUDGET:-595}"

  # --- Pre-flight: CLI existence check (permanent failure, no retry) + one-
  #     time per-engine setup (model resolution, temp resource prep) —
  #     delegated to the sourced engine's engine_probe(), called once outside
  #     the retry loop below. ---
  if ! engine_probe; then
    return 1
  fi

  for (( engine_attempt=1; engine_attempt<=2; engine_attempt++ )); do
    # Degraded-state skip: jump out of CLI retry immediately on first iteration.
    if (( engine_attempt == 1 )) && [ "$_gemini_skip_cli" = "1" ]; then
      break
    fi

    # Time-budget guard: on retry, check remaining wall-clock time can fit
    # a full ENGINE_TIMEOUT. Prevents hook timeout SIGTERM from killing
    # the script mid-retry, making REST fallback unreachable.
    if (( engine_attempt > 1 )); then
      remaining=$(( HOOK_BUDGET - SECONDS ))
      if (( remaining < ENGINE_TIMEOUT )); then
        echo "plan-review: time budget exhausted for retry (${remaining}s remaining < ${ENGINE_TIMEOUT}s needed), breaking to fallback..." >&2
        log_decision "skip-retry reason=time-budget remaining=${remaining}s timeout=${ENGINE_TIMEOUT}s budget=${HOOK_BUDGET}s"
        break
      fi
    fi
    engine_exit=0

    # --- Call the sourced engine's invoke hook. agy's invoke may set
    #     _ENGINE_ABORT_RETRY=1 (oversized prompt, ARG_MAX defense) to signal
    #     an immediate break BEFORE extraction/exit-code handling — mirroring
    #     the pre-refactor inline `break`. A literal `break` inside the
    #     function itself would be bash-version-dependent (verified: bash 3.2
    #     propagates it to this loop, bash 5.x does not), so an explicit flag
    #     is the only portable signal.
    _ENGINE_ABORT_RETRY=0
    engine_invoke
    if [ "$_ENGINE_ABORT_RETRY" = "1" ]; then
      break
    fi

    # Capacity-exhaustion detection (used further below) MUST scan the raw
    # $ENGINE_ERR before backfill_engine_err (next) truncates it (see
    # lib/common.sh) — capture into a flag now, consumed later instead of
    # re-grepping a file that will already be empty by then.
    _capacity_hit=0
    grep -qE "RESOURCE_EXHAUSTED|MODEL_CAPACITY" "$ENGINE_ERR" 2>/dev/null && _capacity_hit=1

    # Backfill this round's $ENGINE_ERR into LOG_FILE per the engine's own
    # $ENGINE_ERR_POLICY (see lib/common.sh) — unconditionally for
    # "verbatim" engines (success and failure alike), failure-only and
    # filtered for codex. Also truncates $ENGINE_ERR once backfilled, so a
    # later defensive re-backfill (_cleanup on hook-kill) is a harmless no-op
    # in the normal exit path.
    backfill_engine_err "$engine_exit"

    engine_extract

    # Orchestrator-level CONV_FILE invalidation: a non-zero CLI exit (timeout
    # 124, resume-rejected, network, plain 1) means engine_extract()'s own
    # outer guard (`[ "$engine_exit" = "0" ] && [ -s "$ENGINE_OUT" ]`) never
    # ran, so agy's internal persist/rm logic never touched CONV_FILE this
    # round — the orchestrator is the ONLY thing that can invalidate it here.
    # Drop it so the next round starts a fresh full first round instead of
    # re-sending a --conversation onto a session that just failed. (A 0-exit-
    # but-malformed-envelope round is the other invalidation path, handled
    # entirely inside engine_extract() itself — see lib/engines/agy.sh.)
    if [ "$engine_exit" != "0" ]; then
      rm -f "${CONV_FILE:-}"
    fi

    # Call site 2: by this point this round's native-handle state is FINAL,
    # whichever of the paths above (or agy's own internal rm inside
    # engine_extract) got it there — see inject_review_thread's own comment
    # for why this single point replaces per-rm-site patches.
    declare -F consult_on_round_end >/dev/null 2>&1 && consult_on_round_end || true

    : > "$ENGINE_OUT"
    if [ "$engine_exit" != "0" ]; then
      REVIEW=""
      _fail_reason="${REVIEW_ENGINE}: exit ${engine_exit}"
      if [ "$engine_attempt" -lt 2 ]; then
        # Detect capacity-exhausted 429 (MODEL_CAPACITY_EXHAUSTED via cloudcode-pa.googleapis.com).
        # These outages last minutes — the default 2s retry delay is useless;
        # a longer wait gives the server time to recover.
        # $_capacity_hit was captured above (BEFORE backfill_engine_err ran)
        # from this round's raw, un-truncated $ENGINE_ERR directly — NOT
        # LOG_FILE. This is the fix for the codex fast-break bug: codex's raw
        # stderr never reaches LOG_FILE wholesale (privacy filter, see
        # engine_err_filter in lib/engines/codex.sh), so grepping LOG_FILE
        # only ever caught this pattern for agy/claude by coincidence —
        # codex's fast-break depended on the capacity keyword happening to
        # survive the 500-byte filtered codex-diag excerpt. All three engines
        # are treated identically here because $ENGINE_ERR always held this
        # round's complete, unfiltered stderr regardless of engine (at the
        # time it was captured, before this same round's backfill truncated it).
        if [ "$_capacity_hit" = "1" ]; then
          _fail_reason="${REVIEW_ENGINE}: capacity exhausted (MODEL_CAPACITY_EXHAUSTED)"
          # CONV_FILE was already dropped and re-injected (if needed) by call
          # site 2 above, right after engine_extract() — a capacity-flavored
          # non-zero exit is still a non-zero exit, no separate handling
          # needed here (the old duplicate rm+inject pinned to this branch
          # specifically was provably a no-op: this code only runs inside the
          # `engine_exit != 0` branch, whose invalidation already ran).
          # If REST fallback is configured, skip retry immediately — retrying a
          # capacity-exhausted endpoint wastes the time budget REST needs.
          if [ -n "${REVIEW_API_URL:-}" ] && [ -n "${REVIEW_API_KEY:-}" ]; then
            # Persist degraded state: subsequent hooks skip CLI for TTL seconds.
            if [ "$REVIEW_ENGINE" = "gemini" ]; then
              printf '%s' "$(date +%s)" > "$DEGRADE_FILE" 2>/dev/null || true
              log_decision "gemini-degrade-write ts=$(date +%s)"
            fi
            echo "plan-review: $REVIEW_ENGINE capacity exhausted, skipping retry (REST fallback available)" >&2
            log_decision "rest-skip=capacity-fast-break engine=$REVIEW_ENGINE attempt=$engine_attempt"
            break
          fi
          retry_delay="${REVIEW_CAPACITY_DELAY:-25}"
          echo "plan-review: $REVIEW_ENGINE capacity exhausted, waiting ${retry_delay}s for recovery..." >&2
        else
          retry_delay="${REVIEW_RETRY_DELAY:-2}"
          echo "plan-review: $REVIEW_ENGINE failed (attempt $engine_attempt/2, exit $engine_exit), retrying in ${retry_delay}s..." >&2
        fi
        sleep "$retry_delay"
      fi
      continue
    fi

    # Engine succeeded (exit 0) but returned empty → retry
    if [ -z "$REVIEW" ]; then
      if [ "$engine_attempt" -lt 2 ]; then
        echo "plan-review: engine returned empty response (attempt $engine_attempt/2), retrying..." >&2
        sleep "${REVIEW_RETRY_DELAY:-2}"
      fi
      continue
    fi

    # Non-empty response obtained — exit retry loop
    break
  done

  # --- REST API fallback: CLI exhausted, try OpenAI-compatible endpoint ---
  # Zero-intrusion: only fires when CLI produced no result AND env vars are set.
  # REVIEW_API_URL/REVIEW_API_KEY empty → skip (preserves original fail-open).
  if [ -z "$REVIEW" ] && [ -n "${REVIEW_API_URL:-}" ] && [ -n "${REVIEW_API_KEY:-}" ]; then
    # Persist (or refresh) Gemini degraded state for any failure mode.
    # Covers timeout (exit 124), network errors (ECONNRESET), empty responses, etc.
    # Always refreshes the timestamp — even if the file already exists but has expired.
    # Without refresh, an expired degrade file blocks TTL renewal: the check above lets
    # Gemini run again (_gemini_skip_cli=0), it fails again, but the stale file prevents
    # writing a new timestamp, creating an infinite retry-with-40s-REST-budget loop.
    if [ "$REVIEW_ENGINE" = "gemini" ] && [ "$_gemini_skip_cli" = "0" ]; then
      printf '%s' "$(date +%s)" > "$DEGRADE_FILE" 2>/dev/null || true
      log_decision "gemini-degrade-write ts=$(date +%s) reason=rest-fallback-triggered"
    fi
    echo "plan-review: CLI exhausted, trying REST API fallback..." >&2
    log_decision "rest-start url=${REVIEW_API_URL:+(set)} key=${REVIEW_API_KEY:+(set)}"

    # Call site 3 (force): REST is a DIFFERENT engine, not "agy with a maybe-
    # cleared CONV_FILE" — it never has session memory of its own, so gating
    # its injection on agy's CONV_FILE state is a category error. `force`
    # skips that condition entirely; this is what closes the gap where a
    # round aborts BEFORE ever reaching engine_extract() (agy's own ARG_MAX
    # guard, ${TIMEOUT_CMD:+...} never invoked, ${_ENGINE_ABORT_RETRY}=1) —
    # CONV_FILE is untouched in that path and can still look perfectly live,
    # even though REST, about to receive this exact prompt, has no way to
    # consume that liveness. HISTORY_INJECTED still guards this from
    # double-injecting on top of call site 1 or 2 if either already injected
    # this round.
    declare -F consult_on_rest_prepare >/dev/null 2>&1 && consult_on_rest_prepare || true
    rest_invoke
    rest_extract

    # Cross-ROUND fix (different dimension from the three same-round
    # injection call sites above — do not fold this into any of them). This
    # round's CONV_FILE can still be live even after REST — not agy — just
    # produced the authoritative REVIEW for it (e.g. the ARG_MAX-abort path:
    # agy's own CLI never ran, so nothing ever touched CONV_FILE). If left
    # alone, agy's server-side session history silently stops one round
    # short of current: the NEXT round's composition-time check
    # (call site 1) sees a non-empty CONV_FILE, concludes agy has native
    # memory, and skips thread injection — but agy's actual session never
    # saw this round's REST-produced finding, so the next round gets NEITHER
    # the injected thread NOR a native memory of what REST just found.
    # Dropping CONV_FILE here forces the next round onto the thread path
    # instead, which DOES have this round's finding (written into
    # HISTORY_FILE via A3 further below). Gated on REVIEW being non-empty:
    # if REST also failed, this round produced no authoritative result at
    # all, so agy's (possibly still-valid) session must not be invalidated
    # for nothing.
    [ -z "$REVIEW" ] || { declare -F consult_on_rest_success >/dev/null 2>&1 && consult_on_rest_success || true; }

    : > "$ENGINE_OUT"
    [ -z "$REVIEW" ] || echo "plan-review: REST API fallback succeeded." >&2
  fi

  return 0
}
