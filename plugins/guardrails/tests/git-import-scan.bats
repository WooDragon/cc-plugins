#!/usr/bin/env bats
# BDD tests for git-import-scan.sh (PostToolUse:Bash hook)
#
# Covers: out-of-scope commands (non-git, git-without-import-keyword),
# import-triggered scanning (clone/pull/gh-repo-clone/submodule/worktree/
# am/apply), hidden-char alert emitted only on a hit (silent otherwise), the
# `" am"` tightening vs. blame/--amend, kill switch, and fail-open paths.

bats_require_minimum_version 1.5.0

setup() {
  load 'test_helper/common-setup'
  common_setup
}

teardown() {
  common_teardown
}

# ============================================================
# Out of scope → silent
# ============================================================

@test "scope: non-git/gh command (npm install) → silent exit 0" {
  write_hidden_char_file "$WORKROOT/CLAUDE.md" 200B
  INPUT=$(build_post_bash_input command="npm install" cwd="$WORKROOT")
  run_git_import_scan
  assert_silent
}

@test "scope: git status (git present, no import keyword) → silent exit 0" {
  write_hidden_char_file "$WORKROOT/CLAUDE.md" 200B
  INPUT=$(build_post_bash_input command="git status" cwd="$WORKROOT")
  run_git_import_scan
  assert_silent
}

# ============================================================
# Import-triggered scanning — hidden-char alert wording
# ============================================================

@test "trigger: git clone ... + cwd has hidden-char instruction file → alert with warning wording" {
  write_hidden_char_file "$WORKROOT/CLAUDE.md" 200B
  INPUT=$(build_post_bash_input command="git clone https://example.com/repo.git ." cwd="$WORKROOT")
  run_git_import_scan
  assert_post_tooluse_alert_contains "git-import-scan"
  assert_post_tooluse_alert_contains "隐藏 Unicode"
  assert_post_tooluse_alert_contains "U+200B"
}

@test "trigger: git pull + cwd has clean instruction file → silent (no hit, no notification)" {
  write_clean_instruction_file "$WORKROOT/CLAUDE.md"
  INPUT=$(build_post_bash_input command="git pull" cwd="$WORKROOT")
  run_git_import_scan
  assert_silent
}

@test "trigger: gh repo clone ... → also triggers (gh path)" {
  write_hidden_char_file "$WORKROOT/CLAUDE.md" 200B
  INPUT=$(build_post_bash_input command="gh repo clone someorg/somerepo" cwd="$WORKROOT")
  run_git_import_scan
  assert_post_tooluse_alert_contains "U+200B"
}

@test "trigger: git submodule update + hidden-char file → triggers alert" {
  write_hidden_char_file "$WORKROOT/CLAUDE.md" 200B
  INPUT=$(build_post_bash_input command="git submodule update --init" cwd="$WORKROOT")
  run_git_import_scan
  assert_post_tooluse_alert_contains "CLAUDE.md"
  assert_post_tooluse_alert_contains "U+200B"
}

@test "trigger: git worktree add + hidden-char file → triggers alert" {
  write_hidden_char_file "$WORKROOT/CLAUDE.md" 200B
  INPUT=$(build_post_bash_input command="git worktree add ../wt feature-x" cwd="$WORKROOT")
  run_git_import_scan
  assert_post_tooluse_alert_contains "CLAUDE.md"
  assert_post_tooluse_alert_contains "U+200B"
}

@test "trigger: git am <patch> + hidden-char file → triggers alert" {
  write_hidden_char_file "$WORKROOT/CLAUDE.md" 200B
  INPUT=$(build_post_bash_input command="git am /tmp/some.patch" cwd="$WORKROOT")
  run_git_import_scan
  assert_post_tooluse_alert_contains "CLAUDE.md"
  assert_post_tooluse_alert_contains "U+200B"
}

@test "trigger: git apply <patch> + hidden-char file → triggers alert" {
  write_hidden_char_file "$WORKROOT/CLAUDE.md" 200B
  INPUT=$(build_post_bash_input command="git apply /tmp/some.patch" cwd="$WORKROOT")
  run_git_import_scan
  assert_post_tooluse_alert_contains "CLAUDE.md"
  assert_post_tooluse_alert_contains "U+200B"
}

# ============================================================
# `am` keyword tightening — leading-space match, not bare substring
# ============================================================

@test "am-tighten: git commit --amend + hidden-char file present → silent (not import-shaped)" {
  write_hidden_char_file "$WORKROOT/CLAUDE.md" 200B
  INPUT=$(build_post_bash_input command="git commit --amend -m fix" cwd="$WORKROOT")
  run_git_import_scan
  assert_silent
}

@test "am-tighten: git blame + hidden-char file present → silent (not import-shaped)" {
  write_hidden_char_file "$WORKROOT/CLAUDE.md" 200B
  INPUT=$(build_post_bash_input command="git blame CLAUDE.md" cwd="$WORKROOT")
  run_git_import_scan
  assert_silent
}

@test "am-tighten: git am ... + hidden-char file → still triggers" {
  write_hidden_char_file "$WORKROOT/CLAUDE.md" 200B
  INPUT=$(build_post_bash_input command="git am --continue" cwd="$WORKROOT")
  run_git_import_scan
  assert_post_tooluse_alert_contains "U+200B"
}

# ============================================================
# Kill switch
# ============================================================

@test "kill switch: GIT_IMPORT_SCAN_DISABLED=1 → silent even for git clone + hidden-char file" {
  export GIT_IMPORT_SCAN_DISABLED=1
  write_hidden_char_file "$WORKROOT/CLAUDE.md" 200B
  INPUT=$(build_post_bash_input command="git clone https://example.com/repo.git ." cwd="$WORKROOT")
  run_git_import_scan
  assert_silent
}

# ============================================================
# Fail-open
# ============================================================

@test "fail-open: missing command field → silent, exit 0" {
  INPUT='{"hook_event_name":"PostToolUse","tool_name":"Bash","session_id":"s1","cwd":"'"$WORKROOT"'","tool_input":{}}'
  run_git_import_scan_raw_stdin "$INPUT"
  assert_silent
}

@test "fail-open: missing cwd field → silent, exit 0" {
  INPUT=$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:"s1", tool_input:{command:"git clone https://example.com/repo.git ."}}')
  run_git_import_scan_raw_stdin "$INPUT"
  assert_silent
}

@test "fail-open: malformed JSON on stdin → silent, exit 0" {
  run_git_import_scan_raw_stdin "not-json{{"
  assert_silent
}

@test "fail-open: empty stdin → silent, exit 0" {
  run_git_import_scan_raw_stdin ""
  assert_silent
}

@test "fail-open: cwd not a directory → silent, exit 0" {
  INPUT=$(build_post_bash_input command="git clone https://example.com/repo.git ." cwd="$WORKROOT/does-not-exist")
  run_git_import_scan
  assert_silent
}
