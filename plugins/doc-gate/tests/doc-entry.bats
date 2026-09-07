#!/usr/bin/env bats
# BDD tests for doc-entry.sh (PostToolUse injection layer)

setup() {
  source "${BATS_TEST_DIRNAME}/test_helper/common-setup.bash"
  common_setup
}

teardown() {
  common_teardown
}

# ============================================================
# Injection success paths
# ============================================================

@test "injection: Edit on ordinary .md produces additionalContext JSON" {
  INPUT=$(build_edit_input file_path="/project/docs/guide.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  echo "$HOOK_STDOUT" | jq . >/dev/null 2>&1
  [ "$?" -eq 0 ]
  local event_name
  event_name=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.hookEventName')
  [ "$event_name" = "PostToolUse" ]
  local context
  context=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
  [ -n "$context" ]
}

@test "injection: Write on ordinary .md produces additionalContext JSON" {
  INPUT=$(build_write_input file_path="/project/docs/guide.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  echo "$HOOK_STDOUT" | jq . >/dev/null 2>&1
  [ "$?" -eq 0 ]
  local event_name
  event_name=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.hookEventName')
  [ "$event_name" = "PostToolUse" ]
  local context
  context=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
  [ -n "$context" ]
}

@test "injection: .MD (uppercase) is recognized and injects" {
  INPUT=$(build_write_input file_path="/project/docs/README.MD")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  local context
  context=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
  [ -n "$context" ]
}

@test "injection: output is valid JSON with correct structure" {
  INPUT=$(build_edit_input file_path="/project/docs/guide.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  echo "$HOOK_STDOUT" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null
  echo "$HOOK_STDOUT" | jq -e '.hookSpecificOutput.additionalContext != null' >/dev/null
}

# ============================================================
# Payload content assertions (core architecture protection)
# ============================================================

@test "payload: contains A6 judgment criteria (noun pile, 的 string handling)" {
  INPUT=$(build_edit_input file_path="/project/docs/guide.md")
  run_entry_gate
  assert_additional_context_contains "名词群精简"
  assert_additional_context_contains '的'
}

@test "payload: contains A9 four-level mapping (应 / 宜 / 可 / 不应)" {
  INPUT=$(build_edit_input file_path="/project/docs/guide.md")
  run_entry_gate
  assert_additional_context_contains "应 / 宜 / 可 / 不应"
}

@test "payload: contains A10-A12 (English-only criteria, not stripped)" {
  INPUT=$(build_edit_input file_path="/project/docs/guide.md")
  run_entry_gate
  assert_additional_context_contains "拼写变体一致（仅英文）"
  assert_additional_context_contains "冠词完整（仅英文）"
  assert_additional_context_contains "悬垂分词（仅英文）"
}

@test "payload: contains the target file path for context binding" {
  INPUT=$(build_edit_input file_path="/project/docs/special-guide.md")
  run_entry_gate
  assert_additional_context_contains "/project/docs/special-guide.md"
}

@test "payload: contains an absolute path to writing-standards.md via the script-relative fallback" {
  # Unconditional hard assertion, no either-branch escape hatch: A1 is
  # injected unconditionally regardless of whether the path resolved, so an
  # if/else that falls back to asserting A1 is present is vacuously true on
  # both paths and immune to a broken path-resolution regression.
  #
  # CLAUDE_PLUGIN_ROOT is unset here (not exported by common_setup, and no
  # prior test in this file leaves it exported) so this exercises exactly
  # the script-relative fallback branch (`standards_self` in doc-entry.sh)
  # that run_entry_gate's plain `bash "$ENTRY_SCRIPT"` invocation actually
  # takes by default.
  unset CLAUDE_PLUGIN_ROOT

  INPUT=$(build_edit_input file_path="/project/docs/guide.md")
  run_entry_gate
  local context
  context=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext // ""')

  local abs_path
  abs_path=$(echo "$context" | grep -oE '/[^[:space:]]*writing-standards\.md' | head -1)
  [ -n "$abs_path" ]
  # Must be an actual absolute path to a file that exists on disk, not just
  # the bare filename string appearing somewhere in the payload.
  [ "${abs_path:0:1}" = "/" ]
  [ -f "$abs_path" ]
}

@test "payload: contains the four objective trigger conditions" {
  INPUT=$(build_edit_input file_path="/project/docs/guide.md")
  run_entry_gate
  assert_additional_context_contains "目标文件是 CLAUDE.md"
  assert_additional_context_contains "本次操作属于 CREATE / RENAME / ARCHIVE / RESTRUCTURE / DEDUP"
  assert_additional_context_contains "写入内容含英文叙述段落"
  assert_additional_context_contains "写入内容紧邻代码块"
}

# ============================================================
# Critical architecture regression: stateless re-injection
# ============================================================

@test "stateless: same file edited twice in same session both get injected (no deny-once)" {
  # First edit
  INPUT=$(build_edit_input file_path="/project/docs/guide.md" session_id="test-session")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  local first_output="$HOOK_STDOUT"

  # Second edit of same file, same session
  INPUT=$(build_edit_input file_path="/project/docs/guide.md" session_id="test-session")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  local second_output="$HOOK_STDOUT"

  # Both must have additionalContext (no state-based filtering)
  echo "$first_output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
  echo "$second_output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
}

# ============================================================
# Exclusion paths (should not inject)
# ============================================================

@test "excluded: .txt file produces no output" {
  INPUT=$(build_edit_input file_path="/project/docs/notes.txt")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "excluded: memory.md produces no output" {
  INPUT=$(build_edit_input file_path="/project/memory.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "excluded: SKILL.md (case-insensitive) produces no output" {
  INPUT=$(build_edit_input file_path="/project/SKILL.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "excluded: CHANGELOG.md produces no output" {
  INPUT=$(build_edit_input file_path="/project/CHANGELOG.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "excluded: node_modules/ path produces no output" {
  INPUT=$(build_edit_input file_path="/project/node_modules/pkg/README.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "excluded: /tmp/ path produces no output" {
  INPUT=$(build_edit_input file_path="/tmp/draft.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "excluded: Read tool (not Edit/Write) produces no output" {
  INPUT=$(build_raw_input "Read" session_id="test-session")
  INPUT=$(echo "$INPUT" | jq '.tool_input.file_path = "/project/docs/guide.md"')
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

# ============================================================
# Global CLAUDE.md special handling
# ============================================================

@test "global CLAUDE.md: ~/.claude/CLAUDE.md is recognized and injects with universalization segment" {
  INPUT=$(build_edit_input file_path="${HOME}/.claude/CLAUDE.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  assert_additional_context_contains "通用化原则四判据"
}

@test "global CLAUDE.md: lowercase ~/.claude/claude.md also recognized (case-insensitive APFS)" {
  INPUT=$(build_edit_input file_path="${HOME}/.claude/claude.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  assert_additional_context_contains "通用化原则四判据"
}

@test "global CLAUDE.md: HOME with trailing slash still recognized" {
  local home_with_slash="${HOME}/"
  INPUT=$(build_edit_input file_path="${home_with_slash}.claude/CLAUDE.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  assert_additional_context_contains "通用化原则四判据"
}

@test "project-level CLAUDE.md: injects but WITHOUT universalization segment" {
  INPUT=$(build_edit_input file_path="/project/CLAUDE.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  local context
  context=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext')
  # Must contain general criteria
  echo "$context" | grep -q "A1 一句一事"
  # Must NOT contain the universalization four principles
  if echo "$context" | grep -q "通用化原则四判据"; then
    echo "Project-level CLAUDE.md should not have universalization segment"
    return 1
  fi
}

# ============================================================
# Fail-open behavior
# ============================================================

@test "fail-open: DOC_ENTRY_GATE_DISABLED=1 produces no output" {
  export DOC_ENTRY_GATE_DISABLED=1
  INPUT=$(build_edit_input file_path="/project/docs/guide.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "fail-open: malformed JSON input produces no output, exit 0" {
  INPUT="{ this is not json }"
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "fail-open: empty stdin produces no output, exit 0" {
  INPUT=""
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ] || {
    echo "Exit code was $HOOK_EXIT, not 0"
    return 1
  }
  [ -z "$HOOK_STDOUT" ] || {
    echo "HOOK_STDOUT was not empty: [$HOOK_STDOUT]"
    return 1
  }
}

@test "fail-open: missing file_path produces no output" {
  INPUT=$(jq -n '{tool_name: "Edit", session_id: "test", tool_input: {}}')
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "fail-open: unresolvable writing-standards path still injects criteria without broken path" {
  # Simulate unreachable standards file by setting CLAUDE_PLUGIN_ROOT to nonexistent dir
  export CLAUDE_PLUGIN_ROOT="/nonexistent/path"
  INPUT=$(build_edit_input file_path="/project/docs/guide.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]
  # Should inject with criteria
  assert_additional_context_contains "A1 一句一事"
  # Should NOT contain a broken path like '/nonexistent/path'
  local context
  context=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext')
  if echo "$context" | grep -q "/nonexistent"; then
    echo "Broken path should not be in output"
    return 1
  fi
}

# ============================================================
# Regression: Bug 1 — additionalContext encoding
# ============================================================

@test "regression: additionalContext is raw text, not a double-encoded JSON string literal" {
  INPUT=$(build_edit_input file_path="/project/docs/guide.md")
  run_entry_gate
  [ "$HOOK_EXIT" -eq 0 ]

  # Extract additionalContext and verify it's raw text (not a quoted string)
  local context
  context=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext // ""')

  # Test 1: First character must NOT be a double quote (sign of double-encoding)
  local first_char
  first_char=$(printf '%s' "$context" | head -c 1)
  [ "$first_char" != '"' ] || {
    echo "additionalContext starts with '\"' — signs of double-encoding"
    return 1
  }

  # Test 2: Output must contain real newlines (line count > 1), not literal \n
  local line_count
  line_count=$(echo "$context" | wc -l)
  [ "$line_count" -gt 1 ] || {
    echo "additionalContext has only 1 line — expected multiple real newlines"
    return 1
  }

  # Test 3: Output must NOT contain literal two-character sequences \n
  if echo "$context" | grep -F '\n' >/dev/null 2>&1; then
    echo "additionalContext contains literal \\n sequences (sign of escape encoding)"
    return 1
  fi
}

# ============================================================
# Regression: Bug 2 — absolute path normalization
# ============================================================

@test "regression: a RELATIVE CLAUDE_PLUGIN_ROOT is normalized to an absolute standards path" {
  # This regression test verifies that when CLAUDE_PLUGIN_ROOT is set to a RELATIVE
  # path (e.g., "plugins/doc-gate"), the resolved writing-standards.md path in the
  # output is normalized to an ABSOLUTE path. The fix at lines 69-71 of doc-entry.sh
  # (cd "$standards_cand" && pwd) converts CLAUDE_PLUGIN_ROOT's relative path to absolute.
  #
  # Why this test exists:
  # - Without the fix, a relative CLAUDE_PLUGIN_ROOT would leak directly into output
  #   as "plugins/doc-gate/skills/doc-maintenance/references/writing-standards.md"
  # - With the fix, it becomes "/absolute/path/to/plugins/doc-gate/skills/.../writing-standards.md"
  # - If relative paths ever leak, subagents with unknown cwd cannot resolve them
  #
  # Why workdir is from BATS_TEST_DIRNAME, not $PWD:
  # - $PWD is the shell's cwd when calling bats, not the test file's directory
  # - From a different directory (e.g., CI, or cd /tmp && bats), $PWD would be wrong
  # - BATS_TEST_DIRNAME is always the test directory (plugins/doc-gate/tests)
  # - Computing plugin_parent as "$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)" gives
  #   the repo root, which is where "plugins/doc-gate" resolves correctly
  # - This eliminates cwd dependency and makes the test work from any location

  INPUT=$(build_edit_input file_path="/project/docs/guide.md")

  # Derive workdir from BATS_TEST_DIRNAME (test directory) instead of $PWD
  # This ensures the relative "plugins/doc-gate" path resolves correctly
  # regardless of where bats was invoked from
  local plugin_parent
  plugin_parent=$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)

  # Run with relative CLAUDE_PLUGIN_ROOT=doc-gate from its parent directory
  # This ensures the first candidate (CLAUDE_PLUGIN_ROOT) is triggered
  run_entry_gate_with_root "doc-gate" "$plugin_parent"
  [ "$HOOK_EXIT" -eq 0 ]

  local context
  context=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext // ""')

  # Hard assert 1: writing-standards.md must be present in output
  if ! echo "$context" | grep -q 'writing-standards\.md'; then
    echo "FAILED: writing-standards.md not found in context"
    echo "Context: $context"
    return 1
  fi

  # Hard assert 2: the path must be absolute (starts with /)
  local line_with_path
  line_with_path=$(echo "$context" | grep -E '在 /.*writing-standards\.md' | head -1)

  if [ -z "$line_with_path" ]; then
    echo "FAILED: no absolute path line found (pattern: 在 /.*writing-standards.md)"
    echo "Context: $context"
    return 1
  fi

  # Hard assert 3: must NOT contain any non-absolute form of writing-standards.md
  # (e.g., "plugins/..." or just "writing-standards.md" without a path prefix)
  if echo "$context" | grep -q -E '(在 [^/]|: [^/].*writing-standards\.md)'; then
    echo "FAILED: found relative or unqualified writing-standards.md path"
    local bad_lines
    bad_lines=$(echo "$context" | grep -E '(在 [^/]|: [^/].*writing-standards\.md)' || true)
    echo "Bad lines: $bad_lines"
    return 1
  fi

  return 0
}
