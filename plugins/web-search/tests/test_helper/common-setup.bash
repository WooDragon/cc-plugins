# Explicit host utilities only: capability commands must be installed per test.
setup_sandbox() {
  local tool resolved python_candidate banner target_bash
  ORIGINAL_PATH="$PATH"
  target_bash="${WEB_SEARCH_TEST_BASH:-$BASH}"
  REAL_PYTHON=""
  for python_candidate in python3 python; do
    resolved="$(command -v "$python_candidate" 2>/dev/null)" || continue
    banner="$("$resolved" --version 2>&1)" || continue
    case "$banner" in "Python 3"*) REAL_PYTHON="$resolved"; break ;; esac
  done
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/web-search-test.XXXXXX")"
  mkdir -p "$SANDBOX/bin"
  for tool in env cat chmod cp ln rm mkdir rmdir wc tr grep head cut uname sleep dirname basename sort touch mktemp date; do
    resolved="$(command -v "$tool")" || return 1
    case "$resolved" in
      *.exe) ln -s "$resolved" "$SANDBOX/bin/$tool.exe" ;;
      *) ln -s "$resolved" "$SANDBOX/bin/$tool" ;;
    esac
  done
  ln -s "$target_bash" "$SANDBOX/bin/bash"
  unset BASH_ENV ENV AGY_BIN GROK_BIN TIMEOUT_BIN PYTHON_BIN CURL_BIN CURL_CMD
  unset WEB_SEARCH_BUILTIN_UNAVAILABLE WEB_SEARCH_TIMEOUT WEB_SEARCH_RETRY_SLEEP
  unset FAKE_AGY_MODE FAKE_AGY_FAILS FAKE_AGY_COUNTER FAKE_GROK_MODE FAKE_GROK_ARGS_LOG
  unset FAKE_CURL_CODE FAKE_CURL_BODY FAKE_CURL_SEQUENCE FAKE_CURL_COUNTER FAKE_CURL_ARGS_LOG
  export PATH="$SANDBOX/bin" HOME="$SANDBOX"
}
