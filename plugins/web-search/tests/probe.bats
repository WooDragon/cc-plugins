#!/usr/bin/env bats

# Contract tests for skills/web-search/scripts/probe.sh.
#
# Every test runs against a sandbox PATH so a real agy/grok/python3 on the host
# cannot leak into the assertions. The sandbox holds only the fixtures a test
# installs, plus a directory of real utilities the probe itself needs.

PROBE="$BATS_TEST_DIRNAME/../skills/web-search/scripts/probe.sh"
FIXTURES="$BATS_TEST_DIRNAME/fixtures"
EXPECTED_KEYS="PLATFORM AGY_BIN GROK_BIN TIMEOUT_BIN PYTHON_BIN CURL_BIN CURL_DATA_URLENCODE DDG_READY"

load test_helper/common-setup

setup() {
  setup_sandbox
}

teardown() {
  export PATH="$ORIGINAL_PATH"
  hash -r
  rm -rf "$SANDBOX"
}

install_fixture() {
  # install_fixture <fixture-name> <command-name>
  cp "$FIXTURES/$1" "$SANDBOX/bin/$2"
  chmod +x "$SANDBOX/bin/$2"
}

matrix_value() {
  # matrix_value <KEY> reads the capability matrix from stdin.
  local key="$1"
  grep "^${key}=" | head -1 | cut -d= -f2-
}

@test "with only a fake agy installed, AGY_BIN resolves and GROK_BIN stays empty" {
  install_fixture fake-agy agy

  run bash "$PROBE"
  [ "$status" -eq 0 ]

  agy="$(printf '%s\n' "$output" | matrix_value AGY_BIN)"
  grok="$(printf '%s\n' "$output" | matrix_value GROK_BIN)"
  [ -n "$agy" ]
  [ -z "$grok" ]
}

@test "a timeout whose --version lacks a coreutils banner is not accepted as POSIX timeout" {
  install_fixture fake-timeout-windows timeout

  run bash "$PROBE"
  [ "$status" -eq 0 ]

  timeout_bin="$(printf '%s\n' "$output" | matrix_value TIMEOUT_BIN)"
  [ -z "$timeout_bin" ]
}

@test "gtimeout is accepted when the timeout name is taken by a non-coreutils binary" {
  install_fixture fake-timeout-windows timeout
  cat >"$SANDBOX/bin/gtimeout" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && printf 'timeout (GNU coreutils) 9.4\n'
exit 0
EOF
  chmod +x "$SANDBOX/bin/gtimeout"

  run bash "$PROBE"
  [ "$status" -eq 0 ]

  timeout_bin="$(printf '%s\n' "$output" | matrix_value TIMEOUT_BIN)"
  [[ "$timeout_bin" == *gtimeout ]]
}

@test "a python stub that exits 0 with no output is not accepted" {
  install_fixture fake-python-stub python3
  install_fixture fake-python-stub python

  run bash "$PROBE"
  [ "$status" -eq 0 ]

  python_bin="$(printf '%s\n' "$output" | matrix_value PYTHON_BIN)"
  [ -z "$python_bin" ]
}

@test "a python that reports Python 3 is accepted even behind the python alias" {
  cat >"$SANDBOX/bin/python" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && printf 'Python 3.13.0\n'
exit 0
EOF
  chmod +x "$SANDBOX/bin/python"

  run bash "$PROBE"
  [ "$status" -eq 0 ]

  python_bin="$(printf '%s\n' "$output" | matrix_value PYTHON_BIN)"
  [[ "$python_bin" == *python ]]
}

@test "a python 2 banner is rejected" {
  cat >"$SANDBOX/bin/python3" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && printf 'Python 2.7.18\n'
exit 0
EOF
  chmod +x "$SANDBOX/bin/python3"

  run bash "$PROBE"
  [ "$status" -eq 0 ]

  python_bin="$(printf '%s\n' "$output" | matrix_value PYTHON_BIN)"
  [ -z "$python_bin" ]
}

@test "DDG_READY is 0 when curl is absent and 1 when curl reports urlencode support" {
  run bash "$PROBE"
  curl_bin="$(printf '%s\n' "$output" | matrix_value CURL_BIN)"
  ddg_ready="$(printf '%s\n' "$output" | matrix_value DDG_READY)"
  [ -z "$curl_bin" ]
  [ "$ddg_ready" = "0" ]

  install_fixture fake-curl curl
  run bash "$PROBE"
  curl_bin="$(printf '%s\n' "$output" | matrix_value CURL_BIN)"
  urlencode="$(printf '%s\n' "$output" | matrix_value CURL_DATA_URLENCODE)"
  [ -n "$curl_bin" ]
  [ "$urlencode" = "1" ]
}

@test "DDG_READY stays 0 when curl is present but python is not" {
  install_fixture fake-curl curl

  run bash "$PROBE"
  [ "$status" -eq 0 ]

  curl_bin="$(printf '%s\n' "$output" | matrix_value CURL_BIN)"
  python_bin="$(printf '%s\n' "$output" | matrix_value PYTHON_BIN)"
  ddg_ready="$(printf '%s\n' "$output" | matrix_value DDG_READY)"
  [ -n "$curl_bin" ]
  [ -z "$python_bin" ]
  [ "$ddg_ready" = "0" ]
}

@test "output always carries all eight keys and exits 0, even with an empty sandbox" {
  run bash "$PROBE"
  [ "$status" -eq 0 ]

  key=""
  for key in $EXPECTED_KEYS; do
    printf '%s\n' "$output" | grep -q "^${key}=" || {
      printf 'missing key: %s\n' "$key" >&2
      return 1
    }
  done

  line_count="$(printf '%s\n' "$output" | wc -l)"
  [ "$line_count" -eq 8 ]
}

@test "MINGW and MSYS kernels map to Windows without host capability leaks" {
  rm "$SANDBOX/bin/uname"
  for kernel in MINGW64_NT-10.0 MSYS_NT-10.0; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$kernel" >"$SANDBOX/bin/uname"
    chmod +x "$SANDBOX/bin/uname"
    run bash "$PROBE"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | matrix_value PLATFORM)" = windows ]
    [ "$(printf '%s\n' "$output" | matrix_value DDG_READY)" = 0 ]
  done
}

@test "sandbox bash is the selected target interpreter" {
  run bash -c 'printf "%s\n" "$BASH_VERSION"'
  [ "$status" -eq 0 ]
  expected="$("${WEB_SEARCH_TEST_BASH:-$BASH}" -c 'printf "%s\n" "$BASH_VERSION"')"
  [ "$output" = "$expected" ]
}

@test "PLATFORM reports a known value" {
  run bash "$PROBE"
  [ "$status" -eq 0 ]

  platform="$(printf '%s\n' "$output" | matrix_value PLATFORM)"
  case "$platform" in
    macos|linux|windows|unknown) ;;
    *) printf 'unexpected platform: %s\n' "$platform" >&2; return 1 ;;
  esac
}

@test "sourcing the probe defines every function and prints nothing" {
  run bash -c '. "$1" >"$2"' _ "$PROBE" "$SANDBOX/source.out"
  [ "$status" -eq 0 ]

  sourced="$(cat "$SANDBOX/source.out")"
  [ -z "$sourced" ]

  run bash -c '. "$1"; declare -F probe_bin probe_timeout probe_python probe_curl_urlencode probe_platform probe_main' _ "$PROBE"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 6 ]
}
