#!/usr/bin/env bats
# BDD tests for skill-gate.sh (PreToolUse:Edit/Write hook)

setup() {
  load 'test_helper/common-setup'
  common_setup
}

teardown() {
  common_teardown
}

# ============================================================
# Non-.md files — zero false positives
# ============================================================

@test "filter: Edit .ts file → silent allow" {
  INPUT=$(build_edit_input file_path=/project/src/app.ts)
  run_gate
  assert_allowed
  [ -z "$HOOK_STDOUT" ]
}

@test "filter: Write .py file → silent allow" {
  INPUT=$(build_write_input file_path=/project/script.py)
  run_gate
  assert_allowed
  [ -z "$HOOK_STDOUT" ]
}

@test "filter: Edit .json file → silent allow" {
  INPUT=$(build_edit_input file_path=/project/config.json)
  run_gate
  assert_allowed
}

@test "filter: Edit .mdx file → silent allow (not .md)" {
  INPUT=$(build_edit_input file_path=/project/page.mdx)
  run_gate
  assert_allowed
  [ -z "$HOOK_STDOUT" ]
}

@test "filter: Edit file without extension → silent allow" {
  INPUT=$(build_edit_input file_path=/project/Makefile)
  run_gate
  assert_allowed
}

# ============================================================
# Basename exclusions
# ============================================================

@test "gate: project CLAUDE.md without marker → deny" {
  INPUT=$(build_edit_input file_path=/project/CLAUDE.md)
  run_gate
  assert_deny_json
}

@test "exclude: MEMORY.md → silent allow" {
  INPUT=$(build_edit_input file_path=/project/MEMORY.md)
  run_gate
  assert_allowed
}

@test "exclude: SKILL.md → silent allow" {
  INPUT=$(build_edit_input file_path=/project/skills/foo/SKILL.md)
  run_gate
  assert_allowed
}

@test "gate: README.md without marker → deny" {
  INPUT=$(build_edit_input file_path=/project/README.md)
  run_gate
  assert_deny_json
}

@test "exclude: CHANGELOG.md → silent allow" {
  INPUT=$(build_edit_input file_path=/project/CHANGELOG.md)
  run_gate
  assert_allowed
}

@test "gate: CONTRIBUTING.md without marker → deny" {
  INPUT=$(build_edit_input file_path=/project/CONTRIBUTING.md)
  run_gate
  assert_deny_json
}

@test "exclude: LICENSE.md → silent allow" {
  INPUT=$(build_edit_input file_path=/project/LICENSE.md)
  run_gate
  assert_allowed
}

@test "gate: project claude.MD without marker → deny (case-insensitive)" {
  INPUT=$(build_edit_input file_path=/project/claude.MD)
  run_gate
  assert_deny_json
}

# ============================================================
# Path exclusions
# ============================================================

@test "path exclude: .claude/plans/x.md → silent allow" {
  INPUT=$(build_edit_input file_path=/home/user/.claude/plans/plan.md)
  run_gate
  assert_allowed
}

@test "path exclude: .claude-plugin/config.md → silent allow" {
  INPUT=$(build_edit_input file_path=/project/.claude-plugin/config.md)
  run_gate
  assert_allowed
}

@test "path exclude: node_modules/pkg/doc.md → silent allow" {
  INPUT=$(build_edit_input file_path=/project/node_modules/pkg/doc.md)
  run_gate
  assert_allowed
}

@test "path exclude: .git/hooks/readme.md → silent allow" {
  INPUT=$(build_edit_input file_path=/project/.git/hooks/readme.md)
  run_gate
  assert_allowed
}

@test "path exclude: .agents/directives/handoff.md → silent allow (team-ops progress)" {
  INPUT=$(build_edit_input file_path=/project/.agents/directives/handoff.md)
  run_gate
  assert_allowed
}

@test "path exclude: relative .agents/directives/x.md → silent allow (team-ops progress)" {
  INPUT=$(build_edit_input file_path=.agents/directives/dev-001.md)
  run_gate
  assert_allowed
}

@test "path exclude: relative path .claude/plans/x.md → silent allow" {
  INPUT=$(build_edit_input file_path=.claude/plans/x.md)
  run_gate
  assert_allowed
}

@test "path exclude: /tmp/foo.md → silent allow" {
  INPUT=$(build_edit_input file_path=/tmp/foo.md)
  run_gate
  assert_allowed
}

@test "path exclude: /tmp/claude-reviews/plan.md → silent allow" {
  INPUT=$(build_edit_input file_path=/tmp/claude-reviews/plan.md)
  run_gate
  assert_allowed
}

@test "path exclude: /var/tmp/scratch.md → silent allow" {
  INPUT=$(build_edit_input file_path=/var/tmp/scratch.md)
  run_gate
  assert_allowed
}

@test "path exclude: /private/tmp/bats.md → silent allow (macOS)" {
  INPUT=$(build_edit_input file_path=/private/tmp/bats.md)
  run_gate
  assert_allowed
}

@test "path exclude: /var/folders/xx/yz/T/tmp.md → silent allow (macOS)" {
  INPUT=$(build_edit_input file_path=/var/folders/xx/yz/T/tmp.md)
  run_gate
  assert_allowed
}

@test "path exclude: pipeline/verification/x.md → silent allow (deep-research intermediate)" {
  INPUT=$(build_edit_input file_path=/project/pipeline/verification/x.md)
  run_gate
  assert_allowed
  [ -z "$HOOK_STDOUT" ]
}

@test "path exclude: intake/requirements/research-goal.md → silent allow (deep-research G0)" {
  INPUT=$(build_edit_input file_path=/project/intake/requirements/research-goal.md)
  run_gate
  assert_allowed
  [ -z "$HOOK_STDOUT" ]
}

@test "gate: deliverables/final/report.md without marker → deny (final deliverable, governed)" {
  INPUT=$(build_edit_input file_path=/project/deliverables/final/report.md)
  run_gate
  assert_deny_json
}

@test "path exclude: logs/run.md → silent allow (drift regression)" {
  INPUT=$(build_edit_input file_path=/project/logs/run.md)
  run_gate
  assert_allowed
}

# ============================================================
# Gate enforcement — no marker
# ============================================================

@test "gate: Edit docs/guide.md without marker → deny" {
  INPUT=$(build_edit_input file_path=/project/docs/guide.md)
  run_gate
  assert_deny_json
}

@test "gate: Write playbook/runbook.md without marker → deny" {
  INPUT=$(build_write_input file_path=/project/playbook/runbook.md)
  run_gate
  assert_deny_json
}

@test "gate: deny message contains actionable instruction" {
  INPUT=$(build_edit_input file_path=/project/docs/guide.md)
  run_gate
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"doc-maintenance"* ]]
  [[ "$reason" == *"guide.md"* ]]
}

@test "gate: deny message suggests SKILL_GATE_DISABLED" {
  INPUT=$(build_edit_input file_path=/project/docs/guide.md)
  run_gate
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"SKILL_GATE_DISABLED"* ]]
}

# ============================================================
# Gate pass — marker present
# ============================================================

@test "gate: Edit docs/guide.md with marker → allow" {
  create_gate_marker
  INPUT=$(build_edit_input file_path=/project/docs/guide.md)
  run_gate
  assert_allowed
}

@test "gate: Write playbook/runbook.md with marker → allow" {
  create_gate_marker
  INPUT=$(build_write_input file_path=/project/playbook/runbook.md)
  run_gate
  assert_allowed
}

@test "gate: marker from different session → deny" {
  create_gate_marker "doc-maintenance" "other-session"
  INPUT=$(build_edit_input file_path=/project/docs/guide.md)
  run_gate
  assert_deny_json
}

# ============================================================
# Fail-open
# ============================================================

@test "fail-open: DISABLED=1 → silent allow" {
  export SKILL_GATE_DISABLED=1
  INPUT=$(build_edit_input file_path=/project/docs/guide.md)
  run_gate
  assert_allowed
  [ -z "$HOOK_STDOUT" ]
}

@test "fail-open: jq missing → silent allow" {
  local mock_bin="${TEST_TEMP_DIR}/nojq"
  mkdir -p "$mock_bin"
  PATH="$mock_bin:/usr/bin:/bin" INPUT=$(build_edit_input file_path=/project/docs/guide.md) run_gate
  [ "$HOOK_EXIT" -eq 0 ]
}

@test "fail-open: empty stdin → silent allow" {
  run_gate_raw_stdin ""
  assert_allowed
}

@test "fail-open: corrupt JSON → silent allow" {
  run_gate_raw_stdin "not-json{{"
  assert_allowed
}

@test "fail-open: missing session_id → silent allow" {
  INPUT=$(build_edit_input session_id= file_path=/project/docs/guide.md)
  run_gate
  assert_allowed
}

@test "fail-open: missing file_path → silent allow" {
  INPUT=$(build_edit_input file_path=)
  run_gate
  assert_allowed
}

@test "fail-open: wrong tool_name → silent allow" {
  INPUT=$(build_raw_input "Agent")
  run_gate
  assert_allowed
}

@test "fail-open: GATE_DIR not writable → silent allow" {
  chmod 000 "$SKILL_GATE_DIR"
  INPUT=$(build_edit_input file_path=/project/docs/guide.md)
  run_gate
  assert_allowed
  chmod 755 "$SKILL_GATE_DIR"
}

# ============================================================
# Stale cleanup
# ============================================================

@test "stale: marker >120min cleaned" {
  create_gate_marker "doc-maintenance" "old-session"
  local marker="$SKILL_GATE_DIR/.skill-gate-old-session-doc-maintenance"
  # Backdate by 130 minutes (cross-platform)
  local old_time
  if old_time=$(date -v -130M +%Y%m%d%H%M 2>/dev/null); then
    touch -t "$old_time" "$marker"
  else
    touch -d "130 minutes ago" "$marker" 2>/dev/null || skip "cannot backdate on this platform"
  fi

  INPUT=$(build_edit_input file_path=/project/docs/guide.md)
  run_gate

  [ ! -f "$marker" ]
}

# ============================================================
# Case sensitivity
# ============================================================

@test "case: Edit DOCS.MD → deny (no marker)" {
  INPUT=$(build_edit_input file_path=/project/DOCS.MD)
  run_gate
  assert_deny_json
}

@test "case: Edit docs/GUIDE.Md → deny (no marker)" {
  INPUT=$(build_edit_input file_path=/project/docs/GUIDE.Md)
  run_gate
  assert_deny_json
}

# ============================================================
# Logging
# ============================================================

@test "logging: deny logged" {
  INPUT=$(build_edit_input file_path=/project/docs/guide.md)
  run_gate
  assert_log_contains "decision=deny"
  assert_log_contains "skill-not-invoked"
}

@test "logging: allow with marker logged" {
  create_gate_marker
  INPUT=$(build_edit_input file_path=/project/docs/guide.md)
  run_gate
  assert_log_contains "decision=allow"
  assert_log_contains "marker-found"
}

# ============================================================
# End-to-end flow
# ============================================================

@test "e2e: marker script → gate pass" {
  # Step 1: invoke skill (via marker script)
  INPUT=$(build_skill_input)
  run_marker
  [ -f "$SKILL_GATE_DIR/.skill-gate-test-session-doc-maintenance" ]

  # Step 2: edit should now be allowed
  INPUT=$(build_edit_input file_path=/project/docs/guide.md)
  run_gate
  assert_allowed
}

@test "e2e: namespaced skill → gate pass" {
  # Step 1: invoke skill with plugin namespace prefix
  INPUT=$(build_skill_input skill=doc-gate:doc-maintenance)
  run_marker
  [ -f "$SKILL_GATE_DIR/.skill-gate-test-session-doc-maintenance" ]

  # Step 2: edit should now be allowed
  INPUT=$(build_edit_input file_path=/project/docs/guide.md)
  run_gate
  assert_allowed
}

# ============================================================
# CLAUDE.md governance — project & global tiers
# ============================================================

@test "gate: project CLAUDE.md with marker → allow" {
  create_gate_marker
  INPUT=$(build_edit_input file_path=/project/CLAUDE.md)
  run_gate
  assert_allowed
}

@test "gate: global ~/.claude/CLAUDE.md without marker → deny (global branch)" {
  # mock HOME lives under mktemp's tmpdir (/var/folders on macOS, /tmp on Linux),
  # so this also asserts the global identity bypasses the TEMP-DIR exclusion,
  # not merely the */.claude/* path exclusion.
  export HOME="${TEST_TEMP_DIR}/mock_home"
  INPUT=$(build_edit_input file_path="${HOME}/.claude/CLAUDE.md")
  run_gate
  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"全局"* ]]
  assert_log_contains "skill-not-invoked-global"
}

@test "gate: global lowercase ~/.claude/claude.md without marker → deny (case-insensitive global)" {
  export HOME="${TEST_TEMP_DIR}/mock_home"
  INPUT=$(build_edit_input file_path="${HOME}/.claude/claude.md")
  run_gate
  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"全局"* ]]
  assert_log_contains "skill-not-invoked-global"
}

@test "gate: global ~/.claude/CLAUDE.md with marker → allow" {
  export HOME="${TEST_TEMP_DIR}/mock_home"
  create_gate_marker
  INPUT=$(build_edit_input file_path="${HOME}/.claude/CLAUDE.md")
  run_gate
  assert_allowed
}

@test "gate: global CLAUDE.md with trailing-slash HOME → deny (HOME normalized)" {
  # HOME=/x/ would otherwise yield /x//.claude/... and miss the global match,
  # silently letting it slip into */.claude/* — regression guard for the %/ strip.
  export HOME="${TEST_TEMP_DIR}/mock_home/"
  INPUT=$(build_edit_input file_path="${TEST_TEMP_DIR}/mock_home/.claude/CLAUDE.md")
  run_gate
  assert_deny_json
  assert_log_contains "skill-not-invoked-global"
}

@test "gate: global CLAUDE.md with glob char in HOME → deny (quoted pattern is literal)" {
  # The quoted case pattern matches $HOME_DIR LITERALLY, so a glob metachar in
  # HOME (here '[') must NOT alter matching. Pins the quoting semantics — guards
  # against a refactor to an unquoted pattern that would break global detection.
  export HOME="${TEST_TEMP_DIR}/ho[me"
  INPUT=$(build_edit_input file_path="${TEST_TEMP_DIR}/ho[me/.claude/CLAUDE.md")
  run_gate
  assert_deny_json
  assert_log_contains "skill-not-invoked-global"
}

@test "exclude: non-global ~/.claude/plugins/cache/x/CLAUDE.md → silent allow" {
  export HOME="${TEST_TEMP_DIR}/mock_home"
  INPUT=$(build_edit_input file_path="${HOME}/.claude/plugins/cache/x/CLAUDE.md")
  run_gate
  assert_allowed
}
