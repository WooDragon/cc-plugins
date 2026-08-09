#!/usr/bin/env bash
# PreToolUse:Edit/Write hook — Brain routing advisory.
#
# Sole responsibility: when a Write/Edit targets a local project memory
# file (projects/*/memory/*.md) and the content being written looks like
# a cross-project engineering lesson, remind the caller to consider
# routing it to second-brain (via the brain-recall skill) instead of
# writing it to the local file. This hook does NOT dedupe (that already
# happens server-side in second-brain's write path) and makes NO network
# calls — purely local, millisecond-scale string matching.
#
# Deny-once-per-file-per-session: same file in the same session only
# prompts once; retrying the write after that always passes.
#
# Environment variables:
#   BRAIN_ROUTE_DISABLED=1       — kill switch
#   BRAIN_ROUTE_GATE_DIR         — marker directory override
#   SKILL_GATE_DIR               — shared marker directory (default: /tmp/claude-reviews)
#   BRAIN_ROUTE_STALE_MIN        — marker staleness minutes (default: 120)
#   BRAIN_ROUTE_MIN_HITS         — distinct signal-word threshold (default: 2)
set -euo pipefail

_main() {
  INPUT=$(cat)

  # Phase 1: Kill switch
  [ "${BRAIN_ROUTE_DISABLED:-0}" != "1" ] || return

  # Phase 2: Preconditions
  command -v jq >/dev/null 2>&1 || return

  # Phase 3: Input extract
  TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || return
  SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || return
  [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ] || return
  [ -n "$SESSION_ID" ] || return

  FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null) || return
  [ -n "$FILE_PATH" ] || return

  # Phase 4: Path judge — only */memory/*.md, excluding MEMORY.md itself
  case "$FILE_PATH" in
    */memory/*.md) ;;
    *) return ;;
  esac

  BASENAME="${FILE_PATH##*/}"
  [ "$BASENAME" != "MEMORY.md" ] || return

  GATE_DIR="${BRAIN_ROUTE_GATE_DIR:-${SKILL_GATE_DIR:-/tmp/claude-reviews}}"
  STALE_MIN="${BRAIN_ROUTE_STALE_MIN:-120}"

  # Path sanitization
  SESSION_ID="${SESSION_ID//\//_}"

  # Phase 5: Per-file marker — allow silently on subsequent writes this session
  FILE_HASH=$(printf '%s' "$FILE_PATH" | shasum -a 256 2>/dev/null | cut -c1-16) || return
  MARKER=".brain-route-${SESSION_ID}-${FILE_HASH}"
  [ -n "$GATE_DIR" ] && mkdir -p "$GATE_DIR" 2>/dev/null || true

  # Stale cleanup
  find "$GATE_DIR" -maxdepth 1 -name '.brain-route-*' -mmin +"$STALE_MIN" -delete 2>/dev/null || true

  if [ -f "$GATE_DIR/$MARKER" ]; then
    return
  fi

  # Phase 6: Content extract
  if [ "$TOOL_NAME" = "Write" ]; then
    CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // ""' 2>/dev/null) || return
  else
    CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // ""' 2>/dev/null) || return
  fi

  # Phase 7: Content judge — score against signal-word list
  MIN_HITS="${BRAIN_ROUTE_MIN_HITS:-2}"
  SIGNAL_WORDS="worktree hook 门禁 printf subagent commit fail-open 逃生舱 夹具 假绿 payload timeout 并行 git bats pathspec index"

  CONTENT_LOWER=$(printf '%s' "$CONTENT" | tr '[:upper:]' '[:lower:]')

  HITS=0
  for word in $SIGNAL_WORDS; do
    case "$CONTENT_LOWER" in
      *"$word"*) HITS=$((HITS + 1)) ;;
    esac
  done

  [ "$HITS" -ge "$MIN_HITS" ] || return

  # Phase 8: Write marker + output deny JSON
  [ -w "$GATE_DIR" ] || return
  touch "$GATE_DIR/$MARKER" 2>/dev/null || true

  MSG="路由提醒（首次写入 ${BASENAME}，同 session 后续写入不再提示）：

这段内容看起来是跨项目通用的工程教训。判据：漏召回的后果若只是「少一个提示」→ 适合走 brain；若是「规则被违反」（铁律、skill 调度表、docs 导航）→ 必须留本地文件。

若确认是跨项目通用教训：调用 brain-recall skill 写入 second-brain（volatility: durable），不要落本地文件。

若确认是项目局部记忆或确定性规则：照原计划继续写本地文件即可，重新发起这次写入就会放行。

逃生舱：BRAIN_ROUTE_DISABLED=1（需写入 ~/.claude/settings.json 的 env 段，Bash export 传不进 hook 进程）。"

  DENY_JSON=$(printf '%s' "$MSG" | jq -Rs .)
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}' "$DENY_JSON"
}

_main 2>/dev/null || true
