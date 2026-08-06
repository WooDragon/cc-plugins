# lib/common.sh — shared logging + allow-helper + plan-hash primitives.
# Sourced (not executed) by plan-review.sh. Requires LOG_FILE and LOG_DIR to
# already be set by the caller before any of these functions are invoked.
#
# bash 3.2 compatible: no associative arrays, no ${var^^}, no &>>.

# DELTA_REVIEW_RULES — single source of truth for the delta-review-rules
# NUMBERED LIST (the actual re-verification discipline) used in every
# non-first round of adversarial review. Referenced by BOTH plan-review.sh's
# Consultation Context heredoc (composed via PROMPT_FILE, used by every
# engine's first round and most reuse rounds) AND agy.sh's resume-round
# AGY_PROMPT (agy's session-native reuse path, which bypasses PROMPT_FILE
# entirely and cannot share that heredoc directly). Do not duplicate this
# text inline anywhere else — a drifted copy is exactly the class of bug
# that the Dispatch Manifest single-source fix (manifest.sh's
# MANIFEST_EXAMPLE vs. review-system-prompt.md) addressed.
#
# Deliberately excludes the one-line intro sentence ("Delta review rules
# (...): "): that line legitimately differs per call site — plan-review.sh's
# copy may point at an injected "## Prior Review Thread" section (which that
# path can produce), agy's resume round never has one (it bypasses
# PROMPT_FILE, so no such section is ever injected there) and a regression
# test (tests/plan-review.bats, "agy with live CONV_FILE does not inject
# Prior Review Thread") asserts that exact string's absence from agy's
# resume-round prompt as a proxy for "no thread section was injected". Each
# call site keeps its own accurate intro sentence and interpolates this
# constant for the shared body.
#
# Interpolation contract (verified in both consumers):
#   - plan-review.sh uses an UNQUOTED heredoc delimiter (<< RNDEOF), which
#     performs parameter expansion — ${DELTA_REVIEW_RULES} expands in place.
#   - agy.sh assigns AGY_PROMPT as a double-quoted string, which also
#     performs parameter expansion — ${DELTA_REVIEW_RULES} expands in place.
DELTA_REVIEW_RULES=$(cat <<'DELTA_RULES_EOF'
1. Re-check every prior Critical against the CURRENT artifact: if resolved,
   drop it; if effectively rebutted, withdraw it.
2. A new non-Critical finding on text that is UNCHANGED since the last round
   is a forfeited relitigation — it burns a round without improving the
   artifact. Do not raise it.
3. Focus new-finding attention on text that has changed since the last round.
4. Evidence burden is symmetric. A rebuttal resting on an unverifiable
   factual claim about the codebase does NOT clear a finding — keep the
   original severity and name the specific claim that needs proof.
DELTA_RULES_EOF
)

log_decision() {
  printf '[%s] session=%s attempt=%s/%s total=%s/%s %s\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    "${SESSION_ID:-unknown}" "${ATTEMPT:-?}" "${REVIEW_MAX_ROUNDS:-?}" \
    "${TOTAL_ROUNDS:-?}" "${REVIEW_MAX_TOTAL_ROUNDS:-?}" \
    "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# --- Entry-point diagnostic log (before guards, does not require ATTEMPT/TOTAL) ---
log_entry() {
  printf '[%s] ENTRY tool=%s session=%s %s\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    "${1:-unknown}" "${2:-unknown}" "${3:-}" >> "$LOG_FILE" 2>/dev/null || true
}

# --- Raw payload capture (diagnostic-only; never let IO failure kill core logic) ---
# CC 2.1.x moved plan content out of tool_input into an out-of-band plan file whose
# path is NOT in the hook stdin. When plan extraction fails we dump the complete raw
# payload + a key-schema summary so the true field layout can be inspected post-hoc.
dump_payload() {
  local raw="$1" session="$2"
  local dump_dir="${LOG_DIR:-$HOME/.claude/logs}/payloads"
  mkdir -p "$dump_dir" 2>/dev/null || return 0
  local stamp; stamp=$(date -u +"%Y%m%dT%H%M%SZ")
  local dump_file="${dump_dir}/exitplanmode-${session:-nosession}-${stamp}-$$.json"
  printf '%s' "$raw" > "$dump_file" 2>/dev/null || return 0
  # Echo the dump path into the main log so it can be located later.
  printf '[%s] PAYLOAD-DUMP session=%s file=%s\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "${session:-unknown}" "$dump_file" \
    >> "$LOG_FILE" 2>/dev/null || true
}

# --- Visible allow helper (eliminates silent exit 0 for non-guard paths) ---
allow_with_reason() {
  local reason="$1"
  local reason_json
  reason_json=$(printf '%s' "$reason" | jq -Rs . 2>/dev/null) || reason_json="\"$reason\""
  cat << EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":${reason_json}}}
EOF
  exit 0
}

# --- Engine stderr backfill: the orchestrator owns the CHANNEL ($ENGINE_ERR,
#     allocated once in plan-review.sh as "${ENGINE_OUT}.err" for every
#     engine), but each engine owns the CONTENT policy via its own
#     $ENGINE_ERR_POLICY (set in its engine_probe()):
#       "verbatim" (agy/claude) — non-empty $ENGINE_ERR is appended into
#         LOG_FILE UNCONDITIONALLY, on success AND on failure. This mirrors
#         the old inline `2>>"$LOG_FILE"` behavior exactly: success-path CLI
#         warnings (deprecation notices, internal retries, near-limit
#         throttle warnings) still land in the log. Backfilling only on
#         failure would silently drop those — a regression, not a fix.
#       "filtered" (codex) — codex's stderr echoes the FULL prompt (global +
#         project CLAUDE.md + conversation + plan) before its real
#         diagnostics, so the raw file must NEVER be appended wholesale.
#         Only on failure ($1 != "0"), call the engine's own
#         engine_err_filter() hook (if it defines one) and log ONLY its
#         already-filtered, length-bounded return value under the engine's
#         own self-declared $ENGINE_ERR_LOG_TAG (set in its engine_probe();
#         falls back to the generic "engine-diag" for engines that don't
#         declare one) — this generic layer must not hardcode a
#         codex-private label.
#     Truncates $ENGINE_ERR after backfilling (both branches, whether or not
#     engine_err_filter actually ran) so a LATER call against the SAME
#     $ENGINE_ERR — e.g. plan-review.sh's _cleanup() defensively re-invoking
#     this on hook-kill — is a harmless no-op via the `[ -s ]` guard above,
#     instead of double-appending/double-logging this round's content. The
#     caller's capacity detection (grep for RESOURCE_EXHAUSTED|MODEL_CAPACITY)
#     therefore MUST read $ENGINE_ERR itself BEFORE calling this function —
#     see plan-review.sh's retry loop, which captures that grep result into a
#     flag ahead of the backfill_engine_err call for exactly this reason.
backfill_engine_err() {
  local exit_code="${1:-0}"
  [ -s "${ENGINE_ERR:-}" ] || return 0
  if [ "${ENGINE_ERR_POLICY:-verbatim}" = "filtered" ]; then
    if [ "$exit_code" != "0" ] && declare -F engine_err_filter >/dev/null 2>&1; then
      local diag
      diag=$(engine_err_filter)
      log_decision "${ENGINE_ERR_LOG_TAG:-engine-diag} $(printf '%s' "$diag" | tr -d '\000-\037')"
    fi
  else
    cat "$ENGINE_ERR" >> "$LOG_FILE" 2>/dev/null || true
  fi
  : > "$ENGINE_ERR" 2>/dev/null || true
}

# --- Byte-budget clamps: stdin -> stdout, UTF-8-safe truncation. ---
#     Used for CLAUDE.md ingestion (plan-review.sh) and round-memory bytes
#     (A3 single-round record, A4 thread total). A naive `head -c N` / `tail
#     -c N` slices at an arbitrary byte offset, which can land inside a
#     multi-byte UTF-8 character — the review output is Chinese by contract
#     (review-system-prompt.md), so this is not a hypothetical edge case.
#     Each function has three branches, and all three are load-bearing (not
#     just the truncation branch):
#       1. Input already within budget: pass through byte-for-byte. Skipping
#          this branch would make every UNDER-budget caller pay the line-drop
#          cost of branch 2 too — silent data loss on the common case.
#       2. Over budget: cut at N bytes, then drop the line that the cut fell
#          inside (sed '$d' for head / sed '1d' for tail) — a bare newline
#          byte (0x0A) can never appear inside a multi-byte UTF-8 sequence, so
#          dropping the (possibly-mid-character) boundary line guarantees
#          every remaining byte belongs to a complete line, hence complete
#          characters.
#       3. Branch 2 produced an empty result — the truncation point fell
#          before any complete line existed yet (e.g. one long line with no
#          newline in the first N bytes at all). Falling back to the raw cut
#          means the result MAY still split a character, but an occasional
#          dirty tail beats returning nothing at all — an empty clamp result
#          would silently degrade a caller from "has context" to "has zero
#          context" for content that legitimately doesn't fit.
#     stdin/stdout (not a file-path interface) so the same pair serves both
#     shapes: A3 clamps a variable ($REVIEW) and D clamps a file (CLAUDE.md).
#     `wc -c` matches this file's existing byte-counting idiom (see
#     lib/engines/agy.sh's AGY_PROMPT_BYTES ARG_MAX guard).

# Byte-budget constants for clamp_head_bytes/clamp_tail_bytes call sites —
# single source of truth so a future tune only needs one edit, not a grep
# across plan-review.sh. Same spirit as DELTA_REVIEW_RULES above.
#   GLOBAL_MD_BYTES      — $HOME/.claude/CLAUDE.md ingestion cap.
#   PROJECT_MD_BYTES     — $CWD/CLAUDE.md ingestion cap.
#   HISTORY_ROUND_BYTES  — A3: per-round review text written into HISTORY_FILE.
#                           9000 (not 6000): review-system-prompt.md caps
#                           review output at 3000 CHARACTERS, and 3000 Chinese
#                           characters is ~9KB — the old 6000-byte cap would
#                           truncate roughly a third of a full-length CJK
#                           review before it's even written to history.
#   HISTORY_INJECT_BYTES — inject_review_thread: total accumulated thread
#                           budget read back from HISTORY_FILE. 48000 (not
#                           24000): keeps ~5 full HISTORY_ROUND_BYTES rounds
#                           instead of ~4, now that each round is larger.
#                           When the accumulated thread exceeds this budget,
#                           clamp_tail_bytes keeps the MOST RECENT rounds and
#                           drops the oldest — earlier rounds are the ones
#                           silently cut, not later ones.
GLOBAL_MD_BYTES=8000
PROJECT_MD_BYTES=24000
HISTORY_ROUND_BYTES=9000
HISTORY_INJECT_BYTES=48000

# clamp_head_bytes <N> — keep the HEAD (first N bytes), drop the tail.
clamp_head_bytes() {
  local n="$1" content total clamped
  content=$(cat)
  total=$(printf '%s' "$content" | wc -c | tr -d ' ')
  if [ "$total" -le "$n" ]; then
    printf '%s' "$content"
    return 0
  fi
  clamped=$(printf '%s' "$content" | head -c "$n" | sed '$d')
  if [ -z "$clamped" ]; then
    printf '%s' "$content" | head -c "$n"
  else
    printf '%s\n' "$clamped"
  fi
}

# clamp_tail_bytes <N> — keep the TAIL (last N bytes), drop the head.
clamp_tail_bytes() {
  local n="$1" content total clamped
  content=$(cat)
  total=$(printf '%s' "$content" | wc -c | tr -d ' ')
  if [ "$total" -le "$n" ]; then
    printf '%s' "$content"
    return 0
  fi
  clamped=$(printf '%s' "$content" | tail -c "$n" | sed '1d')
  if [ -z "$clamped" ]; then
    printf '%s' "$content" | tail -c "$n"
  else
    printf '%s\n' "$clamped"
  fi
}

# --- Plan content hasher (portable: sha256sum > shasum > cksum POSIX fallback) ---
# All branches pipe through awk '{print $1}' to strip filename/extra fields.
plan_hash() {
  local content="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$content" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$content" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$content" | cksum | awk '{print $1}'
  fi
}
