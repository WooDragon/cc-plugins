#!/bin/bash
# second-opinion.sh — out-of-plugin driver for plan-review's engine
# infrastructure (agy + Gemini 3.1 Pro + REST fallback + session reuse),
# built on top of lib/consult.sh's run_consultation() state machine (PR1).
#
# Unlike plan-review.sh (a PreToolUse hook with plan-specific policy: plan
# extraction, ack-round counters, verdict routing, manifest parsing), this
# is a plain CLI a caller invokes directly to get a second opinion on any
# artifact. It does NO verdict parsing — stdout is the engine's raw review
# text, verbatim.
#
# Usage:
#   second-opinion.sh --system-prompt-file <path> [--system-prompt-file <path2> ...]
#                     [--prompt-file <path>] [--session <label>]
#
#   --system-prompt-file <path>  Required, repeatable. Concatenated in
#                                 command-line order to form the system
#                                 instructions sent to the engine. Missing
#                                 (none given), nonexistent, or empty file
#                                 → fail loud (nonzero exit, empty stdout).
#   --prompt-file <path>         Artifact body. If omitted, body is read from
#                                 stdin. If BOTH are given, --prompt-file wins
#                                 (stdin is the fallback for callers that
#                                 cannot write files, not a second source to
#                                 merge with an explicit file).
#   --session <label>            Opaque label for cross-invocation session
#                                 continuation (see "Session key derivation"
#                                 below). Charset: [A-Za-z0-9._-] only — no
#                                 "/" or "..". Omitted → single-round
#                                 stateless (a throwaway temp file backs
#                                 CONV_FILE for this one call, then is
#                                 removed).
#
# stdout: ONLY the review body (no JSON wrapper, no logs).
# stderr: diagnostics.
# exit 0: a result was obtained. exit != 0: all engines exhausted, OR a
#   fail-loud precondition (missing/bad args) was violated. This driver
#   deliberately does NOT reuse plan-review.sh's fail-OPEN pattern (a
#   synthesized "looks like a review" response is more dangerous than
#   getting nothing) — every failure here is fail-CLOSED.
#
# Explicitly NOT read: REVIEW_DISABLED, REVIEW_DRY_RUN — those two encode
# "turn off the ExitPlanMode gate" semantics; an explicit direct invocation
# of this driver must not be silently reshaped by them.
#
# Session key derivation (the design core — see plan issue #165 PR2 §B):
#   ${REVIEW_COUNTER_DIR:-/tmp/claude-reviews}/.so-<hash(label + system prompt bytes)[:16]>
# The hash folds in the ASSEMBLED system-prompt bytes, not just the label —
# so any rubric/prompt change automatically invalidates old sessions instead
# of silently resuming a stale one under a changed rubric. Reuses
# plan_hash() from lib/common.sh verbatim (sha256sum > shasum -a 256 >
# cksum fallback) — no new hash call is written here.
#
# CONV_FILE must never be passed empty: lib/engines/agy.sh's persistence
# step does `mv -f "${CONV_FILE}.tmp.$$" "$CONV_FILE"` — if CONV_FILE were
# ever an empty string, that `mv` target is empty, the command fails, is
# swallowed by `|| true`, and the `.tmp.$$` file leaks permanently into
# this process's cwd. This driver always assigns CONV_FILE a real path
# (either the derived session path, or a throwaway mktemp for the
# stateless case, registered into ENGINE_TMP_FILES for cleanup).
#
# REVIEW_COUNTER_DIR is shared with plan-review.sh (same DEGRADE_FILE, so
# Gemini capacity-exhaustion degraded state is shared between the hook and
# this driver) — this driver does not invent a separate directory.
#
# bash 3.2 compatible: no associative arrays, no ${var^^}, no &>>.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# --- Logging (best-effort side channel; never let a write failure kill the
#     driver's core logic — same rationale as plan-review.sh) ---
LOG_DIR="${REVIEW_LOG_DIR:-$HOME/.claude/logs}"
mkdir -p "$LOG_DIR" 2>/dev/null && LOG_FILE="${LOG_DIR}/second-opinion.log" || LOG_FILE="/dev/null"

# --- Fail-loud helper: this driver's ONE error-reporting path. Always
#     writes to stderr, never to stdout (stdout is reserved for the review
#     body), and always exits non-zero. ---
_fail() {
  echo "second-opinion: $1" >&2
  exit 1
}

# --- Argument parsing ---
SYS_PROMPT_FILES=()
PROMPT_FILE_ARG=""
SESSION_LABEL=""
SESSION_LABEL_GIVEN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --system-prompt-file)
      [ $# -ge 2 ] || _fail "--system-prompt-file requires a value"
      SYS_PROMPT_FILES+=("$2")
      shift 2
      ;;
    --prompt-file)
      [ $# -ge 2 ] || _fail "--prompt-file requires a value"
      PROMPT_FILE_ARG="$2"
      shift 2
      ;;
    --session)
      [ $# -ge 2 ] || _fail "--session requires a value"
      SESSION_LABEL="$2"
      SESSION_LABEL_GIVEN=1
      shift 2
      ;;
    *)
      _fail "unknown argument: $1"
      ;;
  esac
done

# --- Reject an explicitly-empty --session value. `--session ""` sets
#     SESSION_LABEL to an empty string, which the later `[ -n "$SESSION_LABEL" ]`
#     check cannot distinguish from "flag omitted" — it silently falls to the
#     stateless single-round else-branch. A caller who passed --session
#     believes it opened a session; it didn't. Fail loud instead of
#     downgrading silently. ---
if [ "$SESSION_LABEL_GIVEN" -eq 1 ] && [ -z "$SESSION_LABEL" ]; then
  _fail "invalid --session label (must not be empty)"
fi

# --- Charset-validate a given --session label up front, before this driver
#     consumes stdin for the artifact body (a rejected label should fail
#     before stdin is read, not after). ---
if [ -n "$SESSION_LABEL" ]; then
  case "$SESSION_LABEL" in
    *[!A-Za-z0-9._-]*) _fail "invalid --session label (allowed charset: [A-Za-z0-9._-]): $SESSION_LABEL" ;;
  esac
fi

# --- Validate --system-prompt-file: required, repeatable, each must exist
#     and be non-empty. Fail loud on any violation — no fallback rubric. ---
[ ${#SYS_PROMPT_FILES[@]} -gt 0 ] || _fail "--system-prompt-file is required (repeatable, at least one)"
for _f in "${SYS_PROMPT_FILES[@]}"; do
  [ -s "$_f" ] || _fail "--system-prompt-file not found or empty: $_f"
done
unset _f

# --- Concatenate system-prompt files in command-line order. Sentinel-byte
#     technique (same rationale as plan-review.sh:489-490): a plain $(...)
#     strips ALL trailing newlines from the last file, so a trailing
#     sentinel byte is appended before capture and stripped back off after —
#     this preserves the exact byte sequence of the concatenated files
#     (no separator is inserted between files; "concatenate in order" is
#     read literally as back-to-back bytes). Each file is piped through
#     `tr -d '\r'` — same normalization plan-review.sh:493 applies to its own
#     two prompt assets — so a CRLF-authored rubric file doesn't change the
#     bytes actually sent to the engine (and therefore doesn't change the
#     --session hash, which is derived from these assembled bytes) relative
#     to an LF-only file with identical content. ---
SYSTEM_INSTRUCTIONS=$(
  for _f in "${SYS_PROMPT_FILES[@]}"; do
    tr -d '\r' < "$_f"
  done
  printf 'x'
)
SYSTEM_INSTRUCTIONS="${SYSTEM_INSTRUCTIONS%x}"
unset _f

# --- Artifact body: --prompt-file wins over stdin if both are given (stdin
#     is the fallback path for callers that cannot write files, not a
#     second source to merge with an explicit file). ---
if [ -n "$PROMPT_FILE_ARG" ]; then
  [ -f "$PROMPT_FILE_ARG" ] || _fail "--prompt-file not found: $PROMPT_FILE_ARG"
  ARTIFACT=$(cat "$PROMPT_FILE_ARG"; printf 'x')
  ARTIFACT="${ARTIFACT%x}"
else
  ARTIFACT=$(cat; printf 'x')
  ARTIFACT="${ARTIFACT%x}"
fi

# --- Reject an empty artifact body. A `--prompt-file` pointing at a
#     zero-byte file, or an empty stdin stream, would otherwise silently send
#     the engine an empty artifact and still return "a review" — symmetric
#     with the empty-system-prompt-file rejection above (line ~117). ---
[ -n "$ARTIFACT" ] || _fail "artifact body is empty (--prompt-file or stdin)"

# --- Bootstrap: source shared libs (same pattern as plan-review.sh, but
#     fail-loud instead of fail-open — a driver invoked directly has no
#     "allow the tool call anyway" concept to fall back to). ---
LIB_COMMON="$SCRIPT_DIR/lib/common.sh"
LIB_CONSULT="$SCRIPT_DIR/lib/consult.sh"

[ -s "$LIB_COMMON" ] || _fail "lib file missing or empty: $LIB_COMMON"
# shellcheck source=lib/common.sh
source "$LIB_COMMON" || _fail "failed to source $LIB_COMMON"

# --- Engine temp-resource cleanup registry (MUST be declared before trap
#     registration — see plan-review.sh's identical comment: an undeclared
#     array throws unbound-variable under `set -u` inside the trap). ---
ENGINE_TMP_FILES=()
ENGINE_TMP_DIRS=()

_cleanup() {
  declare -F backfill_engine_err >/dev/null 2>&1 && backfill_engine_err 143 || true
  rm -f "${PROMPT_FILE:-}" "${ENGINE_OUT:-}" "${ENGINE_ERR:-}"
  [ ${#ENGINE_TMP_FILES[@]} -eq 0 ] || rm -f "${ENGINE_TMP_FILES[@]}"
  [ ${#ENGINE_TMP_DIRS[@]}  -eq 0 ] || rmdir "${ENGINE_TMP_DIRS[@]}" 2>/dev/null || true
  ENGINE_TMP_FILES=()
  ENGINE_TMP_DIRS=()
  [ -z "${ENGINE_PID:-}" ] || kill "${ENGINE_PID:-}" 2>/dev/null || true
}
trap '_cleanup' EXIT
trap '_cleanup; exit 130' INT TERM HUP

# --- Engine selection: same whitelist case as plan-review.sh — REVIEW_ENGINE
#     is externally controlled via env var, never string-concat into
#     `source` (path-injection surface). ---
REVIEW_ENGINE="${REVIEW_ENGINE:-gemini}"
case "$REVIEW_ENGINE" in
  claude) ENGINE_LIB="claude.sh" ; ENGINE_CMD="claude" ;;
  codex)  ENGINE_LIB="codex.sh"  ; ENGINE_CMD="${CODEX_BIN:-codex}" ;;
  *)      ENGINE_LIB="agy.sh"    ; ENGINE_CMD="agy" ;;
esac
LIB_ENGINES_DIR="$SCRIPT_DIR/lib/engines"
LIB_REST="$LIB_ENGINES_DIR/rest.sh"
LIB_ENGINE_SELECTED="$LIB_ENGINES_DIR/$ENGINE_LIB"

for _lib in "$LIB_REST" "$LIB_ENGINE_SELECTED" "$LIB_CONSULT"; do
  [ -s "$_lib" ] || _fail "lib file missing or empty: $_lib"
done
unset _lib

# shellcheck source=lib/engines/rest.sh
source "$LIB_REST" || _fail "failed to source $LIB_REST"
# shellcheck disable=SC1090  # dynamic path — engine chosen by the whitelisted case above
source "$LIB_ENGINE_SELECTED" || _fail "failed to source $LIB_ENGINE_SELECTED"
# shellcheck source=lib/consult.sh
source "$LIB_CONSULT" || _fail "failed to source $LIB_CONSULT"

# --- Shared state directory (same default as plan-review.sh's COUNTER_DIR)
#     — DEGRADE_FILE must live here for the two callers to share Gemini
#     degraded-state bookkeeping. ---
COUNTER_DIR="${REVIEW_COUNTER_DIR:-/tmp/claude-reviews}"
mkdir -p "$COUNTER_DIR"
DEGRADE_FILE="$COUNTER_DIR/.gemini-degraded"

# --- Session key derivation + CONV_FILE assignment. Charset already
#     validated up-front (before stdin was consumed) — no re-check here. ---
if [ -n "$SESSION_LABEL" ]; then
  # Fold the ASSEMBLED system-prompt bytes into the hash input (not just the
  # label) — a newline separator keeps label/content from concatenating into
  # an ambiguous boundary. plan_hash() (lib/common.sh) is reused verbatim,
  # not reimplemented.
  SESSION_KEY_INPUT="${SESSION_LABEL}"$'\n'"${SYSTEM_INSTRUCTIONS}"
  SESSION_HASH=$(plan_hash "$SESSION_KEY_INPUT")
  CONV_FILE="${COUNTER_DIR}/.so-${SESSION_HASH:0:16}"
  # ROUND_INDEX inference: the driver does not count rounds itself — it only
  # distinguishes "first round" (no session file yet) from "continuation
  # round" (session file already exists, whatever its content). This must be
  # evaluated BEFORE run_consultation ever touches CONV_FILE this call.
  if [ -s "$CONV_FILE" ]; then
    ROUND_INDEX=1
  else
    ROUND_INDEX=0
  fi
else
  # Stateless single-round: CONV_FILE must still be a REAL path (see header
  # comment on the agy.sh mv danger) — a throwaway temp file, registered for
  # cleanup so it never survives past this invocation.
  CONV_FILE=$(mktemp)
  rm -f "$CONV_FILE"
  ENGINE_TMP_FILES+=("$CONV_FILE")
  ROUND_INDEX=0
fi

# --- Artifact body → PROMPT_FILE. Unlike plan-review.sh, this driver has no
#     GLOBAL_MD/PROJECT_MD/USER_REQ framing to layer on — PROMPT_FILE holds
#     exactly the artifact body, nothing else. ---
PROMPT_FILE=$(mktemp)
printf '%s' "$ARTIFACT" > "$PROMPT_FILE"

ENGINE_OUT=""
ENGINE_STATUS=""
ENGINE_PID=""
REQ_FILE=""

# --- Call the engine state machine. No REVIEW_DRY_RUN synthetic-APPROVE
#     branch here (this driver does not read that var at all — see header).
#
#     consult_on_round_end / consult_on_rest_prepare deliberately stay
#     UNDEFINED: both exist (in plan-review.sh) only to drive
#     inject_review_thread() against HISTORY_FILE, the orchestrator-owned
#     cross-round memory this driver simply doesn't have — it relies solely
#     on agy's own server-side --conversation session for continuity. With
#     no HISTORY_FILE concept, `declare -F` inside consult.sh finds neither
#     and no-ops, exactly as intended.
#
#     consult_on_rest_success IS defined, unlike the two above — it isn't
#     about HISTORY_FILE at all. When the CLI path fails and REST produces a
#     usable REVIEW, consult.sh calls this hook to invalidate CONV_FILE. The
#     REST call never went through agy, so its output was never appended to
#     any agy server-side session history; leaving a stale CONV_FILE behind
#     would make the NEXT round's --conversation resume a session that is
#     silently missing this round's finding, while the engine believes its
#     own history is complete. Dropping CONV_FILE forces a clean first round
#     next time instead of resuming a session with a gap in it.
consult_on_rest_success() { rm -f "${CONV_FILE:-}"; }

if ! run_consultation; then
  _fail "engine not found: $ENGINE_PROBE_REASON"
fi

if [ -z "$REVIEW" ]; then
  _fail "all review engines exhausted${_fail_reason:+ — ${_fail_reason}}"
fi

printf '%s' "$REVIEW"
