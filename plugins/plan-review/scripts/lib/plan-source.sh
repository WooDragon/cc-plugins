# lib/plan-source.sh — resolves plan content location from the CC 2.1.x
# out-of-band plan-file contract, plus the resolver's error-message router.
# Sourced (not executed) by plan-review.sh.
#
# bash 3.2 compatible: no associative arrays, no ${var^^}, no &>>.

# --- Transcript-based plan recovery (CC 2.1.x contract: plan lives in an
#     out-of-band file referenced by the plan_mode attachment, which is NOT in
#     the hook stdin; only transcript_path is). Resolve the latest plan file
#     path from the transcript and, if — and only if — it clears three security
#     gates, set RECOVERED_PATH to its physical absolute path. On any rejection,
#     leave RECOVERED_PATH empty and set RESOLVE_REASON for the caller's error
#     messaging.
#
#     IMPORTANT: sets globals directly (no echo + $(...)), because command
#     substitution runs in a subshell and would discard RESOLVE_REASON.
#
#     Threat model (defense in depth):
#       - FIFO / device file → blocking read hangs jq/cat, drains the 600s hook
#         budget, wedges the whole CLI. Gate: [ -f ] (regular file only).
#       - Symlink in plans dir → string-prefix whitelist is bypassable; a link to
#         ~/.ssh/id_rsa or /etc/passwd would be cat'd into the review engine.
#         Gate: reject [ -h ], then realpath to the physical path before the check.
#       - Path traversal → reject any '..' in the raw path.
# ---
RESOLVE_REASON=""
RECOVERED_PATH=""
RESOLVE_PATH=""
resolve_plan_from_transcript() {
  RESOLVE_REASON=""
  RECOVERED_PATH=""
  RESOLVE_PATH=""
  local transcript="$1"
  # Gate 0: transcript must be a regular file (not FIFO/device → no blocking read).
  [ -n "$transcript" ] && [ -f "$transcript" ] || { RESOLVE_REASON="no-transcript"; return; }

  # Whitelist root for plan files (REVIEW_PLAN_DIR reused; prod fallback ~/.claude/plans).
  local whitelist_root="${REVIEW_PLAN_DIR:-$HOME/.claude/plans}"

  # Streaming extraction (line-by-line, no slurp): newest plan_mode planFilePath.
  local raw_path
  raw_path=$(jq -r 'select(.attachment?.type == "plan_mode" and .attachment?.planFilePath != null) | .attachment.planFilePath' "$transcript" 2>/dev/null | tail -1 || true)
  [ -n "$raw_path" ] && [ "$raw_path" != "null" ] || { RESOLVE_REASON="no-plan-attachment"; return; }
  # Expose the path under evaluation so error messages stay actionable on every reject path.
  RESOLVE_PATH="$raw_path"

  # Gate 1: reject path traversal in the raw path.
  case "$raw_path" in
    *..*) RESOLVE_REASON="path-traversal"; return ;;
  esac

  # Gate 2: reject symlinks outright (don't follow links out of the sandbox).
  if [ -h "$raw_path" ]; then
    RESOLVE_REASON="symlink-rejected"
    return
  fi

  # Resolve to the physical path before the whitelist check. Resolve the PARENT
  # directory physically (cd -P collapses symlinked path components) and re-append
  # the basename — this works whether or not the target file exists yet, and is
  # portable (no realpath-on-missing-file dependency, which fails on macOS/BSD).
  local dir base dir_resolved resolved
  dir=$(dirname "$raw_path"); base=$(basename "$raw_path")
  if [ ! -d "$dir" ]; then
    # Parent dir absent → framework named a file under a nonexistent dir; treat as missing.
    RESOLVE_REASON="resolved-but-missing"
    return
  fi
  dir_resolved=$(cd "$dir" 2>/dev/null && pwd -P) || { RESOLVE_REASON="unresolvable"; return; }
  [ -n "$dir_resolved" ] || { RESOLVE_REASON="unresolvable"; return; }
  resolved="${dir_resolved}/${base}"
  RESOLVE_PATH="$resolved"

  # Resolve the whitelist root the same way so the prefix compare is apples-to-apples.
  local root_resolved
  if [ -d "$whitelist_root" ]; then
    root_resolved=$(cd "$whitelist_root" 2>/dev/null && pwd -P) || root_resolved="$whitelist_root"
  else
    root_resolved="$whitelist_root"
  fi

  # Gate 3: physical path must live under the whitelist root.
  case "$resolved" in
    "$root_resolved"/*) : ;;
    *) RESOLVE_REASON="outside-whitelist"; return ;;
  esac

  # Final: must be an existing regular file (covers "framework named it but never wrote it").
  if [ ! -f "$resolved" ]; then
    RESOLVE_REASON="resolved-but-missing"
    return
  fi

  RESOLVE_REASON="ok"
  RECOVERED_PATH="$resolved"
}

# --- Resolver error-message router (verbatim case block, formerly inline
#     in plan-review.sh's fail-closed no-plan-content branch). Reads the
#     RESOLVE_REASON/RESOLVE_PATH globals set by resolve_plan_from_transcript
#     plus the caller's PLAN_FILE_PATH, and sets the REASON global directly
#     (no $(...) subshell — matches resolve_plan_from_transcript's own
#     global-assignment style so callers just read $REASON afterward).
# Resolver-reason error message. Every path-aware branch names the plan file
# under evaluation (RESOLVE_PATH) so the user can act — "write your plan to
# this exact file" instead of a bare directive.
plan_source_error_reason() {
  REASON=""
  case "${RESOLVE_REASON:-}" in
    resolved-but-missing)
      REASON="[ERROR] plan 内容未传入。框架在 transcript 中指定了 plan 文件 \"${RESOLVE_PATH}\"，但该文件尚未写入。请用 Write 将 plan 写入该文件后重新调用 ExitPlanMode。" ;;
    outside-whitelist|symlink-rejected|path-traversal)
      REASON="[ERROR] plan 文件路径 \"${RESOLVE_PATH}\" 非法（${RESOLVE_REASON}），出于安全已拒绝读取。请将 plan 写入框架许可的 plan 目录；路径不得包含 ..，且不能是软链接。" ;;
    *)
      if [ -n "${PLAN_FILE_PATH:-}" ] && [ "${PLAN_FILE_PATH:-}" != "null" ]; then
        REASON="[ERROR] plan 内容未传入。tool_input.plan 为空，planFilePath=\"${PLAN_FILE_PATH}\" 指向的文件不存在。请将 plan 写入该文件后重新调用 ExitPlanMode。"
      else
        REASON="[ERROR] plan 内容未传入。tool_input.plan 和 planFilePath 均为空，且无法从 transcript 反查到 plan 文件（${RESOLVE_REASON:-no-transcript}）。请确保 plan 已写入框架指定的 plan 文件后重试。"
      fi ;;
  esac
}
