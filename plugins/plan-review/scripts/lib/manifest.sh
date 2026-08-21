# lib/manifest.sh — Dispatch Manifest v2 detection, validation, and serialization.
# Sourced by plan-review.sh. This file validates only manifest structure; it
# deliberately has no dynamic agent catalog or model ownership policy.
# bash 3.2 compatible: no associative arrays, no ${var^^}, no &>>.

needs_manifest() { printf '%s' "$1" | grep -qiE '(Task\(|subagent_type|agent_type|Plan agent|Explore agent|worker agent|dev agent)'; }
has_manifest() { printf '%s' "$1" | grep -qi '^## Dispatch Manifest'; }
# manifest_table_rows <plan>
# Emits only table rows in the Dispatch Manifest section. A single terminal CR
# is normalized as line ending syntax; after the table starts, a blank line is
# a hard boundary so later prose/tables cannot affect validation or dispatch.
manifest_table_rows() {
  local plan="$1" line="" in_manifest=0 table_started=0
  local had_nocasematch=0
  local carriage_return=$'\r'

  # Do not pipe the complete plan into an early-exiting reader. On a large plan,
  # awk's former `exit` closed the pipe while printf was still writing; pipefail
  # then turned the expected section boundary into SIGPIPE. Iterate the argument
  # directly instead: no pipe writer and no heredoc delimiter that plan content
  # could accidentally terminate. This is supported by macOS bash 3.2.
  shopt -q nocasematch && had_nocasematch=1 || shopt -s nocasematch
  while [ -n "$plan" ]; do
    case "$plan" in
      *$'\n'*)
        line=${plan%%$'\n'*}
        plan=${plan#*$'\n'}
        ;;
      *)
        line=$plan
        plan=""
        ;;
    esac
    line=${line%"$carriage_return"}
    if [ "$in_manifest" -eq 0 ]; then
      case "$line" in
        '## Dispatch Manifest'*) in_manifest=1 ;;
      esac
      continue
    fi

    case "$line" in
      '## '*) break ;;
    esac
    if [ "$table_started" -eq 1 ] && [[ "$line" =~ ^[[:space:]]*$ ]]; then
      break
    fi
    if [[ "$line" =~ ^[[:space:]]*\| ]]; then
      table_started=1
      printf '%s\n' "$line"
    fi
  done
  [ "$had_nocasematch" -eq 1 ] || shopt -u nocasematch
}

manifest_has_agent_signature() {
  local rows
  rows=$(manifest_table_rows "$1")
  awk '
    {
      line=$0
      sub(/^[[:space:]]*\|[[:space:]]*/, "", line)
      split(line, fields, /[[:space:]]*\|[[:space:]]*/)
      if (tolower(fields[2]) ~ /^[[:space:]]*agent[[:space:]]*$/) found=1
    }
    END { exit !found }
  ' <<MANIFEST_ROWS_EOF
$rows
MANIFEST_ROWS_EOF
}

# Manifest v2 is intentionally explicit about dispatch ownership:
# - main rows describe work retained in the main context;
# - agent/preset rows name a registered agent and must omit model;
# - agent/runtime rows name both the agent and exact runtime model.
MANIFEST_EXAMPLE=$(cat <<'MANIFEST_EOF'
格式示例（占位值 <...> 替换为你 plan 的真实步骤，勿原样复制本表）：

## Dispatch Manifest
| step | location | subagent_type | model_source | model | depends_on | parallel_with |
|------|----------|---------------|--------------|-------|------------|---------------|
| 1    | main     | -             | -            | -     | -          | -             |
| 2    | agent    | <agent_type>  | preset       | -     | 1          | -             |
| 3    | agent    | <agent_type>  | runtime      | <model> | 1        | 2             |

填写规则：
- `main` 行：subagent_type、model_source、model 均填 `-`。
- `agent` + `preset` 行：subagent_type 必填，model 必须填 `-`（调用时完全省略 model）。
- `agent` + `runtime` 行：subagent_type 与 model 必填（调用时二者精确匹配）。
- depends_on / parallel_with：填依赖/并行的 step 号，无则填 `-`。
MANIFEST_EOF
)

# validate_manifest_v2 <plan>
# Returns zero only for the v2 table shape and row semantics. On failure it
# stores a human-readable structural reason in MANIFEST_ERROR for pre-flight.
validate_manifest_v2() {
  local plan="$1"
  MANIFEST_ERROR=$(manifest_table_rows "$plan" | awk '
    function trim(value) { sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value); return value }
    # Keep consuming rows after the first error. The caller runs under pipefail;
    # exiting here would SIGPIPE manifest_table_rows on a large valid plan.
    function fail(message) { if (!failed) { print message; failed=1 } }
    BEGIN { expected[1]="step"; expected[2]="location"; expected[3]="subagent_type"; expected[4]="model_source"; expected[5]="model"; expected[6]="depends_on"; expected[7]="parallel_with" }
    {
      if (failed) next
      # The serializer uses tab-delimited records internally. Reject control
      # separators before extraction so a cell cannot alter that framing.
      if (header_seen && (index($0, "\t") || index($0, "\r"))) { fail("data cells must not contain tab or carriage-return"); next }
      line=$0; sub(/^[[:space:]]*\|[[:space:]]*/, "", line); sub(/[[:space:]]*\|[[:space:]]*$/, "", line)
      count=split(line, fields, /[[:space:]]*\|[[:space:]]*/)
      for (i=1; i<=count; i++) fields[i]=trim(fields[i])
      if (!header_seen) {
        if (count != 7) { fail("header must have seven v2 columns"); next }
        for (i=1; i<=7; i++) if (fields[i] != expected[i]) { fail("header must be: step | location | subagent_type | model_source | model | depends_on | parallel_with"); next }
        header_seen=1
        next
      }
      if (count != 7) { fail("every row must have seven columns"); next }
      if (fields[1] ~ /^:?-+:?$/) {
        for (i=2; i<=7; i++) if (fields[i] !~ /^:?-+:?$/) { fail("table separator must have seven Markdown separator cells"); next }
        separator_seen=1
        next
      }
      step=fields[1]; location=fields[2]; agent_type=fields[3]; model_source=fields[4]; model=fields[5]
      if (step == "" || step == "-") fail("step is required")
      if (location == "main") {
        if (agent_type != "-" || model_source != "-" || model != "-") fail("main rows require subagent_type, model_source, and model to be -")
      } else if (location == "agent") {
        if (agent_type == "" || agent_type == "-") fail("agent rows require subagent_type")
        if (model_source == "preset") {
          if (model != "-") fail("preset rows require model to be -")
        } else if (model_source == "runtime") {
          if (model == "" || model == "-") fail("runtime rows require model")
        } else {
          fail("agent rows require model_source preset or runtime")
        }
      } else {
        fail("location must be main or agent")
      }
      row_count++
    }
    END {
      if (!failed && !header_seen) { print "missing v2 table header"; exit 1 }
      if (!failed && !separator_seen) { print "missing table separator"; exit 1 }
      if (!failed && row_count == 0) { print "manifest has no data rows"; exit 1 }
      if (failed) exit 1
    }
  ')
}

# parse_manifest_to_json <plan> <hash>
# The validator has already checked the table and rejected TSV framing controls.
# awk only extracts tab-delimited records; jq is the sole JSON serializer, so
# quotes and backslashes are escaped instead of being stripped or spliced.
parse_manifest_to_json() {
  local plan="$1" hash="$2"
  validate_manifest_v2 "$plan" || return 1
  manifest_table_rows "$plan" | awk '
    function trim(value) { sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value); return value }
    {
      line=$0; sub(/^[[:space:]]*\|[[:space:]]*/, "", line); sub(/[[:space:]]*\|[[:space:]]*$/, "", line)
      count=split(line, fields, /[[:space:]]*\|[[:space:]]*/)
      for (i=1; i<=count; i++) fields[i]=trim(fields[i])
      if (!header_seen) { header_seen=1; next }
      if (fields[1] ~ /^-+$/ || count != 7) next
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7]
    }
  ' | jq -Rn --arg hash "$hash" --argjson created_at "$(date +%s)" '
    def null_if_dash: if . == "-" then null else . end;
    [inputs | split("\t") | {
      id: .[0],
      location: .[1],
      subagent_type: (.[2] | null_if_dash),
      model_source: (.[3] | null_if_dash),
      model: (.[4] | null_if_dash),
      depends_on: (.[5] | null_if_dash),
      parallel_with: (.[6] | null_if_dash)
    }] as $steps |
    {
      schema_version: 2,
      plan_hash: $hash,
      created_at: $created_at,
      requires_dispatch_check: true,
      steps: $steps,
      allowed_signatures: (
        reduce ($steps[] | select(.location == "agent") |
          if .model_source == "preset" then
            {subagent_type, model_source}
          else
            {subagent_type, model_source, model}
          end
        ) as $signature
        ([]; if index($signature) == null then . + [$signature] else . end)
      )
    }
  '
}

# dispatch_state_is_valid_v2 <state-file>
# The state writer and dispatch hook share this predicate. It accepts only a
# complete v2 payload whose signature set is exactly derived from its steps.
dispatch_state_is_valid_v2() {
  local state_file="$1"
  jq -e '
    def nonempty_string: type == "string" and length > 0;
    def nullable_string: . == null or type == "string";
    def step_signatures:
      [.steps[] | select(.location == "agent") |
        if .model_source == "preset" then
          {subagent_type, model_source}
        else
          {subagent_type, model_source, model}
        end] |
      unique_by([.subagent_type, .model_source, (.model // "")]);
    def declared_signatures:
      .allowed_signatures |
      unique_by([.subagent_type, .model_source, (.model // "")]);

    .schema_version == 2 and
    .requires_dispatch_check == true and
    (.plan_hash | nonempty_string) and
    (.created_at | type == "number") and
    (.steps | type == "array") and
    all(.steps[];
      (.id | nonempty_string) and
      (.depends_on | nullable_string) and
      (.parallel_with | nullable_string) and
      if .location == "main" then
        .subagent_type == null and .model_source == null and .model == null
      elif .location == "agent" and .model_source == "preset" then
        (.subagent_type | nonempty_string) and .model == null
      elif .location == "agent" and .model_source == "runtime" then
        (.subagent_type | nonempty_string) and (.model | nonempty_string)
      else
        false
      end
    ) and
    (.allowed_signatures | type == "array") and
    all(.allowed_signatures[];
      (.subagent_type | nonempty_string) and
      if .model_source == "preset" then
        (has("model") | not)
      elif .model_source == "runtime" then
        (.model | nonempty_string)
      else
        false
      end
    ) and
    declared_signatures == step_signatures
  ' "$state_file" >/dev/null 2>&1
}
