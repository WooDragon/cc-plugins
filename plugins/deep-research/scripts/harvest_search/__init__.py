"""harvest_search - web search backends (duckduckgo, tavily,
gemini-grounding) + orchestration (call_search_backend/do_search), plus a
re-export of harvest_search.social's independent social-media search chain
(do_social_search/call_social_backend -- see that module for why social
search is its own tool/chain rather than a web-search backend). Depends on
harvest_safety (blacklist) and harvest_clients.base (HTTP primitives +
curl_cffi capability); never imports harvest_fetch (strict siblings)."""
import html
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

import harvest_safety
import harvest_clients.base
import harvest_journal
from harvest_search.social import call_social_backend, do_social_search

__all__ = [
    "_ddg_extract_target_url", "_search_duckduckgo",
    "_search_tavily", "_resolve_grounding_redirect", "_search_gemini_grounding",
    "_no_redirect_opener", "call_search_backend", "do_search",
    "call_social_backend", "do_social_search",
]
# (_NoRedirect / _DDG_* / _GROUNDING_* / _HTML_TAG_RE are internal implementation,
# not listed in __all__ -- but tests referencing them go through qualified
# harvest_search.X access, see contract §3)

# Parallel redirect resolution in _search_gemini_grounding needs a worker cap.
# harvest.py's own _PARALLEL_FETCH_MAX_WORKERS (fetch-domain driver, not moved
# here) is a sibling constant for the same purpose -- kept as a trivial local
# duplicate rather than a cross-package import, same rationale as _HTML_TAG_RE.
_PARALLEL_FETCH_MAX_WORKERS = 3


# ---------------------------------------------------------------------------
# Search backends (degrade in config order)
# ---------------------------------------------------------------------------

_DDG_ANCHOR_RE = re.compile(r'<a\b([^>]*)>(.*?)</a>', re.IGNORECASE | re.DOTALL)
_DDG_HREF_RE = re.compile(r'href="([^"]*)"')
_HTML_TAG_RE = re.compile(r'<[^>]+>')
# Markers observed in html.duckduckgo.com's anti-bot interstitial ("Select
# all squares containing a duck") -- used to distinguish a genuine
# zero-results page from an IP-reputation block, for observability only.
_DDG_BOT_CHECK_MARKERS = ("anomaly-modal", "challenge-form")


def _ddg_extract_target_url(href):
    # html.duckduckgo.com wraps result links in a same-site redirect
    # (//duckduckgo.com/l/?uddg=<url-encoded target>&rut=...); unwrap it to
    # get the real target URL. Non-redirect hrefs pass through unchanged.
    parsed = urllib.parse.urlsplit(href)
    host = (parsed.hostname or "").lower().rstrip(".")
    # Suffix/equality match, not substring containment -- "in" would also
    # match an unrelated host like "duckduckgo.com.evil.com" (same class of
    # anti-pattern is_blacklisted() already guards against elsewhere in
    # this file).
    if host == "duckduckgo.com" or host.endswith(".duckduckgo.com"):
        qs = urllib.parse.parse_qs(parsed.query)
        if "uddg" in qs and qs["uddg"]:
            # parse_qs() already percent-decodes query values once; a second
            # unquote() here double-decodes and corrupts any target URL that
            # itself contains a literal "%" escape sequence.
            return qs["uddg"][0]
    return href


def _search_duckduckgo(cfg, query, timeout):
    url = "https://html.duckduckgo.com/html/?q=" + urllib.parse.quote(query)

    if harvest_clients.base._HAS_CURL_CFFI:
        try:
            resp = harvest_clients.base.curl_cffi_requests.get(
                url, impersonate=(cfg or {}).get("impersonate", "chrome"),
                timeout=timeout, allow_redirects=True,
            )
            if resp.status_code != 200:
                return None, f"duckduckgo: HTTP {resp.status_code}"
            page = resp.text
        except Exception as e:
            return None, f"duckduckgo: curl-cffi request failed: {e}"
    else:
        headers = {"User-Agent": "Mozilla/5.0 (compatible; harvest.py/1.0)",
                   "Accept-Encoding": "identity"}
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = harvest_clients.base._maybe_decompress(resp.read(), resp)
        except (urllib.error.URLError, OSError) as e:
            return None, f"duckduckgo: request failed: {e}"
        try:
            page = raw.decode("utf-8", errors="replace")
        except Exception as e:
            return None, f"duckduckgo: failed to decode response body: {e}"

    results = []
    for attrs, inner in _DDG_ANCHOR_RE.findall(page):
        if "result__a" not in attrs:
            continue
        href_match = _DDG_HREF_RE.search(attrs)
        if not href_match:
            continue
        target = _ddg_extract_target_url(html.unescape(href_match.group(1)))
        if not target:
            continue
        title = html.unescape(_HTML_TAG_RE.sub("", inner)).strip()
        results.append({"url": target, "title": title, "snippet": ""})
    if results:
        return results, None
    if any(marker in page for marker in _DDG_BOT_CHECK_MARKERS):
        return None, ("duckduckgo: bot-check challenge page returned instead of results "
                       "(IP-reputation block, not a parsing bug)")
    return None, "duckduckgo: no result links found in response"


def _search_tavily(cfg, query, timeout):
    api_key = os.environ.get(cfg.get("api_key_env", ""), "")
    if not api_key:
        return None, f"tavily: {cfg.get('api_key_env') or '(no api_key_env configured)'} not set"
    payload = {"api_key": api_key, "query": query}
    try:
        data = harvest_clients.base._http_json_post("https://api.tavily.com/search", payload, {"Content-Type": "application/json"}, timeout)
    except (urllib.error.URLError, OSError, json.JSONDecodeError, ValueError) as e:
        return None, f"tavily: request failed: {e}"
    items = data.get("results") or []
    results = [{"url": r.get("url", ""), "title": r.get("title", ""), "snippet": r.get("content", "")}
               for r in items if r.get("url")]
    if not results:
        return None, "tavily: empty results"
    return results, None


# Gemini's grounding chunks never carry the real source URL directly -- each
# web.uri is a Google redirect short link on this fixed host. It is the ONLY
# host _resolve_grounding_redirect is ever allowed to connect to; anything
# else (a hallucinated/injected uri like http://169.254.169.254/) is rejected
# before a byte leaves the process.
_GROUNDING_REDIRECT_HOST = "vertexaisearch.cloud.google.com"
_GROUNDING_REDIRECT_STATUSES = (301, 302, 303, 307, 308)
_GROUNDING_REDIRECT_TIMEOUT_S = 10

# Grounding is a real live search, so (unlike the old fake gateway-gemini) the
# prompt doesn't ask the model to invent URLs -- it just steers the query and
# mirrors the repo-wide content-farm exclusion. The exclusion line is a
# courtesy only -- prompting the model to skip a domain does not stop it
# appearing in groundingChunks (those are raw retrieval results the prompt
# text has no control over); is_blacklisted() in do_search() is the actual
# enforcement. No SEARCH_FAILED sentinel: whether retrieval happened is read
# structurally from groundingMetadata, not parsed out of free text.
#
# The "cite EVERY source ... COMPLETE set ... do not truncate" line is
# load-bearing, not decoration. Debugging against the raw API showed the
# model already searches even on a MISS (groundingMetadata/webSearchQueries/
# 9-15 chunks all present) -- the miss was this prompt only asking to search
# "the live web" and the model then under-reporting which sources it
# actually consulted. Adding this sentence took a repeatedly-empty-chunks
# Chinese query from 0 to 21 chunks and this backend's measured hit rate
# from ~60% to 100%. Deliberately NOT adding a "you MUST call google_search"
# hard constraint -- tested too, no measured gain and it adds thinking-token
# latency.
_GROUNDING_SEARCH_PROMPT = (
    "Search the live web for: {query}\n"
    "Cite EVERY source you actually consulted -- return the COMPLETE set of "
    "source URLs, do not truncate or summarize the list.\n"
    "Exclude results from content-farm hosts: csdn.net, cloud.baidu.com, "
    "cloud.tencent.com, huaweicloud.com, aliyun.com, volcengine.com, juejin.cn."
)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Intercept every 30x so urllib never auto-follows a grounding redirect
    to its real target. urllib.request.urlopen installs an HTTPRedirectHandler
    by default that transparently connects to the Location host -- that would
    defeat the host-allowlist check in _resolve_grounding_redirect entirely
    (the guard vets the redirect host, not the target). Returning None here
    turns the 302 into a raised HTTPError whose Location header we read WITHOUT
    ever connecting to it."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_no_redirect_opener = urllib.request.build_opener(_NoRedirect)


def _resolve_grounding_redirect(uri, timeout):
    """Resolve a grounding-api-redirect short link to its real landing URL by
    reading the 302 Location header without following it. Connects ONLY to the
    fixed, trusted grounding host -- any other host is rejected before a single
    byte goes out (so this is not an SSRF surface even though the uri
    originates from model output). Returns the real URL, or None (caller drops
    the chunk) on a malformed uri, a non-grounding host, a non-redirect
    response, or any network error."""
    try:
        # uri is model/provider-controlled grounding output; a malformed value
        # (e.g. an unterminated IPv6 literal) makes urlsplit raise ValueError.
        # Treat it as a droppable bad chunk -- same guard is_blacklisted() puts
        # on this exact call -- so one bad uri can't abort the whole backend
        # and discard every other valid chunk.
        host = urllib.parse.urlsplit(uri).hostname
    except ValueError:
        return None
    if host != _GROUNDING_REDIRECT_HOST:
        return None
    req = urllib.request.Request(
        uri, headers={"User-Agent": "Mozilla/5.0 (compatible; harvest.py/1.0)"})
    try:
        # A genuine 200 (no redirect) means the short link resolved to nothing
        # citable -- close it and drop. The redirect case below is the norm.
        resp = _no_redirect_opener.open(req, timeout=timeout)
        resp.close()
        return None
    except urllib.error.HTTPError as e:
        if e.code in _GROUNDING_REDIRECT_STATUSES:
            return e.headers.get("Location")
        return None
    except (urllib.error.URLError, OSError):
        return None


def _search_gemini_grounding(cfg, query, timeout, config):
    """Real grounded web search via the gateway's Gemini-native
    generateContent endpoint + built-in google_search tool. Replaces the old
    fake gateway-gemini backend, which asked an OpenAI-compat /chat/completions
    to 'list some URLs' and got model-recalled (hallucinated) links with no
    live retrieval -- and, worse, since do_search stops at the first backend
    that returns any non-blacklisted URL, that fake result permanently masked
    the real tavily/duckduckgo backends behind it. Here the model actually
    searches; grounding chunks carry real (redirect-wrapped) source URLs that
    we resolve to true landing pages before returning them to the
    citation-verifiable pipeline."""
    gw = config["gateway"]
    api_key = os.environ.get(gw["api_key_env"], "")
    if not api_key:
        return None, f"gemini-grounding: {gw.get('api_key_env') or '(no api_key_env configured)'} not set"
    # Native endpoint is <origin>/v1beta/models/<model>:generateContent. Derive
    # origin via urlsplit -- NOT base_url.rstrip('/v1'), which strips a char
    # SET not a suffix and would mangle '.../v1' unpredictably. This makes a
    # base_url of '.../v1', '.../v1/', or a bare origin all resolve correctly.
    parts = urllib.parse.urlsplit(gw["base_url"])
    url = f"{parts.scheme}://{parts.netloc}/v1beta/models/{cfg.get('model', '')}:generateContent"
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
    payload = {
        "contents": [{"role": "user", "parts": [{"text": _GROUNDING_SEARCH_PROMPT.format(query=query)}]}],
        "tools": [{"google_search": {}}],
    }
    # thinkingBudget is opt-in and back-compat-strict: only add
    # generationConfig at all when the config explicitly sets it, so a
    # config predating this key sends byte-for-byte the same payload as
    # before (no generationConfig with an implicit default sneaking in).
    # Measured: thinkingBudget=0 does not lower the hit rate (google_search
    # is a tool call, not something reasoning/thinking gates) and cuts
    # latency to ~11-16s from the un-budgeted baseline.
    if "thinking_budget" in cfg:
        payload["generationConfig"] = {"thinkingConfig": {"thinkingBudget": cfg["thinking_budget"]}}
    try:
        data = harvest_clients.base._http_json_post(url, payload, headers, timeout)
    except (urllib.error.URLError, OSError, json.JSONDecodeError, ValueError) as e:
        return None, f"gemini-grounding: request failed: {e}"
    try:
        chunks = data["candidates"][0]["groundingMetadata"]["groundingChunks"]
    except (KeyError, IndexError, TypeError):
        # No groundingMetadata/chunks -> the model chose not to search
        # (grounding is model-discretionary, never guaranteed). Degrade to the
        # next backend rather than mining plain text for URLs.
        return None, "gemini-grounding: no grounding chunks (model did not search)"
    redirect_timeout = min(timeout, _GROUNDING_REDIRECT_TIMEOUT_S)
    # Redirect resolution is a network round-trip per chunk with no data
    # dependency between chunks -- resolving serially measured 18.2s for 16
    # chunks vs 2.5s in parallel. Same index-preallocate + future-to-index +
    # as_completed-fills-by-original-index pattern as
    # _run_fetch_calls_parallel (as_completed only picks scheduling order,
    # never the order results land in `resolved`) so chunk-submission order
    # -- which the dedup/citation-mapping below depends on -- survives
    # regardless of which redirect answers first.
    resolved = [None] * len(chunks)
    with ThreadPoolExecutor(max_workers=min(len(chunks), _PARALLEL_FETCH_MAX_WORKERS) or 1) as pool:
        future_to_index = {
            pool.submit(_resolve_grounding_redirect, (ch.get("web") or {}).get("uri", ""), redirect_timeout): i
            for i, ch in enumerate(chunks)
        }
        for fut in as_completed(future_to_index):
            i = future_to_index[fut]
            try:
                resolved[i] = fut.result()
            except Exception:
                # A single bad uri (malformed/hostile/network blip) must not
                # take down the whole grounding backend -- drop just this
                # chunk, same as a normal unresolvable-redirect result.
                resolved[i] = None
    results, seen = [], set()
    for ch, real_url in zip(chunks, resolved):
        web = ch.get("web") or {}
        uri = web.get("uri", "")
        if not uri:
            continue
        if not real_url or real_url in seen:
            continue
        seen.add(real_url)
        title = web.get("title", "")
        # snippet = title (usually just the domain); blacklist filtering is
        # do_search's job, kept out of here to avoid duplicating that concern.
        results.append({"url": real_url, "title": title, "snippet": title})
    if not results:
        return None, "gemini-grounding: no resolvable source URLs in grounding chunks"
    return results, None


def call_search_backend(backend_cfg, limiter, query, lang, config, attempts=None):
    limiter.acquire()
    timeout = config["limits"]["call_timeout_s"]
    btype = backend_cfg["type"]
    try:
        if btype == "tavily":
            result, reason = _search_tavily(backend_cfg, query, timeout)
        elif btype == "duckduckgo":
            result, reason = _search_duckduckgo(backend_cfg, query, timeout)
        elif btype == "gemini-grounding":
            result, reason = _search_gemini_grounding(backend_cfg, query, timeout, config)
        else:
            result, reason = None, f"unknown search backend type: {btype}"
    except Exception as e:
        result, reason = None, f"unexpected error: {e}"
    if not result and attempts is not None:
        attempts.append({"backend": btype, "error": reason or "no results"})
    return result


def do_search(query, lang, search_backends, journal, config):
    # Search backends only ever connect to a fixed, developer-configured
    # host (api.tavily.com / html.duckduckgo.com / our own gateway) -- the model's
    # query text does not steer the connection destination, so this is not
    # an SSRF surface and is not wrapped in tool_request_guard().
    _t0 = time.monotonic()
    blacklist = config.get("blacklist_domains", [])
    attempts = []
    for backend_cfg, limiter in search_backends:
        results = call_search_backend(backend_cfg, limiter, query, lang, config, attempts)
        if results:
            filtered = [r for r in results if not harvest_safety.is_blacklisted(r["url"], blacklist)]
            if not filtered:
                # Every result from this backend was blacklisted -- that's a
                # degrade-worthy failure, not a genuine "no results" answer;
                # try the next backend instead of returning an empty set.
                attempts.append({"backend": backend_cfg["type"], "error": "all results filtered by blacklist"})
                continue
            if backend_cfg["type"] == "gemini-grounding":
                for r in filtered:
                    # NOT "fetch": grounding gives us a URL the model *saw* in
                    # search results, not full page text -- content here is
                    # only a title/domain string. Using a distinct tool type
                    # keeps build_fetch_index() (which only recognizes
                    # "fetch"/"read_local") from treating this title string as
                    # verified full-text content, while build_journal_url_set()
                    # still recognizes "search_grounding" so a claim citing
                    # this URL without an explicit fetch() call correctly
                    # fails as url_not_fetched (real citation retry required)
                    # rather than url_not_in_journal (worse: implies the model
                    # never even saw the URL) or silently passing.
                    harvest_journal.jappend(journal, {"tool": "search_grounding", "url": r["url"],
                                    "backend": "grounding", "content": None,
                                    "title": r.get("title") or r["url"]})
            harvest_journal.jappend(journal, {"tool": "search", "query": query, "lang": lang,
                             "backend": backend_cfg["type"], "urls": [r["url"] for r in filtered],
                             "attempts": attempts, "duration_s": round(time.monotonic() - _t0, 3)})
            return json.dumps({"results": filtered}, ensure_ascii=False)
    harvest_journal.jappend(journal, {"tool": "search", "query": query, "lang": lang, "backend": None, "urls": [],
                     "attempts": attempts, "duration_s": round(time.monotonic() - _t0, 3)})
    return json.dumps({"results": [], "error": "all search backends failed"})
