#!/usr/bin/env bats
# BDD tests for instruction-scan.sh (SessionStart hook)
#
# Covers: clean-file silence, hidden-char detection (zero-width, bidi
# control), legitimate-BOM handling (stripped vs. payload-right-after-BOM),
# MAX_HITS truncation + anti-desensitization warning, kill switch,
# fail-open paths, recursive filename-whitelist scanning, and directory
# exclusion (.git / node_modules).

bats_require_minimum_version 1.5.0

setup() {
  load 'test_helper/common-setup'
  common_setup
}

teardown() {
  common_teardown
}

# ============================================================
# Clean file → silent
# ============================================================

@test "clean: CLAUDE.md with no hidden chars → silent exit 0" {
  write_clean_instruction_file "$WORKROOT/CLAUDE.md"
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_silent
}

# ============================================================
# Hidden-char detection
# ============================================================

@test "detect: zero-width space U+200B in CLAUDE.md → additionalContext hit" {
  write_hidden_char_file "$WORKROOT/CLAUDE.md" 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains "CLAUDE.md"
  assert_session_start_alert_contains "U+200B"
  assert_session_start_alert_contains "1:U+200B"
}

@test "detect: bidi control U+202E in CLAUDE.md → hit" {
  write_hidden_char_file "$WORKROOT/CLAUDE.md" 202E
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains "U+202E"
}

@test "detect: tag character U+E0001 in CLAUDE.md → hit" {
  write_hidden_char_file "$WORKROOT/CLAUDE.md" E0001
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains "U+E0001"
}

# ============================================================
# Legitimate BOM handling
# ============================================================

@test "bom: legitimate leading U+FEFF on line 1, otherwise clean → NOT flagged" {
  write_bom_prefixed_clean_file "$WORKROOT/CLAUDE.md"
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_silent
}

@test "bom: leading U+FEFF immediately followed by hidden payload on same line → payload still caught" {
  write_bom_then_payload_file "$WORKROOT/CLAUDE.md" 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains "U+200B"
}

# ============================================================
# MAX_HITS truncation + anti-desensitization warning
# ============================================================

@test "max-hits: >10 hidden chars in one file → truncation warning about too many hidden chars / must read in full" {
  write_many_hidden_chars_file "$WORKROOT/CLAUDE.md" 15 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains "隐藏 Unicode 字符过多"
  assert_session_start_alert_contains "必须直接通读"
}

@test "max-hits: custom MAX_HITS respected (truncates earlier)" {
  export MAX_HITS=3
  write_many_hidden_chars_file "$WORKROOT/CLAUDE.md" 5 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains "隐藏 Unicode 字符过多"
  # Only lines 1-3 should be reported before truncation fires.
  [[ "$HOOK_STDOUT" == *"4:U+200B"* ]] && {
    echo "Expected truncation before line 4, but line 4 hit was reported: $HOOK_STDOUT"
    return 1
  }
  return 0
}

@test "max-hits: MAX_HITS=0 truncates at the first hit (explicit zero is respected, not treated as unset)" {
  export MAX_HITS=0
  write_many_hidden_chars_file "$WORKROOT/CLAUDE.md" 3 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains "1:U+200B"
  assert_session_start_alert_contains "隐藏 Unicode 字符过多"
  [[ "$HOOK_STDOUT" == *"2:U+200B"* ]] && {
    echo "Expected truncation after line 1 (MAX_HITS=0), but line 2 hit was reported: $HOOK_STDOUT"
    return 1
  }
  return 0
}

# ============================================================
# Kill switch
# ============================================================

@test "kill switch: INSTRUCTION_SCAN_DISABLED=1 → silent even with hidden chars present" {
  export INSTRUCTION_SCAN_DISABLED=1
  write_hidden_char_file "$WORKROOT/CLAUDE.md" 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_silent
}

# ============================================================
# Fail-open
# ============================================================

@test "fail-open: missing cwd field → silent, exit 0" {
  INPUT='{"hook_event_name":"SessionStart","session_id":"s1"}'
  run_instruction_scan_raw_stdin "$INPUT"
  assert_silent
}

@test "fail-open: cwd is not a directory → silent, exit 0" {
  write_hidden_char_file "$WORKROOT/CLAUDE.md" 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT/CLAUDE.md")
  run_instruction_scan
  assert_silent
}

@test "fail-open: malformed JSON on stdin → silent, exit 0" {
  run_instruction_scan_raw_stdin "not-json{{"
  assert_silent
}

@test "fail-open: empty stdin → silent, exit 0" {
  run_instruction_scan_raw_stdin ""
  assert_silent
}

# ============================================================
# Recursive scanning + filename whitelist + directory exclusion
# ============================================================

@test "recurse: .cursorrules in a subdirectory is scanned and hit reported" {
  mkdir -p "$WORKROOT/subdir"
  write_hidden_char_file "$WORKROOT/subdir/.cursorrules" 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains "subdir/.cursorrules"
  assert_session_start_alert_contains "U+200B"
}

@test "exclude: hidden-char file under node_modules is not scanned (excluded dir)" {
  mkdir -p "$WORKROOT/node_modules/somepkg"
  write_hidden_char_file "$WORKROOT/node_modules/somepkg/CLAUDE.md" 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_silent
}

@test "exclude: hidden-char file under .git is not scanned (excluded dir)" {
  mkdir -p "$WORKROOT/.git/hooks"
  write_hidden_char_file "$WORKROOT/.git/hooks/CLAUDE.md" 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_silent
}

# ============================================================
# New whitelist entries (v1.3.0)
# ============================================================

@test "whitelist: CLAUDE.local.md with hidden char → hit" {
  write_hidden_char_file "$WORKROOT/CLAUDE.local.md" 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains "CLAUDE.local.md"
}

@test "whitelist: AGENT.md with hidden char → hit" {
  write_hidden_char_file "$WORKROOT/AGENT.md" 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains "AGENT.md"
}

@test "whitelist: .continuerules with hidden char → hit" {
  write_hidden_char_file "$WORKROOT/.continuerules" 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains ".continuerules"
}

@test "whitelist: .roorules with hidden char → hit" {
  write_hidden_char_file "$WORKROOT/.roorules" 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains ".roorules"
}

@test "whitelist: .roorules-code with hidden char → hit" {
  write_hidden_char_file "$WORKROOT/.roorules-code" 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains ".roorules-code"
}

@test "whitelist: .roo/rules/x.md with hidden char → hit" {
  mkdir -p "$WORKROOT/.roo/rules"
  write_hidden_char_file "$WORKROOT/.roo/rules/x.md" 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains ".roo/rules/x.md"
}

@test "whitelist: .roo/rules-code/x.md with hidden char → hit" {
  mkdir -p "$WORKROOT/.roo/rules-code"
  write_hidden_char_file "$WORKROOT/.roo/rules-code/x.md" 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains ".roo/rules-code/x.md"
}

@test "whitelist: .clinerules/x.md with hidden char → hit" {
  mkdir -p "$WORKROOT/.clinerules"
  write_hidden_char_file "$WORKROOT/.clinerules/x.md" 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains ".clinerules/x.md"
}

@test "whitelist: .clinerules/y.txt with hidden char → hit" {
  mkdir -p "$WORKROOT/.clinerules"
  write_hidden_char_file "$WORKROOT/.clinerules/y.txt" 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains ".clinerules/y.txt"
}

@test "whitelist: .windsurf/rules/w.md with hidden char → hit" {
  mkdir -p "$WORKROOT/.windsurf/rules"
  write_hidden_char_file "$WORKROOT/.windsurf/rules/w.md" 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains ".windsurf/rules/w.md"
}

@test "whitelist: .devin/rules/d.md with hidden char → hit" {
  mkdir -p "$WORKROOT/.devin/rules"
  write_hidden_char_file "$WORKROOT/.devin/rules/d.md" 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains ".devin/rules/d.md"
}

@test "whitelist: .continue/rules/c.md with hidden char → hit" {
  mkdir -p "$WORKROOT/.continue/rules"
  write_hidden_char_file "$WORKROOT/.continue/rules/c.md" 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains ".continue/rules/c.md"
}

@test "whitelist: .github/instructions/api.instructions.md with hidden char → hit" {
  mkdir -p "$WORKROOT/.github/instructions"
  write_hidden_char_file "$WORKROOT/.github/instructions/api.instructions.md" 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains ".github/instructions/api.instructions.md"
}

# ============================================================
# Symlink boundary validation (v1.3.0)
# ============================================================

@test "symlink: CLAUDE.md -> in-tree target with hidden char → hit" {
  mkdir -p "$WORKROOT/sub"
  write_hidden_char_file "$WORKROOT/sub/actual.md" 200B
  ln -s "$WORKROOT/sub/actual.md" "$WORKROOT/CLAUDE.md"
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains "CLAUDE.md"
}

@test "symlink: CLAUDE.md -> out-of-tree target (absolute) → escape alert, content NOT scanned" {
  write_hidden_char_file "$TEST_TEMP_DIR/outside.md" 200B
  ln -s "$TEST_TEMP_DIR/outside.md" "$WORKROOT/CLAUDE.md"
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  # Escape is surfaced (no longer silent) but the out-of-tree content is not
  # opened, so no hidden-char hit ("U+200B") should leak into the report.
  assert_session_start_alert_contains "工作区外"
  assert_session_start_alert_not_contains "U+200B"
}

@test "symlink: CLAUDE.md -> out-of-tree target (relative ../) → escape alert" {
  # monorepo-shaped: app/CLAUDE.md -> ../shared/CLAUDE.md, target outside cwd.
  mkdir -p "$WORKROOT/app" "$TEST_TEMP_DIR/shared"
  write_hidden_char_file "$TEST_TEMP_DIR/shared/CLAUDE.md" 200B
  ln -s ../../shared/CLAUDE.md "$WORKROOT/app/CLAUDE.md"
  INPUT=$(build_session_start_input cwd="$WORKROOT/app")
  run_instruction_scan
  assert_session_start_alert_contains "工作区外"
  assert_session_start_alert_not_contains "U+200B"
}

@test "symlink: dangling CLAUDE.md -> nonexistent target → silent" {
  ln -s "$WORKROOT/nonexistent.md" "$WORKROOT/CLAUDE.md"
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_silent
}
