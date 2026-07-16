#!/usr/bin/env bash
# PostToolUse:Edit/Write hook — Code size gate (informational, non-blocking).
#
# After Edit/Write on a source file, checks total line count (dual threshold)
# and single-function length (ast-grep, degradable) against watermarked state.
# Only alerts when the current tier is HIGHER than last time for this file in
# this session — never re-alerts at a steady state, but re-arms if the file
# shrinks back down (tier drops) and later grows again. Fail-open on ALL
# anomalies: missing tools, parse errors, unwritable dirs all degrade to
# silent no-op, never to a hard failure.
#
# Environment variables:
#   CODE_SIZE_GATE_DISABLED=1     — kill switch
#   CODE_SIZE_SOFT_LINES          — soft line-count threshold (default: 500)
#   CODE_SIZE_HARD_LINES          — hard line-count threshold (default: 2000)
#   CODE_SIZE_MAX_FN_LINES        — single-function length threshold (default: 150)
#   CODE_SIZE_GATE_DIR            — marker directory (default: /tmp/claude-reviews)
#   CODE_SIZE_GATE_STALE_MIN      — marker stale threshold minutes (default: 120)
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_gate_common.sh"

# Tier → number, for watermark comparison. NONE is shared (0) across both
# dimensions; SOFT/HARD (file-size dimension) and HIGH (function-length
# dimension) never get compared against each other, so reusing "1" for both
# SOFT and HIGH is safe.
_tier_num() {
  case "$1" in
    HARD) printf '2' ;;
    SOFT) printf '1' ;;
    HIGH) printf '1' ;;
    *) printf '0' ;;
  esac
}

_main() {
  INPUT=$(cat)

  # Kill switch (frontmost)
  _gate_bypass_on CODE_SIZE_GATE_DISABLED && return

  # Preconditions
  _gate_require_jq || return

  # Input extract
  TOOL_NAME=$(_gate_field "$INPUT" '.tool_name // ""') || return
  SESSION_ID=$(_gate_field "$INPUT" '.session_id // ""') || return
  [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ] || return
  [ -n "$SESSION_ID" ] || return

  # file_path is the field Edit/Write carry — the only tools this hook matches
  # (hooks.json matcher is "Edit|Write"). NOTE: a real NotebookEdit call is
  # already rejected by the tool_name gate above, so notebook_path here is NOT
  # a NotebookEdit code path — it is only a cheap fallback for the odd case of
  # an Edit/Write payload carrying notebook_path instead of file_path. Never
  # target_file (that is a Cursor field, not Claude Code).
  FILE_PATH=$(_gate_field "$INPUT" '.tool_input.file_path // .tool_input.notebook_path // ""') || return
  [ -n "$FILE_PATH" ] || return

  CWD=$(_gate_field "$INPUT" '.cwd // ""') || return

  # Resolve to absolute path (relative → via payload cwd)
  if [ -n "$CWD" ] && [ "${FILE_PATH:0:1}" != "/" ]; then
    ABS_PATH="${CWD%/}/${FILE_PATH}"
  else
    ABS_PATH="$FILE_PATH"
  fi

  # PostToolUse fires after the write lands — file must exist on disk.
  [ -f "$ABS_PATH" ] || return

  BASENAME="${ABS_PATH##*/}"

  # Source-suffix whitelist — everything else is silently out of scope.
  case "$BASENAME" in
    *.py|*.ts|*.tsx|*.js|*.jsx|*.sh|*.go|*.rs|*.c|*.cpp|*.h|*.java|*.rb) ;;
    *) return ;;
  esac

  # ---- Main criterion: dual-threshold line count (wc -l never fails) ----
  SOFT="${CODE_SIZE_SOFT_LINES:-500}"
  HARD="${CODE_SIZE_HARD_LINES:-2000}"

  LINES=$(wc -l < "$ABS_PATH" 2>/dev/null) || LINES=0
  LINES=$(printf '%d' "$LINES" 2>/dev/null) || LINES=0

  if [ "$LINES" -gt "$HARD" ]; then
    FILE_TIER="HARD"
  elif [ "$LINES" -gt "$SOFT" ]; then
    FILE_TIER="SOFT"
  else
    FILE_TIER="NONE"
  fi

  # ---- Structural signal: single-function length (ast-grep, degradable) ----
  # kind map: extension → "language|rule". Split on first "|" below.
  # Deliberately no big registry — six languages, inline case is enough.
  MAXFN="${CODE_SIZE_MAX_FN_LINES:-150}"
  FN_TIER="NONE"
  MAX_FN_LEN=0
  MAX_FN_START=0

  AST_SPEC=""
  case "$BASENAME" in
    *.py) AST_SPEC='python|{kind: function_definition}' ;;
    *.go) AST_SPEC='go|{kind: function_declaration}' ;;
    *.rs) AST_SPEC='rust|{kind: function_item}' ;;
    *.tsx) AST_SPEC='tsx|{any: [{kind: function_declaration}, {kind: arrow_function}, {kind: method_definition}]}' ;;
    *.ts) AST_SPEC='typescript|{any: [{kind: function_declaration}, {kind: arrow_function}, {kind: method_definition}]}' ;;
    *.js|*.jsx) AST_SPEC='javascript|{any: [{kind: function_declaration}, {kind: arrow_function}, {kind: method_definition}]}' ;;
    # .sh/.c/.cpp/.h/.java/.rb intentionally left out of the kind map — no
    # single-function structural signal for them yet; line-count tier still
    # applies via the dual-threshold check above. Graceful skip, not an error.
  esac

  if [ -n "$AST_SPEC" ] && command -v ast-grep >/dev/null 2>&1; then
    AST_LANG="${AST_SPEC%%|*}"
    AST_RULE="${AST_SPEC#*|}"
    AST_JSON=$(ast-grep scan --json --inline-rules "{id: fn-len, language: ${AST_LANG}, rule: ${AST_RULE}}" "$ABS_PATH" 2>/dev/null) || AST_JSON=""
    if [ -n "$AST_JSON" ]; then
      FN_COMBINED=$(printf '%s' "$AST_JSON" | jq -r '
        [.[] | {len: (.range.end.line - .range.start.line + 1), start: (.range.start.line + 1)}]
        | (sort_by(.len) | last) // {len:0, start:0}
        | "\(.len) \(.start)"
      ' 2>/dev/null) || FN_COMBINED=""
      if [ -n "$FN_COMBINED" ]; then
        read -r MAX_FN_LEN MAX_FN_START <<< "$FN_COMBINED"
      fi
    fi
  fi

  # Double-safety: clamp to clean non-negative integers no matter what leaked
  # through (empty read, non-numeric jq artifact, etc). Fail-open, not fail-loud.
  case "${MAX_FN_LEN:-}" in '' | *[!0-9]*) MAX_FN_LEN=0 ;; esac
  case "${MAX_FN_START:-}" in '' | *[!0-9]*) MAX_FN_START=0 ;; esac

  if [ "$MAX_FN_LEN" -gt "$MAXFN" ]; then
    FN_TIER="HIGH"
  fi

  # ---- Watermark state machine (anti-spam) ----
  GATE_DIR="${CODE_SIZE_GATE_DIR:-/tmp/claude-reviews}"
  STALE_MIN="${CODE_SIZE_GATE_STALE_MIN:-120}"

  # /tmp is volatile (cleared on reboot) — create unconditionally before any
  # write or find, or a cold-start missing dir silently defeats the whole
  # watermark and every run re-alerts.
  mkdir -p "$GATE_DIR" 2>/dev/null || true

  SAFE_SESSION_ID="${SESSION_ID//\//_}"
  # Hash the absolute PATH only, never file content — content changes on
  # every edit by definition, which would make the marker useless as a
  # watermark. Pure hash (awk field 1), not raw shasum output (which trails
  # a "  -" that would corrupt the marker filename).
  PATH_HASH=$(printf '%s' "$ABS_PATH" | shasum -a 256 2>/dev/null | awk '{print $1}') || PATH_HASH=""
  [ -n "$PATH_HASH" ] || return

  # .code-size- prefix keeps this namespace distinct from doc-gate's
  # .skill-gate-*/.recall-gate-* markers sharing the same directory.
  MARKER="$GATE_DIR/.code-size-${SAFE_SESSION_ID}_${PATH_HASH}"

  # Stale cleanup — scoped strictly to our own prefix so doc-gate markers
  # are never touched by this hook.
  find "$GATE_DIR" -maxdepth 1 -name '.code-size-*' -mmin +"$STALE_MIN" -delete 2>/dev/null || true

  PREV_FILE_TIER="NONE"
  PREV_FN_TIER="NONE"
  if [ -f "$MARKER" ]; then
    V=$(grep '^FILE_TIER=' "$MARKER" 2>/dev/null | cut -d= -f2) && [ -n "$V" ] && PREV_FILE_TIER="$V"
    V=$(grep '^FN_TIER=' "$MARKER" 2>/dev/null | cut -d= -f2) && [ -n "$V" ] && PREV_FN_TIER="$V"
  fi

  ALERT_FILE=0
  if [ "$(_tier_num "$FILE_TIER")" -gt "$(_tier_num "$PREV_FILE_TIER")" ]; then
    ALERT_FILE=1
  fi
  ALERT_FN=0
  if [ "$(_tier_num "$FN_TIER")" -gt "$(_tier_num "$PREV_FN_TIER")" ]; then
    ALERT_FN=1
  fi

  # Marker MUST be rewritten unconditionally, every run, including a
  # downgrade to NONE — never gated behind the alert decision, and never an
  # early-return before this point once we've committed to a real file.
  # Otherwise a file that shrinks from HARD back to NONE never re-arms: the
  # stale HARD watermark stays forever and the file could regrow all the way
  # past HARD again without ever alerting.
  GATE_DIR_WRITABLE=0
  [ -w "$GATE_DIR" ] && GATE_DIR_WRITABLE=1
  if [ "$GATE_DIR_WRITABLE" = "1" ]; then
    {
      printf 'FILE_TIER=%s\n' "$FILE_TIER"
      printf 'FN_TIER=%s\n' "$FN_TIER"
    } > "$MARKER" 2>/dev/null || true
  fi

  # Nothing crossed a new watermark → stay silent (marker already updated above).
  if [ "$ALERT_FILE" != "1" ] && [ "$ALERT_FN" != "1" ]; then
    return
  fi

  # ---- Compose alert (additionalContext, not decision:block — the write
  # already landed, PostToolUse cannot undo it) ----
  MSG="代码规模提示："

  if [ "$ALERT_FILE" = "1" ]; then
    if [ "$FILE_TIER" = "HARD" ]; then
      MSG="${MSG}当前文件 ${LINES} 行，超过强提醒阈值 ${HARD}（Claude Code Read 工具在 2000 行截断，超过后读取会降级为 PARTIAL view）。"
    else
      MSG="${MSG}当前文件 ${LINES} 行，超过提醒阈值 ${SOFT}。"
    fi
  fi

  if [ "$ALERT_FN" = "1" ]; then
    MSG="${MSG}文件含一个 ${MAX_FN_LEN} 行的超长函数（起于第 ${MAX_FN_START} 行）。"
  fi

  MSG="${MSG}建议考虑按职责拆分。"

  MSG_JSON=$(printf '%s' "$MSG" | jq -Rs .) || return
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":%s}}' "$MSG_JSON"
}

_main 2>/dev/null || true
