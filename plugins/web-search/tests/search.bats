#!/usr/bin/env bats

# Contract tests for skills/web-search/scripts/search.sh.
#
# The entry point is exercised through the same probe the real run uses, with
# sandboxed fakes for agy/grok/curl. Invocation counts come from shim scripts
# that append to a counter file, so "not called" is asserted as 0 rather than
# inferred from output.

SEARCH="$BATS_TEST_DIRNAME/../skills/web-search/scripts/search.sh"
FIXTURES="$BATS_TEST_DIRNAME/fixtures"

load test_helper/common-setup

setup() {
  setup_sandbox
  AGY_CALLS="$SANDBOX/agy.calls"
  GROK_CALLS="$SANDBOX/grok.calls"
  : >"$AGY_CALLS"
  : >"$GROK_CALLS"
  export WEB_SEARCH_TIMEOUT=10
}

teardown() {
  export PATH="$ORIGINAL_PATH"
  hash -r
  rm -rf "$SANDBOX"
}

# A shim that counts calls, then delegates to the real fixture.
install_counting_shim() {
  # install_counting_shim <command-name> <fixture-name> <counter-file>
  local name="$1" fixture="$2" counter="$3"
  cat >"$SANDBOX/bin/$name" <<EOF
#!/usr/bin/env bash
printf 'x\n' >>'$counter'
exec bash '$FIXTURES/$fixture' "\$@"
EOF
  chmod +x "$SANDBOX/bin/$name"
}

call_count() {
  wc -l <"$1" | tr -d '[:space:]'
}

# The probe must see a command named `curl` for DDG_READY to turn on, so the
# fake is installed under the real name rather than redirected via CURL_CMD.
install_fake_curl() {
  # install_fake_curl <http-code> <fixture-body>
  local code="$1" fixture="$2"
  cat >"$SANDBOX/bin/curl" <<EOF
#!/usr/bin/env bash
exec env FAKE_CURL_CODE='$code' FAKE_CURL_BODY='$FIXTURES/$fixture' bash '$FIXTURES/fake-curl' "\$@"
EOF
  chmod +x "$SANDBOX/bin/curl"
  CURL_CALLS="$SANDBOX/curl.calls"
  : >"$CURL_CALLS"
  curl_count() { wc -l <"$CURL_CALLS" | tr -d '[:space:]'; }
}

install_sequenced_curl() {
  # install_sequenced_curl <"code code ..."> <fixture-dir-map-log>
  # Each call serves the next code; the last one repeats. Arguments are logged.
  local sequence="$1" fixture_dir="$2"
  cat >"$SANDBOX/bin/curl" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  [ "\$a" = "--help" ] && { printf 'Usage: curl\n    --data-urlencode <data>\n'; exit 0; }
done
printf '%s\n' "\$*" >>'$SANDBOX/curl.args'
n=0
[ -f '$SANDBOX/curl.seq' ] && n="\$(cat '$SANDBOX/curl.seq')"
n=\$((n + 1))
printf '%s\n' "\$n" >'$SANDBOX/curl.seq'
code='$sequence'
last=''
idx=\$((n - 1))
for candidate in \$code; do
  last="\$candidate"
  if [ "\$idx" -le 0 ]; then code="\$candidate"; break; fi
  idx=\$((idx - 1))
done
out=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in -o) out="\${2:-}"; shift 2 ;; *) shift ;; esac
done
body=""
case "\$code" in
  200) body='$fixture_dir/ddg-results.html' ;;
  202) body='$fixture_dir/ddg-captcha.html' ;;
  403) body='$fixture_dir/ddg-captcha.html' ;;
esac
[ -n "\$out" ] && [ -n "\$body" ] && cat "\$body" >"\$out"
printf '%s' "\$code"
EOF
  chmod +x "$SANDBOX/bin/curl"
  : >"$SANDBOX/curl.args"
  # curl.seq is a counter overwritten on each call; curl.args is the append-only
  # log, so it is the one that can be counted.
  CURL_CALLS="$SANDBOX/curl.args"
  curl_count() { wc -l <"$SANDBOX/curl.args" | tr -d '[:space:]'; }
}

ddg_args() {
  cat "$SANDBOX/curl.args" 2>/dev/null
}

install_real_python() {
  # DDG_READY needs a working Python 3 behind the `python3` name.
  [ -n "$REAL_PYTHON" ] || skip "no python3 on this host"
  ln -sf "$REAL_PYTHON" "$SANDBOX/bin/python3"
}

@test "with neither agy nor grok installed, no CLI call happens and stderr reports skips" {
  run bash "$SEARCH" "some query"
  [ "$status" -eq 3 ]

  [ "$(call_count "$AGY_CALLS")" = "0" ]
  [ "$(call_count "$GROK_CALLS")" = "0" ]
  case "$output" in
    *"[skip] agy:"*) ;;
    *) printf 'missing agy skip line: %s\n' "$output" >&2; return 1 ;;
  esac
  case "$output" in
    *"[skip] grok:"*) ;;
    *) printf 'missing grok skip line: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "a missing agy is called zero times, not three" {
  install_counting_shim grok fake-grok "$GROK_CALLS"

  run bash "$SEARCH" "some query"
  [ "$status" -eq 0 ]
  [ "$(call_count "$AGY_CALLS")" = "0" ]
  [ "$(call_count "$GROK_CALLS")" = "1" ]
}

@test "a working agy short-circuits the chain and grok is never called" {
  install_counting_shim agy fake-agy "$AGY_CALLS"
  install_counting_shim grok fake-grok "$GROK_CALLS"

  run bash "$SEARCH" "some query"
  [ "$status" -eq 0 ]
  case "$output" in
    *"agy-result"*) ;;
    *) printf 'agy output missing: %s\n' "$output" >&2; return 1 ;;
  esac
  [ "$(call_count "$AGY_CALLS")" = "1" ]
  [ "$(call_count "$GROK_CALLS")" = "0" ]
}

@test "an agy SEARCH_FAILED payload with exit 0 still frees, retries twice, then escalates" {
  FAKE_AGY_MODE=search-failed
  export FAKE_AGY_MODE
  install_counting_shim agy fake-agy "$AGY_CALLS"
  install_counting_shim grok fake-grok "$GROK_CALLS"

  run bash "$SEARCH" "some query"
  [ "$status" -eq 0 ]
  [ "$(call_count "$AGY_CALLS")" = "3" ]
  [ "$(call_count "$GROK_CALLS")" = "1" ]
  case "$output" in
    *"grok-result"*) ;;
    *) printf 'grok result missing: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "an agy with a non-zero exit status is retried three times before escalation" {
  FAKE_AGY_MODE=exit-nonzero
  export FAKE_AGY_MODE
  install_counting_shim agy fake-agy "$AGY_CALLS"
  install_counting_shim grok fake-grok "$GROK_CALLS"

  run bash "$SEARCH" "some query"
  [ "$status" -eq 0 ]
  [ "$(call_count "$AGY_CALLS")" = "3" ]
  [ "$(call_count "$GROK_CALLS")" = "1" ]
}

@test "an empty agy payload is retried three times before escalation" {
  FAKE_AGY_MODE=empty
  export FAKE_AGY_MODE
  install_counting_shim agy fake-agy "$AGY_CALLS"
  install_counting_shim grok fake-grok "$GROK_CALLS"

  run bash "$SEARCH" "some query"
  [ "$status" -eq 0 ]
  [ "$(call_count "$AGY_CALLS")" = "3" ]
}

@test "agy recovers on the third attempt and grok is never called" {
  export FAKE_AGY_MODE=fail-then-ok
  export FAKE_AGY_FAILS=2
  export FAKE_AGY_COUNTER="$SANDBOX/agy-progress"
  install_counting_shim agy fake-agy "$AGY_CALLS"
  install_counting_shim grok fake-grok "$GROK_CALLS"

  run bash "$SEARCH" "some query"
  [ "$status" -eq 0 ]
  [ "$(call_count "$AGY_CALLS")" = "3" ]
  [ "$(call_count "$GROK_CALLS")" = "0" ]
  case "$output" in
    *"recovered"*) ;;
    *) printf 'recovered result missing: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "when grok also fails the script hands off to builtin WebSearch with exit 3" {
  FAKE_AGY_MODE=search-failed FAKE_GROK_MODE=search-failed
  export FAKE_AGY_MODE FAKE_GROK_MODE
  install_counting_shim agy fake-agy "$AGY_CALLS"
  install_counting_shim grok fake-grok "$GROK_CALLS"

  run bash "$SEARCH" "some query"
  [ "$status" -eq 3 ]
  case "$output" in
    *"[handoff] builtin-websearch"*) ;;
    *) printf 'handoff line missing: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "re-entering after builtin WebSearch fails falls through to DuckDuckGo" {
  install_fake_curl 200 ddg-results.html
  install_real_python
  export WEB_SEARCH_BUILTIN_UNAVAILABLE=1

  run bash "$SEARCH" "some query"
  [ "$status" -eq 0 ]
  case "$output" in
    *"https://example.com/one"*) ;;
    *) printf 'decoded uddg URL missing: %s\n' "$output" >&2; return 1 ;;
  esac
  case "$output" in
    *"https://example.com/two"*) ;;
    *) printf 'second decoded URL missing: %s\n' "$output" >&2; return 1 ;;
  esac
  # the DuckDuckGo wrapper URL must never leak into the results
  case "$output" in
    *"uddg="*) printf 'raw ddg wrapper leaked: %s\n' "$output" >&2; return 1 ;;
    *) ;;
  esac
}

@test "the DuckDuckGo request carries a Linux UA and the matching Accept headers" {
  install_sequenced_curl "200" "$FIXTURES"
  install_real_python
  export WEB_SEARCH_BUILTIN_UNAVAILABLE=1

  run bash "$SEARCH" "some query"
  [ "$status" -eq 0 ]

  args="$(ddg_args)"
  [ -n "$args" ]

  # The macOS UA is refused with a hard 403 by DuckDuckGo. Its characteristic
  # token must never reappear in the request.
  case "$args" in
    *Macintosh*) printf 'macOS user agent is back: %s\n' "$args" >&2; return 1 ;;
    *) ;;
  esac
  case "$args" in
    *"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"*) ;;
    *) printf 'expected Linux user agent missing: %s\n' "$args" >&2; return 1 ;;
  esac
  case "$args" in
    *"Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"*) ;;
    *) printf 'Accept header missing: %s\n' "$args" >&2; return 1 ;;
  esac
  case "$args" in
    *"Accept-Language: en-US,en;q=0.9"*) ;;
    *) printf 'Accept-Language header missing: %s\n' "$args" >&2; return 1 ;;
  esac
  case "$args" in
    *"Referer: https://duckduckgo.com/"*) ;;
    *) printf 'Referer header missing: %s\n' "$args" >&2; return 1 ;;
  esac
  case "$args" in
    *--data-urlencode*) ;;
    *) printf '--data-urlencode missing: %s\n' "$args" >&2; return 1 ;;
  esac
}

@test "a 202 CAPTCHA is retried once and the retry succeeds" {
  install_sequenced_curl "202 200" "$FIXTURES"
  install_real_python
  export WEB_SEARCH_BUILTIN_UNAVAILABLE=1

  run bash "$SEARCH" "some query"
  [ "$status" -eq 0 ]
  [ "$(curl_count)" = "2" ]
  case "$output" in
    *"https://example.com/one"*) ;;
    *) printf 'result missing after retry: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "a 403 is a deterministic refusal and is not retried" {
  install_sequenced_curl "403" "$FIXTURES"
  install_real_python
  export WEB_SEARCH_BUILTIN_UNAVAILABLE=1

  run bash "$SEARCH" "some query"
  [ "$status" -eq 1 ]
  [ "$(curl_count)" = "1" ]
}

@test "two consecutive 202 CAPTCHAs fail the level after one retry" {
  install_sequenced_curl "202 202" "$FIXTURES"
  install_real_python
  export WEB_SEARCH_BUILTIN_UNAVAILABLE=1

  run bash "$SEARCH" "some query"
  [ "$status" -eq 1 ]
  [ "$(curl_count)" = "2" ]
}

@test "a 200 DuckDuckGo page with no result__a rows fails as well" {
  install_fake_curl 200 ddg-no-results.html
  install_real_python
  export WEB_SEARCH_BUILTIN_UNAVAILABLE=1

  run bash "$SEARCH" "some query"
  [ "$status" -eq 1 ]
}

@test "with every level unavailable the chain fails with exit 1" {
  export WEB_SEARCH_BUILTIN_UNAVAILABLE=1

  run bash "$SEARCH" "some query"
  [ "$status" -eq 1 ]
  [ "$(call_count "$AGY_CALLS")" = "0" ]
}

@test "--community without grok reports unavailable and exits non-zero" {
  run bash "$SEARCH" "some topic" --community
  [ "$status" -ne 0 ]
  [ "$status" -ne 3 ]
  [ "$(call_count "$GROK_CALLS")" = "0" ]
  case "$output" in
    *"不可用"*) ;;
    *) printf 'unavailability notice missing: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "--community with grok succeeds and never touches agy" {
  install_counting_shim agy fake-agy "$AGY_CALLS"
  install_counting_shim grok fake-grok "$GROK_CALLS"

  run bash "$SEARCH" "some topic" --community
  [ "$status" -eq 0 ]
  [ "$(call_count "$GROK_CALLS")" = "1" ]
  [ "$(call_count "$AGY_CALLS")" = "0" ]
  case "$output" in
    *"grok-result"*) ;;
    *) printf 'community result missing: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "--community has no fallback when grok fails" {
  FAKE_GROK_MODE=search-failed
  export FAKE_GROK_MODE
  install_counting_shim grok fake-grok "$GROK_CALLS"
  install_fake_curl 200 ddg-results.html
  install_real_python

  run bash "$SEARCH" "some topic" --community
  [ "$status" -eq 1 ]
  case "$output" in
    *"example.com"*) printf 'community mode leaked a fallback result: %s\n' "$output" >&2; return 1 ;;
    *) ;;
  esac
}

@test "re-entry bypasses installed agy and grok entirely" {
  install_counting_shim agy fake-agy "$AGY_CALLS"
  install_counting_shim grok fake-grok "$GROK_CALLS"
  install_fake_curl 200 ddg-results.html
  install_real_python
  export WEB_SEARCH_BUILTIN_UNAVAILABLE=1
  run bash "$SEARCH" "some query"
  [ "$status" -eq 0 ]
  [[ "$output" == *https://example.com/one* ]]
  [ "$(call_count "$AGY_CALLS")" = 0 ]
  [ "$(call_count "$GROK_CALLS")" = 0 ]
}

@test "community remains independent of the general re-entry flag" {
  install_counting_shim agy fake-agy "$AGY_CALLS"
  install_counting_shim grok fake-grok "$GROK_CALLS"
  export WEB_SEARCH_BUILTIN_UNAVAILABLE=1
  run bash "$SEARCH" topic --community
  [ "$status" -eq 0 ]
  [ "$(call_count "$GROK_CALLS")" = 1 ]
  [ "$(call_count "$AGY_CALLS")" = 0 ]
}

@test "failure marker substrings in normal agy results do not trigger fallback" {
  install_counting_shim agy fake-agy "$AGY_CALLS"
  export FAKE_AGY_MODE=literal-marker
  run bash "$SEARCH" query
  [ "$status" -eq 0 ]
  [[ "$output" == *https://example.com/SEARCH_FAILED* ]]
  [ "$(call_count "$AGY_CALLS")" = 1 ]
}

@test "failure marker is an exact line for agy and both grok modes" {
  run bash -c '. "$1"; level_failed 0 "A SEARCH_FAILED B" && exit 9; level_failed 0 "SEARCH_FAILED extra" && exit 9; level_failed 0 "$(printf "result\\nSEARCH_FAILED\\nresult")"' _ "$SEARCH"
  [ "$status" -eq 0 ]
}

@test "double dash preserves option-looking queries as literals" {
  install_counting_shim agy fake-agy "$AGY_CALLS"
  install_counting_shim grok fake-grok "$GROK_CALLS"
  for query in --community --help -h; do
    run bash "$SEARCH" -- "$query"
    [ "$status" -eq 0 ]
    [[ "$output" == *agy-result* ]]
  done
  [ "$(call_count "$AGY_CALLS")" = 3 ]
  [ "$(call_count "$GROK_CALLS")" = 0 ]
}

@test "DDG associates optional snippets and preserves encoded URLs and literal markers" {
  install_fake_curl 200 ddg-structured.html
  install_real_python
  export WEB_SEARCH_BUILTIN_UNAVAILABLE=1
  run bash -c 'bash "$1" query 2>"$2"' _ "$SEARCH" "$SANDBOX/stderr"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' 'First SEARCH_FAILED title & more |  | https://example.com/a%2Fb?q=x%2By&n=1' 'Second result | Second snippet only & complete | https://example.org/direct%2Fpath?q=a%2Bb&n=2')" ]
}

@test "explicit curl path with spaces is both probed and executed without host curl" {
  install_fake_curl 200 ddg-results.html
  install_real_python
  mkdir -p "$SANDBOX/with spaces"
  cp "$SANDBOX/bin/curl" "$SANDBOX/with spaces/curl.exe"
  rm "$SANDBOX/bin/curl"
  export CURL_CMD="$SANDBOX/with spaces/curl.exe" WEB_SEARCH_BUILTIN_UNAVAILABLE=1
  run bash "$SEARCH" query
  [ "$status" -eq 0 ]
  [[ "$output" == *https://example.com/one* ]]
}

@test "an explicit curl without urlencode is rejected even when PATH curl has it" {
  install_fake_curl 200 ddg-results.html
  install_real_python
  printf '#!/usr/bin/env bash\nprintf "no options\\n"\n' >"$SANDBOX/no-urlencode"
  chmod +x "$SANDBOX/no-urlencode"
  export CURL_CMD="$SANDBOX/no-urlencode" WEB_SEARCH_BUILTIN_UNAVAILABLE=1
  run bash "$SEARCH" query
  [ "$status" -eq 1 ]
  [[ "$output" == *"[skip] duckduckgo:"* ]]
}

@test "DDG has curl request timeout even without GNU timeout and warns only on stderr" {
  install_sequenced_curl 200 "$FIXTURES"
  install_real_python
  export WEB_SEARCH_BUILTIN_UNAVAILABLE=1
  run bash -c 'bash "$1" query 2>"$2"' _ "$SEARCH" "$SANDBOX/stderr"
  [ "$status" -eq 0 ]
  [[ "$(ddg_args)" == *"--max-time 10"* ]]
  [[ "$output" != *"[warn]"* ]]
  grep -qF '[warn]' "$SANDBOX/stderr"
}

@test "GNU timeout includes a finite kill-after grace" {
  # Neither a real timeout nor a command-not-found may satisfy this assertion.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*"\n' >"$SANDBOX/timeout"
  chmod +x "$SANDBOX/timeout"
  run bash -c '. "$1"; TIMEOUT_BIN="$2"; run_with_timeout 7 true' _ "$SEARCH" "$SANDBOX/timeout"
  [ "$status" -eq 0 ]
  [ "$output" = '--kill-after=5 7 true' ]
}

@test "both Grok modes use only locally confirmed tools and matching prompts" {
  install_counting_shim grok fake-grok "$GROK_CALLS"
  export FAKE_GROK_ARGS_LOG="$SANDBOX/grok.args"
  for mode in general community; do
    if [ "$mode" = general ]; then
      run bash "$SEARCH" query
    else
      run bash "$SEARCH" query --community
    fi
    [ "$status" -eq 0 ]
    grep -qxF 'web_search,web_fetch' "$FAKE_GROK_ARGS_LOG"
    grep -qF -- '--no-subagents' "$FAKE_GROK_ARGS_LOG"
    grep -qF -- '--no-memory' "$FAKE_GROK_ARGS_LOG"
    if grep -Eq 'open_page|x_keyword_search|x_semantic_search|x_thread_fetch' "$FAKE_GROK_ARGS_LOG"; then
      return 1
    fi
  done
}

@test "000 is retried only once" {
  install_sequenced_curl '000 000' "$FIXTURES"
  install_real_python
  export WEB_SEARCH_BUILTIN_UNAVAILABLE=1
  run bash "$SEARCH" query
  [ "$status" -eq 1 ]
  [ "$(curl_count)" = 2 ]
}

@test "a missing query is a usage error, not a search" {
  run bash "$SEARCH"
  [ "$status" -eq 1 ]
  case "$output" in
    *"usage:"*) ;;
    *) printf 'usage line missing: %s\n' "$output" >&2; return 1 ;;
  esac
  [ "$(call_count "$AGY_CALLS")" = "0" ]
}
