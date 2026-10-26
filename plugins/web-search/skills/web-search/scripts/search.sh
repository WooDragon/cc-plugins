#!/usr/bin/env bash
# web-search unified entry point.
#
#   bash search.sh "<query>" [--community]
#
# Escalation ladder for general search:
#   agy -> grok -> builtin WebSearch (host tool, handoff) -> DuckDuckGo html
#
# Exit codes are a contract:
#   0  results were produced on stdout
#   1  the whole chain failed (every level unavailable or failed)
#   3  the caller must run the host WebSearch tool itself, then re-enter with
#      WEB_SEARCH_BUILTIN_UNAVAILABLE=1 to reach the DuckDuckGo fallback
#
# Levels that the probe cannot see are skipped wholesale, never retried.
# All agy/grok and curl invocations go through overridable functions so tests
# can substitute fakes without installing either CLI.

script_path="${BASH_SOURCE[0]}"
case "$script_path" in
  */*) script_dir="${script_path%/*}" ;;
  *) script_dir="." ;;
esac
# shellcheck source=probe.sh
if [ ! -f "$script_dir/probe.sh" ]; then
  printf 'search.sh: probe.sh not found next to the entry point\n' >&2
  exit 1
fi
# shellcheck disable=SC1091
. "$script_dir/probe.sh"

AGY_BIN=""
GROK_BIN=""
TIMEOUT_BIN=""
PYTHON_BIN=""
CURL_BIN=""
CURL_DATA_URLENCODE="0"
DDG_READY="0"
PLATFORM=""
CURL_CMD="${CURL_CMD-}"

# DuckDuckGo rejects a macOS Safari/Chrome user agent outright with HTTP 403;
# a desktop Linux Chrome UA with matching Accept headers is served normally.
# Do not swap this back to a macOS string - the block is on that UA itself,
# not on this machine.
DDG_USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

load_capabilities() {
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      PLATFORM) PLATFORM="$value" ;;
      AGY_BIN) AGY_BIN="$value" ;;
      GROK_BIN) GROK_BIN="$value" ;;
      TIMEOUT_BIN) TIMEOUT_BIN="$value" ;;
      PYTHON_BIN) PYTHON_BIN="$value" ;;
      CURL_BIN) CURL_BIN="$value" ;;
      CURL_DATA_URLENCODE) CURL_DATA_URLENCODE="$value" ;;
      DDG_READY) DDG_READY="$value" ;;
    esac
  done <<<"$(probe_main)"

  # Honour an explicit CURL_CMD override; otherwise use the probed binary so
  # the command that was checked for --data-urlencode is the one that runs.
  if [ -z "$CURL_CMD" ]; then
    CURL_CMD="$CURL_BIN"
  fi
}

run_with_timeout() {
  # Apply the probed POSIX timeout when one exists; otherwise run the command
  # directly (an absent timeout must not turn into "do not run").
  local seconds="$1"
  shift
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$seconds" "$@"
  else
    "$@"
  fi
}

if ! declare -F sleep_backoff >/dev/null 2>&1; then
  sleep_backoff() { sleep "$1"; }
fi

agy_prompt() {
  local query="$1"
  cat <<EOF
使用Google搜索查找以下问题的最新信息。

规则：
1. 必须联网搜索，严禁使用内置知识回答
2. 搜索失败则只返回SEARCH_FAILED
3. 只返回本次搜索实际检索到的结果，上限10条。宁少勿凑数：检索到几条就返回几条，只有1条也照返，严禁为凑够数量补充条目
4. URL必须逐字复制自本次搜索结果。严禁依据记忆、推测或"看起来合理"拼接域名与路径。无法确认真实存在的条目一律丢弃，不要输出
5. 每条格式：标题 | 关键信息（1-2句） | 完整来源URL（必须包含完整路径）
6. 不要做总结或分析，只返回搜索结果
7. 去重：同一来源只保留最相关的一条
8. 排除以下内容农场：CSDN、百度云、腾讯云、华为云、阿里云、火山引擎、稀土掘金
9. 最后单独一行输出：GROUNDED_COUNT=<本次实际检索到并返回的条数>

搜索问题：$query
EOF
}

GROK_SYSTEM_PROMPT="$(cat <<'EOF'
You are a web search tool. You have NO shell and NO access to any external CLI (agy, gemini, codex). Never attempt to run terminal commands or invoke other CLIs. Use only your built-in web_search and open_page tools. Return 5-10 results, one per line: Title | key info (1-2 sentences) | full URL. Dedupe by domain. No summary, no analysis. Exclude these content farms entirely: CSDN, 百度云, 腾讯云, 华为云, 阿里云, 火山引擎, 稀土掘金. If search yields nothing, output exactly SEARCH_FAILED.
EOF
)"

GROK_COMMUNITY_SYSTEM_PROMPT="$(cat <<'EOF'
You are an X/Twitter community research tool. You have NO shell and NO access to any external CLI. Never attempt to run terminal commands. Search ONLY for posts on X (x.com/twitter.com). Every result MUST be an actual X post with a real x.com/<handle>/status/<id> URL. Do NOT return blogs, news articles, Reddit, HN, or any non-X source. Use x_keyword_search / x_semantic_search when they work; if they return nothing, fall back to web_search restricted to site:x.com. Output one post per line: @handle | key point (1-2 sentences) | full x.com URL. If you cannot find real X posts, output exactly SEARCH_FAILED.
EOF
)"

if ! declare -F invoke_agy >/dev/null 2>&1; then
  invoke_agy() {
    # $1 = prompt, $2 = per-attempt timeout in seconds
    run_with_timeout "$2" "$AGY_BIN" --model "Gemini 3.8 Flash (Low)" -p "$1" 2>&1
  }
fi

if ! declare -F invoke_grok >/dev/null 2>&1; then
  invoke_grok() {
    # $1 = query, $2 = timeout in seconds
    run_with_timeout "$2" "$GROK_BIN" \
      --system-prompt-override "$GROK_SYSTEM_PROMPT" \
      -p "$1" \
      --effort low --output-format plain \
      --tools web_search,open_page \
      --no-subagents --no-memory --max-turns 8 2>&1
  }
fi

if ! declare -F invoke_grok_community >/dev/null 2>&1; then
  invoke_grok_community() {
    # $1 = query, $2 = timeout in seconds
    run_with_timeout "$2" "$GROK_BIN" \
      --system-prompt-override "$GROK_COMMUNITY_SYSTEM_PROMPT" \
      -p "搜索 X 上关于 $1 的近期真实讨论帖。找到几条返回几条，不要为凑数编造；一条真实的都没有则只输出 SEARCH_FAILED" \
      --effort low --output-format plain \
      --tools x_keyword_search,x_semantic_search,x_thread_fetch,web_search,open_page \
      --no-subagents --no-memory --max-turns 10 2>&1
  }
fi

level_failed() {
  # agy/grok share one predicate: a 429 can leave the exit status at 0, so the
  # payload must be inspected as well.
  local code="$1" output="$2"
  [ "$code" -ne 0 ] && return 0
  [ -z "$output" ] && return 0
  printf '%s' "$output" | grep -q 'SEARCH_FAILED' && return 0
  return 1
}

run_agy_level() {
  local query="$1" timeout_s="${WEB_SEARCH_TIMEOUT:-130}"
  local prompt attempt=1 output="" code=0
  prompt="$(agy_prompt "$query")"
  while [ "$attempt" -le 3 ]; do
    output="$(invoke_agy "$prompt" "$timeout_s")"
    code=$?
    if ! level_failed "$code" "$output"; then
      printf '%s\n' "$output"
      return 0
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -le 3 ]; then
      sleep_backoff $(((attempt - 1) * 3))
    fi
  done
  return 1
}

run_grok_level() {
  local query="$1" timeout_s="${WEB_SEARCH_TIMEOUT:-200}"
  local output code=0
  output="$(invoke_grok "$query" "$timeout_s")"
  code=$?
  level_failed "$code" "$output" && return 1
  printf '%s\n' "$output"
  return 0
}

run_community_level() {
  local query="$1" timeout_s="${WEB_SEARCH_TIMEOUT:-220}"
  local output code=0
  output="$(invoke_grok_community "$query" "$timeout_s")"
  code=$?
  level_failed "$code" "$output" && return 1
  printf '%s\n' "$output"
  return 0
}

ddg_parse_and_report() {
  # Reads the HTML body on stdin. Always prints either result rows or a
  # SEARCH_FAILED marker; the caller distinguishes the two.
  "$PYTHON_BIN" -c '
import sys, re, urllib.parse, html as H

page = sys.stdin.read()
hrefs = re.findall(r"class=\"result__a\"[^>]*href=\"([^\"]+)\"", page)
titles = re.findall(r"class=\"result__a\"[^>]*>(.*?)</a>", page, re.S)
snippets = re.findall(r"class=\"result__snippet\"[^>]*>(.*?)</a>", page, re.S)
strip = lambda s: H.unescape(re.sub(r"<[^>]+>", "", s)).strip()

rows = 0
for index, (href, title) in enumerate(zip(hrefs, titles)):
    real_url = urllib.parse.unquote(
        urllib.parse.parse_qs(urllib.parse.urlparse(href).query).get("uddg", [href])[0])
    snippet = strip(snippets[index]) if index < len(snippets) else ""
    print("%s | %s | %s" % (strip(title), snippet, real_url))
    rows += 1

if rows == 0:
    if "result__a" not in page and "anomaly" in page:
        print("SEARCH_FAILED (CAPTCHA)")
    else:
        print("SEARCH_FAILED")
'
}

run_ddg_level() {
  local query="$1" timeout_s="${WEB_SEARCH_TIMEOUT:-25}"
  local retry_sleep="${WEB_SEARCH_RETRY_SLEEP:-3}"
  local body http_code parsed attempt=1
  # Two attempts at most: one initial request plus one retry for a transient
  # status. A permanent refusal never reaches the second attempt.
  local max_attempts=2

  body="$(mktemp "${TMPDIR:-/tmp}/web-search-ddg.XXXXXX")" || return 1

  while [ "$attempt" -le "$max_attempts" ]; do
    http_code="$(
      # shellcheck disable=SC2086
      run_with_timeout "$timeout_s" $CURL_CMD -sS -o "$body" -w '%{http_code}' \
        -A "$DDG_USER_AGENT" \
        -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
        -H "Accept-Language: en-US,en;q=0.9" \
        -H "Referer: https://duckduckgo.com/" \
        --compressed -G \
        --data-urlencode "q=$query" \
        "https://html.duckduckgo.com/html/"
    )" || http_code="000"

    if [ "$http_code" = "200" ]; then
      parsed="$(ddg_parse_and_report <"$body")"
      if [ -n "$parsed" ] && ! printf '%s' "$parsed" | grep -q 'SEARCH_FAILED'; then
        rm -f "$body"
        printf '%s\n' "$parsed"
        return 0
      fi
      # A 200 whose body yields no result rows is not retried: the server
      # answered, so repeating the request spends a round trip without new
      # information. Treat it as this level failing.
      rm -f "$body"
      return 1
    fi

    # Non-200. Only transient statuses earn the retry:
    #   202 - CAPTCHA interstitial. DDG serves these intermittently on
    #         identical parameters, so one 202 says nothing about the level's
    #         health; the immediate retry often comes back 200.
    #   000 - no response at all (connection failure or client timeout).
    # 403 is a deterministic refusal: the request fingerprint is blocked. It
    # does not become transient by asking again, so it fails immediately.
    case "$http_code" in
      202|000)
        if [ "$attempt" -lt "$max_attempts" ]; then
          attempt=$((attempt + 1))
          sleep_backoff "$retry_sleep"
          continue
        fi
        ;;
    esac

    rm -f "$body"
    return 1
  done

  rm -f "$body"
  return 1
}

skip_level() {
  printf '[skip] %s: %s\n' "$1" "$2" >&2
}

usage() {
  printf 'usage: bash search.sh "<query>" [--community]\n' >&2
}

main() {
  local query="" community=0 arg
  for arg in "$@"; do
    case "$arg" in
      --community) community=1 ;;
      -h|--help) usage; exit 0 ;;
      --) ;;
      *)
        if [ -z "$query" ]; then
          query="$arg"
        fi
        ;;
    esac
  done

  if [ -z "$query" ]; then
    usage
    exit 1
  fi

  load_capabilities

  if [ "$community" -eq 1 ]; then
    if [ -z "$GROK_BIN" ]; then
      skip_level grok "binary not found"
      printf '社区调研档仅支持 grok，本机未安装 grok，本档不可用。\n' >&2
      exit 1
    fi
    run_community_level "$query" && exit 0
    printf '社区调研档 grok 检索失败（无 fallback）。\n' >&2
    exit 1
  fi

  if [ -n "$AGY_BIN" ]; then
    run_agy_level "$query" && exit 0
  else
    skip_level agy "binary not found"
  fi

  if [ -n "$GROK_BIN" ]; then
    run_grok_level "$query" && exit 0
  else
    skip_level grok "binary not found"
  fi

  if [ "${WEB_SEARCH_BUILTIN_UNAVAILABLE:-0}" != "1" ]; then
    printf '[handoff] builtin-websearch\n' >&2
    exit 3
  fi
  skip_level builtin-websearch "caller reported unavailable"

  if [ "$DDG_READY" = "1" ]; then
    run_ddg_level "$query" && exit 0
  else
    skip_level duckduckgo "needs curl + python3 + curl --data-urlencode"
  fi

  printf '全链失败：所有级别均不可用或检索失败。\n' >&2
  exit 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
