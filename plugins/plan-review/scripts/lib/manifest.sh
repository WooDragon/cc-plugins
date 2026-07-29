# lib/manifest.sh — Dispatch Manifest detection + parsing primitives.
# Sourced (not executed) by plan-review.sh. The two pre-flight `if` guards
# (missing-manifest / degenerate-manifest deny branches) stay in the caller —
# this file only supplies the functions/variable those guards call.
#
# bash 3.2 compatible: no associative arrays, no ${var^^}, no &>>.

# --- Manifest detection helpers (case-insensitive: LLM may write "Worker Agent"/"TASK(") ---
needs_manifest() { printf '%s' "$1" | grep -qiE '(Task\(|subagent_type|agent_type|Plan agent|Explore agent|worker agent|dev agent)'; }
has_manifest()   { printf '%s' "$1" | grep -qi '^## Dispatch Manifest'; }

# Returns 0 if at least one manifest data row has a non-dash agent_type.
manifest_has_real_agent() {
  printf '%s\n' "$1" | awk '
    /^## Dispatch Manifest/ {in_m=1; seen_table=0; next}
    in_m && /^## / {in_m=0}
    in_m && /^ *\|/ {seen_table=1}
    in_m && seen_table && /^ *$/ {in_m=0}
    in_m && /^\|/ && !/^\|---/ && !/^\| *[Ss][Tt][Ee][Pp]/ {
      gsub(/^\| *| *\| *$/, ""); n = split($0, f, / *\| */)
      if (n >= 2) { at=f[2]; gsub(/^ +| +$|"/, "", at); if (at != "-" && at != "") found=1 }
    }
    END { exit (found ? 0 : 1) }
  '
}

# --- Canonical manifest example (single source of truth for both deny messages) ---
# Single-quoted heredoc: backticks, $ and <placeholders> stay literal (no command
# substitution, no expansion). Embedded verbatim into deny reasons so a blocked LLM
# sees the exact format inline instead of guessing column names from CLAUDE.md.
# Agent-row values are <placeholders>, not a copy-pastable real step, so the LLM
# can't paste the example wholesale and inject a phantom dispatch step.
MANIFEST_EXAMPLE=$(cat <<'MANIFEST_EOF'
格式示例（占位值 <...> 替换为你 plan 的真实步骤，勿原样复制本表）：

## Dispatch Manifest
| step | agent_type    | model   | depends_on | parallel_with |
|------|---------------|---------|------------|---------------|
| 1    | -             | -       | -          | -             |
| 2    | <agent_type>  | <model> | 1          | -             |

填写规则：
- 主上下文执行的 step：agent_type 与 model 两列均填 `-`。
- 委派给 Agent 的 step：两列必填，model 用全名（sonnet / opus / haiku）。
- depends_on / parallel_with：填依赖/并行的 step 号，无则填 `-`。
MANIFEST_EOF
)

# --- Manifest JSON serializer (called only from APPROVE branch; failures are silent) ---
# Parses the ## Dispatch Manifest markdown table and outputs a dispatch JSON blob.
# JSON injection defense: strips stray double-quotes LLM may write in manifest rows.
parse_manifest_to_json() {
  local plan="$1" hash="$2"
  printf '%s\n' "$plan" | awk -v hash="$hash" -v now="$(date +%s)" '
    /^## Dispatch Manifest/ {in_manifest=1; seen_table=0; next}
    in_manifest && /^## / {in_manifest=0}
    in_manifest && /^ *\|/ {seen_table=1}
    in_manifest && seen_table && /^ *$/ {in_manifest=0}
    in_manifest && /^\|/ && !/^\|---/ && !/^\| *[Ss][Tt][Ee][Pp]/ {
      gsub(/^\| *| *\| *$/, ""); n = split($0, f, / *\| */)
      if (n >= 3) {
        id=f[1]; at=f[2]; md=f[3]
        gsub(/^ +| +$/, "", id); gsub(/^ +| +$/, "", at); gsub(/^ +| +$/, "", md)
        gsub(/"/, "", id); gsub(/"/, "", at); gsub(/"/, "", md)
        rows[++count] = sprintf("{\"id\":\"%s\",\"agent_type\":%s,\"model\":%s}",
          id,
          (at == "-" ? "null" : "\"" at "\""),
          (md == "-" ? "null" : "\"" md "\""))
      }
    }
    END {
      printf "{\"plan_hash\":\"%s\",\"created_at\":%s,\"requires_dispatch_check\":true,\"steps\":[", hash, now
      for (i=1; i<=count; i++) printf "%s%s", (i>1?",":""), rows[i]
      printf "]}\n"
    }
  '
}
