#!/usr/bin/env bats
# BDD tests for post-code-size.sh (PostToolUse:Edit/Write hook)
#
# Covers: stdin parsing, suffix whitelist, dual line-count thresholds,
# ast-grep structural signal (real, unmocked), graceful degradation,
# fail-open paths, kill switch, and the watermark anti-spam/re-arm state
# machine.

setup() {
  load 'test_helper/common-setup'
  common_setup
}

teardown() {
  common_teardown
}

# ============================================================
# stdin parsing
# ============================================================

@test "parse: file_path extracted from tool_input.file_path" {
  make_lines_file "$SRC_DIR/a.py" 10
  INPUT=$(build_edit_input file_path="$SRC_DIR/a.py")
  run_gate
  assert_silent
}

@test "parse: notebook_path used as fallback for NotebookEdit-shaped payload" {
  # tool_name gate only allows Edit/Write, so a NotebookEdit-shaped payload
  # (tool_name=NotebookEdit) is rejected before the notebook_path fallback is
  # ever reached — see "dead code" note in final report.
  make_lines_file "$SRC_DIR/nb_src.py" 10
  INPUT=$(build_input tool_name=NotebookEdit notebook_path="$SRC_DIR/nb_src.py" session_id=s1)
  run_gate
  assert_silent
}

@test "parse: notebook_path fallback IS reachable when tool_name is Edit" {
  # Same fallback expression, exercised through the one path that can reach
  # it: an Edit call whose tool_input has notebook_path but no file_path
  # (jq's // treats missing file_path as null, falls through).
  make_lines_file "$SRC_DIR/b.py" 501
  INPUT=$(jq -n --arg np "$SRC_DIR/b.py" '{tool_name:"Edit", session_id:"s1", cwd:"", tool_input:{notebook_path:$np}}')
  run_gate
  assert_alert_contains "超过提醒阈值 500"
}

@test "parse: empty file_path → silent (jq // does not fall through on empty string)" {
  INPUT=$(build_edit_input file_path=)
  run_gate
  assert_silent
}

@test "parse: relative file_path resolved via payload cwd" {
  make_lines_file "$SRC_DIR/rel.py" 501
  INPUT=$(build_edit_input file_path=rel.py cwd="$SRC_DIR")
  run_gate
  assert_alert_contains "超过提醒阈值 500"
}

@test "parse: nonexistent file on disk → silent (PostToolUse requires file to exist)" {
  INPUT=$(build_edit_input file_path="$SRC_DIR/does-not-exist.py")
  run_gate
  assert_silent
}

# ============================================================
# Suffix whitelist
# ============================================================

@test "whitelist: .py file → in scope" {
  make_lines_file "$SRC_DIR/f.py" 501
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py")
  run_gate
  assert_alert_contains "超过提醒阈值 500"
}

@test "whitelist: .json file → out of scope, silent" {
  make_lines_file "$SRC_DIR/f.json" 501
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.json")
  run_gate
  assert_silent
}

@test "whitelist: .md file → out of scope, silent" {
  make_lines_file "$SRC_DIR/f.md" 2001
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.md")
  run_gate
  assert_silent
}

@test "whitelist: file without extension → out of scope, silent" {
  make_lines_file "$SRC_DIR/Makefile" 2001
  INPUT=$(build_edit_input file_path="$SRC_DIR/Makefile")
  run_gate
  assert_silent
}

# ============================================================
# Dual-threshold line count
# ============================================================

@test "lines: 499 lines (< 500 soft) → silent" {
  make_lines_file "$SRC_DIR/f.py" 499
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py")
  run_gate
  assert_silent
}

@test "lines: exactly 500 lines (boundary, not > 500) → silent" {
  make_lines_file "$SRC_DIR/f.py" 500
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py")
  run_gate
  assert_silent
}

@test "lines: 501 lines (SOFT tier) → alert with soft wording" {
  make_lines_file "$SRC_DIR/f.py" 501
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py")
  run_gate
  assert_alert_contains "超过提醒阈值 500"
}

@test "lines: 1999 lines (still SOFT, below hard) → alert with soft wording, not hard" {
  make_lines_file "$SRC_DIR/f.py" 1999
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py")
  run_gate
  assert_alert_contains "超过提醒阈值 500"
  [[ "$HOOK_STDOUT" != *"PARTIAL view"* ]]
}

@test "lines: exactly 2000 lines (boundary, not > 2000) → SOFT, not HARD" {
  make_lines_file "$SRC_DIR/f.py" 2000
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py")
  run_gate
  assert_alert_contains "超过提醒阈值 500"
  [[ "$HOOK_STDOUT" != *"PARTIAL view"* ]]
}

@test "lines: 2001 lines (HARD tier) → alert with hard wording + PARTIAL view mention" {
  make_lines_file "$SRC_DIR/f.py" 2001
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py")
  run_gate
  assert_alert_contains "超过强提醒阈值 2000"
  assert_alert_contains "PARTIAL view"
}

@test "lines: custom thresholds via env vars respected" {
  export CODE_SIZE_SOFT_LINES=10
  export CODE_SIZE_HARD_LINES=20
  make_lines_file "$SRC_DIR/f.py" 15
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py")
  run_gate
  assert_alert_contains "超过提醒阈值 10"
}

# ============================================================
# Structural signal — real ast-grep, unmocked (most important: proves the
# ast-grep invocation syntax is actually correct, not silently fail-open dead)
# ============================================================

@test "structural: 201-line function in a 201-line file (under soft line threshold) → HIGH fn alert fires" {
  make_py_with_long_function "$SRC_DIR/longfn.py" 201 200
  INPUT=$(build_edit_input file_path="$SRC_DIR/longfn.py")
  run_gate
  assert_alert_contains "超长函数"
  assert_alert_contains "201 行"
  # Must NOT contain the file-size wording — this run is fn-only.
  [[ "$HOOK_STDOUT" != *"超过提醒阈值"* ]]
}

@test "structural: 150-line function (boundary, not > 150) → no fn alert" {
  # make_py_with_long_function's function span is fn_body_lines + 1 (the
  # `def` line plus the body) — fn_body=149 yields exactly a 150-line
  # function, the boundary case.
  make_py_with_long_function "$SRC_DIR/f.py" 150 149
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py")
  run_gate
  assert_silent
}

@test "structural: 151-line function (just over default 150 threshold) → fn alert fires" {
  make_py_with_long_function "$SRC_DIR/f.py" 152 151
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py")
  run_gate
  assert_alert_contains "超长函数"
}

@test "structural: custom CODE_SIZE_MAX_FN_LINES respected" {
  export CODE_SIZE_MAX_FN_LINES=20
  make_py_with_long_function "$SRC_DIR/f.py" 30 25
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py")
  run_gate
  assert_alert_contains "超长函数"
}

@test "structural: short functions only → no fn alert even if file is long" {
  # 501 lines of short (1-line-body) functions — line tier should fire,
  # fn tier should not.
  {
    i=1
    while [ "$i" -le 250 ]; do
      printf 'def f_%d():\n    return %d\n\n' "$i" "$i"
      i=$((i + 1))
    done
  } > "$SRC_DIR/manyshort.py"
  INPUT=$(build_edit_input file_path="$SRC_DIR/manyshort.py")
  run_gate
  assert_alert_contains "超过提醒阈值 500"
  [[ "$HOOK_STDOUT" != *"超长函数"* ]]
}

@test "structural: go function > 150 lines triggers HIGH" {
  {
    printf 'package main\n\nfunc longOne() int {\n'
    i=1
    while [ "$i" -le 155 ]; do printf '\tx := %d\n' "$i"; i=$((i + 1)); done
    printf '\treturn 0\n}\n'
  } > "$SRC_DIR/f.go"
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.go")
  run_gate
  assert_alert_contains "超长函数"
}

@test "structural: rust function > 150 lines triggers HIGH" {
  {
    printf 'fn long_one() -> i32 {\n'
    i=1
    while [ "$i" -le 155 ]; do printf '    let x%d = %d;\n' "$i" "$i"; i=$((i + 1)); done
    printf '    0\n}\n'
  } > "$SRC_DIR/f.rs"
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.rs")
  run_gate
  assert_alert_contains "超长函数"
}

@test "structural: typescript arrow function > 150 lines triggers HIGH" {
  {
    printf 'const longArrow = (): number => {\n'
    i=1
    while [ "$i" -le 155 ]; do printf '  const x%d = %d;\n' "$i" "$i"; i=$((i + 1)); done
    printf '  return 0;\n};\n'
  } > "$SRC_DIR/f.ts"
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.ts")
  run_gate
  assert_alert_contains "超长函数"
}

@test "structural: .sh file has no fn-length signal (not in ast-grep kind map) but line tier still applies" {
  make_lines_file "$SRC_DIR/f.sh" 501
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.sh")
  run_gate
  assert_alert_contains "超过提醒阈值 500"
  [[ "$HOOK_STDOUT" != *"超长函数"* ]]
}

@test "structural: both file-size AND fn-length alerts fire together, combined message" {
  # total lines > hard threshold AND contains an oversized function
  make_py_with_long_function "$SRC_DIR/big.py" 2001 200
  INPUT=$(build_edit_input file_path="$SRC_DIR/big.py")
  run_gate
  assert_alert_contains "超过强提醒阈值 2000"
  assert_alert_contains "超长函数"
}

# ============================================================
# Graceful degradation — ast-grep absent, jq absent
# ============================================================

@test "degrade: ast-grep absent → line-count tier still works, no crash" {
  make_lines_file "$SRC_DIR/f.py" 501
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py")
  PATH="/usr/bin:/bin" BATS_RUN_BASH="/opt/homebrew/bin/bash" HOOK_SCRIPT="$HOOK_SCRIPT" run_gate
  assert_alert_contains "超过提醒阈值 500"
}

@test "degrade: ast-grep absent → fn-length signal silently skipped (no crash, no fn alert)" {
  make_py_with_long_function "$SRC_DIR/f.py" 201 200
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py")
  PATH="/usr/bin:/bin" BATS_RUN_BASH="/opt/homebrew/bin/bash" HOOK_SCRIPT="$HOOK_SCRIPT" run_gate
  assert_silent
}

@test "degrade: jq absent → silent allow, exit 0 (jq is a hard precondition)" {
  local mock_bin="${TEST_TEMP_DIR}/nojq"
  mkdir -p "$mock_bin"
  # mktemp itself is needed by run_gate() for its stderr capture file, and
  # bats' own machinery may shell out too — carry the whole core-utils set,
  # just omit jq.
  # dirname is required by the plugin's top-level `source _gate_common.sh`
  # line (doc-gate-style shared-lib loading) — added during the guardrails
  # migration; carry it here so this fixture keeps probing "jq absent" only,
  # not "dirname absent too".
  for tool in bash cat printf mkdir find grep cut wc shasum awk mktemp rm ast-grep dirname; do
    local src
    src=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$src" "$mock_bin/$tool"
  done
  make_lines_file "$SRC_DIR/f.py" 2001
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py")
  PATH="$mock_bin" run_gate
  assert_silent
}

# ============================================================
# Fail-open — malformed input, wrong tool, missing fields
# ============================================================

@test "fail-open: empty stdin → silent, exit 0" {
  run_gate_raw_stdin ""
  assert_silent
}

@test "fail-open: corrupt JSON → silent, exit 0" {
  run_gate_raw_stdin "not-json{{"
  assert_silent
}

@test "fail-open: wrong tool_name (Bash) → silent" {
  make_lines_file "$SRC_DIR/f.py" 2001
  INPUT=$(jq -n --arg fp "$SRC_DIR/f.py" '{tool_name:"Bash", session_id:"s1", cwd:"", tool_input:{file_path:$fp}}')
  run_gate
  assert_silent
}

@test "fail-open: wrong tool_name (Read) → silent" {
  make_lines_file "$SRC_DIR/f.py" 2001
  INPUT=$(jq -n --arg fp "$SRC_DIR/f.py" '{tool_name:"Read", session_id:"s1", cwd:"", tool_input:{file_path:$fp}}')
  run_gate
  assert_silent
}

@test "fail-open: missing session_id → silent" {
  make_lines_file "$SRC_DIR/f.py" 2001
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py" session_id=)
  run_gate
  assert_silent
}

@test "fail-open: missing tool_name field entirely → silent" {
  make_lines_file "$SRC_DIR/f.py" 2001
  INPUT=$(jq -n --arg fp "$SRC_DIR/f.py" '{session_id:"s1", cwd:"", tool_input:{file_path:$fp}}')
  run_gate
  assert_silent
}

@test "fail-open: null tool_input → silent, no crash" {
  INPUT='{"tool_name":"Edit","session_id":"s1","cwd":""}'
  run_gate_raw_stdin "$INPUT"
  assert_silent
}

# ============================================================
# Kill switch
# ============================================================

@test "kill switch: CODE_SIZE_GATE_DISABLED=1 → silent even for a huge file" {
  export CODE_SIZE_GATE_DISABLED=1
  make_lines_file "$SRC_DIR/f.py" 5000
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py")
  run_gate
  assert_silent
}

@test "kill switch: CODE_SIZE_GATE_DISABLED=0 (explicit) → normal operation" {
  export CODE_SIZE_GATE_DISABLED=0
  make_lines_file "$SRC_DIR/f.py" 501
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py")
  run_gate
  assert_alert_contains "超过提醒阈值 500"
}

# ============================================================
# Watermark anti-spam
# ============================================================

@test "watermark: first HARD crossing alerts" {
  make_lines_file "$SRC_DIR/f.py" 2001
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py" session_id=wm1)
  run_gate
  assert_alert_contains "PARTIAL view"
}

@test "watermark: second run at same HARD tier → silent (no re-alert at steady state)" {
  make_lines_file "$SRC_DIR/f.py" 2001
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py" session_id=wm2)
  run_gate
  assert_alert_contains "PARTIAL view"

  make_lines_file "$SRC_DIR/f.py" 2050
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py" session_id=wm2)
  run_gate
  assert_silent
}

@test "watermark: SOFT then grows to HARD → alerts again (tier increased)" {
  make_lines_file "$SRC_DIR/f.py" 501
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py" session_id=wm3)
  run_gate
  assert_alert_contains "超过提醒阈值 500"

  make_lines_file "$SRC_DIR/f.py" 2001
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py" session_id=wm3)
  run_gate
  assert_alert_contains "PARTIAL view"
}

@test "watermark: different session_id for same file → independent state, both alert" {
  make_lines_file "$SRC_DIR/f.py" 2001

  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py" session_id=sessA)
  run_gate
  assert_alert_contains "PARTIAL view"

  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py" session_id=sessB)
  run_gate
  assert_alert_contains "PARTIAL view"
}

@test "watermark: re-arm — HARD alerts, shrinks to NONE (silent), regrows to HARD → alerts again" {
  local sess="rearm"

  make_lines_file "$SRC_DIR/f.py" 2001
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py" session_id="$sess")
  run_gate
  assert_alert_contains "PARTIAL view"

  make_lines_file "$SRC_DIR/f.py" 10
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py" session_id="$sess")
  run_gate
  assert_silent

  local marker
  marker=$(marker_path "$SRC_DIR/f.py" "$sess")
  [ -f "$marker" ]
  grep -q '^FILE_TIER=NONE$' "$marker"

  make_lines_file "$SRC_DIR/f.py" 2001
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py" session_id="$sess")
  run_gate
  assert_alert_contains "PARTIAL view"
}

@test "watermark: fn-tier re-arm independent of file-tier — shrink fn, regrow fn re-alerts" {
  local sess="fn-rearm"

  make_py_with_long_function "$SRC_DIR/f.py" 201 200
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py" session_id="$sess")
  run_gate
  assert_alert_contains "超长函数"

  # Shrink function back under threshold (file total stays under soft too)
  make_py_with_long_function "$SRC_DIR/f.py" 60 5
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py" session_id="$sess")
  run_gate
  assert_silent

  # Regrow the function past threshold again
  make_py_with_long_function "$SRC_DIR/f.py" 201 200
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py" session_id="$sess")
  run_gate
  assert_alert_contains "超长函数"
}

@test "watermark: marker file uses .code-size- prefix, distinct from doc-gate markers" {
  make_lines_file "$SRC_DIR/f.py" 2001
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py" session_id=prefix-test)
  run_gate
  local marker
  marker=$(marker_path "$SRC_DIR/f.py" "prefix-test")
  [ -f "$marker" ]
  [[ "$(basename "$marker")" == .code-size-* ]]
}

@test "watermark: GATE_DIR not writable → silent allow, no crash" {
  chmod 000 "$CODE_SIZE_GATE_DIR"
  make_lines_file "$SRC_DIR/f.py" 2001
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py")
  run_gate
  assert_exit_zero
  chmod 755 "$CODE_SIZE_GATE_DIR"
}

@test "watermark: stale marker (>120min) is cleaned up on next run" {
  make_lines_file "$SRC_DIR/f.py" 2001
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py" session_id=stale-sess)
  run_gate
  local marker
  marker=$(marker_path "$SRC_DIR/f.py" "stale-sess")
  [ -f "$marker" ]

  local old_time
  if old_time=$(date -v -130M +%Y%m%d%H%M 2>/dev/null); then
    touch -t "$old_time" "$marker"
  else
    touch -d "130 minutes ago" "$marker" 2>/dev/null || skip "cannot backdate on this platform"
  fi

  # A second, unrelated file triggers the stale sweep (find over GATE_DIR).
  make_lines_file "$SRC_DIR/other.py" 2001
  INPUT=$(build_edit_input file_path="$SRC_DIR/other.py" session_id=other-sess)
  run_gate

  [ ! -f "$marker" ]
}

@test "watermark: custom CODE_SIZE_GATE_STALE_MIN respected" {
  make_lines_file "$SRC_DIR/f.py" 2001
  INPUT=$(build_edit_input file_path="$SRC_DIR/f.py" session_id=stale-custom)
  run_gate
  local marker
  marker=$(marker_path "$SRC_DIR/f.py" "stale-custom")
  [ -f "$marker" ]

  # Backdate by 15 minutes — should survive a 120min default but not a 10min custom.
  local old_time
  if old_time=$(date -v -15M +%Y%m%d%H%M 2>/dev/null); then
    touch -t "$old_time" "$marker"
  else
    touch -d "15 minutes ago" "$marker" 2>/dev/null || skip "cannot backdate on this platform"
  fi

  export CODE_SIZE_GATE_STALE_MIN=10
  make_lines_file "$SRC_DIR/other.py" 2001
  INPUT=$(build_edit_input file_path="$SRC_DIR/other.py" session_id=other-sess2)
  run_gate

  [ ! -f "$marker" ]
}
