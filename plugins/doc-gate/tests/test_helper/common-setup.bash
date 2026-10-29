#!/bin/bash
# Test infrastructure for doc-gate hook BDD tests (v2.0.0 architecture:
# entry-side additionalContext injection + exit-side worktree consistency
# check — no PreToolUse deny, no marker files).

ENTRY_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/doc-entry.sh"
EXIT_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/doc-exit.sh"

# --- Setup / Teardown ---

common_setup() {
  TEST_TEMP_DIR=$(mktemp -d)

  # Strip escape-hatch / root-override env vars that may leak in from the
  # host shell running this bats suite (A5, #219). CLAUDE_PLUGIN_ROOT in
  # particular: when bats runs inside a live CC session, the session's own
  # environment can carry a CLAUDE_PLUGIN_ROOT pointing at the
  # marketplace-INSTALLED copy of this same plugin, not this working tree.
  # Without stripping it, doc-exit.sh's root resolution would silently
  # exercise the installed copy's tools/ instead of the PR's own edits --
  # a false green indistinguishable from "the fix works" (the exact bug A5
  # exists to prevent). run_exit_gate below pins CLAUDE_PLUGIN_ROOT back to
  # this checkout explicitly, so tests are never at the mercy of whatever
  # ambient value the host happened to have.
  unset CLAUDE_PLUGIN_ROOT
  unset DOC_ENTRY_GATE_DISABLED
  unset DOC_EXIT_GATE_DISABLED
  unset DOC_EXIT_GATE_THRESHOLD
  unset DOC_EXIT_GATE_TOP_N
  unset DOC_EXIT_GATE_BUDGET_SEC
}

common_teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

# --- Input Construction ---

# build_edit_input [file_path=X] [session_id=Y]
#
# Real PostToolUse payloads also carry a tool_response field; this hook
# never reads it, so it is deliberately not modeled here.
build_edit_input() {
  local file_path="/project/docs/guide.md"
  local session_id="test-session"

  for arg in "$@"; do
    local key="${arg%%=*}"
    local val="${arg#*=}"
    case "$key" in
      file_path)   file_path="$val" ;;
      session_id)  session_id="$val" ;;
    esac
  done

  jq -n \
    --arg fp "$file_path" \
    --arg sid "$session_id" \
    '{
      tool_name: "Edit",
      session_id: $sid,
      tool_input: { file_path: $fp, old_string: "old", new_string: "new" }
    }'
}

# build_write_input [file_path=X] [session_id=Y]
build_write_input() {
  local file_path="/project/docs/guide.md"
  local session_id="test-session"

  for arg in "$@"; do
    local key="${arg%%=*}"
    local val="${arg#*=}"
    case "$key" in
      file_path)   file_path="$val" ;;
      session_id)  session_id="$val" ;;
    esac
  done

  jq -n \
    --arg fp "$file_path" \
    --arg sid "$session_id" \
    '{
      tool_name: "Write",
      session_id: $sid,
      tool_input: { file_path: $fp, content: "content" }
    }'
}

# build_raw_input <tool_name> [session_id=Y]
build_raw_input() {
  local tool_name="$1"
  local session_id="test-session"

  for arg in "${@:2}"; do
    local key="${arg%%=*}"
    local val="${arg#*=}"
    case "$key" in
      session_id) session_id="$val" ;;
    esac
  done

  jq -n \
    --arg tn "$tool_name" \
    --arg sid "$session_id" \
    '{tool_name: $tn, session_id: $sid, tool_input: {}}'
}

# build_stop_input [stop_hook_active=X] [background_tasks=<json array literal>]
#
# background_tasks must be passed as a raw JSON array literal (via --argjson)
# so a caller can pass e.g. '[{"status":"running"}]' and get a real array,
# not a string.
build_stop_input() {
  local cwd="${REPO_DIR:-}"
  local stop_hook_active="false"
  local background_tasks="[]"

  for arg in "$@"; do
    local key="${arg%%=*}"
    local val="${arg#*=}"
    case "$key" in
      cwd)               cwd="$val" ;;
      stop_hook_active)  stop_hook_active="$val" ;;
      background_tasks)  background_tasks="$val" ;;
    esac
  done

  jq -n \
    --arg cwd "$cwd" \
    --argjson sha "$stop_hook_active" \
    --argjson bt "$background_tasks" \
    '{
      hook_event_name: "Stop",
      cwd: $cwd,
      stop_hook_active: $sha,
      background_tasks: $bt
    }'
}

# --- Run Helpers ---

# run_entry_gate — runs ENTRY_SCRIPT over stdin, capturing HOOK_STDOUT /
# HOOK_STDERR / HOOK_EXIT. Uses $INPUT if the caller set it (even to an
# empty string, to support empty/malformed-input test cases); otherwise
# defaults to build_edit_input.
run_entry_gate() {
  local input
  if [ "${INPUT+set}" = "set" ]; then
    input="$INPUT"
  else
    input="$(build_edit_input)"
  fi

  HOOK_STDOUT=""
  HOOK_STDERR=""
  HOOK_EXIT=0

  local stderr_file
  stderr_file=$(mktemp)

  HOOK_STDOUT=$(printf '%s' "$input" | bash "$ENTRY_SCRIPT" 2>"$stderr_file") || HOOK_EXIT=$?
  HOOK_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

# run_entry_gate_with_root <plugin_root> [workdir]
#
# Sets CLAUDE_PLUGIN_ROOT="$1" and, if given, cd's to "$2" before running the
# entry script — used to exercise the CLAUDE_PLUGIN_ROOT-relative resolution
# branch in doc-entry.sh. Restores cwd and unsets CLAUDE_PLUGIN_ROOT
# afterward regardless of outcome.
run_entry_gate_with_root() {
  local plugin_root="$1"
  local workdir="${2:-}"

  local orig_pwd="$PWD"
  if [ -n "$workdir" ]; then
    cd "$workdir" || return 1
  fi

  export CLAUDE_PLUGIN_ROOT="$plugin_root"
  run_entry_gate
  unset CLAUDE_PLUGIN_ROOT

  cd "$orig_pwd" || true
}

# run_exit_gate — same shape as run_entry_gate but for EXIT_SCRIPT, default
# input is build_stop_input (cwd defaults to $REPO_DIR).
#
# CLAUDE_PLUGIN_ROOT is pinned to "${BATS_TEST_DIRNAME}/.." (this checkout's
# plugins/doc-gate/, resolved from bats' own knowledge of where the test
# file lives) rather than left ambient or derived from $PWD. Using $PWD here
# would make the test suite's root resolution depend on the CALLER's current
# directory when invoking bats -- pass a different cwd to `bats` and this
# would silently degrade to a no-op against the wrong tree, exactly the
# false-green shape A5 exists to close (#219, and a repeat of a mistake this
# project has made twice before per MEMORY.md).
run_exit_gate() {
  local input
  if [ "${INPUT+set}" = "set" ]; then
    input="$INPUT"
  else
    input="$(build_stop_input)"
  fi

  HOOK_STDOUT=""
  HOOK_STDERR=""
  HOOK_EXIT=0

  local stderr_file
  stderr_file=$(mktemp)

  HOOK_STDOUT=$(printf '%s' "$input" | CLAUDE_PLUGIN_ROOT="${BATS_TEST_DIRNAME}/.." bash "$EXIT_SCRIPT" 2>"$stderr_file") || HOOK_EXIT=$?
  HOOK_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

# --- Git repo fixture (doc-exit.sh reads real `git status`) ---

# init_test_git_repo — creates a real git repo at $TEST_TEMP_DIR/repo,
# configures a throwaway identity, exports REPO_DIR. Uses `return 1` rather
# than `exit` so a single flaky `git init` only fails the one test, not the
# whole bats process.
init_test_git_repo() {
  REPO_DIR="${TEST_TEMP_DIR}/repo"
  mkdir -p "$REPO_DIR" || return 1
  git -C "$REPO_DIR" init -q || return 1
  git -C "$REPO_DIR" config user.email "doc-gate-test@example.com" || return 1
  git -C "$REPO_DIR" config user.name "doc-gate-test" || return 1
  export REPO_DIR
}

# write_md <relpath> <content> — writes content verbatim (no newline
# normalization) under $REPO_DIR/<relpath>, creating parent dirs as needed.
write_md() {
  local relpath="$1"
  local content="$2"
  local abs="${REPO_DIR}/${relpath}"
  mkdir -p "$(dirname "$abs")"
  printf '%s' "$content" > "$abs"
}

# git_commit_all <message>
git_commit_all() {
  local message="$1"
  git -C "$REPO_DIR" add -A
  git -C "$REPO_DIR" commit -q -m "$message"
}

# --- Assertion Helpers ---

# assert_additional_context_contains <substring>
assert_additional_context_contains() {
  local substring="$1"
  [ "$HOOK_EXIT" -eq 0 ] || {
    echo "Expected exit 0, got $HOOK_EXIT"
    echo "stderr: $HOOK_STDERR"
    return 1
  }
  echo "$HOOK_STDOUT" | jq . >/dev/null 2>&1 || {
    echo "stdout is not valid JSON: $HOOK_STDOUT"
    return 1
  }
  local context
  context=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
  [ -n "$context" ] || {
    echo "additionalContext is empty"
    return 1
  }
  echo "$context" | grep -qF -- "$substring" || {
    echo "additionalContext does not contain: $substring"
    echo "context: $context"
    return 1
  }
}
