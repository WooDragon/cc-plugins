#!/usr/bin/env bats
# BDD tests for _doc_gate_exclude.sh (shared path-exclusion predicate)

setup() {
  source "${BATS_TEST_DIRNAME}/../scripts/_doc_gate_exclude.sh"
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
