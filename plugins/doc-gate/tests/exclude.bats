#!/usr/bin/env bats
# BDD tests for _doc_gate_exclude.sh (shared path-exclusion predicate)

setup() {
  source "${BATS_TEST_DIRNAME}/test_helper/common-setup.bash"
  common_setup
  source "${BATS_TEST_DIRNAME}/../scripts/_doc_gate_exclude.sh"
}

teardown() {
  common_teardown
}

# ============================================================
# Excluded (return 0)
# ============================================================

@test "excluded: pipeline/verification/x.md (deep-research intermediate)" {
  run doc_gate_is_excluded_path "/project/pipeline/verification/x.md"
  [ "$status" -eq 0 ]
}

@test "excluded: logs/run.md" {
  run doc_gate_is_excluded_path "/project/logs/run.md"
  [ "$status" -eq 0 ]
}

@test "excluded: /tmp/foo.md" {
  run doc_gate_is_excluded_path "/tmp/foo.md"
  [ "$status" -eq 0 ]
}

@test "excluded: .git/COMMIT_EDITMSG" {
  run doc_gate_is_excluded_path "/project/.git/COMMIT_EDITMSG"
  [ "$status" -eq 0 ]
}

@test "excluded: node_modules/pkg/readme.md" {
  run doc_gate_is_excluded_path "/project/node_modules/pkg/readme.md"
  [ "$status" -eq 0 ]
}

@test "excluded: intake/requirements/research-goal.md (deep-research G0 product)" {
  run doc_gate_is_excluded_path "/project/intake/requirements/research-goal.md"
  [ "$status" -eq 0 ]
}

@test "excluded: intake/background/context.md (deep-research G0 product)" {
  run doc_gate_is_excluded_path "/project/intake/background/context.md"
  [ "$status" -eq 0 ]
}

@test "excluded: deliverables/final/report.md (ADR-010 conflict, own quality system)" {
  run doc_gate_is_excluded_path "/project/deliverables/final/report.md"
  [ "$status" -eq 0 ]
}

@test "excluded: deliverables via relative path (projects/x/deliverables/final/report.md)" {
  run doc_gate_is_excluded_path "projects/x/deliverables/final/report.md"
  [ "$status" -eq 0 ]
}

@test "excluded: deliverables nested arbitrarily deep (a/b/c/deliverables/drafts/v2/report.md)" {
  run doc_gate_is_excluded_path "/project/a/b/c/deliverables/drafts/v2/report.md"
  [ "$status" -eq 0 ]
}

@test "excluded: .agents/intel/5-intel.md (team-ops runtime artifact, #176)" {
  run doc_gate_is_excluded_path "/project/.agents/intel/5-intel.md"
  [ "$status" -eq 0 ]
}

@test "excluded: .agents/handoffs/x-dev-report.md (team-ops runtime artifact, #176)" {
  run doc_gate_is_excluded_path "/project/.agents/handoffs/x-dev-report.md"
  [ "$status" -eq 0 ]
}

@test "excluded: .agents/tasks/t-1.md (team-ops runtime artifact, #176)" {
  run doc_gate_is_excluded_path "/project/.agents/tasks/t-1.md"
  [ "$status" -eq 0 ]
}

@test "excluded: .agents/directives/sprint-x.md (regression, original exemption retained)" {
  run doc_gate_is_excluded_path "/project/.agents/directives/sprint-x.md"
  [ "$status" -eq 0 ]
}

@test "excluded: relative .agents/intel/a.md" {
  run doc_gate_is_excluded_path ".agents/intel/a.md"
  [ "$status" -eq 0 ]
}

@test "excluded: research/foo.md (A3: aligned with tools/_doc_gate_common.py EXCLUDED_DIRS)" {
  run doc_gate_is_excluded_path "/project/research/foo.md"
  [ "$status" -eq 0 ]
}

@test "excluded: .venv/lib/notes.md (A3: aligned with EXCLUDED_DIRS)" {
  run doc_gate_is_excluded_path "/project/.venv/lib/notes.md"
  [ "$status" -eq 0 ]
}

@test "excluded: docs-graph-tests/fixture.md (A3: aligned with EXCLUDED_DIRS)" {
  run doc_gate_is_excluded_path "/project/docs-graph-tests/fixture.md"
  [ "$status" -eq 0 ]
}

# ============================================================
# NOT excluded (return 1)
# ============================================================

@test "not excluded: docs/guide.md" {
  run doc_gate_is_excluded_path "/project/docs/guide.md"
  [ "$status" -eq 1 ]
}

@test "not excluded: CLAUDE.md" {
  run doc_gate_is_excluded_path "/project/CLAUDE.md"
  [ "$status" -eq 1 ]
}

@test "not excluded: docs/foo.md (no dot-prefix, gate must not be pierced)" {
  run doc_gate_is_excluded_path "/project/docs/foo.md"
  [ "$status" -eq 1 ]
}

@test "not excluded: agents/foo.md (no dot-prefix, distinct from .agents)" {
  run doc_gate_is_excluded_path "/project/agents/foo.md"
  [ "$status" -eq 1 ]
}

# ============================================================
# doc_gate_is_excluded_basename — excluded (return 0)
# ============================================================

@test "basename excluded: MEMORY.md" {
  run doc_gate_is_excluded_basename "MEMORY.md"
  [ "$status" -eq 0 ]
}

@test "basename excluded: memory.md (lowercase, case-insensitive)" {
  run doc_gate_is_excluded_basename "memory.md"
  [ "$status" -eq 0 ]
}

@test "basename excluded: SKILL.md" {
  run doc_gate_is_excluded_basename "SKILL.md"
  [ "$status" -eq 0 ]
}

@test "basename excluded: skill.md (lowercase, case-insensitive)" {
  run doc_gate_is_excluded_basename "skill.md"
  [ "$status" -eq 0 ]
}

@test "basename excluded: CHANGELOG.md" {
  run doc_gate_is_excluded_basename "CHANGELOG.md"
  [ "$status" -eq 0 ]
}

@test "basename excluded: ChangeLog.md (mixed case, case-insensitive)" {
  run doc_gate_is_excluded_basename "ChangeLog.md"
  [ "$status" -eq 0 ]
}

@test "basename excluded: LICENSE.md" {
  run doc_gate_is_excluded_basename "LICENSE.md"
  [ "$status" -eq 0 ]
}

@test "basename excluded: License.md (mixed case, case-insensitive)" {
  run doc_gate_is_excluded_basename "License.md"
  [ "$status" -eq 0 ]
}

# ============================================================
# doc_gate_is_excluded_basename — NOT excluded (return 1): governed docs
# ============================================================

@test "basename not excluded: CLAUDE.md (governed document)" {
  run doc_gate_is_excluded_basename "CLAUDE.md"
  [ "$status" -eq 1 ]
}

@test "basename not excluded: README.md (governed document)" {
  run doc_gate_is_excluded_basename "README.md"
  [ "$status" -eq 1 ]
}

@test "basename not excluded: CONTRIBUTING.md (governed document)" {
  run doc_gate_is_excluded_basename "CONTRIBUTING.md"
  [ "$status" -eq 1 ]
}

@test "basename not excluded: foo.md (ordinary content file)" {
  run doc_gate_is_excluded_basename "foo.md"
  [ "$status" -eq 1 ]
}

# ============================================================
# doc_gate_is_excluded_basename — nocasematch restoration
# ============================================================

@test "basename check restores nocasematch state (does not leak shopt setting)" {
  shopt -u nocasematch
  doc_gate_is_excluded_basename "SKILL.md" >/dev/null
  if shopt -q nocasematch; then
    echo "nocasematch leaked ON after doc_gate_is_excluded_basename returned"
    return 1
  fi
}

# ============================================================
# Claude Code auto-memory — root-aware lexical path predicate
# ============================================================

@test "auto-memory: shared JSON matrix excludes only exact normalized components" {
  local fixture="${BATS_TEST_DIRNAME}/fixtures/auto-memory-paths.json"
  local root="/tmp/fake claude root/.claude"
  local ordinary_root="/tmp/fake claude root/ordinary"
  local path case_root expected
  local case_count=0
  local expected_count
  expected_count=$(jq 'length' "$fixture")
  [ "$expected_count" -gt 0 ]

  while IFS= read -r -d $'\036' path && \
        IFS= read -r -d $'\036' case_root && \
        IFS= read -r -d $'\036' expected; do
    path="${path//ORDINARY_ROOT/$ordinary_root}"
    path="${path//ROOT/$root}"
    case_root="${case_root//ORDINARY_ROOT/$ordinary_root}"
    case_root="${case_root//ROOT/$root}"
    run doc_gate_is_auto_memory_path "$path" "$case_root"
    [ "$status" -eq "$expected" ]
    case_count=$((case_count + 1))
  done < <(jq -j '.[] | .path, "", .root, "", (if .expected then "0" else "1" end), ""' "$fixture")

  [ "$case_count" -eq "$expected_count" ]
  printf 'auto-memory shared cases=%s\n' "$case_count" >&3
}

@test "auto-memory: excluded-path wrapper applies only new rule with explicit root" {
  local root="/tmp/fake-root/.claude"

  run doc_gate_is_excluded_path "projects/fictional/memory/entry.md" "$root"
  [ "$status" -eq 0 ]
  run doc_gate_is_excluded_path "projects/fictional/docs/guide.md" "$root"
  [ "$status" -eq 1 ]
  run doc_gate_is_excluded_path "projects/fictional/memory/entry.md"
  [ "$status" -eq 1 ]
}

@test "auto-memory: Bash 3.2 and Homebrew Bash run the same JSON matrix under nounset" {
  local fixture="${BATS_TEST_DIRNAME}/fixtures/auto-memory-paths.json"
  local runner="${BATS_TEST_DIRNAME}/auto-memory-paths.sh"
  local exclude_script="${BATS_TEST_DIRNAME}/../scripts/_doc_gate_exclude.sh"
  local expected_count
  expected_count=$(jq 'length' "$fixture")
  [ "$expected_count" -gt 0 ]

  run /bin/bash "$runner" "$fixture" "$exclude_script"
  [ "$status" -eq 0 ]
  [ "$output" = "auto-memory shared cases=$expected_count" ]

  run /opt/homebrew/bin/bash "$runner" "$fixture" "$exclude_script"
  [ "$status" -eq 0 ]
  [ "$output" = "auto-memory shared cases=$expected_count" ]
}

@test "auto-memory runner rejects an empty fixture without success output" {
  local fixture="${TEST_TEMP_DIR}/empty.json"
  local runner="${BATS_TEST_DIRNAME}/auto-memory-paths.sh"
  local exclude_script="${BATS_TEST_DIRNAME}/../scripts/_doc_gate_exclude.sh"
  printf '[]\n' > "$fixture"

  run /opt/homebrew/bin/bash -u "$runner" "$fixture" "$exclude_script"
  printf '%s\n' "$output" >&3
  [ "$status" -ne 0 ]
  case "$output" in
    *"auto-memory shared cases="*) return 1 ;;
  esac
}

@test "auto-memory runner rejects a count mutation in a temporary copy" {
  local fixture="${BATS_TEST_DIRNAME}/fixtures/auto-memory-paths.json"
  local runner="${BATS_TEST_DIRNAME}/auto-memory-paths.sh"
  local mutated_runner="${TEST_TEMP_DIR}/auto-memory-paths-mutated.sh"
  local exclude_script="${BATS_TEST_DIRNAME}/../scripts/_doc_gate_exclude.sh"
  local expected_count
  local mutation_applied=0
  expected_count=$(jq -er 'if (type == "array" and length > 0) then length else error("fixture must be a non-empty array") end' "$fixture")

  while IFS= read -r line; do
    case "$line" in
      '  case_count=$((case_count + 1))')
        printf '%s\n' '  case_count=$((case_count + 0))' >> "$mutated_runner"
        mutation_applied=1
        ;;
      *) printf '%s\n' "$line" >> "$mutated_runner" ;;
    esac
  done < "$runner"

  [ "$mutation_applied" -eq 1 ]
  run /opt/homebrew/bin/bash -u "$mutated_runner" "$fixture" "$exclude_script"
  printf '%s\n' "$output" >&3
  [ "$status" -ne 0 ]
  case "$output" in
    *"auto-memory matrix count mismatch: expected=${expected_count} actual=0"*) ;;
    *) return 1 ;;
  esac
}
