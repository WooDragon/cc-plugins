#!/bin/bash
# Test infrastructure for guardrails plugin BDD tests (code-size.bats +
# git-push-guard.bats). Pattern mirrors cc-plugins doc-gate test_helper
# (mock/assert/setup-teardown style).

HOOK_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/code-size.sh"
GIT_PUSH_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/git-push-guard.sh"

# --- Setup / Teardown ---

common_setup() {
  TEST_TEMP_DIR=$(mktemp -d)

  export CODE_SIZE_GATE_DIR="${TEST_TEMP_DIR}/markers"
  mkdir -p "$CODE_SIZE_GATE_DIR"

  export CODE_SIZE_GATE_DISABLED="0"
  export CODE_SIZE_GATE_STALE_MIN="120"
  unset CODE_SIZE_SOFT_LINES
  unset CODE_SIZE_HARD_LINES
  unset CODE_SIZE_MAX_FN_LINES

  # Scratch dir for generated source fixtures — cleaned by teardown.
  SRC_DIR="${TEST_TEMP_DIR}/src"
  mkdir -p "$SRC_DIR"

  unset ALLOW_PUSH_MAIN
  # Prevent a PROTECTED_BRANCHES exported in the parent env from polluting the
  # default-protection cases (git-push-guard defaults to "main master" only
  # when unset). Tests that need a custom list pass it explicitly via env.
  unset PROTECTED_BRANCHES
}

common_teardown() {
  # Restore GATE_DIR perms in case a test chmod'd it 000 and failed before restore.
  [ -n "${CODE_SIZE_GATE_DIR:-}" ] && chmod 755 "$CODE_SIZE_GATE_DIR" 2>/dev/null || true
  rm -rf "$TEST_TEMP_DIR"
}

# --- Fixture Generation ---

# make_lines_file <path> <line_count> — every line is a harmless python comment,
# so line-count tier is exercised independently of the function-length signal.
make_lines_file() {
  local path="$1"
  local count="$2"
  : > "$path"
  local i=1
  while [ "$i" -le "$count" ]; do
    printf '# line %d\n' "$i" >> "$path"
    i=$((i + 1))
  done
}

# make_py_with_long_function <path> <total_lines> <fn_body_lines>
# Produces a .py file with a leading pad of comments, then one function whose
# body has exactly <fn_body_lines> statement lines (so the function's own
# span is fn_body_lines + 1 for the `def` line), so total file line count is
# controllable independently of the function's length.
make_py_with_long_function() {
  local path="$1"
  local total_lines="$2"
  local fn_body_lines="$3"

  : > "$path"
  {
    printf 'def long_one():\n'
    local i=1
    while [ "$i" -le "$fn_body_lines" ]; do
      printf '    x = %d\n' "$i"
      i=$((i + 1))
    done
  } >> "$path"

  local fn_lines=$((fn_body_lines + 1))
  local pad=$((total_lines - fn_lines))
  local j=1
  while [ "$j" -le "$pad" ]; do
    printf '# pad %d\n' "$j" >> "$path"
    j=$((j + 1))
  done
}

# --- Input Construction (code-size) ---

# build_input tool_name=X file_path=Y [session_id=Z] [notebook_path=W] [cwd=C]
build_input() {
  local tool_name="Edit"
  local file_path=""
  local notebook_path=""
  local session_id="test-session"
  local cwd=""
  local use_notebook=0

  for arg in "$@"; do
    local key="${arg%%=*}"
    local val="${arg#*=}"
    case "$key" in
      tool_name)     tool_name="$val" ;;
      file_path)     file_path="$val" ;;
      notebook_path) notebook_path="$val"; use_notebook=1 ;;
      session_id)    session_id="$val" ;;
      cwd)           cwd="$val" ;;
    esac
  done

  if [ "$use_notebook" = "1" ]; then
    jq -n \
      --arg tn "$tool_name" --arg sid "$session_id" \
      --arg np "$notebook_path" --arg cwd "$cwd" \
      '{tool_name: $tn, session_id: $sid, cwd: $cwd, tool_input: {notebook_path: $np}}'
  else
    jq -n \
      --arg tn "$tool_name" --arg sid "$session_id" \
      --arg fp "$file_path" --arg cwd "$cwd" \
      '{tool_name: $tn, session_id: $sid, cwd: $cwd, tool_input: {file_path: $fp}}'
  fi
}

# build_edit_input file_path=X [session_id=Y] [cwd=Z] — convenience wrapper
build_edit_input() {
  build_input tool_name=Edit "$@"
}

# build_write_input file_path=X [session_id=Y] [cwd=Z]
build_write_input() {
  build_input tool_name=Write "$@"
}

# --- Run Helpers (code-size) ---

# run_gate — invokes hook with $INPUT (or default) on stdin, using $BATS_RUN_BASH if set
run_gate() {
  local input="${INPUT:-$(build_edit_input file_path=/nonexistent)}"
  local runner="${BATS_RUN_BASH:-bash}"

  HOOK_STDOUT=""
  HOOK_STDERR=""
  HOOK_EXIT=0

  local stderr_file
  stderr_file=$(mktemp)

  HOOK_STDOUT=$("$runner" "$HOOK_SCRIPT" <<< "$input" 2>"$stderr_file") || HOOK_EXIT=$?
  HOOK_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

# run_gate_raw_stdin <literal_input>
run_gate_raw_stdin() {
  local raw_input="$1"
  local runner="${BATS_RUN_BASH:-bash}"
  HOOK_STDOUT="" HOOK_STDERR="" HOOK_EXIT=0
  local stderr_file
  stderr_file=$(mktemp)
  HOOK_STDOUT=$(printf '%s' "$raw_input" | "$runner" "$HOOK_SCRIPT" 2>"$stderr_file") || HOOK_EXIT=$?
  HOOK_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

# --- Assertion Helpers (code-size) ---

# assert_silent — exit 0, empty stdout
assert_silent() {
  [ "$HOOK_EXIT" -eq 0 ] || {
    echo "Expected exit 0, got $HOOK_EXIT"
    echo "stderr: $HOOK_STDERR"
    return 1
  }
  [ -z "$HOOK_STDOUT" ] || {
    echo "Expected empty stdout, got: $HOOK_STDOUT"
    return 1
  }
}

# assert_exit_zero — exit 0 regardless of stdout content
assert_exit_zero() {
  [ "$HOOK_EXIT" -eq 0 ] || {
    echo "Expected exit 0, got $HOOK_EXIT"
    echo "stderr: $HOOK_STDERR"
    return 1
  }
}

# assert_alert_contains <pattern> — exit 0, valid JSON, additionalContext contains pattern
assert_alert_contains() {
  local pattern="$1"
  [ "$HOOK_EXIT" -eq 0 ] || {
    echo "Expected exit 0, got $HOOK_EXIT"
    echo "stderr: $HOOK_STDERR"
    return 1
  }
  echo "$HOOK_STDOUT" | jq . >/dev/null 2>&1 || {
    echo "stdout is not valid JSON: $HOOK_STDOUT"
    return 1
  }
  local event_name
  event_name=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.hookEventName')
  [ "$event_name" = "PostToolUse" ] || {
    echo "Expected hookSpecificOutput.hookEventName=PostToolUse, got: '$event_name'"
    return 1
  }
  local ctx
  ctx=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext')
  case "$ctx" in
    *"$pattern"*) ;;
    *)
      echo "Pattern '$pattern' not found in additionalContext: $ctx"
      return 1
      ;;
  esac
}

# marker_path <abs_path> <session_id> — replicate hook's marker filename derivation
marker_path() {
  local abs_path="$1"
  local session_id="$2"
  local safe_session="${session_id//\//_}"
  local hash
  hash=$(printf '%s' "$abs_path" | shasum -a 256 | awk '{print $1}')
  printf '%s/.code-size-%s_%s' "$CODE_SIZE_GATE_DIR" "$safe_session" "$hash"
}

# --- Input Construction + Run Helpers (git-push-guard) ---

# mk_payload <command> — build the PreToolUse:Bash tool_input payload
mk_payload() {
  jq -n --arg cmd "$1" '{"tool_input":{"command":$cmd}}'
}

# run_push_guard <payload> [ENV=val ...] — invokes git-push-guard.sh with
# $payload on stdin via bats' `run`, setting $status/$output/$stderr.
# Extra positional args are passed to `env` (e.g. ALLOW_PUSH_MAIN=1) —
# mirrors the original test script's `env $env_prefix bash "$HOOK"` shape.
# Respects $BATS_RUN_BASH (same convention as run_gate in code-size tests)
# so the whole suite can be re-run against a specific bash binary, e.g.
# BATS_RUN_BASH=/bin/bash for the macOS system bash 3.2 pitfall.
run_push_guard() {
  local payload="$1"
  shift
  local runner="${BATS_RUN_BASH:-bash}"
  if [ "$#" -gt 0 ]; then
    run --separate-stderr env "$@" "$runner" "$GIT_PUSH_SCRIPT" <<< "$payload"
  else
    run --separate-stderr "$runner" "$GIT_PUSH_SCRIPT" <<< "$payload"
  fi
}
