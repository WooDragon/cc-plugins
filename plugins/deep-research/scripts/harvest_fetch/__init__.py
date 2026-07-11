"""harvest_fetch - URL fetch backends (tavily-extract, jina-reader, curl-cffi,
urllib-ua) + orchestration (call_fetch_backend/do_fetch). Depends on
harvest_safety (SSRF/blacklist) and harvest_clients.base (HTTP primitives +
curl_cffi capability); never imports harvest_search (strict siblings)."""
import html
import json
import os
import re
import socket
import time
import urllib.error
import urllib.parse
import urllib.request

import harvest_safety
import harvest_clients.base

__all__ = [
    "_fetch_tavily_extract", "_fetch_jina_reader", "_strip_html_to_text",
    "_looks_like_challenge_page", "_fetch_curl_cffi", "_fetch_urllib_ua",
    "call_fetch_backend", "do_fetch",
]

_HTML_TAG_RE = re.compile(r'<[^>]+>')


# ---------------------------------------------------------------------------
# Fetch backends (degrade in config order)
# ---------------------------------------------------------------------------

def _fetch_tavily_extract(cfg, url, timeout, max_chars):
    api_key = os.environ.get(cfg.get("api_key_env", ""), "")
    if not api_key:
        return None, f"tavily-extract: {cfg.get('api_key_env') or '(no api_key_env configured)'} not set"
    payload = {"api_key": api_key, "urls": [url]}
    try:
        data = harvest_clients.base._http_json_post("https://api.tavily.com/extract", payload, {"Content-Type": "application/json"}, timeout)
    except (urllib.error.URLError, OSError, json.JSONDecodeError, ValueError) as e:
        return None, f"tavily-extract: request failed: {e}"
    results = data.get("results") or []
    if not results:
        return None, "tavily-extract: empty results"
    content = results[0].get("raw_content") or results[0].get("content")
    if not content:
        return None, "tavily-extract: empty content in result"
    return content, None


def _fetch_jina_reader(cfg, url, timeout, max_chars):
    api_key = os.environ.get(cfg.get("api_key_env", ""), "")
    # r.jina.ai rejects urllib's default "Python-urllib/3.x" UA with HTTP 403
    # (independent of the API key -- any non-default UA gets 200). Send the
    # same UA as _fetch_urllib_ua so this backend isn't silently 403'd.
    headers = {"User-Agent": "Mozilla/5.0 (compatible; harvest.py/1.0)",
               "Accept": "text/plain", "Accept-Encoding": "identity"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request("https://r.jina.ai/" + url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = harvest_clients.base._maybe_decompress(resp.read(max_chars * 4), resp)
    except (urllib.error.URLError, OSError) as e:
        return None, f"jina-reader: request failed: {e}"
    try:
        return raw.decode("utf-8", errors="replace"), None
    except Exception as e:
        return None, f"jina-reader: failed to decode response body: {e}"


_HTML_SCRIPT_STYLE_RE = re.compile(r'<(script|style)\b[^>]*>.*?</\1>', re.IGNORECASE | re.DOTALL)


def _strip_html_to_text(raw_html):
    # urllib-ua and curl-cffi are the backends that return raw page source
    # (tavily-extract/jina-reader already return clean text) -- without
    # this, the fetch_max_chars budget is spent on markup instead of prose,
    # and an excerpt that spans an inline tag (e.g. "...the <a href=...>WAL
    # </a> file...") fails substring matching against the untouched HTML
    # even though it's a real verbatim quote of the rendered text. Strip
    # script/style blocks first (their contents aren't page text at all),
    # then every remaining tag, then resolve entities, then fold whitespace
    # -- in that order so truncation to fetch_max_chars (done by the
    # caller, after this returns) spends the budget on prose, not tags.
    text = _HTML_SCRIPT_STYLE_RE.sub(" ", raw_html)
    text = _HTML_TAG_RE.sub(" ", text)
    text = html.unescape(text)
    return re.sub(r"\s+", " ", text).strip()


_CURL_CFFI_MAX_REDIRECT_HOPS = 3
_CURL_CFFI_REDIRECT_STATUSES = (301, 302, 303, 307, 308)

# curl_cffi impersonates a real browser's TLS/HTTP fingerprint but cannot
# execute JavaScript -- so when a WAF (Cloudflare/DataDome/PerimeterX/
# Imperva) serves a JS challenge ("holding page"), curl_cffi gets exactly
# that holding page back as its final response, not the article. Without
# this check, that holding page's body (often HTTP 200, sometimes 403/503)
# is silently stripped-to-text and returned as if it were real page
# content, poisoning the downstream citation-verification pipeline with
# challenge-script prose that happens to contain no obvious HTTP error.
# See issue #81.
#
# Markers are deliberately script paths / JS globals / DOM ids / CDN
# domains -- unique implementation artifacts of the challenge widgets
# themselves -- rather than human-readable phrases like "checking your
# browser" or "just a moment". Human phrases appear verbatim in ordinary
# prose (news articles about Cloudflare outages, blog posts explaining
# Turnstile, this very code review) and would cause false positives;
# the literal script/DOM/CDN artifacts below only ever appear when the
# actual vendor widget markup is present on the page.
_CHALLENGE_PAGE_MARKERS = (
    # Cloudflare (challenge-platform script, browser-verification banner,
    # the cf_chl_opt JS config object, Turnstile widget, _cf_chl JS global)
    "/cdn-cgi/challenge-platform/",
    "cf-browser-verification",
    "_cf_chl_opt",
    "cf-turnstile",
    "window._cf_chl",
    # DataDome (captcha delivery CDN the challenge script loads from)
    "captcha-delivery.com",
    # PerimeterX / HUMAN (captcha widget id, JS app-id global)
    "px-captcha",
    "window._pxappid",
    # Imperva / Incapsula (challenge resource endpoint)
    "_incapsula_resource",
)

# Challenge/holding pages are minimal (a script tag, a spinner, a couple
# of divs) -- always tiny, never anywhere near fetch_max_chars territory.
# Real long-form content that happens to discuss these vendors (e.g. a
# deep-research task investigating WAF/Turnstile bypass techniques, or an
# article with an embedded code sample) can legitimately contain these
# same artifact strings inside tens of KB of genuine prose. This gate lets
# such long-form pages through unconditionally while still catching even
# a bloated/verbose challenge page, since real-world challenge HTML has
# never been observed anywhere close to 100KB.
_CHALLENGE_MAX_PAGE_CHARS = 100 * 1024


def _looks_like_challenge_page(raw_html):
    # resp.text can be None or "" (empty body, e.g. a HEAD-like 204, or a
    # decode that yielded nothing) -- guard first, since .lower() on None
    # would raise AttributeError and take curl-cffi out of rotation via
    # call_fetch_backend's broad except instead of cleanly degrading.
    if not raw_html:
        return False
    if len(raw_html) >= _CHALLENGE_MAX_PAGE_CHARS:
        return False
    lowered = raw_html.lower()
    return any(marker in lowered for marker in _CHALLENGE_PAGE_MARKERS)


def _fetch_curl_cffi(cfg, url, timeout, max_chars, config):
    # libcurl (which curl_cffi wraps via C bindings) does its own DNS
    # resolution entirely inside libcurl's C layer -- it never calls back
    # into Python's socket.getaddrinfo, so the process-level SSRF guard
    # (install_ssrf_guard()'s monkeypatch) provides ZERO protection here.
    # The fix: resolve each hop ourselves through the guarded
    # getaddrinfo (via _ssrf_validate_and_resolve, which raises
    # SSRFBlocked on any private/reserved address), then pin libcurl to
    # that exact, already-vetted IP with CURLOPT_RESOLVE. This closes the
    # TOCTOU window entirely -- libcurl is never allowed to resolve the
    # host itself, only to connect to the address we already validated.
    # Redirects are followed manually (allow_redirects=False) so every hop
    # gets its own independent guard + blacklist check; libcurl's built-in
    # redirect-following would silently reuse the pinned IP for whatever
    # Location header a compromised/malicious first hop returned.
    #
    # No "not installed -> skip" branch here: _check_curl_cffi_available()
    # already fail-fast-exits cmd_run() before any fetch happens if this
    # backend is configured but curl_cffi isn't importable, so by the time
    # this function runs, _HAS_CURL_CFFI is guaranteed True.
    #
    # `timeout` is the total budget for this call *across all redirect
    # hops*, not per-hop -- without this, a tarpit (slow-drip response)
    # combined with a redirect chain could burn hops * timeout wall clock.
    # `.get(key, default)` (not `config["limits"][key]`) is deliberate:
    # these three keys are new, and a config that predates them must keep
    # working with these defaults rather than KeyError -> get swallowed by
    # call_fetch_backend's broad except into a silent, permanent
    # "unexpected error" that takes curl-cffi out of rotation for good.
    limits = config.get("limits", {})
    connect_timeout_s = limits.get("fetch_connect_timeout_s", 5)
    low_speed_bytes_s = limits.get("fetch_low_speed_bytes_s", 512)
    low_speed_window_s = limits.get("fetch_low_speed_window_s", 10)
    blacklist = config.get("blacklist_domains", [])
    impersonate = cfg.get("impersonate", "chrome")
    current_url = url
    deadline = time.monotonic() + timeout
    for hop in range(_CURL_CFFI_MAX_REDIRECT_HOPS + 1):
        # < 1, not <= 0: curl_cffi converts seconds to milliseconds via
        # int(x * 1000), and libcurl treats a 0ms timeout as *no limit*.
        # A remaining budget inside that sub-millisecond window would
        # otherwise round down to 0 and silently reopen the hang this
        # deadline exists to close.
        remaining = deadline - time.monotonic()
        if remaining < 1:
            return None, "curl-cffi: total fetch deadline exceeded across redirects"
        if harvest_safety.is_blacklisted(current_url, blacklist):
            return None, f"curl-cffi: redirect target domain blacklisted: {current_url}"
        try:
            host, port, ip = harvest_safety._ssrf_validate_and_resolve(current_url)
        except (socket.gaierror, OSError) as e:
            return None, f"curl-cffi: DNS resolution failed: {e}"
        pin = f"{host}:{port}:{ip}"
        # curl_cffi 0.15.0 sets CURLOPT_TIMEOUT_MS = connect + read for a
        # tuple timeout (it sums the two components, it doesn't treat
        # `read` as the total) -- so to cap this hop's total at exactly
        # `remaining`, the read component must be `remaining - conn`, not
        # `remaining` itself. `- 0.1` keeps a strictly positive read
        # component even when remaining is barely above the connect cap.
        conn = min(connect_timeout_s, remaining - 0.1)
        try:
            resp = harvest_clients.base.curl_cffi_requests.get(
                current_url, timeout=(conn, remaining - conn), impersonate=impersonate,
                allow_redirects=False, headers={"Accept-Encoding": "identity"},
                curl_options={
                    harvest_clients.base.CurlCffiOpt.RESOLVE: [pin],
                    harvest_clients.base.CurlCffiOpt.MAXFILESIZE_LARGE: max_chars * 4,
                    harvest_clients.base.CurlCffiOpt.LOW_SPEED_LIMIT: low_speed_bytes_s,
                    harvest_clients.base.CurlCffiOpt.LOW_SPEED_TIME: low_speed_window_s,
                },
            )
        except Exception as e:
            return None, f"curl-cffi: request failed: {e}"
        if resp.status_code in _CURL_CFFI_REDIRECT_STATUSES:
            location = resp.headers.get("location")
            if not location:
                return None, f"curl-cffi: redirect status {resp.status_code} missing Location header"
            current_url = urllib.parse.urljoin(current_url, location)
            continue
        try:
            text = resp.text
        except Exception as e:
            return None, f"curl-cffi: failed to decode response body: {e}"
        # Gate 1: challenge page first, regardless of status code -- a
        # Cloudflare/DataDome/etc holding page served with 403/503 must be
        # reported as a challenge, not swallowed by the generic HTTP-error
        # gate below (which would lose the actual root cause from
        # telemetry: "anti-bot challenge" vs. "some 403").
        if _looks_like_challenge_page(text):
            return None, "curl-cffi: anti-bot JS challenge page (needs a JS-capable backend)"
        # Gate 2: an ordinary error page (403/404/5xx, no challenge marker)
        # is also not article content -- refuse to return its body too.
        if not (200 <= resp.status_code < 300):
            return None, f"curl-cffi: HTTP {resp.status_code}"
        return _strip_html_to_text(text), None
    return None, f"curl-cffi: exceeded max redirect hops ({_CURL_CFFI_MAX_REDIRECT_HOPS})"


def _fetch_urllib_ua(cfg, url, timeout, max_chars):
    headers = {"User-Agent": "Mozilla/5.0 (compatible; harvest.py/1.0)",
               "Accept-Encoding": "identity"}
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = harvest_clients.base._maybe_decompress(resp.read(max_chars * 4), resp)
    except (urllib.error.URLError, OSError) as e:
        return None, f"urllib-ua: request failed: {e}"
    try:
        text = raw.decode("utf-8", errors="replace")
    except Exception as e:
        return None, f"urllib-ua: failed to decode response body: {e}"
    return _strip_html_to_text(text), None


def call_fetch_backend(backend_cfg, limiter, url, config, attempts=None):
    limiter.acquire()
    # Per-backend timeout_s override, falling back to the shared
    # call_timeout_s -- .get() means backends that don't declare timeout_s
    # (or a config predating this field) keep the old 180s behavior.
    timeout = backend_cfg.get("timeout_s", config["limits"]["call_timeout_s"])
    max_chars = config["limits"]["fetch_max_chars"]
    btype = backend_cfg["type"]
    try:
        if btype == "tavily-extract":
            content, reason = _fetch_tavily_extract(backend_cfg, url, timeout, max_chars)
        elif btype == "jina-reader":
            content, reason = _fetch_jina_reader(backend_cfg, url, timeout, max_chars)
        elif btype == "curl-cffi":
            content, reason = _fetch_curl_cffi(backend_cfg, url, timeout, max_chars, config)
        elif btype == "urllib-ua":
            content, reason = _fetch_urllib_ua(backend_cfg, url, timeout, max_chars)
        else:
            content, reason = None, f"unknown fetch backend type: {btype}"
    except harvest_safety.SSRFBlocked:
        raise
    except Exception as e:
        content, reason = None, f"unexpected error: {e}"
    if not content and attempts is not None:
        attempts.append({"backend": btype, "error": reason or "no content"})
    return content


def do_fetch(url, fetch_backends, journal, config):
    # SSRF guard scope: only the connection whose destination host is
    # derived from model-controlled input is a real SSRF surface -- that is
    # urllib-ua's and curl-cffi's direct connection to `url` (and any
    # redirects they follow). tavily-extract/jina-reader take `url` as a
    # request *parameter* to a fixed, trusted API host; the actual fetch of
    # that URL happens on their servers, not on this machine, so guarding
    # them here would only false-positive-block a legitimate internally-
    # hosted gateway/API without adding any real protection. The domain
    # blacklist still applies to `url` regardless of which backend ends up
    # serving it. (curl-cffi additionally re-validates + re-pins every
    # redirect hop internally, since libcurl's own DNS resolution bypasses
    # this guard entirely -- see _fetch_curl_cffi().)
    blacklist = config.get("blacklist_domains", [])
    if harvest_safety.is_blacklisted(url, blacklist):
        journal.append({"tool": "fetch", "url": url, "blocked": "blacklist", "content": None})
        return json.dumps({"error": "domain blacklisted"})

    max_chars = config["limits"]["fetch_max_chars"]
    attempts = []
    for backend_cfg, limiter in fetch_backends:
        guarded = backend_cfg["type"] in ("urllib-ua", "curl-cffi")
        try:
            if guarded:
                with harvest_safety.tool_request_guard():
                    harvest_safety._ssrf_precheck(url)
                    content = call_fetch_backend(backend_cfg, limiter, url, config, attempts)
            else:
                content = call_fetch_backend(backend_cfg, limiter, url, config, attempts)
        except harvest_safety.SSRFBlocked as e:
            journal.append({"tool": "fetch", "url": url, "blocked": "ssrf", "content": None, "attempts": attempts})
            return json.dumps({"error": f"blocked by SSRF guard: {e}"})
        except Exception as e:
            content = None
            attempts.append({"backend": backend_cfg["type"], "error": f"unexpected error: {e}"})
        if content:
            truncated = content[:max_chars]
            journal.append({"tool": "fetch", "url": url, "backend": backend_cfg["type"], "content": truncated,
                             "attempts": attempts})
            return truncated
    journal.append({"tool": "fetch", "url": url, "backend": None, "content": None, "attempts": attempts})
    return json.dumps({"error": "all fetch backends failed"})
