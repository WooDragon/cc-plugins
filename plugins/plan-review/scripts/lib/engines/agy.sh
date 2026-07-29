# lib/engines/agy.sh — agy (Gemini) engine implementation of the three-hook
# contract (engine_probe / engine_invoke / engine_extract). Sourced (not
# executed) by plan-review.sh when REVIEW_ENGINE is "gemini" (default) or
# any unrecognized value — see plan-review.sh's engine-selection case for
# why unrecognized values fall through here (current-behavior preservation).
#
# Orchestrator pre-sets before calling these hooks: PROMPT_FILE,
# SYSTEM_INSTRUCTIONS, PLAN, TOTAL_ROUNDS, ENGINE_OUT, ENGINE_TIMEOUT,
# TIMEOUT_CMD, CONV_FILE, LOG_FILE, ENGINE_CMD.
#
# engine_invoke may set _ENGINE_ABORT_RETRY=1 to signal the caller's retry
# loop to break immediately (deliberately NOT a bare `break` inside this
# function — bash 3.2 propagates a function-body `break` out to the CALLER's
# enclosing loop, but bash 5.x does not (it errors "only meaningful in a
# for/while/until loop" and falls through) — a verified cross-version
# divergence, not a hypothetical one. An explicit flag variable is the only
# portable signal.).
#
# bash 3.2 compatible: no associative arrays, no ${var^^}, no &>>.

# --- One-time setup (called once, outside the retry loop): CLI existence
#     check + model resolution. Returns 0 if usable, 1 (with
#     ENGINE_PROBE_REASON set) otherwise. ---
engine_probe() {
  if ! command -v "$ENGINE_CMD" >/dev/null 2>&1; then
    ENGINE_PROBE_REASON="$ENGINE_CMD"
    return 1
  fi
  # GEMINI_MODEL retained as the REST fallback's model id (OpenAI-compatible payload).
  GEMINI_MODEL="${GEMINI_MODEL:-gemini-3.1-pro-preview}"
  AGY_MODEL="${AGY_MODEL:-Gemini 3.1 Pro (High)}"
  return 0
}

# --- Actual call (called every round inside the retry loop). Writes raw
#     output to $ENGINE_OUT, sets $engine_exit, maintains $ENGINE_PID so the
#     caller's trap can kill it on hook timeout. ---
engine_invoke() {
  # --- agy multi-round session reuse ---
  # Read back a previously-captured agy conversation_id (if any) so this
  # round can resume it instead of resending the full static prefix — the
  # prefix (system instructions + GLOBAL_MD/PROJECT_MD/USER_REQ) already
  # lives in agy's server-side session history, which lets the provider
  # hit prompt cache on it. Validate strictly (36-char UUID) since a
  # malformed/stale value would make `--conversation` resume garbage.
  CONV_ID=$(cat "${CONV_FILE:-}" 2>/dev/null | tr 'A-F' 'a-f' || true)
  [[ "$CONV_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || CONV_ID=""
  CONV_ARGS=()
  [ -z "$CONV_ID" ] || CONV_ARGS=(--conversation "$CONV_ID")

  # agy does not read stdin as a prompt — must pass inline via -p. ANSI-C
  # quoting ($'\n\n') for a real newline separator; a plain "\n" inside
  # double quotes is a literal backslash-n, not a newline.
  if [ -z "$CONV_ID" ]; then
    # First round (no session to resume yet): send the full static+dynamic prompt.
    AGY_PROMPT="$SYSTEM_INSTRUCTIONS"$'\n\n'"$(cat "$PROMPT_FILE")"
  else
    # Reuse round: static prefix already lives in agy's session history —
    # resend only the volatile tail. Mirror the first-round Consultation
    # Context framing (round number + "APPROVE if prior concerns addressed")
    # so the reuse round carries the same negotiation semantics, not a bare
    # plan dump. Resending the delta only (not the static context) is the
    # point — it gets appended to session history, so duplicating context
    # would cost tokens, not save them.
    AGY_PROMPT="## Consultation Context
This is round $((TOTAL_ROUNDS + 1)) of adversarial review.
The plan author may have revised or added rebuttals since the previous round.
Evaluate the CURRENT plan on its merits — if prior concerns have been addressed, APPROVE.

## Plan to Review
${PLAN}"
  fi

  # ARG_MAX defense: agy only accepts the prompt as a command-line argument,
  # so an oversized prompt trips E2BIG. Treat this as a CLI failure and
  # fall straight through to REST fallback rather than exec'ing a doomed command.
  # Count BYTES, not characters: the ARG_MAX limit is byte-denominated, but
  # ${#VAR} counts characters under a UTF-8 locale, so a CJK plan (3 bytes/
  # char) would undercount ~3x and defeat the 256KB guard. `wc -c` counts
  # bytes regardless of locale — one fork per hook invocation is negligible,
  # and it sidesteps the LC_ALL=C prefix-assignment locale-leak footgun.
  AGY_PROMPT_BYTES=$(printf '%s' "$AGY_PROMPT" | wc -c | tr -d ' ')
  if [ "$AGY_PROMPT_BYTES" -gt 256000 ]; then
    log_decision "agy-skip reason=prompt-too-large bytes=$AGY_PROMPT_BYTES"
    REVIEW=""
    _fail_reason="agy: prompt too large (${AGY_PROMPT_BYTES}B > 256000B), skipped to REST"
    _ENGINE_ABORT_RETRY=1
    return 0
  fi

  ${TIMEOUT_CMD:+$TIMEOUT_CMD -k 5 $ENGINE_TIMEOUT} agy --model "$AGY_MODEL" --sandbox --dangerously-skip-permissions \
    ${CONV_ARGS[@]+"${CONV_ARGS[@]}"} --output-format json \
    -p "$AGY_PROMPT" > "$ENGINE_OUT" 2>>"$LOG_FILE" &
  ENGINE_PID=$!
  wait "$ENGINE_PID" 2>/dev/null || engine_exit=$?
  ENGINE_PID=""
}

# --- Read $ENGINE_OUT, set $REVIEW. agy's JSON is NOT well-formed (the
#     "response" field contains raw unescaped newlines), so jq/python
#     json.loads chokes on it. Everything below is deliberate sed/awk text
#     slicing — zero jq, zero python. Also persists the conversation_id (for
#     next-round session reuse) and logs usage observations. ---
engine_extract() {
  REVIEW=""
  if [ "$engine_exit" = "0" ] && [ -s "$ENGINE_OUT" ]; then
    # Capture the real conversation_id agy assigned (self-chosen server-side
    # UUID; a client-invented one would not resume anything). `q` after the
    # first match — no pipe, no SIGPIPE. Tolerate a lowercase-normalized id;
    # persist is DEFERRED until response extraction succeeds (see below) so a
    # broken envelope never leaves a CONV_FILE that the next round resumes.
    NEW_CONV=$(sed -n '/"conversation_id"/{s/.*"conversation_id"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F-]\{36\}\)".*/\1/p;q;}' "$ENGINE_OUT" 2>/dev/null || true)
    NEW_CONV=$(printf '%s' "$NEW_CONV" | tr 'A-F' 'a-f')

    # Extract the "response" field value and unescape it. Deliberately NOT
    # keyed to field order/position — scan forward from the "response":"
    # marker and stop at the first UNESCAPED double-quote, so trailing keys
    # (usage, etc.) after response in the object don't matter.
    REVIEW=$(awk '
      BEGIN { RS="\x01" }
      {
        s = $0
        # Tolerate optional whitespace around the key colon
        # ("response" : "...") — do not bet on the compact serialization.
        if (match(s, /"response"[ \t]*:[ \t]*"/) == 0) { exit }
        s = substr(s, RSTART + RLENGTH)
        out = ""; i = 1; n = length(s)
        while (i <= n) {
          c = substr(s, i, 1)
          if (c == "\\") {
            i++
            nc = substr(s, i, 1)
            if (nc == "n") out = out "\n"
            else if (nc == "t") out = out "\t"
            else if (nc == "\"") out = out "\""
            else if (nc == "\\") out = out "\\"
            else if (nc == "r") out = out "\r"
            else if (nc == "u") {
              # \uXXXX: Go encoding/json HTML-safe mode escapes <, >, & and
              # U+2028/U+2029 this way by default (XSS defense) — that set
              # is what agy actually emits, verified by reproduction. Any
              # other \uXXXX is passed through literally (backslash intact)
              # rather than silently dropped, so an unanticipated escape is
              # visibly wrong instead of corrupting the tag structure.
              hex = tolower(substr(s, i + 1, 4))
              if (hex == "003c") out = out "<"
              else if (hex == "003e") out = out ">"
              else if (hex == "0026") out = out "&"
              else if (hex == "2028" || hex == "2029") out = out "\n"
              else out = out "\\u" substr(s, i + 1, 4)
              i += 4
            }
            else out = out nc
            i++
          } else if (c == "\"") {
            break
          } else {
            out = out c
            i++
          }
        }
        printf "%s", out
      }
    ' "$ENGINE_OUT" 2>/dev/null || true)

    # Fallback: never hand the shell-wrapped JSON to the downstream verdict
    # extractor — the raw envelope can contain echoed-back <verdict> tags
    # from the prompt and cause a false match. Extraction failure = empty
    # REVIEW, which the existing empty-response retry/REST path handles.
    #
    # CONV_FILE persist policy (only when we got a usable review): persisting
    # a conversation_id from a call whose response we COULDN'T parse would
    # make the next round resume a session we can't actually consume — so
    # persist only on non-empty REVIEW, and drop any stale CONV_FILE on
    # extract failure (the session may be shaped wrong / unusable this cycle).
    if [ -n "$REVIEW" ]; then
      if [[ "$NEW_CONV" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        printf '%s' "$NEW_CONV" > "${CONV_FILE}.tmp.$$" 2>/dev/null && mv -f "${CONV_FILE}.tmp.$$" "$CONV_FILE" 2>/dev/null || true
        log_decision "agy-conversation id=$NEW_CONV reuse=$([ -n "$CONV_ID" ] && echo yes || echo no)"
      fi
      log_decision "agy-success"
    else
      rm -f "${CONV_FILE:-}"
      log_decision "agy-response-extract-failed conv-cleared"
    fi

    # Usage observation (best-effort, never fatal if absent/unparseable).
    # `q` after first match — consistent with the conversation_id sed, no
    # pipe, no SIGPIPE.
    AGY_IN=$(sed -n 's/.*"input_tokens"[[:space:]]*:[[:space:]]*\([0-9]\{1,\}\).*/\1/p;/"input_tokens"/q' "$ENGINE_OUT" 2>/dev/null || true)
    AGY_TOTAL=$(sed -n 's/.*"total_tokens"[[:space:]]*:[[:space:]]*\([0-9]\{1,\}\).*/\1/p;/"total_tokens"/q' "$ENGINE_OUT" 2>/dev/null || true)
    [ -z "$AGY_IN" ] && [ -z "$AGY_TOTAL" ] || log_decision "agy-usage in=${AGY_IN:-?} total=${AGY_TOTAL:-?}"
  fi
}
