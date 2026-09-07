#!/usr/bin/env bash
# Stop hook — doc-gate exit-judgment layer.
#
# Invariant: doc set consistency is a property of the repo working tree, not
# of any one agent session. This hook derives "which .md files are currently
# dirty" from `git status`, and "who must be kept in sync" from the link
# graph — a check that can't be satisfied by anything short of actually
# touching the working tree, unlike the old marker-based entry gate.
#
# Platform facts this script relies on (CC 2.1.263,实测):
#   - Stop payload fields used here: cwd, stop_hook_active, background_tasks.
#   - stop_hook_active is false on the first Stop, true on every re-entry
#     after this hook's own `exit 2` — the platform maintains this, but its
#     upper bound on retries is unverified, so re-entry must be judged
#     locally (this hook blocks at most once per Stop cycle).
#   - Stop fires twice for a teammate ("name") spawn: once while the main
#     agent is waiting on a still-running background_tasks entry, and once
#     for the real finish. The first firing must be a no-op — the work isn't
#     done yet, and reporting findings there would look like "already
#     checked" when it wasn't.
#   - Only exit 2 + stderr blocks a Stop hook; hookSpecificOutput wrapping is
#     inert for this event. Same protocol as
#     plugins/dispatch-contract/hooks/subagent-done-gate.sh.
#   - A hook that times out is killed silently by the platform — the session
#     continues with no error and no trace. One timeout is one invisible gate
#     failure. See the --budget-sec plumbing into doc-exit-report.py.
#
# `git status --porcelain=v1 -z` layout (实测): a normal record is
# `XY<space>path\0`. A rename record's second NUL-terminated segment is the
# OLD path and carries no status prefix at all. A naive per-record loop
# would treat that old-path segment as a malformed independent record and
# drop it — precisely in the rename/archive scenario this hook exists to
# catch via dangling_refs.
#
# Rename can surface in EITHER column: `R `/`RM`/`RD` (X=R, a staged rename)
# or ` R`/`DR` (Y=R, a worktree-only rename from `git add -N` / `git add -p`
# — X is a space or D). Both forms carry the same two-NUL-segment layout, so
# both must trigger the old-path read; checking only X drops the Y-column
# case silently (实测: `git mv a.md b.md && git add -N b.md` emits
# ` R b.md\0a.md\0` — X is a space). These are two independent facts, kept
# separate: (1) copy is structurally impossible in --porcelain output
# (`git status` has no --find-copies; content-identical new files report as
# A, verified) — no C branch is written; (2) rename can appear in either
# column — both X and Y must be checked for 'R'.
#
# Environment variables:
#   DOC_EXIT_GATE_DISABLED=1     — kill switch
#   DOC_EXIT_GATE_THRESHOLD      — min BM25 recall score (default: 0.30)
#   DOC_EXIT_GATE_TOP_N          — max recall results per file (default: 5)
#   DOC_EXIT_GATE_BUDGET_SEC     — recall time budget in seconds (default: 25)
#
# No DOC_EXIT_GATE_ROOT override: root is git rev-parse --show-toplevel,
# single source — an override would reintroduce the two-root-detection split
# this design deliberately removed (a mismatched root between the git-status
# paths and the corpus paths is a worse failure than "no check ran").
set -u

# Phase 1: kill switch
[ "${DOC_EXIT_GATE_DISABLED:-0}" != "1" ] || exit 0

# Phase 2: preconditions
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_doc_gate_exclude.sh"

# Phase 3: read + validate stdin payload
INPUT=$(cat)
[ -n "$INPUT" ] || exit 0
printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1 || exit 0

# Phase 4: stop_hook_active — block at most once per Stop cycle. Whitelist
# form: only an explicit boolean `false` continues past this gate; every
# other case (`true`, `null`, a string/number, a missing field, or jq itself
# failing) exits quietly. This is deliberately asymmetric with "already
# blocked once" being the one thing that gets the SAME treatment as
# "couldn't tell" — the platform's upper bound on Stop re-entry retries is
# unverified, so an undetermined case must fail toward "do nothing", not
# toward "block again".
STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r 'if .stop_hook_active == false then "false" else "true" end' 2>/dev/null)
[ $? -eq 0 ] || exit 0
[ -n "$STOP_ACTIVE" ] || STOP_ACTIVE="true"
[ "$STOP_ACTIVE" = "true" ] && exit 0

# Phase 5: mid-flight Stop while a background teammate is still running —
# the work isn't finished, so any finding reported here would be incomplete
# and would masquerade as "already checked".
RUNNING=$(printf '%s' "$INPUT" | jq -r '[(.background_tasks // [])[] | select(.status=="running")] | length' 2>/dev/null)
[ -n "$RUNNING" ] || RUNNING=0
case "$RUNNING" in ''|*[!0-9]*) RUNNING=0 ;; esac
[ "$RUNNING" -gt 0 ] && exit 0

# Phase 6: resolve cwd (falls back to $PWD — 实测两者相等)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
[ -n "$CWD" ] || CWD="$PWD"

# Phase 7: git root — the ONLY root-detection path for this hook. A non-git
# working directory is handled by exiting quietly here, never by falling
# back to _doc_gate_common.py's detect_root() walk-up — two different root
# algorithms disagreeing would desync the git-reported paths from the
# corpus's paths, a worse failure than skipping the check.
ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
[ -n "$ROOT" ] || exit 0

# Phase 8: parse `git status -z` for dirty .md files (see header comment for
# the rename-record layout this loop must consume correctly).
#
# Deliberately no `-- '*.md'` pathspec here: git pathspec matching is
# case-sensitive even when the filesystem/core.ignorecase is not, so a
# `*.md` pathspec silently drops a dirty `UPPER.MD` before it ever reaches
# this loop — while the `*.[mM][dD]` case pattern below has always accepted
# `.MD` (doc-entry.sh's PostToolUse side does too). That mismatch made the
# uppercase branch below dead code. Fixing it means asking git for every
# dirty path (all extensions) and relying solely on the case pattern here to
# keep non-.md paths out of DIRTY_PATHS — a rename record for a non-.md path
# must still have its old-path NUL segment consumed (see the `else` branch)
# so it doesn't get misparsed as an independent record on the next
# iteration.
declare -a DIRTY_PATHS=()
while IFS= read -r -d '' rec; do
  [ -n "$rec" ] || continue
  xy="${rec:0:2}"
  x="${xy:0:1}"
  y="${xy:1:1}"
  path="${rec:3}"

  # Rename can be flagged in either column (see header comment) — either
  # one being 'R' means a second NUL-terminated old-path segment follows.
  is_rename=false
  if [ "$x" = "R" ] || [ "$y" = "R" ]; then
    is_rename=true
  fi

  bn="${path##*/}"
  case "$bn" in
    *.[mM][dD])
      DIRTY_PATHS+=("$path")
      if [ "$is_rename" = "true" ]; then
        if IFS= read -r -d '' old_path; then
          DIRTY_PATHS+=("$old_path")
        fi
      fi
      ;;
    *)
      # New-side path didn't match .md (shouldn't normally happen under the
      # '*.md' pathspec, but stay defensive): a rename record still owes us
      # consuming its old-path segment so the NEXT loop iteration doesn't
      # misparse it as an independent record.
      if [ "$is_rename" = "true" ]; then
        IFS= read -r -d '' _discard || true
      fi
      ;;
  esac
done < <(git -C "$ROOT" status --porcelain=v1 -z 2>/dev/null)

# Phase 9: exclusion filter — same source as doc-entry.sh, not a second copy.
declare -a FILTERED_PATHS=()
if [ "${#DIRTY_PATHS[@]}" -gt 0 ]; then
  for p in "${DIRTY_PATHS[@]}"; do
    [ -n "$p" ] || continue
    bn="${p##*/}"
    doc_gate_is_excluded_basename "$bn" && continue
    doc_gate_is_excluded_path "$p" && continue
    FILTERED_PATHS+=("$p")
  done
fi

# Phase 10: nothing dirty and in-scope
[ "${#FILTERED_PATHS[@]}" -gt 0 ] || exit 0

# Phase 11: invoke doc-exit-report.py — single call over the whole batch,
# fail-open on any error (missing tool, non-zero exit, unparsable output).
TOOL_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/tools"
RESULT=$(printf '%s\0' "${FILTERED_PATHS[@]}" | python3 "$TOOL_DIR/doc-exit-report.py" \
  --root "$ROOT" \
  --threshold "${DOC_EXIT_GATE_THRESHOLD:-0.30}" \
  --top-n "${DOC_EXIT_GATE_TOP_N:-5}" \
  --budget-sec "${DOC_EXIT_GATE_BUDGET_SEC:-25}" 2>/dev/null)
[ $? -eq 0 ] || exit 0
[ -n "$RESULT" ] || exit 0

# Phase 12: has_findings gate
HAS_FINDINGS=$(printf '%s' "$RESULT" | jq -r '.has_findings // false' 2>/dev/null)
[ $? -eq 0 ] || exit 0
[ "$HAS_FINDINGS" = "true" ] || exit 0

# Phase 13: render findings to stderr, block with exit 2.
DEGRADED=$(printf '%s' "$RESULT" | jq -r '.degraded // false' 2>/dev/null)
DEGRADED_REASON=$(printf '%s' "$RESULT" | jq -r '.degraded_reason // ""' 2>/dev/null)

MSG="文档出口检查：以下 .md 文件当前处于未提交状态，发现下列结构性问题："

if [ "$DEGRADED" = "true" ]; then
  MSG="${MSG}

[降级] 因耗时预算已放弃查重检查，本次只做了结构检查。${DEGRADED_REASON}"
fi

# Iterate file keys NUL-separated (not jq -r + line-read) — a legal path may
# contain a literal newline, and splitting on newline here would reintroduce
# on the render side the exact hazard the NUL-delimited git->python transfer
# was built to avoid.
while IFS= read -r -d '' fkey; do
  [ -n "$fkey" ] || continue
  FILE_JSON=$(printf '%s' "$RESULT" | jq -c --arg k "$fkey" '.files[$k]' 2>/dev/null) || continue
  [ -n "$FILE_JSON" ] && [ "$FILE_JSON" != "null" ] || continue

  STALE_LEN=$(printf '%s' "$FILE_JSON" | jq -r '.stale_inlinks | length' 2>/dev/null)
  ORPHAN=$(printf '%s' "$FILE_JSON" | jq -r '.orphan' 2>/dev/null)
  RECALL_LEN=$(printf '%s' "$FILE_JSON" | jq -r '.recall | length' 2>/dev/null)
  BROKEN_LEN=$(printf '%s' "$FILE_JSON" | jq -r '.broken_outlinks | length' 2>/dev/null)
  DANGLING_LEN=$(printf '%s' "$FILE_JSON" | jq -r '.dangling_refs | length' 2>/dev/null)

  case "$STALE_LEN" in ''|*[!0-9]*) STALE_LEN=0 ;; esac
  case "$RECALL_LEN" in ''|*[!0-9]*) RECALL_LEN=0 ;; esac
  case "$BROKEN_LEN" in ''|*[!0-9]*) BROKEN_LEN=0 ;; esac
  case "$DANGLING_LEN" in ''|*[!0-9]*) DANGLING_LEN=0 ;; esac
  [ "$ORPHAN" = "true" ] || ORPHAN="false"

  if [ "$STALE_LEN" -eq 0 ] && [ "$ORPHAN" != "true" ] && [ "$RECALL_LEN" -eq 0 ] && [ "$BROKEN_LEN" -eq 0 ] && [ "$DANGLING_LEN" -eq 0 ]; then
    continue
  fi

  MSG="${MSG}

--- ${fkey} ---"

  if [ "$STALE_LEN" -gt 0 ]; then
    STALE_LIST=$(printf '%s' "$FILE_JSON" | jq -r '.stale_inlinks | join("、")' 2>/dev/null)
    MSG="${MSG}
${fkey} 当前处于未提交状态；以下文件链向它且自身未被改动，其中的描述可能已经陈旧：${STALE_LIST}"
  fi

  if [ "$ORPHAN" = "true" ]; then
    MSG="${MSG}
结构信号：当前文件无入链（未被索引），建议补充索引链接。"
  fi

  if [ "$RECALL_LEN" -gt 0 ]; then
    RECALL_LINES=$(printf '%s' "$FILE_JSON" | jq -r '.recall | to_entries[] | "  \(.key + 1). [\(.value.score)] \(.value.path)"' 2>/dev/null)
    MSG="${MSG}
相关文档（可能存在内容重叠）：
${RECALL_LINES}"
  fi

  if [ "$BROKEN_LEN" -gt 0 ]; then
    BROKEN_LINES=$(printf '%s' "$FILE_JSON" | jq -r '.broken_outlinks[] | "  - \(.target) (line \(.line))"' 2>/dev/null)
    MSG="${MSG}
出链验证：内容引用了不存在的文件：
${BROKEN_LINES}"
  fi

  if [ "$DANGLING_LEN" -gt 0 ]; then
    DANGLING_LIST=$(printf '%s' "$FILE_JSON" | jq -r '.dangling_refs | join("、")' 2>/dev/null)
    MSG="${MSG}
断链反查：以下文件仍链着 ${fkey}，而它已不存在于当前工作树：${DANGLING_LIST}"
  fi
done < <(printf '%s' "$RESULT" | jq -j '.files | keys[] | (. + "\u0000")' 2>/dev/null)

printf '%s\n' "$MSG" >&2
exit 2
