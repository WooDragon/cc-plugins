# lib/verdict.sh — verdict extraction + feedback rendering (pure rendering
# layer: takes already-computed state as arguments, renders text → JSON,
# prints it, and exits 0). Sourced (not executed) by plan-review.sh.
#
# State-machine concerns (counter writes, ATTEMPT/TOTAL_ROUNDS mutation,
# dispatch JSON persistence) stay in the caller — this file only renders.
#
# bash 3.2 compatible: no associative arrays, no ${var^^}, no &>>.

# --- Extract structured verdict (XML-tag isolation, anti-hijack) ---
# Defensive extraction: LLM output is untrusted external input.
#   1. printf — safe for text starting with -n/-E (echo is not), trailing \n for POSIX
#   2. tr upper — case-normalize before matching (BSD sed has no /I flag)
#   3. grep -oE (first pass) — extract <VERDICT>...</VERDICT> tag
#   4. grep -oE (second pass) — extract verdict keyword from the tag
#   5. head -n 1 — LLM may emit multiple tags; guarantee single value
#   || true — grep returns exit 1 on no match; suppress for set -e + pipefail
# Echoes the verdict keyword (APPROVE/CONCERNS/REJECT) via stdout — same
# calling convention as plan_hash() in lib/common.sh.
extract_verdict() {
  local review="$1" verdict
  verdict=$(printf "%s\n" "$review" \
    | tr '[:lower:]' '[:upper:]' \
    | grep -oE '<VERDICT>[[:space:]]*(APPROVE|CONCERNS|REJECT)[[:space:]]*</VERDICT>' \
    | grep -oE 'APPROVE|CONCERNS|REJECT' \
    | head -n 1) || true
  if [ -z "$verdict" ]; then
    verdict="CONCERNS"
    echo "plan-review: verdict tag missing or malformed, falling back to CONCERNS." >&2
  fi
  printf '%s' "$verdict"
}

# --- APPROVE feedback: ack-deny so Claude presents the approval to the user ---
# Args: $1=TOTAL_ROUNDS $2=REVIEW_ENGINE $3=REVIEW. Prints the deny JSON and exits 0.
render_approve_feedback() {
  local total_rounds="$1" review_engine="$2" review="$3"
  local approve_header feedback feedback_json

  if [ "$total_rounds" -gt 0 ]; then
    approve_header="Red Team Review — ${review_engine} — APPROVED (Round $((total_rounds + 1)))"
  else
    approve_header="Red Team Review — ${review_engine} — APPROVED"
  fi

  feedback=$(cat << APPROVE_EOF
## ${approve_header}

审阅引擎对本次 plan **技术上无异议**（verdict=APPROVE）。以下是审阅摘要：

---

${review}

---

**审阅通过 ≠ 可以开工。** 审阅引擎只是对等 peer，它的 APPROVE 仅表示"技术上无异议"，**不代表**用户已授权执行。此刻**禁止**开始任何落地动作（编辑文件、执行命令）。

下一步（必须严格照做）：
1. 向用户简要展示上述审阅结果；
2. **不修改 plan**，直接再次调用 ExitPlanMode——这一步才会把 plan 交给用户做原生的 go/no-go 决策；
3. 只有在用户通过 ExitPlanMode 原生批准后，才可以开工。
APPROVE_EOF
  )
  feedback_json=$(printf '%s' "$feedback" | jq -Rs .)
  cat << EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":${feedback_json}}}
EOF
  exit 0
}

# --- CONCERNS / REJECT feedback (severity-differentiated) ---
# Args: $1=VERDICT $2=ATTEMPT $3=TOTAL_ROUNDS $4=REVIEW_ENGINE $5=REVIEW_MAX_ROUNDS
#       $6=REVIEW_MAX_TOTAL_ROUNDS $7=REVIEW. Prints the deny JSON and exits 0.
render_concerns_or_reject_feedback() {
  local verdict="$1" attempt="$2" total_rounds="$3" review_engine="$4"
  local review_max_rounds="$5" review_max_total_rounds="$6" review="$7"
  local feedback_header phase_msg remaining feedback feedback_json

  if [ "$verdict" = "REJECT" ]; then
    feedback_header="Red Team Review — ${review_engine} — REJECT (Round ${total_rounds}/${review_max_total_rounds})"
    phase_msg="审阅引擎发现 Critical 级别问题。非 Critical 磋商计数已重置，解决 Critical 项后可重新获得 ${review_max_rounds} 轮磋商机会。"
  else
    remaining=$((review_max_rounds - attempt))
    feedback_header="Red Team Review — ${review_engine} — CONCERNS (Round ${attempt}/${review_max_rounds})"
    phase_msg="磋商剩余轮次：${remaining}。若双方无法达成一致，plan 将直接呈现给用户做最终裁决。"
  fi

  feedback=$(cat << REVIEW_EOF
## ${feedback_header}

${phase_msg}

你有两个选择：
1. 如意见合理，修正 plan 后再次调用 ExitPlanMode
2. 如你认为意见不成立，在 plan 中补充辩护理由后再次调用 ExitPlanMode

---

${review}
REVIEW_EOF
  )

  feedback_json=$(printf '%s' "$feedback" | jq -Rs .)

  cat << EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":${feedback_json}}}
EOF

  exit 0
}
