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

@test "max-hits: >10 hidden chars in one file → truncation warning about emoji-cover / must read directly" {
  write_many_hidden_chars_file "$WORKROOT/CLAUDE.md" 15 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains "emoji 掩护"
  assert_session_start_alert_contains "必须直接读取"
}

@test "max-hits: custom MAX_HITS respected (truncates earlier)" {
  export MAX_HITS=3
  write_many_hidden_chars_file "$WORKROOT/CLAUDE.md" 5 200B
  INPUT=$(build_session_start_input cwd="$WORKROOT")
  run_instruction_scan
  assert_session_start_alert_contains "emoji 掩护"
  # Only lines 1-3 should be reported before truncation fires.
  [[ "$HOOK_STDOUT" == *"4:U+200B"* ]] && {
    echo "Expected truncation before line 4, but line 4 hit was reported: $HOOK_STDOUT"
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
