# lib/engines/claude.sh — Claude engine implementation of the three-hook
# contract (engine_probe / engine_invoke / engine_extract). Sourced (not
# executed) by plan-review.sh when REVIEW_ENGINE=claude.
#
# Orchestrator pre-sets before calling these hooks: PROMPT_FILE,
# SYSTEM_INSTRUCTIONS, PLAN, TOTAL_ROUNDS, ENGINE_OUT, ENGINE_TIMEOUT,
# TIMEOUT_CMD, CONV_FILE, LOG_FILE, ENGINE_CMD.
#
# bash 3.2 compatible: no associative arrays, no ${var^^}, no &>>.

# --- One-time setup (called once, outside the retry loop): CLI existence
#     check + model resolution + system-prompt prep. Returns 0 if usable,
#     1 (with ENGINE_PROBE_REASON set) otherwise. ---
engine_probe() {
  if ! command -v "$ENGINE_CMD" >/dev/null 2>&1; then
    ENGINE_PROBE_REASON="$ENGINE_CMD"
    return 1
  fi
  CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"
  # Engine-specific system injection: PROMPT_FILE holds dynamic content only,
  # regardless of engine — claude receives SYSTEM_INSTRUCTIONS via its own
  # --system-prompt rail (agy/codex inject it inline into their own prompt).
  SYSTEM_PROMPT="$SYSTEM_INSTRUCTIONS"
  return 0
}

# --- Actual call (called every round inside the retry loop). Writes raw
#     output to $ENGINE_OUT, sets $engine_exit, maintains $ENGINE_PID so the
#     caller's trap can kill it on hook timeout. ---
engine_invoke() {
  # Strip Claude Code internal env vars to prevent recursive hook/plugin loading.
  # Fragile (depends on internal implementation), but necessary: user authenticates
  # via OAuth (claude login), no ANTHROPIC_API_KEY available, so claude -p is the
  # only viable path. Triple isolation: --setting-sources local + PLAN_REVIEW_RUNNING
  # + --tools "" (no tool calls = no PreToolUse events).
  unset CLAUDECODE
  unset CLAUDE_CODE_ENTRYPOINT
  PLAN_REVIEW_RUNNING=1 ${TIMEOUT_CMD:+$TIMEOUT_CMD -k 5 $ENGINE_TIMEOUT} claude -p \
    --model "$CLAUDE_MODEL" \
    --setting-sources local \
    --no-session-persistence \
    --tools "" \
    --disable-slash-commands \
    --system-prompt "$SYSTEM_PROMPT" \
    < "$PROMPT_FILE" > "$ENGINE_OUT" 2>>"$LOG_FILE" &
  ENGINE_PID=$!
  wait "$ENGINE_PID" 2>/dev/null || engine_exit=$?
  ENGINE_PID=""
}

# --- Read $ENGINE_OUT, set $REVIEW. Claude's stdout is the raw review text
#     verbatim — no envelope to unwrap. ---
engine_extract() {
  REVIEW=$(cat "$ENGINE_OUT" 2>/dev/null || true)
}
