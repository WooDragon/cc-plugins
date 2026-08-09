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

  # Phase 4: Path judge — only */memory/*.md, excluding MEMORY.md itself.
  # macOS/APFS is case-insensitive by default (memory.md / Memory.md / MEMORY.md
  # are the same file), so both the path glob and basename exclusion share one
  # nocasematch block.
  shopt -s nocasematch
  case "$FILE_PATH" in
    */memory/*.md) ;;
    *) shopt -u nocasematch; return ;;
  esac

  BASENAME="${FILE_PATH##*/}"
  case "$BASENAME" in
    memory.md) shopt -u nocasematch; return ;;
  esac
  shopt -u nocasematch

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

  # Phase 7: Content judge — score against signal-word list.
  #
  # Two matching rules, because ASCII and CJK words behave differently:
  # - ASCII/hyphenated words (letters/digits/hyphen only): matched with a
  #   word boundary via bash [[ =~ ]] regex, not a bare substring —
  #   otherwise "commit" fires inside "commitment" and "git" fires inside
  #   "github"/"digital".
  # - CJK words: no word-boundary concept applies (no whitespace between
  #   tokens), so substring matching is correct and stays as-is.
  #
  # Deliberately dropped: git, index, commit, timeout, hook. These are
  # generic ASCII tech vocabulary that shows up constantly in ordinary
  # project-local notes (e.g. "git 分支命名约定", "timeout 设成 30s，index
  # 建在 user_id 上") with zero discriminative power on their own. Keeping
  # them caused false-positive denies on routine local notes. The judgment
  # here is deliberately conservative: this is a soft reminder, not a hard
  # gate, so it's fine to occasionally miss a real cross-project lesson —
  # it's not fine to repeatedly deny mundane local writes.
  MIN_HITS="${BRAIN_ROUTE_MIN_HITS:-2}"
  SIGNAL_WORDS="worktree 门禁 printf subagent fail-open 逃生舱 夹具 假绿 payload 并行 bats pathspec"

  CONTENT_LOWER=$(printf '%s' "$CONTENT" | tr '[:upper:]' '[:lower:]')

  HITS=0
  for word in $SIGNAL_WORDS; do
    case "$word" in
      *[^a-z0-9-]*)
        # Contains a char outside [a-z0-9-] → CJK/non-ASCII → substring match.
        case "$CONTENT_LOWER" in
          *"$word"*) HITS=$((HITS + 1)) ;;
        esac
        ;;
      *)
        # Pure ASCII (letters/digits/hyphen) → word-boundary match.
        if [[ "$CONTENT_LOWER" =~ (^|[^a-z0-9_])${word}($|[^a-z0-9_]) ]]; then
          HITS=$((HITS + 1))
        fi
        ;;
    esac
  done

  [ "$HITS" -ge "$MIN_HITS" ] || return

  # Phase 8: Write marker + output deny JSON.
  # If the marker can't be written (quota/race), fail open rather than deny
  # without a marker on disk — otherwise a retry would deny again forever,
  # violating the "retry always passes" contract.
  [ -w "$GATE_DIR" ] || return
  touch "$GATE_DIR/$MARKER" 2>/dev/null || return

  MSG="路由提醒（首次写入 ${BASENAME}，同 session 后续写入不再提示）：

这段内容看起来是跨项目通用的工程教训。判据：漏召回的后果若只是「少一个提示」→ 适合走 brain；若是「规则被违反」（铁律、skill 调度表、docs 导航）→ 必须留本地文件。

若确认是跨项目通用教训：调 brain-recall skill，按其「写入」节走 /capture，写入 second-brain（volatility: durable），不要落本地文件。

若确认是项目局部记忆或确定性规则：照原计划继续写本地文件即可，重新发起这次写入就会放行。

逃生舱：BRAIN_ROUTE_DISABLED=1（需写入 ~/.claude/settings.json 的 env 段，Bash export 传不进 hook 进程）。"

  DENY_JSON=$(printf '%s' "$MSG" | jq -Rs .)
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}' "$DENY_JSON"
}

_main 2>/dev/null || true
