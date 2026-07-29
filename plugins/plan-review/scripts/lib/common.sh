# lib/common.sh — shared logging + allow-helper + plan-hash primitives.
# Sourced (not executed) by plan-review.sh. Requires LOG_FILE and LOG_DIR to
# already be set by the caller before any of these functions are invoked.
#
# bash 3.2 compatible: no associative arrays, no ${var^^}, no &>>.

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
