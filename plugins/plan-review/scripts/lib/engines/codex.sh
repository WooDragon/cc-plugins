# lib/engines/codex.sh — Codex engine implementation of the three-hook
# contract (engine_probe / engine_invoke / engine_extract). Sourced (not
# executed) by plan-review.sh when REVIEW_ENGINE=codex.
#
# Orchestrator pre-sets before calling these hooks: PROMPT_FILE,
# SYSTEM_INSTRUCTIONS, PLAN, TOTAL_ROUNDS, ENGINE_OUT, ENGINE_TIMEOUT,
# TIMEOUT_CMD, CONV_FILE, LOG_FILE, ENGINE_CMD. ENGINE_TMP_FILES/
# ENGINE_TMP_DIRS arrays are declared (and cleared) by the caller before
# trap registration — this file only appends its own private temp paths.
#
# bash 3.2 compatible: no associative arrays, no ${var^^}, no &>>.

# --- One-time setup (called once, outside the retry loop): CLI existence
#     check + model resolution + sandboxed workdir/merged-prompt/UTF-8
#     sanitation prep. Returns 0 if usable, 1 (with ENGINE_PROBE_REASON set)
#     otherwise. ---
engine_probe() {
  if ! command -v "$ENGINE_CMD" >/dev/null 2>&1; then
    ENGINE_PROBE_REASON="$ENGINE_CMD"
    return 1
  fi
  # Empty CODEX_MODEL means inherit codex's own ~/.codex/config.toml default.
  CODEX_MODEL="${CODEX_MODEL:-}"

  # codex-only temp resources: a sandboxed workdir (-C target, deliberately NOT
  # the project cwd — codex runs read-only but there's no reason to hand it the
  # real tree), a merged prompt file (system instructions + PROMPT_FILE's
  # dynamic content — kept SEPARATE from PROMPT_FILE itself so the REST
  # fallback's --rawfile read of PROMPT_FILE doesn't double-send the system
  # instructions), and an isolated stderr capture (codex echoes the FULL
  # prompt to stderr — see the diagnostic backfill in engine_invoke, never let
  # this reach LOG_FILE wholesale). Registered into the generic cleanup arrays
  # so the caller's trap reaps them without knowing their codex-private names.
  CODEX_WORKDIR=$(mktemp -d)
  ENGINE_TMP_DIRS+=("$CODEX_WORKDIR")
  CODEX_PROMPT_FILE=$(mktemp)
  ENGINE_TMP_FILES+=("$CODEX_PROMPT_FILE" "${CODEX_PROMPT_FILE}.u8")
  ENGINE_ERR="${ENGINE_OUT}.err"
  ENGINE_TMP_FILES+=("$ENGINE_ERR")

  { printf '%s\n\n' "$SYSTEM_INSTRUCTIONS"; cat "$PROMPT_FILE"; } > "$CODEX_PROMPT_FILE"
  printf '\n' >> "$CODEX_PROMPT_FILE"

  # UTF-8 sanitation (codex-only — the other engines never see this file).
  # GLOBAL_MD/PROJECT_MD are truncated by BYTE count (`head -c 3000` / `-c 8000`),
  # which slices a multi-byte character in half whenever a CLAUDE.md is non-ASCII
  # near the cut. codex hard-rejects such input — it does not degrade, it aborts:
  #   "Failed to read prompt from stdin: input is not valid UTF-8 (invalid byte
  #    at offset N). Convert it to UTF-8 and retry"
  # …making REVIEW_ENGINE=codex unusable for anyone with a non-ASCII CLAUDE.md.
  # `iconv -c` drops only the orphaned bytes and keeps every valid character.
  # Guarded on iconv's presence and on success (`&& mv || rm`), so a missing or
  # failing iconv degrades to the unsanitized file rather than an empty prompt.
  if command -v iconv >/dev/null 2>&1; then
    if iconv -f UTF-8 -t UTF-8 -c < "$CODEX_PROMPT_FILE" > "${CODEX_PROMPT_FILE}.u8" 2>/dev/null; then
      mv -f "${CODEX_PROMPT_FILE}.u8" "$CODEX_PROMPT_FILE"
    else
      rm -f "${CODEX_PROMPT_FILE}.u8"
    fi
  fi
  # Counted AFTER sanitation: PROMPT_LINES drives the diagnostic backfill's
  # positional cut, which must match the file codex actually received.
  PROMPT_LINES=$(wc -l < "$CODEX_PROMPT_FILE")
  return 0
}

# --- Actual call (called every round inside the retry loop). Writes raw
#     output to $ENGINE_OUT, sets $engine_exit, maintains $ENGINE_PID so the
#     caller's trap can kill it on hook timeout. On failure, backfills a
#     privacy-filtered stderr diagnostic into LOG_FILE. ---
engine_invoke() {
  # Model id can contain spaces (see AGY_MODEL's default "Gemini 3.1 Pro
  # (High)" precedent) — must be an array, not ${VAR:+...} word-splitting.
  CODEX_MODEL_ARGS=()
  [ -z "$CODEX_MODEL" ] || CODEX_MODEL_ARGS=(-m "$CODEX_MODEL")
  ${TIMEOUT_CMD:+$TIMEOUT_CMD -k 5 $ENGINE_TIMEOUT} "$ENGINE_CMD" exec \
    --skip-git-repo-check -s read-only --ephemeral --color never \
    -C "$CODEX_WORKDIR" ${CODEX_MODEL_ARGS[@]+"${CODEX_MODEL_ARGS[@]}"} \
    -o "$ENGINE_OUT" - < "$CODEX_PROMPT_FILE" > /dev/null 2> "$ENGINE_ERR" &
  ENGINE_PID=$!
  wait "$ENGINE_PID" 2>/dev/null || engine_exit=$?
  ENGINE_PID=""

  if [ "$engine_exit" != "0" ]; then
    # --- Privacy boundary: codex echoes the FULL prompt to stderr before
    # its real diagnostics (global CLAUDE.md + project CLAUDE.md + recent
    # conversation + the plan). Never let ENGINE_ERR reach LOG_FILE
    # wholesale — backfill only a filtered tail, two-layer defense:
    #   Layer A (positional): locate the banner's SECOND "--------" line
    #     (within the first 20 lines) followed by a line that is exactly
    #     "user" — that marks where the echoed prompt begins; cut it out
    #     using PROMPT_LINES (captured once, outside the retry loop) to
    #     find where it ends, keeping the banner + the real tail after it.
    #     Any of the three guards failing falls through to the fail-closed
    #     `tail -n 20` branch, which still preserves diagnostics for
    #     failures that happen before codex echoes anything (auth/network).
    #   Layer B (content-based): grep -Fvxf strips any surviving line that
    #     is byte-identical to a prompt line — this is what survives codex
    #     version drift in line counts (banner shape / prompt line count
    #     changing between versions).
    # `|| true` on the ECHO_END lookup and the final pipe are MANDATORY:
    # set -euo pipefail means a grep returning 1 (no match / everything
    # filtered out) would otherwise kill the hook before it emits its
    # decision JSON.
    # LC_ALL=C on both greps (command-scoped, not exported — deliberately
    # narrower than the LC_ALL=C prefix-assignment pattern avoided
    # elsewhere in this file): CODEX_PROMPT_FILE embeds GLOBAL_MD/
    # PROJECT_MD truncated by BYTE count (`head -c`), which can slice a
    # multi-byte UTF-8 character in half. Under the active UTF-8 locale
    # that makes grep abort with "illegal byte sequence" — silently
    # emptying CODEX_DIAG (the trailing `|| true` hides the failure).
    # Forcing the C locale makes grep treat input as raw bytes, matching
    # this pipeline's real behavior anyway: -F is already a fixed-string
    # byte match, and -x needs no locale-aware collation.
    CODEX_DIAG=$(
      ECHO_END=$(head -n 20 "$ENGINE_ERR" | grep -n '^--------$' | sed -n '2p' | cut -d: -f1) || true
      NEXT_LINE=$(sed -n "$(( ${ECHO_END:-0} + 1 ))p" "$ENGINE_ERR" 2>/dev/null)
      if [ -n "$ECHO_END" ] && [ "$ECHO_END" -le 20 ] && [ "$NEXT_LINE" = "user" ]; then
        { head -n "$ECHO_END" "$ENGINE_ERR"
          tail -n "+$(( ECHO_END + PROMPT_LINES + 2 ))" "$ENGINE_ERR"; }
      else
        tail -n 20 "$ENGINE_ERR"
      fi \
      | LC_ALL=C grep -Fvxf "$CODEX_PROMPT_FILE" \
      | LC_ALL=C grep '[^[:space:]]' \
      | head -c 500 || true
    )
    # tr -d '\000-\037': strip control chars, keep log single-line safe
    # (mirrors the existing rest-debug body_prefix backfill).
    log_decision "codex-diag $(printf '%s' "$CODEX_DIAG" | tr -d '\000-\037')"
  fi
}

# --- Read $ENGINE_OUT, set $REVIEW. Codex's -o output file is the raw review
#     text verbatim — no envelope to unwrap. ---
engine_extract() {
  REVIEW=$(cat "$ENGINE_OUT" 2>/dev/null || true)
}
