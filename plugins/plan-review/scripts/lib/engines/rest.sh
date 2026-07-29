# lib/engines/rest.sh — REST API fallback (OpenAI-compatible endpoint).
# Sourced (not executed) UNCONDITIONALLY by plan-review.sh, alongside
# whichever CLI engine (agy/claude/codex) is selected — REST is a downgrade
# channel, not a fourth first-class engine, so it deliberately does NOT
# implement the engine_probe/engine_invoke/engine_extract trio: it fires
# only AFTER the CLI retry loop is exhausted, meaning it always coexists in
# the same process with an already-sourced CLI engine. Reusing the
# engine_invoke/engine_extract names would silently shadow that engine's
# functions — the single hardest class of bug to chase down at runtime.
# The rest_ prefix guarantees zero name collision, zero dynamic re-source.
#
# Orchestrator-owned policy that stays OUT of this file: the decision of
# whether to trigger REST at all (CLI exhausted + REVIEW_API_URL/KEY set),
# the gemini degraded-state bookkeeping, and the post-call ENGINE_OUT
# truncation / success log — those are engine-agnostic retry/degrade
# state-machine concerns and live in plan-review.sh itself.
#
# Orchestrator globals this file reads (already in scope, same process):
# PROMPT_FILE, SYSTEM_INSTRUCTIONS, ENGINE_OUT, TIMEOUT_CMD, LOG_FILE,
# HOOK_BUDGET, REVIEW_API_URL, REVIEW_API_KEY, GEMINI_MODEL,
# REVIEW_REST_TIMEOUT, REVIEW_REST_STALL_TIMEOUT, _fail_reason.
#
# bash 3.2 compatible: no associative arrays, no ${var^^}, no &>>.

# --- Build the request + call the endpoint. Writes body to $ENGINE_OUT,
#     HTTP status to $ENGINE_STATUS, sets $curl_exit. REQ_FILE/ENGINE_STATUS
#     are REST-private temp resources — appended to the caller's generic
#     ENGINE_TMP_FILES cleanup array rather than hardcoded into _cleanup. ---
rest_invoke() {
  REQ_FILE=$(mktemp)
  ENGINE_TMP_FILES+=("$REQ_FILE")
  # --rawfile (not --arg + $(cat ...)) reads PROMPT_FILE directly inside jq,
  # keeping the large plan body off the command line entirely (no E2BIG risk
  # on this side). messages[0]=system stays a stable prefix across rounds —
  # prefix-cacheable by the upstream provider. stream:true enables SSE below.
  jq -n --arg model "${GEMINI_MODEL:-gemini-3.1-pro-preview}" \
        --arg sys "$SYSTEM_INSTRUCTIONS" \
        --rawfile prompt "$PROMPT_FILE" \
    '{ model: $model, messages: [{ role: "system", content: $sys }, { role: "user", content: $prompt }], max_tokens: 16000, temperature: 0.1, stream: true }' \
    > "$REQ_FILE"

  REST_TIMEOUT="${REVIEW_REST_TIMEOUT:-115}"
  # Stall watchdog: aborts if the stream produces < 1 byte/s for this many
  # seconds. Set well above legitimate TTFT (time-to-first-token) for
  # reasoning models, which can sit silent for tens of seconds before the
  # first SSE chunk arrives — too low a value misfires on a healthy stream.
  STALL_TIMEOUT="${REVIEW_REST_STALL_TIMEOUT:-90}"
  # Clamp to remaining budget: ensure curl self-terminates before hook
  # timeout SIGTERM, preserving diagnostic log writes after curl completes.
  # 3s margin for jq extraction + log_decision after curl returns.
  remaining=$(( HOOK_BUDGET - SECONDS ))
  (( remaining - 3 < REST_TIMEOUT )) && REST_TIMEOUT=$(( remaining - 3 ))
  (( REST_TIMEOUT < 1 )) && REST_TIMEOUT=1

  ENGINE_STATUS="${ENGINE_OUT}.status"
  ENGINE_TMP_FILES+=("$ENGINE_STATUS")

  # -sS: -s suppresses progress meter, -S re-enables error messages (connection-level errors
  # like "Failed to connect" would be silenced by -s alone, making raw_bytes=0 undiagnosable).
  # --no-buffer: disable curl's output buffering so SSE chunks land in ENGINE_OUT as they
  # arrive (only matters for anyone tailing the file live; parsing below still reads it
  # after wait). --speed-limit/--speed-time: curl's own stall watchdog — abort (exit 28)
  # if throughput drops below 1 byte/s for STALL_TIMEOUT seconds, independent of the
  # outer TIMEOUT_CMD wall-clock cap.
  # -w "%{http_code}": write HTTP status to stdout (redirected to ENGINE_STATUS); response
  # body goes to ENGINE_OUT via -o. Read ENGINE_STATUS only AFTER wait completes.
  ${TIMEOUT_CMD:+$TIMEOUT_CMD -k 5 $REST_TIMEOUT} curl -sS \
    --no-buffer --speed-limit 1 --speed-time "$STALL_TIMEOUT" \
    -X POST "${REVIEW_API_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${REVIEW_API_KEY}" \
    -d @"$REQ_FILE" \
    -o "$ENGINE_OUT" \
    -w "%{http_code}" \
    2>>"$LOG_FILE" > "$ENGINE_STATUS" &
  ENGINE_PID=$!
  curl_exit=0
  wait "$ENGINE_PID" 2>/dev/null || curl_exit=$?
  ENGINE_PID=""
  rm -f "$REQ_FILE"; REQ_FILE=""
}

# --- Read $ENGINE_STATUS/$ENGINE_OUT, set $REVIEW (and $_fail_reason on
#     failure). Handles the SSE stream, non-2xx/non-stream error bodies, and
#     the stall-timeout case distinctly. ---
rest_extract() {
  # Read status after wait — shell creates ENGINE_STATUS on redirect, content written by curl.
  # Explicit empty check: command substitution strips trailing newlines, but file may be empty
  # (connection-level failure before HTTP handshake) → use "000" as sentinel for no-response.
  rest_http_status=$(cat "$ENGINE_STATUS" 2>/dev/null)
  [ -z "$rest_http_status" ] && rest_http_status="000"

  if [ "$curl_exit" = "28" ]; then
    # Stall watchdog fired — the provider went silent mid-stream. Don't hand
    # a truncated partial body to the SSE parser; treat as a clean failure.
    log_decision "rest-stall-timeout curl_exit=28"
    REVIEW=""
    _fail_reason="${_fail_reason:+${_fail_reason}; }REST: stall timeout (curl exit 28, no data for ${STALL_TIMEOUT}s)"
  else
    # Non-SSE error bypass: a non-2xx status, or a bare JSON object body (error
    # response, not an SSE stream), must skip the SSE parser — feeding an error
    # JSON through the "data: " cleaning pipeline silently drops it and yields an
    # empty REVIEW with no diagnosis.
    # SIGPIPE-safe first-char probe: `tr <big-file | head -c 1` lets head close
    # the pipe after 1 byte while tr is still streaming the whole body, so tr
    # dies with SIGPIPE (141). Under `set -o pipefail` the pipeline inherits 141
    # and `set -e` then kills the hook mid-REST-fallback — before any decision
    # JSON is emitted — on any sizable body (a normal long review response is
    # enough). Bounding the read with a leading `head -c 100` means no stage
    # faces an unbounded producer, so nothing gets SIGPIPE; 100 bytes is ample
    # to find the first non-space char (leading whitespace before '{'/'data:').
    first_char=$(head -c 100 "$ENGINE_OUT" 2>/dev/null | tr -d '[:space:]' | head -c 1)
    case "$rest_http_status" in
      2[0-9][0-9]) is_2xx=1 ;;
      *) is_2xx=0 ;;
    esac
    if [ "$is_2xx" = "0" ] || [ "$first_char" = "{" ]; then
      REVIEW=""
      # Only emit rest-debug when there is a body to describe. An empty body
      # (connection-level failure before the HTTP handshake, status 000) has
      # nothing to diagnose — [ -s ] guards against a bare "body_prefix=" line.
      if [ -s "$ENGINE_OUT" ]; then
        rest_error=$(jq -r '.error.message // empty' "$ENGINE_OUT" 2>/dev/null || true)
        if [ -n "$rest_error" ]; then
          log_decision "rest-debug api_error=$(printf '%s' "$rest_error" | head -c 200)"
        else
          # tr -d '\000-\037': strip control characters to keep log single-line safe
          log_decision "rest-debug body_prefix=$(head -c 200 "$ENGINE_OUT" | tr -d '\000-\037')"
        fi
      fi
    else
      # SSE cleaning pipeline: strip the "data: " prefix, then parse each frame
      # in isolation and join delta.content across chunks.
      #   -R  : read each line as a raw string (not pre-parsed JSON), so ONE
      #         malformed frame cannot abort the whole parse.
      #   fromjson? : parse the line to JSON, but the trailing "?" swallows a
      #         parse error on that single line and skips it — a truncated /
      #         garbled mid-stream frame (transient gateway hiccup) drops just
      #         itself instead of discarding every chunk after it. The old
      #         "-rj '.choices...'" form fed the whole stream to jq at once, so
      #         a single bad frame aborted parsing and SILENTLY truncated the
      #         review (2>/dev/null || true hid the exit 5) — a partial body can
      #         carry a stale verdict and wrongly approve. fromjson? also makes
      #         the non-JSON "[DONE]" terminator a no-op; the explicit grep -v
      #         below is kept as belt-and-suspenders and to document intent.
      #   -j  : join output, no per-value newline — O(1) memory, streaming.
      #   "// empty": role-only first frame / finish_reason-only last frame /
      #         empty-choices usage tail carry no content key — skip, don't emit "null".
      REVIEW=$(grep '^data: ' "$ENGINE_OUT" | sed 's/^data: //' | grep -v '^\[DONE\]' | jq -j -R 'fromjson? | .choices[0].delta.content // empty' 2>/dev/null || true)
    fi

    raw_bytes=$(wc -c < "$ENGINE_OUT" | tr -d ' ')
    review_bytes=$(printf '%s' "$REVIEW" | wc -c | tr -d ' ')
    log_decision "rest-result http=$rest_http_status raw_bytes=$raw_bytes review_bytes=$review_bytes"
    if [ -z "$REVIEW" ]; then
      _fail_reason="${_fail_reason:+${_fail_reason}; }REST: http=${rest_http_status} raw_bytes=${raw_bytes}"
    fi
  fi
}
