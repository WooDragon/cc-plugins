#!/usr/bin/env bash
# web-search capability probe.
#
# Executed directly: prints a KEY=VALUE capability matrix.
# Sourced: defines the probe_* functions and prints nothing.
# Always exits 0 - it is a probe, not a judge. Callers decide what to do with
# an empty value.

probe_bin() {
  # Resolve a command name to an executable path; prints nothing when absent.
  # `command -v` alone is not enough: it accepts a PATH entry that is not a
  # runnable file, so confirm with -x.
  local name="${1:-}" path=""
  [ -n "$name" ] || return 0
  path="$(command -v "$name" 2>/dev/null)" || return 0
  [ -n "$path" ] || return 0
  [ -x "$path" ] || return 0
  printf '%s\n' "$path"
  return 0
}

probe_timeout() {
  # POSIX-style timeout only. Windows ships timeout.exe under the same name
  # with unrelated semantics (seconds argument, wait-for-keypress), so a name
  # match proves nothing: require a coreutils --version banner. gtimeout is
  # the macOS coreutils install name, checked second.
  local candidate path
  for candidate in timeout gtimeout; do
    path="$(probe_bin "$candidate")"
    [ -n "$path" ] || continue
    "$path" --version 2>/dev/null </dev/null | grep -q 'coreutils' || continue
    printf '%s\n' "$path"
    return 0
  done
  return 0
}

probe_python() {
  # A Python 3 interpreter that actually runs. Windows ships a WindowsApps
  # alias that resolves on PATH, prints nothing, and still exits 0 (or with a
  # store-redirect code); exit status alone would accept that broken stub, so
  # the banner must start with "Python 3".
  local candidate path banner
  for candidate in python3 python; do
    path="$(probe_bin "$candidate")"
    [ -n "$path" ] || continue
    banner="$("$path" --version 2>&1 </dev/null)"
    case "$banner" in
      "Python 3"*) printf '%s\n' "$path"; return 0 ;;
    esac
  done
  return 0
}

probe_curl_urlencode() {
  # Prints 1 when the curl build exposes --data-urlencode, else 0.
  # Newer curl needs `--help all` to list every option; older curl rejects
  # that flag, so fall back to the plain help listing.
  local curl_bin="${1:-}" listing=""
  if [ -z "$curl_bin" ]; then
    printf '0\n'
    return 0
  fi
  listing="$("$curl_bin" --help all 2>/dev/null)" || listing=""
  case "$listing" in
    *--data-urlencode*) printf '1\n'; return 0 ;;
  esac
  listing="$("$curl_bin" --help 2>/dev/null)" || listing=""
  case "$listing" in
    *--data-urlencode*) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
  return 0
}

probe_platform() {
  local kernel=""
  kernel="$(uname -s 2>/dev/null)" || kernel=""
  case "$kernel" in
    Darwin) printf 'macos\n' ;;
    Linux) printf 'linux\n' ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT*) printf 'windows\n' ;;
    *) printf 'unknown\n' ;;
  esac
  return 0
}

probe_main() {
  local platform agy_bin grok_bin timeout_bin python_bin curl_bin urlencode ddg_ready
  platform="$(probe_platform)"
  agy_bin="$(probe_bin agy)"
  grok_bin="$(probe_bin grok)"
  timeout_bin="$(probe_timeout)"
  python_bin="$(probe_python)"
  curl_bin="$(probe_bin curl)"
  urlencode="$(probe_curl_urlencode "$curl_bin")"
  ddg_ready=0
  if [ -n "$curl_bin" ] && [ -n "$python_bin" ] && [ "$urlencode" = "1" ]; then
    ddg_ready=1
  fi
  printf 'PLATFORM=%s\n' "$platform"
  printf 'AGY_BIN=%s\n' "$agy_bin"
  printf 'GROK_BIN=%s\n' "$grok_bin"
  printf 'TIMEOUT_BIN=%s\n' "$timeout_bin"
  printf 'PYTHON_BIN=%s\n' "$python_bin"
  printf 'CURL_BIN=%s\n' "$curl_bin"
  printf 'CURL_DATA_URLENCODE=%s\n' "$urlencode"
  printf 'DDG_READY=%s\n' "$ddg_ready"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  probe_main
  exit 0
fi
