"""harvest.py - multi-model research harvesting with deterministic citation verification.

Three heterogeneous panel models each run a minimal agentic loop (search/fetch/
read_local tools) to independently collect claims. A judge model clusters the
claims (ID-only output); this script mechanically assembles the merged result.
All citations are verified at the URL level against a recorded tool-call
journal -- never by LLM judgment.

Stdlib only, with one optional soft dependency: curl_cffi (only used by the
"curl-cffi" fetch backend; every other code path is pure stdlib). Config
without a "curl-cffi" fetch backend entry never imports curl_cffi at all; a
config that declares it but doesn't have it installed makes `run` exit 4
immediately (see _check_curl_cffi_available()) rather than silently
degrading -- a missing dependency is a setup error the caller should fix,
not a fetch failure to route around. See scripts/tests/test_harvest.py for
behavior coverage.
"""

import argparse
import gzip
import hashlib
import html
import ipaddress
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

# curl_cffi is an optional soft dependency (the "curl-cffi" fetch backend
# only): the core pipeline stays stdlib-only and degrades cleanly to the
# next fetch backend when it isn't installed. Never import it at module
# scope unconditionally -- that would turn a missing optional package into
# a hard crash for every consumer of this module (including the
# SubagentStop hook, which imports harvest.py on every turn).
try:
    from curl_cffi import requests as curl_cffi_requests
    from curl_cffi.const import CurlOpt as CurlCffiOpt
    _HAS_CURL_CFFI = True
except ImportError:
    curl_cffi_requests = None
    CurlCffiOpt = None
    _HAS_CURL_CFFI = False

VERIFY_FILE = "harvest-verify.json"
LEGACY_EXEMPTION_FILE = "legacy-exemption.md"
MERGED_FINDINGS_FILE = "merged-findings.json"
HARVEST_SUBDIR = "harvest"
GOAL_FILE_NAME = "research-goal.md"
GOAL_FILE_CONVENTIONAL_DIR = "intake/requirements"


def resolve_goal_file(project_dir):
    """Single shared resolver used by both run (hash source) and check
    (hash comparison) -- repo convention puts the goal file at
    intake/requirements/research-goal.md (see quality-gates.md G0), with
    project-root as a fallback for older layouts. Returns Path or None."""
    project_dir = Path(project_dir)
    for candidate in (project_dir / GOAL_FILE_CONVENTIONAL_DIR / GOAL_FILE_NAME,
                       project_dir / GOAL_FILE_NAME):
        if candidate.exists():
            return candidate
    return None


TOOL_SCHEMAS = [
    {"type": "function", "function": {
        "name": "search",
        "description": "Search the web for information relevant to a query.",
        "parameters": {"type": "object", "properties": {
            "query": {"type": "string"},
            "lang": {"type": "string"},
        }, "required": ["query"]}}},
    {"type": "function", "function": {
        "name": "fetch",
        "description": "Fetch the full text content of a URL.",
        "parameters": {"type": "object", "properties": {
            "url": {"type": "string"},
        }, "required": ["url"]}}},
    {"type": "function", "function": {
        "name": "read_local",
        "description": "Read local internal material provided for this research.",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string"},
            "offset": {"type": "integer"},
        }, "required": ["path"]}}},
]

JUDGE_SYSTEM_PROMPT = (
    "You are the research panel judge. Input is claim id + claim text from "
    "three independent panel workers. Output ONLY one JSON object mapping "
    "IDs into clusters -- never rewrite, translate, or restate claim text. "
    "Each claim ID must appear in at most one cluster (a claim belongs to "
    "exactly one cluster, not several) -- this is advisory only, the caller "
    "mechanically enforces it regardless of what you output:\n"
    '{"clusters": [{"summary": "...", "source_claim_ids": ["m1-1", "m2-3"], '
    '"relation": "agree|contradict"}], "coverage_gaps": ["..."], '
    '"unique_insights": ["m1-1"], "blind_spots": ["..."]}'
)


# ---------------------------------------------------------------------------
# Rate limiting
# ---------------------------------------------------------------------------

class RateLimiter:
    """One lock-protected timestamp per backend instance. Critical section is
    timestamp-only; sleep and the actual call happen outside the lock."""

    def __init__(self, min_interval_s):
        self._min_interval = min_interval_s
        self._lock = threading.Lock()
        self._next_allowed = 0.0

    def acquire(self):
        with self._lock:
            now = time.monotonic()
            wait = max(0.0, self._next_allowed - now)
            self._next_allowed = max(now, self._next_allowed) + self._min_interval
        if wait > 0:
            time.sleep(wait)


# ---------------------------------------------------------------------------
# SSRF guard: process-level getaddrinfo wrapper + thread-local tool context.
# No TOCTOU window (resolution and connection are the same call), no
# whitelist while the tool-context flag is set.
# ---------------------------------------------------------------------------

class SSRFBlocked(Exception):
    pass


_tool_ctx = threading.local()
_real_getaddrinfo = socket.getaddrinfo


def _is_blocked_ip(ip_str):
    try:
        ip = ipaddress.ip_address(ip_str)
    except ValueError:
        return True
    return (ip.is_private or ip.is_loopback or ip.is_link_local
            or ip.is_reserved or ip.is_multicast or ip.is_unspecified)


def _guarded_getaddrinfo(host, *args, **kwargs):
    result = _real_getaddrinfo(host, *args, **kwargs)
    if getattr(_tool_ctx, "active", False):
        for item in result:
            ip = item[4][0]
            if _is_blocked_ip(ip):
                raise SSRFBlocked(f"blocked address for host {host}: {ip}")
    return result


def install_ssrf_guard():
    """Monkeypatch socket.getaddrinfo. Called at run-start, not at import
    time, so importing this module (e.g. from the SubagentStop hook) stays
    side-effect free."""
    socket.getaddrinfo = _guarded_getaddrinfo


class tool_request_guard:
    """Context manager marking the current thread as executing a tool call
    whose network target may be attacker/model controlled. Only active
    inside this context does the guard reject private/loopback/reserved
    addresses -- gateway chat-completion calls are made outside it."""

    def __enter__(self):
        self._prev = getattr(_tool_ctx, "active", False)
        _tool_ctx.active = True
        return self

    def __exit__(self, exc_type, exc, tb):
        _tool_ctx.active = self._prev
        return False


def _ssrf_validate_and_resolve(url):
    """Shared SSRF validation: scheme + host-presence checks, then a single
    guarded socket.getaddrinfo() call (raises SSRFBlocked if any returned
    address is private/loopback/reserved). Returns (host, port, first_ip)
    so callers that need the actual resolved address -- not just a pass/
    fail check -- don't have to resolve a second time."""
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https"):
        raise SSRFBlocked(f"unsupported scheme: {parts.scheme}")
    host = parts.hostname
    if not host:
        raise SSRFBlocked("no host in URL")
    port = parts.port or (443 if parts.scheme == "https" else 80)
    results = socket.getaddrinfo(host, port)
    return host, port, results[0][4][0]


def _ssrf_precheck(url):
    _ssrf_validate_and_resolve(url)


# ---------------------------------------------------------------------------
# Domain blacklist / path sandbox
# ---------------------------------------------------------------------------

def is_blacklisted(url, blacklist_domains):
    try:
        host = urllib.parse.urlsplit(url).hostname
    except ValueError:
        return True
    if not host:
        return False
    # .hostname (not manual "@"/":" splitting) correctly strips userinfo,
    # port, and IPv6 brackets -- manual colon-splitting breaks on IPv6
    # literals, which contain colons inside the address itself.
    host = host.lower().rstrip(".")
    for domain in blacklist_domains:
        domain = domain.lower().rstrip(".")
        if host == domain or host.endswith("." + domain):
            return True
    return False


def _is_relative_to(path, base):
    try:
        path.relative_to(base)
        return True
    except ValueError:
        return False


def resolve_local_path(local_dir, rel_path):
    """Sandbox check on the *resolved* final path, not the join operation --
    catches '../', absolute paths, and literal '~' alike."""
    base = Path(local_dir).resolve()
    target = (base / rel_path).resolve()
    if not _is_relative_to(target, base):
        return None
    return target


# ---------------------------------------------------------------------------
# URL / whitespace normalization for citation matching
# ---------------------------------------------------------------------------

def normalize_url(url):
    url = (url or "").strip()
    if url.startswith("local://"):
        return "local://" + url[len("local://"):].strip("/")
    try:
        parts = urllib.parse.urlsplit(url)
        netloc = parts.netloc.lower()
        path = parts.path.rstrip("/")
        return urllib.parse.urlunsplit((parts.scheme.lower(), netloc, path, parts.query, ""))
    except ValueError:
        # Malformed URL (e.g. a broken IPv6 literal) from model output or a
        # search backend result -- treat as non-normalizable rather than
        # crashing the worker. Returning it unnormalized just means it
        # won't match any journal-derived key, which correctly fails
        # citation validation instead of taking down the whole run.
        return url


# ---------------------------------------------------------------------------
# Findings / judge JSON parsing
# ---------------------------------------------------------------------------

_FENCE_RE = re.compile(r"```(?:json)?\s*([\s\S]*?)\s*```")


def extract_json_candidate(text):
    fences = _FENCE_RE.findall(text)
    if fences:
        return fences[-1]
    starts = [i for i in (text.find("{"), text.find("[")) if i != -1]
    if not starts:
        return text
    start = min(starts)
    ends = [i for i in (text.rfind("}"), text.rfind("]")) if i != -1]
    if not ends:
        return text
    end = max(ends)
    if end < start:
        return text
    return text[start:end + 1]


def parse_findings_json(text):
    candidate = extract_json_candidate(text)
    try:
        data = json.loads(candidate)
    except json.JSONDecodeError as e:
        return None, f"JSON parse failed: {e}"
    if not isinstance(data, dict):
        return None, "top-level JSON must be an object"
    claims = data.get("claims")
    if not isinstance(claims, list):
        return None, "'claims' must be an array"
    for i, c in enumerate(claims):
        if not isinstance(c, dict):
            return None, f"claims[{i}] must be an object"
        for field in ("claim", "excerpt", "url"):
            v = c.get(field)
            if not isinstance(v, str) or not v.strip():
                return None, f"claims[{i}].{field} must be a non-empty string"
    return data, None


def parse_judge_json(text):
    candidate = extract_json_candidate(text)
    try:
        data = json.loads(candidate)
    except json.JSONDecodeError as e:
        return None, f"JSON parse failed: {e}"
    if not isinstance(data, dict) or not isinstance(data.get("clusters"), list):
        return None, "'clusters' missing or not a list"
    return data, None


def assign_claim_ids(alias, claims):
    out = []
    for i, c in enumerate(claims, 1):
        c = dict(c)
        c["_id"] = f"{alias}-{i}"
        out.append(c)
    return out


# ---------------------------------------------------------------------------
# Citation verification (deterministic, zero LLM)
# ---------------------------------------------------------------------------

def build_fetch_index(journal):
    idx = {}
    for entry in journal:
        if entry.get("tool") in ("fetch", "read_local") and entry.get("content"):
            key = normalize_url(entry["url"])
            idx.setdefault(key, []).append(entry["content"])
    return idx


def build_journal_url_set(journal):
    # Every URL the model has *seen* (via a search result), not just the
    # ones it fetched -- lets validate_claims distinguish "hallucinated a
    # URL nothing ever surfaced" from "saw it in search but skipped fetch".
    urls = set()
    for entry in journal:
        if entry.get("tool") == "search":
            for u in entry.get("urls", []):
                urls.add(normalize_url(u))
        elif entry.get("tool") in ("fetch", "read_local", "search_grounding"):
            u = entry.get("url")
            if u:
                urls.add(normalize_url(u))
    return urls


_REJECT_REASON_MESSAGES = {
    "url_not_in_journal": "url never appeared in any search/fetch/read_local call",
    "url_not_fetched": "url was seen but never successfully fetched; fetch full text before citing",
}


def validate_claims(claims, fetch_index, journal_urls):
    valid, invalid = [], []
    for c in claims:
        key = normalize_url(c.get("url", ""))
        contents = fetch_index.get(key)
        if not contents:
            reason = "url_not_fetched" if key in journal_urls else "url_not_in_journal"
            invalid.append((c, reason, None))
            continue
        valid.append(c)
    return valid, invalid


def build_citation_feedback(invalid):
    lines = ["The following claims failed citation verification; fix and re-output the full findings JSON:"]
    for c, reason, _matched in invalid:
        lines.append(f"- {c.get('_id', '?')}: {_REJECT_REASON_MESSAGES[reason]} (url={c.get('url')})")
    return "\n".join(lines)


def build_rejected_claims(invalid):
    return [{"claim": c.get("claim", ""), "url": c.get("url", ""), "excerpt": c.get("excerpt", ""),
             "reject_reason": reason, "matched_url_normalized": matched} for c, reason, matched in invalid]


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

def _maybe_decompress(raw, resp):
    encoding = (resp.headers.get("Content-Encoding") or "").lower()
    if encoding == "gzip":
        try:
            return gzip.decompress(raw)
        except OSError:
            return raw
    return raw


def _http_json_post(url, payload, headers, timeout):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
        raw = _maybe_decompress(raw, resp)
        return json.loads(raw.decode("utf-8"))


# Retry schedule for the gateway chat/completions call only (shared by the
# panel loop and the judge) -- other backends keep their existing
# degrade-to-next-backend behavior and are not retried here.
_GATEWAY_RETRY_BACKOFFS_TRANSIENT = (5, 15)  # 429/408/5xx: up to 2 retries
_GATEWAY_RETRY_BACKOFFS_OTHER_4XX = (5,)     # other 4xx (401/403/404...): 1 retry
_COMPLETION_RETRY_BACKOFFS = (2, 5, 15, 30)  # 4 retries, 52s total backoff


def _http_json_post_with_retry(url, payload, headers, timeout, transient_backoffs=None):
    """Bounded retry around _http_json_post for transient gateway failures.
    Classification is fixed on the first failure's status code and the
    matching backoff schedule is followed to exhaustion -- no lock is held
    across this function or its sleeps, so worker/judge threads never block
    each other while backing off.

    Two failure shapes share one retry loop: an HTTP response with a status
    code (HTTPError -- classified transient/4xx by status), and a network-
    layer failure with no status code at all (URLError/socket.timeout --
    always treated as transient, same as a 5xx). HTTPError must be caught
    before URLError since urllib raises HTTPError as a URLError subclass;
    catching the parent first would swallow the status-code-bearing case."""
    backoffs = None
    attempt = 0
    while True:
        attempt += 1
        try:
            return _http_json_post(url, payload, headers, timeout)
        except urllib.error.HTTPError as e:
            status = e.code
            if backoffs is None:
                transient = status in (429, 408) or 500 <= status < 600
                backoffs = (transient_backoffs if transient_backoffs is not None else _GATEWAY_RETRY_BACKOFFS_TRANSIENT) if transient else _GATEWAY_RETRY_BACKOFFS_OTHER_4XX
            retries_done = attempt - 1
            if retries_done >= len(backoffs):
                raise RuntimeError(f"HTTP {status} after {attempt} attempts") from e
            time.sleep(backoffs[retries_done])
        except (urllib.error.URLError, socket.timeout, TimeoutError, json.JSONDecodeError) as e:
            # No status code (connection refused/reset, DNS failure, read
            # timeout, ...) -- always transient, same schedule as 429/5xx.
            if backoffs is None:
                backoffs = transient_backoffs if transient_backoffs is not None else _GATEWAY_RETRY_BACKOFFS_TRANSIENT
            retries_done = attempt - 1
            if retries_done >= len(backoffs):
                raise RuntimeError(f"network error after {attempt} attempts: {e}") from e
            time.sleep(backoffs[retries_done])


# ---------------------------------------------------------------------------
# Search backends (degrade in config order)
# ---------------------------------------------------------------------------

def _search_gemini_cli(cfg, query, timeout):
    try:
        proc = subprocess.run(
            ["gemini", "-m", cfg.get("model", "gemini-3.5-flash"), "-p", query],
            capture_output=True, timeout=timeout, stdin=subprocess.DEVNULL, text=True,
        )
    except subprocess.TimeoutExpired:
        return None, "gemini-cli: timed out"
    except OSError as e:
        return None, f"gemini-cli: failed to launch subprocess: {e}"
    if proc.returncode != 0:
        detail = (proc.stderr or "").strip()[:200]
        return None, f"gemini-cli: exited with code {proc.returncode}" + (f": {detail}" if detail else "")
    text = proc.stdout or ""
    if not text.strip():
        return None, "gemini-cli: empty output"
    urls = list(dict.fromkeys(re.findall(r'https?://[^\s\)\]\'"<>]+', text)))
    if not urls:
        return None, "gemini-cli: no URLs found in output"
    return [{"url": u, "title": "", "snippet": text[:500]} for u in urls], None


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

    if _HAS_CURL_CFFI:
        try:
            resp = curl_cffi_requests.get(
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
                raw = _maybe_decompress(resp.read(), resp)
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
        data = _http_json_post("https://api.tavily.com/search", payload, {"Content-Type": "application/json"}, timeout)
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
# mirrors the repo-wide content-farm exclusion (courtesy only; is_blacklisted()
# in do_search() is the actual enforcement). No SEARCH_FAILED sentinel: whether
# retrieval happened is read structurally from groundingMetadata, not parsed
# out of free text.
_GROUNDING_SEARCH_PROMPT = (
    "Search the live web for: {query}\n"
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
    try:
        data = _http_json_post(url, payload, headers, timeout)
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
    results, seen = [], set()
    for ch in chunks:
        web = ch.get("web") or {}
        uri = web.get("uri", "")
        if not uri:
            continue
        real_url = _resolve_grounding_redirect(uri, redirect_timeout)
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
        if btype == "gemini-cli":
            result, reason = _search_gemini_cli(backend_cfg, query, timeout)
        elif btype == "tavily":
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
    blacklist = config.get("blacklist_domains", [])
    attempts = []
    for backend_cfg, limiter in search_backends:
        results = call_search_backend(backend_cfg, limiter, query, lang, config, attempts)
        if results:
            filtered = [r for r in results if not is_blacklisted(r["url"], blacklist)]
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
                    journal.append({"tool": "search_grounding", "url": r["url"],
                                    "backend": "grounding", "content": None,
                                    "title": r.get("title") or r["url"]})
            journal.append({"tool": "search", "query": query, "lang": lang,
                             "backend": backend_cfg["type"], "urls": [r["url"] for r in filtered],
                             "attempts": attempts})
            return json.dumps({"results": filtered}, ensure_ascii=False)
    journal.append({"tool": "search", "query": query, "lang": lang, "backend": None, "urls": [], "attempts": attempts})
    return json.dumps({"results": [], "error": "all search backends failed"})


# ---------------------------------------------------------------------------
# Fetch backends (degrade in config order)
# ---------------------------------------------------------------------------

def _fetch_tavily_extract(cfg, url, timeout, max_chars):
    api_key = os.environ.get(cfg.get("api_key_env", ""), "")
    if not api_key:
        return None, f"tavily-extract: {cfg.get('api_key_env') or '(no api_key_env configured)'} not set"
    payload = {"api_key": api_key, "urls": [url]}
    try:
        data = _http_json_post("https://api.tavily.com/extract", payload, {"Content-Type": "application/json"}, timeout)
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
    headers = {"Accept": "text/plain", "Accept-Encoding": "identity"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request("https://r.jina.ai/" + url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = _maybe_decompress(resp.read(max_chars * 4), resp)
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
        if is_blacklisted(current_url, blacklist):
            return None, f"curl-cffi: redirect target domain blacklisted: {current_url}"
        try:
            host, port, ip = _ssrf_validate_and_resolve(current_url)
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
            resp = curl_cffi_requests.get(
                current_url, timeout=(conn, remaining - conn), impersonate=impersonate,
                allow_redirects=False, headers={"Accept-Encoding": "identity"},
                curl_options={
                    CurlCffiOpt.RESOLVE: [pin],
                    CurlCffiOpt.MAXFILESIZE_LARGE: max_chars * 4,
                    CurlCffiOpt.LOW_SPEED_LIMIT: low_speed_bytes_s,
                    CurlCffiOpt.LOW_SPEED_TIME: low_speed_window_s,
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
        return _strip_html_to_text(text), None
    return None, f"curl-cffi: exceeded max redirect hops ({_CURL_CFFI_MAX_REDIRECT_HOPS})"


_CURL_CFFI_MISSING_MSG = (
    "ERROR: fetch backend 'curl-cffi' is configured but curl_cffi is not "
    "installed. Run: pip3 install --user curl_cffi"
)


def _check_curl_cffi_available(config):
    # Config declares the backend -> it must be installed, fail fast before
    # touching any state (cleanup/tombstone) or spending an API call. Config
    # doesn't declare it -> curl_cffi is never imported at runtime and the
    # pipeline stays exactly as stdlib-only as it always has been.
    types = [b.get("type") for b in config.get("fetch_backends", [])]
    if "curl-cffi" in types and not _HAS_CURL_CFFI:
        print(_CURL_CFFI_MISSING_MSG, file=sys.stderr)
        sys.exit(4)


def _fetch_urllib_ua(cfg, url, timeout, max_chars):
    headers = {"User-Agent": "Mozilla/5.0 (compatible; harvest.py/1.0)",
               "Accept-Encoding": "identity"}
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = _maybe_decompress(resp.read(max_chars * 4), resp)
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
    except SSRFBlocked:
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
    if is_blacklisted(url, blacklist):
        journal.append({"tool": "fetch", "url": url, "blocked": "blacklist", "content": None})
        return json.dumps({"error": "domain blacklisted"})

    max_chars = config["limits"]["fetch_max_chars"]
    attempts = []
    for backend_cfg, limiter in fetch_backends:
        guarded = backend_cfg["type"] in ("urllib-ua", "curl-cffi")
        try:
            if guarded:
                with tool_request_guard():
                    _ssrf_precheck(url)
                    content = call_fetch_backend(backend_cfg, limiter, url, config, attempts)
            else:
                content = call_fetch_backend(backend_cfg, limiter, url, config, attempts)
        except SSRFBlocked as e:
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


# ---------------------------------------------------------------------------
# read_local tool
# ---------------------------------------------------------------------------

def do_read_local(path, offset, journal, config, local_dir):
    local_cfg = config.get("local_sources", {})
    if not local_cfg.get("enabled"):
        journal.append({"tool": "read_local", "url": f"local://{path}", "blocked": "disabled", "content": None})
        return json.dumps({"error": "local_sources disabled"})
    if not local_dir:
        journal.append({"tool": "read_local", "url": f"local://{path}", "blocked": "no_dir", "content": None})
        return json.dumps({"error": "no local_dir configured"})
    resolved = resolve_local_path(local_dir, path)
    if resolved is None or not resolved.is_file():
        journal.append({"tool": "read_local", "url": f"local://{path}", "blocked": "sandbox", "content": None})
        return json.dumps({"error": "path rejected by sandbox"})
    try:
        text = resolved.read_text(encoding="utf-8", errors="replace")
    except OSError:
        journal.append({"tool": "read_local", "url": f"local://{path}", "blocked": "read_error", "content": None})
        return json.dumps({"error": "read error"})
    offset = offset or 0
    max_chars = config["limits"]["fetch_max_chars"]
    chunk = text[offset:offset + max_chars]
    journal.append({"tool": "read_local", "url": f"local://{path}", "content": chunk})
    return chunk


def execute_tool_call(tc, search_backends, fetch_backends, journal, config, local_dir):
    fn_info = tc.get("function", {})
    name = fn_info.get("name", "")
    try:
        args = json.loads(fn_info.get("arguments") or "{}")
    except json.JSONDecodeError:
        args = {}
    if name == "search":
        return do_search(args.get("query", ""), args.get("lang", ""), search_backends, journal, config)
    if name == "fetch":
        return do_fetch(args.get("url", ""), fetch_backends, journal, config)
    if name == "read_local":
        return do_read_local(args.get("path", ""), args.get("offset", 0), journal, config, local_dir)
    return json.dumps({"error": f"unknown tool {name}"})


_PARALLEL_FETCH_MAX_WORKERS = 3


def _run_fetch_calls_parallel(tool_calls, search_backends, fetch_backends, journal, config, local_dir):
    """Only called when every tool_call in this round is a `fetch` and there
    is more than one -- mixed/search/single rounds stay on the plain
    sequential path in run_worker. Each call still runs execute_tool_call ->
    do_fetch in its own pool thread, so the SSRF guard's tool_request_guard
    (thread-local) and the guarded socket.getaddrinfo() are entered on the
    same thread that performs the actual DNS resolution -- do_fetch is the
    parallel unit, the guard is never restructured out of it.

    Returns results in the SAME ORDER as `tool_calls` (by original index),
    not completion order -- as_completed()'s arrival order would otherwise
    scramble which result_text pairs with which tool_call_id. A future that
    raises is not propagated; it is converted to a synthetic tool-error
    JSON string so every tool_call_id still gets exactly one role:tool
    message (a missing one is a 400 on most gateways)."""
    results = [None] * len(tool_calls)
    with ThreadPoolExecutor(max_workers=min(len(tool_calls), _PARALLEL_FETCH_MAX_WORKERS)) as pool:
        future_to_index = {
            pool.submit(execute_tool_call, tc, search_backends, fetch_backends, journal, config, local_dir): i
            for i, tc in enumerate(tool_calls)
        }
        for fut in as_completed(future_to_index):
            i = future_to_index[fut]
            try:
                results[i] = fut.result()
            except Exception as e:
                results[i] = json.dumps({"error": f"parallel fetch failed: {e}"})
    return results


# ---------------------------------------------------------------------------
# Backend registry (global instantiation, shared across worker threads)
# ---------------------------------------------------------------------------

def build_backends(config):
    limiters = {}

    def limiter_for(key, min_interval_s):
        if key not in limiters:
            limiters[key] = RateLimiter(min_interval_s)
        return limiters[key]

    limits = config["limits"]
    search_interval = limits["search_min_interval_s"]
    # fetch previously shared search's interval outright (wrong unit of
    # concern: search backends are quota-limited external APIs, fetch
    # backends are mostly our own outbound HTTP). Independent key with a
    # fallback to the search interval so an older config missing this key
    # still works exactly as before rather than KeyError-ing.
    fetch_interval = limits.get("fetch_min_interval_s", search_interval)

    search_backends = [(b, limiter_for(f"search:{i}", search_interval))
                        for i, b in enumerate(config.get("search_backends", []))]
    fetch_backends = [(b, limiter_for(f"fetch:{i}", fetch_interval))
                       for i, b in enumerate(config.get("fetch_backends", []))]
    return search_backends, fetch_backends


# ---------------------------------------------------------------------------
# Chat client (OpenAI-compatible gateway)
# ---------------------------------------------------------------------------

class GatewayClient:
    def __init__(self, base_url, api_key, model_id, timeout_s):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.model_id = model_id
        self.timeout_s = timeout_s

    def complete(self, messages, tools):
        url = self.base_url + "/chat/completions"
        payload = {"model": self.model_id, "messages": messages}
        if tools:
            payload["tools"] = tools
        headers = {"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"}
        return _http_json_post_with_retry(url, payload, headers, self.timeout_s,
                                           transient_backoffs=_COMPLETION_RETRY_BACKOFFS)


# ---------------------------------------------------------------------------
# Anthropic-native client (claude models only)
#
# claude models get a dedicated path to the gateway's Anthropic-native
# /messages endpoint (not the OpenAI-compatible /chat/completions used for
# gemini/gpt) so that prompt caching (cache_control) actually takes effect --
# the OpenAI-compat conversion in the gateway silently drops cache_control,
# so claude via that path never caches. This client speaks the exact same
# complete(messages, tools) -> OpenAI-shaped-dict interface as GatewayClient,
# so run_worker / judge_clusters stay identical; all protocol translation is
# confined to the pure functions below.
# ---------------------------------------------------------------------------

def _read_http_error_body(e):
    """Best-effort read of an HTTPError's response body so Anthropic's own
    error diagnostics (e.g. {"error":{"message":"messages: roles must
    alternate ..."}}) survive into the raised exception instead of being
    swallowed as a bare status code."""
    try:
        return e.read().decode("utf-8", "replace")[:800]
    except Exception:
        return "<error body unavailable>"


def _anthropic_post_with_retry(url, payload, headers, timeout, transient_backoffs=None):
    """Retry wrapper for the Anthropic /messages endpoint. Unlike the OpenAI
    gateway path, a non-transient 4xx (400/401/403/404) is NOT retried -- a
    malformed request body fails identically on a resend, so we surface the
    Anthropic error body immediately for debugging. Only 429/408/5xx and
    network-layer failures follow the transient backoff schedule. HTTPError
    is caught before URLError (its parent) so the status-bearing case isn't
    swallowed."""
    backoffs = transient_backoffs if transient_backoffs is not None else _GATEWAY_RETRY_BACKOFFS_TRANSIENT
    attempt = 0
    while True:
        attempt += 1
        try:
            return _http_json_post(url, payload, headers, timeout)
        except urllib.error.HTTPError as e:
            status = e.code
            transient = status in (429, 408) or 500 <= status < 600
            body = _read_http_error_body(e)
            if not transient:
                raise RuntimeError(f"Anthropic HTTP {status}: {body}") from e
            if attempt - 1 >= len(backoffs):
                raise RuntimeError(f"Anthropic HTTP {status} after {attempt} attempts: {body}") from e
            time.sleep(backoffs[attempt - 1])
        except (urllib.error.URLError, socket.timeout, TimeoutError, json.JSONDecodeError) as e:
            if attempt - 1 >= len(backoffs):
                raise RuntimeError(f"Anthropic network error after {attempt} attempts: {e}") from e
            time.sleep(backoffs[attempt - 1])


def _oai_tools_to_anthropic(tools):
    """OpenAI function-tool schema -> Anthropic tool schema. Returns None when
    there are no tools (judge path passes tools=None) so the caller can omit
    the field entirely rather than send tools:null / tools:[]."""
    if not tools:
        return None
    out = []
    for t in tools:
        fn = t.get("function", {})
        out.append({
            "name": fn.get("name", ""),
            "description": fn.get("description", ""),
            "input_schema": fn.get("parameters", {"type": "object", "properties": {}}),
        })
    return out


def _assistant_to_anthropic_content(msg):
    """Convert one OpenAI assistant message into an Anthropic assistant
    content-block list: leading text block (only if non-empty -- Anthropic
    rejects empty text blocks) followed by one tool_use block per tool_call.
    A plain-text assistant turn (no tool_calls) returns its string content
    directly. tool_call arguments are JSON strings (json.dumps output on the
    outbound side); json.loads restores the dict for tool_use.input, tolerant
    of a malformed/empty string."""
    tool_calls = msg.get("tool_calls") or []
    text = msg.get("content")
    if not tool_calls:
        # Plain assistant answer. Anthropic needs a non-empty content; fall
        # back to a single space if the model somehow returned empty (should
        # not happen on a no-tool turn, but never emit an empty text block).
        return text if isinstance(text, str) and text else " "
    blocks = []
    if isinstance(text, str) and text:
        blocks.append({"type": "text", "text": text})
    for tc in tool_calls:
        fn = tc.get("function", {})
        try:
            args = json.loads(fn.get("arguments") or "{}")
        except json.JSONDecodeError:
            args = {}
        blocks.append({
            "type": "tool_use",
            "id": tc.get("id", ""),
            "name": fn.get("name", ""),
            "input": args,
        })
    return blocks


def _oai_messages_to_anthropic(messages):
    """Split an OpenAI-style messages list into (system, anthropic_messages).

    - role=system  -> hoisted into the top-level `system` (concatenated if
      more than one; there is only ever one here in practice).
    - role=user    -> passed through (content is str or a content-block list).
    - role=assistant -> text + tool_use blocks (see helper).
    - role=tool    -> a tool_result block; *consecutive* tool messages are
      merged into a single user turn (Anthropic requires all tool_result
      blocks answering the previous assistant's tool_use to live in one user
      message). run_worker appends one role=tool per tool_call, so this run of
      tool messages must collapse into one user turn.

    Adjacent same-role user turns are also merged, mirroring the gateway's
    "no two consecutive user messages" constraint that append_or_merge_user
    already relies on."""
    system_parts = []
    anth = []
    i = 0
    n = len(messages)
    while i < n:
        msg = messages[i]
        role = msg.get("role")
        if role == "system":
            content = msg.get("content")
            if isinstance(content, str):
                system_parts.append(content)
            elif isinstance(content, list):
                for blk in content:
                    if isinstance(blk, dict) and blk.get("type") == "text":
                        system_parts.append(blk.get("text", ""))
            i += 1
            continue
        if role == "tool":
            # Collapse the maximal run of consecutive tool messages into one
            # user turn of tool_result blocks.
            results = []
            while i < n and messages[i].get("role") == "tool":
                tmsg = messages[i]
                results.append({
                    "type": "tool_result",
                    "tool_use_id": tmsg.get("tool_call_id", ""),
                    "content": tmsg.get("content", ""),
                })
                i += 1
            _append_user_blocks(anth, results)
            continue
        if role == "assistant":
            anth.append({"role": "assistant", "content": _assistant_to_anthropic_content(msg)})
            i += 1
            continue
        # role == user (or unknown -> treat as user)
        _append_user_blocks(anth, msg.get("content"))
        i += 1
    system = "\n\n".join(p for p in system_parts if p) if system_parts else None
    return system, anth


def _append_user_blocks(anth, content):
    """Append `content` as a user turn, merging into a trailing user turn if
    present (Anthropic rejects two consecutive user messages). `content` may
    be a str, a single block dict, or a list of blocks; the merged turn is
    normalized to a block list when mixing shapes."""
    if isinstance(content, list):
        incoming = content
    elif isinstance(content, dict):
        incoming = [content]
    elif content:  # non-empty string
        incoming = [{"type": "text", "text": content}]
    else:  # None or "" -> contribute nothing; never fabricate an empty text
        incoming = []  # block (Anthropic rejects empty text blocks -> 400)
    if not incoming:
        return
    if anth and anth[-1]["role"] == "user":
        existing = anth[-1]["content"]
        if isinstance(existing, str):
            existing = [{"type": "text", "text": existing}] if existing else []
        elif isinstance(existing, dict):
            existing = [existing]
        existing.extend(incoming)
        anth[-1]["content"] = existing
    else:
        anth.append({"role": "user", "content": incoming})


def _anthropic_resp_to_oai(resp):
    """Anthropic /messages response -> OpenAI chat-completions shape so
    _extract_message (resp["choices"][0]["message"]) and the run_worker /
    judge_clusters loops read it unchanged.

    - text blocks are concatenated into `content`.
    - tool_use blocks become OpenAI tool_calls (arguments re-serialized to a
      JSON string via json.dumps, matching what the OpenAI path produces).
    - content is a string for a text-only reply (judge / final synthesis rely
      on a str here); it is None only when the turn is purely tool_use, which
      run_worker's `message.get("content") or ""` and the inbound converter
      both tolerate.
    - stop_reason is surfaced as finish_reason for observability (e.g.
      max_tokens truncation shows up instead of silently yielding half a
      JSON blob)."""
    content_blocks = resp.get("content") or []
    text_parts = []
    tool_calls = []
    for blk in content_blocks:
        btype = blk.get("type")
        if btype == "text":
            text_parts.append(blk.get("text", ""))
        elif btype == "tool_use":
            tool_calls.append({
                "id": blk.get("id", ""),
                "type": "function",
                "function": {
                    "name": blk.get("name", ""),
                    "arguments": json.dumps(blk.get("input", {}), ensure_ascii=False),
                },
            })
    message = {"role": "assistant"}
    if tool_calls:
        message["content"] = "".join(text_parts) if text_parts else None
        message["tool_calls"] = tool_calls
    else:
        message["content"] = "".join(text_parts)
    return {
        "choices": [{"message": message, "finish_reason": resp.get("stop_reason")}],
        "usage": resp.get("usage", {}),
    }


class AnthropicGatewayClient:
    def __init__(self, base_url, api_key, model_id, timeout_s, max_tokens):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.model_id = model_id
        self.timeout_s = timeout_s
        self.max_tokens = max_tokens

    def complete(self, messages, tools):
        system, anth_messages = _oai_messages_to_anthropic(messages)
        anth_tools = _oai_tools_to_anthropic(tools)
        system = _inject_cache_control(system, anth_tools, anth_messages)
        payload = {
            "model": self.model_id,
            "max_tokens": self.max_tokens,
            "messages": anth_messages,
        }
        if system is not None:
            payload["system"] = system
        if anth_tools is not None:
            payload["tools"] = anth_tools
        url = self.base_url + "/messages"
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
            "anthropic-version": "2023-06-01",
        }
        resp = _anthropic_post_with_retry(url, payload, headers, self.timeout_s,
                                          transient_backoffs=_COMPLETION_RETRY_BACKOFFS)
        return _anthropic_resp_to_oai(resp)


_CACHE_CONTROL = {"type": "ephemeral"}
# Anthropic allows at most 4 cache breakpoints. We use 3: tools tail, system
# tail, and the last message content block (the moving conversation
# breakpoint). All use the default 5-minute TTL rather than the "1h" option:
# a worker's agentic loop and the judge call all complete well inside 5
# minutes, so the longer TTL buys nothing here while its 2x write cost and
# the unsettled beta-header requirement for "ttl":"1h" (the docs don't state
# whether it needs an anthropic-beta header) would only add risk. A
# breakpoint caches the ENTIRE prefix up to and including its block, in the
# fixed order tools -> system -> messages, so these three points let every
# turn read the whole static prefix (tools+system) plus all prior history
# from cache and pay full price only for the newest increment.


def _mark_block_list_tail(blocks):
    """Attach cache_control to the last cacheable (dict) block in a list.
    Anthropic rejects cache_control on an empty text block, so skip a tail
    block that is an empty-text block. No-op if there is no dict block."""
    for blk in reversed(blocks):
        if not isinstance(blk, dict):
            continue
        if blk.get("type") == "text" and not blk.get("text"):
            continue
        blk["cache_control"] = dict(_CACHE_CONTROL)
        return True
    return False


def _mark_message_tail(messages):
    """Move the conversation breakpoint onto the last content block of the
    last message. String content is promoted to a one-text-block list so the
    marker has somewhere to live (Anthropic accepts either shape); an empty
    string is left untouched (nothing cacheable, and an empty text block is
    rejected)."""
    if not messages:
        return
    last = messages[-1]
    content = last.get("content")
    if isinstance(content, str):
        if not content:
            return
        last["content"] = [{"type": "text", "text": content, "cache_control": dict(_CACHE_CONTROL)}]
    elif isinstance(content, list) and content:
        _mark_block_list_tail(content)


def _inject_cache_control(system, tools, messages):
    """Attach cache_control breakpoints in place for maximal prefix caching.

    cache_control cannot ride on a bare string, so a non-empty system string
    is promoted here into a single cache-marked text block list (Anthropic
    accepts system as either a string or a block list); an already-block-list
    system just gets its tail marked. Because this rewrites system, the value
    is RETURNED and AnthropicGatewayClient.complete must send the returned
    system in the payload -- tools and messages are mutated in place. An empty
    or None system is returned untouched (nothing cacheable).

    Breakpoints: tools tail + system tail (static prefix) + last message
    content block (see _mark_message_tail). Returns the (possibly rewritten)
    system value."""
    if tools:
        _mark_block_list_tail(tools)
    if isinstance(system, str) and system:
        system = [{"type": "text", "text": system, "cache_control": dict(_CACHE_CONTROL)}]
    elif isinstance(system, list) and system:
        _mark_block_list_tail(system)
    _mark_message_tail(messages)
    # Known limit: only the single moving message breakpoint is used, so if
    # one turn ever appended >=20 content blocks (Anthropic's incremental-
    # cache lookback window) the prior breakpoint would fall out of window and
    # that one turn would miss cache. In this pipeline a turn adds ~2 blocks
    # (one tool_use + one tool_result), so the window is never approached; a
    # 4th "anchor" breakpoint would only pay off with heavy parallel tool use
    # and is deliberately omitted to keep the strategy simple.
    return system


def make_client_factory(config):
    gw = config["gateway"]
    api_key = os.environ.get(gw["api_key_env"], "")
    # Chat-completion calls (panel + judge) run their own agentic reasoning
    # and can legitimately take far longer than a single search/fetch call
    # -- decoupled from limits.call_timeout_s (which bounds only the fetch/
    # search backends) so raising one doesn't silently also relax the
    # other. .get() with a default so an older config without this key
    # doesn't KeyError; it just falls back to the same default declared in
    # harvest.config.json.
    timeout = config.get("limits", {}).get("completion_timeout_s", 600)
    # Anthropic requires max_tokens; OpenAI treats it as optional so the
    # OpenAI path never set it. Read from config with a generous default so
    # large findings/judge outputs aren't truncated (truncation would surface
    # as finish_reason=max_tokens and a half-parsed JSON). Same .get()-with-
    # default back-compat pattern as completion_timeout_s.
    max_tokens = config.get("limits", {}).get("completion_max_tokens", 16384)

    def factory(model_id):
        # claude models go through the Anthropic-native /messages path so
        # prompt caching can take effect; everything else (gemini/gpt) stays
        # on the OpenAI-compatible /chat/completions gateway. Same
        # complete(messages, tools) interface either way, so run_judge_with_
        # fallback can freely mix the two client types across its candidates.
        if model_id.startswith("claude"):
            return AnthropicGatewayClient(gw["base_url"], api_key, model_id, timeout, max_tokens)
        return GatewayClient(gw["base_url"], api_key, model_id, timeout)

    return factory


# ---------------------------------------------------------------------------
# Panel worker driver
# ---------------------------------------------------------------------------

def build_system_prompt(goal_text, local_manifest, alias, max_steps):
    lines = [
        "You are one member of a multi-model research panel. Decompose the "
        "research goal independently and collect evidence with the tools.",
        "Tools: search(query, lang), fetch(url), read_local(path, offset).",
        "Hard rules:",
        "1. Never cite a URL before fetching its full text via fetch/read_local; "
        "citing a bare search snippet is forbidden.",
        "2. excerpt should quote the source's original text as closely as "
        "possible for auditability -- prefer copying from the fetched page's "
        "body content.",
        "3. Only cite URLs that appear in your tool results.",
        "4. Search in both Chinese and English for each core concept.",
        f"5. You have a budget of about {max_steps} tool-use rounds.",
        "6. Search bilingually to map sources first, then fetch the most relevant "
        "few, then STOP and output the findings JSON.",
        "7. A reliable partial result is better than being cut off empty-handed -- "
        "converge before the budget runs out rather than searching breadth-first "
        "until the wall.",
        "Final output must be exactly one JSON code block with schema: "
        '{"claims": [{"claim": "...", "excerpt": "...", "url": "...", '
        '"credibility": 1-5, "language": "zh|en|..."}], '
        '"keywords_used": {"zh": [...], "en": [...]}, "term_map": [...]}',
    ]
    if local_manifest:
        lines.append("Local internal materials (filename: first-line summary):")
        for name, summary in local_manifest:
            lines.append(f"- {name}: {summary}")
    lines.append(f"Research goal:\n{goal_text}")
    return "\n".join(lines)


def _extract_message(resp):
    try:
        return resp["choices"][0]["message"]
    except (KeyError, IndexError, TypeError):
        return None


class WorkerResult:
    def __init__(self, alias, model_id, status, findings, journal, reason=None, rejected_claims=None):
        self.alias = alias
        self.model_id = model_id
        self.status = status
        self.findings = findings
        self.journal = journal
        self.reason = reason
        self.rejected_claims = rejected_claims or []


def append_or_merge_user(messages, text):
    """Append `text` as a new user turn, unless the trailing message is
    already role=user -- gateways reject two consecutive user-role messages
    with a 400, and the parse-retry / citation-retry paths both leave a
    role=user message as the last turn, so a forced-synthesis nudge landing
    right after one of those retries must merge into it instead of piling on
    a second one. `content` on a message can be a plain string or a list of
    content blocks (multi-part messages) -- merge according to whichever
    shape is already there rather than assuming str."""
    if messages and messages[-1]["role"] == "user":
        content = messages[-1]["content"]
        if isinstance(content, list):
            content.append({"type": "text", "text": text})
        elif isinstance(content, str):
            messages[-1]["content"] = content + "\n" + text
        else:
            # Unexpected content shape -- fall back to a safe string merge
            # rather than guessing at block structure.
            messages[-1]["content"] = str(content) + "\n" + text
    else:
        messages.append({"role": "user", "content": text})


def finalize_findings(alias, model_id, data, journal):
    """Shared tail of the findings pipeline: assign per-claim IDs, verify
    every citation against the journal, and assemble the OK WorkerResult.
    Used both by the loop's normal end-of-turn finalize and by the forced-
    synthesis path after the step budget is exhausted -- both start from a
    freshly parsed findings dict and finish identically. The citation-retry
    branch (loop only, at most once per worker) runs *before* this is
    called; this function never retries, it only finalizes."""
    claims = assign_claim_ids(alias, data["claims"])
    fetch_index = build_fetch_index(journal)
    journal_urls = build_journal_url_set(journal)
    valid, invalid = validate_claims(claims, fetch_index, journal_urls)
    data["claims"] = valid
    data["invalid_claim_count"] = len(invalid)
    return WorkerResult(alias, model_id, "OK", data, journal, None, rejected_claims=build_rejected_claims(invalid))


_FORCED_SYNTHESIS_PROMPT = (
    "Tool-use budget exhausted. Based ONLY on the evidence you have already "
    "fetched, output the findings JSON now. Do not call any more tools."
)


def run_worker(alias, model_id, client, config, search_backends, fetch_backends,
                goal_text, local_manifest, local_dir):
    journal = []
    try:
        limits = config["limits"]
        max_steps = limits["max_steps_per_model"]
        deadline = time.monotonic() + limits["wall_clock_s"]
        messages = [
            {"role": "system", "content": build_system_prompt(goal_text, local_manifest, alias,
                                                                limits["max_steps_per_model"])},
            {"role": "user", "content": goal_text},
        ]
        parse_retry_used = False
        citation_retry_used = False
        for step in range(max_steps):
            if time.monotonic() > deadline:
                return WorkerResult(alias, model_id, "FAILED", None, journal, "wall_clock_exceeded")
            try:
                resp = client.complete(messages=messages, tools=TOOL_SCHEMAS)
            except Exception:
                break
            message = _extract_message(resp)
            if message is None:
                return WorkerResult(alias, model_id, "FAILED", None, journal, "bad_response")
            messages.append(message)
            tool_calls = message.get("tool_calls") or []
            if tool_calls:
                is_all_fetch = len(tool_calls) > 1 and all(
                    tc.get("function", {}).get("name") == "fetch" for tc in tool_calls
                )
                if is_all_fetch:
                    results = _run_fetch_calls_parallel(tool_calls, search_backends, fetch_backends,
                                                          journal, config, local_dir)
                    for tc, result_text in zip(tool_calls, results):
                        messages.append({"role": "tool", "tool_call_id": tc.get("id", ""), "content": result_text})
                else:
                    for tc in tool_calls:
                        result_text = execute_tool_call(tc, search_backends, fetch_backends, journal, config, local_dir)
                        messages.append({"role": "tool", "tool_call_id": tc.get("id", ""), "content": result_text})
                # Progressive budget nudges so a model that never spontaneously
                # converges (e.g. keeps searching/fetching every round) gets an
                # explicit signal before the hard cutoff. remaining==0 (the
                # loop's last iteration) is deliberately not a nudge point --
                # by the time that round's response comes back the loop is
                # already over, so there is no next turn left for the model to
                # act on it; that case is covered by the forced-synthesis
                # phase below instead.
                remaining = max_steps - (step + 1)
                if remaining == 3:
                    append_or_merge_user(messages,
                        "[BUDGET] 3 rounds remaining. Begin converging — synthesize findings from evidence already fetched.")
                elif remaining == 1:
                    append_or_merge_user(messages,
                        "[BUDGET] Last chance. Output findings JSON on your next turn or data will be lost.")
                continue

            content = message.get("content") or ""
            data, err = parse_findings_json(content)
            if err:
                if parse_retry_used:
                    return WorkerResult(alias, model_id, "FAILED", None, journal, f"parse_failed: {err}")
                parse_retry_used = True
                messages.append({"role": "user", "content": f"Invalid output: {err}. Re-output valid findings JSON."})
                continue

            claims = assign_claim_ids(alias, data["claims"])
            fetch_index = build_fetch_index(journal)
            journal_urls = build_journal_url_set(journal)
            valid, invalid = validate_claims(claims, fetch_index, journal_urls)
            if invalid and not citation_retry_used:
                citation_retry_used = True
                messages.append({"role": "user", "content": build_citation_feedback(invalid)})
                continue

            # Second pass through here (citation_retry_used already True) or
            # a first pass with zero invalid claims both fall through to the
            # same finalize call -- finalize_findings() re-runs
            # validate_claims() itself and strips per-claim rather than
            # failing the whole worker: any invalid claims still present
            # after the one nudge are dropped (counted in
            # invalid_claim_count / rejected_claims), the valid ones ship.
            # There is no path here that returns FAILED for invalid
            # citations alone.
            return finalize_findings(alias, model_id, data, journal)

        # Step budget exhausted without a normal finalize above -- rather
        # than discard every claim already fetched (the old behavior:
        # instant FAILED, throwing away real evidence and risking a
        # below-quorum panel), force one last no-tools synthesis call so
        # the worker converts whatever it already gathered into findings.
        # append_or_merge_user (not a plain append) because the last
        # message here can already be role=user -- a parse-retry or
        # citation-retry nudge that ran out of turns before the model
        # could respond to it -- and two consecutive user messages trip a
        # 400 on most gateways.
        append_or_merge_user(messages, _FORCED_SYNTHESIS_PROMPT)
        # tools=TOOL_SCHEMAS (not None) here even though the prompt forbids
        # further tool calls: keeping the tools block identical to every
        # preceding turn's payload lets the gateway's prompt cache match on
        # the unchanged prefix instead of invalidating it over a
        # tools-block diff, and Anthropic 400s if tool_use blocks already in
        # the message history aren't accompanied by a tools definition on
        # the request. The prompt text is what actually stops the model from
        # calling a tool, not the schema's absence -- so a model that ignores
        # the prompt and returns tool_calls anyway is handled below by
        # looking only at text content, never by re-dispatching those calls.
        try:
            resp = client.complete(messages=messages, tools=TOOL_SCHEMAS)
        except Exception as e:
            return WorkerResult(alias, model_id, "FAILED", None, journal,
                                f"synthesis_failed ({type(e).__name__}): {e}")
        message = _extract_message(resp)
        if message is None:
            return WorkerResult(alias, model_id, "FAILED", None, journal, "synthesis_no_response")
        content = message.get("content") or ""
        data, err = parse_findings_json(content)
        if err:
            if message.get("tool_calls"):
                # Model tried to call tools despite the prompt -- drop its
                # message from history (leaving a dangling tool_use with no
                # tool_result would 400 on the next call) and retry with a
                # forward-looking reminder rather than referencing the
                # discarded response.
                append_or_merge_user(messages,
                    "Reminder: output ONLY a JSON code block with your research findings. Do not use tools.")
            else:
                # Model produced text but it didn't parse as valid findings
                # JSON -- keep its message in history (so it can see what it
                # actually said) and feed back the concrete parse error.
                messages.append(message)
                messages.append({"role": "user", "content": f"JSON parse error: {err}. Re-output valid findings JSON."})
            try:
                resp = client.complete(messages=messages, tools=TOOL_SCHEMAS)
            except Exception as e:
                return WorkerResult(alias, model_id, "FAILED", None, journal,
                                    f"synthesis_retry_failed ({type(e).__name__}): {e}")
            message = _extract_message(resp)
            content = (message.get("content") or "") if message else ""
            data, err = parse_findings_json(content)
        if err:
            return WorkerResult(alias, model_id, "FAILED", None, journal, f"synthesis_parse_failed: {err}")
        return finalize_findings(alias, model_id, data, journal)
    except Exception as e:
        return WorkerResult(alias, model_id, "FAILED", None, journal, f"exception: {e}")


def run_panel(config, goal_text, local_manifest, local_dir, client_factory):
    search_backends, fetch_backends = build_backends(config)
    panel_models = config["panel_models"]
    quorum = config["limits"]["quorum"]
    results = []
    with ThreadPoolExecutor(max_workers=len(panel_models)) as pool:
        futures = {}
        for i, model_id in enumerate(panel_models):
            alias = f"m{i + 1}"
            client = client_factory(model_id)
            fut = pool.submit(run_worker, alias, model_id, client, config,
                               search_backends, fetch_backends, goal_text, local_manifest, local_dir)
            futures[fut] = alias
        for fut in as_completed(futures):
            alias = futures[fut]
            try:
                results.append(fut.result())
            except Exception as e:
                results.append(WorkerResult(alias, "?", "FAILED", None, [], f"executor_exception: {e}"))
    alive = [r for r in results if r.status == "OK"]
    return results, alive, len(alive) >= quorum


# ---------------------------------------------------------------------------
# Judge / merge
# ---------------------------------------------------------------------------

def judge_clusters(judge_client, worker_findings_by_alias):
    payload = {alias: {"claims": [{"id": c["_id"], "claim": c["claim"]} for c in data["claims"]]}
               for alias, data in worker_findings_by_alias.items()}
    messages = [
        {"role": "system", "content": JUDGE_SYSTEM_PROMPT},
        {"role": "user", "content": json.dumps(payload, ensure_ascii=False)},
    ]
    try:
        resp = judge_client.complete(messages=messages, tools=None)
    except Exception as e:
        return None, f"judge call failed: {e}"
    message = _extract_message(resp)
    if message is None:
        return None, "bad judge response"
    return parse_judge_json(message.get("content") or "")


def run_judge_with_fallback(config, client_factory, worker_findings_by_alias, panel_models):
    preferred = config.get("judge_model") or panel_models[0]
    candidates = list(dict.fromkeys([preferred] + list(panel_models)))
    last_err = None
    for model_id in candidates:
        client = client_factory(model_id)
        for _attempt in range(2):
            data, err = judge_clusters(client, worker_findings_by_alias)
            if data is not None:
                return data, None
            last_err = err
    return None, last_err or "all judge candidates exhausted"


def merge_findings(worker_findings_by_alias, judge_data):
    # One-claim-one-cluster is enforced here mechanically, never trusted from
    # the judge: first assignment (in judge-output cluster order) wins, any
    # later cluster claiming the same ID has that ID dropped and logged to
    # dedup_notes. The judge prompt asks for this too, but this invariant
    # must hold even if the judge ignores the instruction.
    all_claims = {}
    for alias, data in worker_findings_by_alias.items():
        for c in data["claims"]:
            all_claims[c["_id"]] = c

    clusters_out = []
    claimed_ids = set()
    dedup_notes = []
    contradictions = []
    for cluster in judge_data.get("clusters", []):
        summary = cluster.get("summary", "")
        candidate_ids = [cid for cid in cluster.get("source_claim_ids", []) if cid in all_claims]
        ids = []
        for cid in candidate_ids:
            if cid in claimed_ids:
                dedup_notes.append({"claim_id": cid, "dropped_from_cluster": summary,
                                     "reason": "claim already assigned to an earlier cluster (first assignment wins)"})
                continue
            ids.append(cid)
        if not ids:
            continue
        claimed_ids.update(ids)
        relation = cluster.get("relation", "agree")
        if relation == "contradict":
            contradictions.append(summary)
        assembled = []
        for cid in ids:
            c = all_claims[cid]
            assembled.append({
                "id": cid,
                "claim": c.get("claim", ""),
                "excerpt": c.get("excerpt", ""),
                "url": c.get("url", ""),
                "language": c.get("language", "unknown"),
                "credibility": c.get("credibility", 3),
            })
        clusters_out.append({"summary": summary, "claims": assembled})

    unique_insights = [cid for cid in judge_data.get("unique_insights", []) if cid in all_claims]
    return {
        "clusters": clusters_out,
        "coverage_gaps": judge_data.get("coverage_gaps", []),
        "unique_insights": unique_insights,
        "blind_spots": judge_data.get("blind_spots", []),
        "contradictions": contradictions,
        "dedup_notes": dedup_notes,
    }


# ---------------------------------------------------------------------------
# Verify.json (single-exit-point writer, tombstones, state cleanup)
# ---------------------------------------------------------------------------

def write_verify_json(verify_dir, goal_hash, verdict, extra=None, verify_filename=VERIFY_FILE):
    verify_dir.mkdir(parents=True, exist_ok=True)
    payload = {"verdict": verdict, "goal_file_sha256": goal_hash, "run_timestamp": time.time()}
    if extra:
        payload.update(extra)
    (verify_dir / verify_filename).write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return payload


def write_tombstone(verify_dir, goal_hash, verify_filename=VERIFY_FILE):
    return write_verify_json(verify_dir, goal_hash, "RUNNING", verify_filename=verify_filename)


def abort_unavailable(verify_dir, goal_hash, reason, extra=None, verify_filename=VERIFY_FILE):
    payload = dict(extra or {})
    payload["reason"] = reason
    write_verify_json(verify_dir, goal_hash, "UNAVAILABLE", payload, verify_filename=verify_filename)
    sys.exit(3)


def cleanup_stale_state(pipeline_dir, verify_dir, raw_dir):
    """Unconditional cleanup before any network request: a failed run must
    never let a hook read last run's stale verify.json / exemption and
    silently pass. The exemption is single-use -- rerunning run() means the
    user is re-accepting the gate for this round.

    Primary-track only: touches the main VERIFY_FILE/EXEMPTION and the main
    raw_dir's shared artifacts. A supplementary (backfill) run must never
    call this -- see cleanup_stale_supplementary_state()."""
    for f in (verify_dir / VERIFY_FILE, verify_dir / LEGACY_EXEMPTION_FILE):
        if f.exists():
            f.unlink()
    merged_file = raw_dir / MERGED_FINDINGS_FILE
    if merged_file.exists():
        merged_file.unlink()
    harvest_dir = raw_dir / HARVEST_SUBDIR
    if harvest_dir.exists():
        shutil.rmtree(harvest_dir)


def track_verify_filename(raw_dir):
    """Supplementary (backfill) runs get their own state file, named after
    the --out subdirectory they write to, instead of sharing the primary
    track's VERIFY_FILE -- see cmd_run()'s is_supplementary branch."""
    return f"track_{raw_dir.name}.json"


def cleanup_stale_supplementary_state(verify_dir, raw_dir, verify_filename):
    """Supplementary-run counterpart of cleanup_stale_state(): scoped
    strictly to this track's own state file (verify_dir/verify_filename)
    and its own --out subdirectory (raw_dir). Must never touch the primary
    track's VERIFY_FILE or LEGACY_EXEMPTION_FILE -- the main gate's
    verdict is not this run's to clear. A track rerunning itself cleans up
    only its own prior track file, so backfill runs don't accumulate
    orphaned track_*.json files across retries."""
    track_file = verify_dir / verify_filename
    if track_file.exists():
        track_file.unlink()
    merged_file = raw_dir / MERGED_FINDINGS_FILE
    if merged_file.exists():
        merged_file.unlink()
    harvest_dir = raw_dir / HARVEST_SUBDIR
    if harvest_dir.exists():
        shutil.rmtree(harvest_dir)


# ---------------------------------------------------------------------------
# check_project: three-state mechanical gate, importable with zero side effects
# ---------------------------------------------------------------------------

def check_project(project_dir):
    """Returns (verdict, reason). verdict is exactly one of "PASS"/"FAIL"/"N_A".
    CLI exit-code mapping (PASS=0, FAIL=1, N_A=2) lives in cmd_check / the
    SubagentStop hook, not here -- this is the shared contract both import."""
    project_dir = Path(project_dir)
    verify_dir = project_dir / "pipeline" / "verification"
    exemption_file = verify_dir / LEGACY_EXEMPTION_FILE
    verify_file = verify_dir / VERIFY_FILE

    # exemption priority is absolute: overrides even an UNAVAILABLE tombstone.
    if exemption_file.exists():
        return "N_A", "legacy exemption present"

    if not verify_file.exists():
        return "N_A", "harvest.py not enabled for this project"

    try:
        data = json.loads(verify_file.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as e:
        return "FAIL", f"{VERIFY_FILE} unreadable: {e}"

    verdict = data.get("verdict")
    if verdict == "UNAVAILABLE":
        return "FAIL", "multi-model harvest UNAVAILABLE: retry / fix config / or request user exemption to legacy"
    if verdict == "LOCAL":
        return "N_A", "local mode: citation verification delegated to caller"
    if verdict != "OK":
        return "FAIL", f"unknown or incomplete verdict: {verdict!r}"

    goal_note = None
    goal_file = resolve_goal_file(project_dir)
    if goal_file is not None:
        goal_hash = hashlib.sha256(goal_file.read_bytes()).hexdigest()
        if data.get("goal_file_sha256") != goal_hash:
            return "FAIL", "goal_file hash mismatch (stale harvest run)"
    else:
        # Path-convention mismatch shouldn't block the gate -- it's not
        # evidence of a stale run, just an inability to re-verify. Leave a
        # trace in the reason instead of silently passing as "ok".
        goal_note = "goal file not found, hash check skipped"

    if not data.get("quorum_met", False):
        return "FAIL", "quorum not met"

    total_claims = data.get("total_claims", 0)
    if not isinstance(total_claims, (int, float)) or isinstance(total_claims, bool) or total_claims <= 0:
        return "FAIL", f"zero or invalid total_claims: {total_claims!r}"

    invalid_rate = data.get("invalid_citation_rate", 0.0)
    if not isinstance(invalid_rate, (int, float)) or isinstance(invalid_rate, bool):
        return "FAIL", f"invalid_citation_rate has unexpected type: {invalid_rate!r}"
    invalid_count = data.get("invalid_claim_count", 0)
    if not isinstance(invalid_count, (int, float)) or isinstance(invalid_count, bool):
        return "FAIL", f"invalid_claim_count has unexpected type: {invalid_count!r}"
    # A single isolated rejection (already caught by retry, already excluded
    # from the merged output) can blow the 5% rate on a small-claims run
    # without being systematic fabrication -- the gate's intent is to catch
    # the latter, not to flag noise. Require both a rate breach *and* at
    # least 2 rejected claims before failing.
    if invalid_count >= 2 and invalid_rate > 0.05:
        return "FAIL", f"invalid_citation_rate {invalid_rate} exceeds 0.05 with {invalid_count} rejected claims"

    return "PASS", goal_note or "ok"


# ---------------------------------------------------------------------------
# Local materials manifest / fetch-report
# ---------------------------------------------------------------------------

_LOCAL_EXTS = (".md", ".txt", ".csv", ".json", ".html")


def build_local_manifest(local_dir, config):
    if not local_dir:
        return []
    base = Path(local_dir)
    if not base.exists():
        return []
    manifest = []
    for p in sorted(base.rglob("*")):
        if p.is_file() and p.suffix.lower() in _LOCAL_EXTS:
            try:
                first_line = p.read_text(encoding="utf-8", errors="replace").splitlines()[0][:200]
            except (OSError, IndexError):
                first_line = ""
            manifest.append((str(p.relative_to(base)), first_line))
    return manifest


def count_blacklist_hits(results):
    """Real count from the three workers' journals -- distinct from the
    domain blacklist logic itself, this only tallies what fetch already
    recorded as blocked=blacklist entries."""
    hits = []
    for r in results:
        for entry in r.journal:
            if entry.get("blocked") == "blacklist":
                hits.append(entry.get("url", ""))
    return hits


def detect_research_type(goal_text):
    """Best-effort scan of goal-file text for an explicit type declaration
    (repo convention: research-goal.md states research type as selection or
    non-selection -- see research-harvester.md / quality-gates.md). Checks
    non-selection first since it's a substring superset of "selection".
    Returns "selection" / "non-selection" / None (undetermined)."""
    if not goal_text:
        return None
    text = goal_text.lower()
    if re.search(r'non[-_ ]?selection', text):
        return "non-selection"
    if re.search(r'\bselection\b', text):
        return "selection"
    return None


def write_fetch_report(raw_dir, results, alive, invalid_total, invalid_rate, local_manifest, goal_text="", quorum_required=2):
    lines = ["# Fetch Report - Multi-Model Harvest", "", "## 采集统计", f"- 总请求数: {len(results)}"]
    for r in results:
        lines.append(f"- {r.alias} ({r.model_id}): status={r.status} reason={r.reason or '-'}")
    lines += ["", "## 翻页统计", "- N/A（多模型采集不分页）", "", "## 中英文覆盖"]
    zh_terms, en_terms = [], []
    for r in alive:
        kw = (r.findings or {}).get("keywords_used", {})
        zh_terms.extend(kw.get("zh", []))
        en_terms.extend(kw.get("en", []))
    lines.append(f"- 中文搜索词: {sorted(set(zh_terms))}")
    lines.append(f"- 英文搜索词: {sorted(set(en_terms))}")
    blacklist_hits = count_blacklist_hits(results)
    research_type = detect_research_type(goal_text)
    if research_type == "non-selection":
        candidate_line = "- N/A（non-selection）"
    elif research_type == "selection":
        candidate_line = "- PENDING——harvester 须补填（selection 类必填）"
    else:
        candidate_line = "- PENDING——由 harvester 按 research-goal 类型判定后补填（selection 类必填）"
    lines += ["", "## 候选集完备性", candidate_line,
              "", "## 错误汇总", f"- 屏蔽源命中: {len(blacklist_hits)}"]
    if blacklist_hits:
        lines.append(f"  - 列表: {blacklist_hits}")
    lines.append("")
    lines.append("## 多模型参与情况")
    lines.append(f"- 参与模型: {[r.alias for r in alive]}")
    lines.append(f"- 法定人数状态: {'met' if len(alive) >= quorum_required else 'not met'}")
    per_model_invalid = {r.alias: len(r.rejected_claims) for r in alive}
    reason_counts = {}
    for r in alive:
        for rc in r.rejected_claims:
            reason_counts[rc["reject_reason"]] = reason_counts.get(rc["reject_reason"], 0) + 1
    lines += ["", "## 引用校验统计", f"- INVALID 计数: {invalid_total}", f"- INVALID 率: {invalid_rate:.4f}",
              f"- 按模型分布: {per_model_invalid}", f"- 按 reject_reason 分布: {reason_counts}", ""]
    lines.append("## 本地材料清单")
    if local_manifest:
        for name, summary in local_manifest:
            lines.append(f"- {name}: {summary}")
    else:
        lines.append("- 无")
    (raw_dir / "fetch-report.md").write_text("\n".join(lines), encoding="utf-8")


def write_fetch_report_local(raw_dir, queries, fetched_pages, journal, goal_text):
    """Local-mode counterpart of write_fetch_report(): no panel/judge/
    citation-verification stats exist yet in this mode (verify-local runs
    later, out-of-process), so the report only records what search+fetch
    actually did."""
    lines = [
        "# Fetch Report (Local Mode)\n",
        "## 采集统计",
        f"- 搜索查询数: {len(queries)}",
        f"- 成功抓取页面: {len(fetched_pages)}",
        f"- 总内容字符数: {sum(p['chars'] for p in fetched_pages)}",
        "",
        "## 多模型参与情况",
        "- N/A (local mode, single-agent)",
        "",
        "## 引用校验统计",
        "- delegated to caller (verify-local subcommand)",
        "",
        "## 搜索查询",
    ]
    for q in queries:
        lines.append(f"- {q}")
    lines.append("")
    lines.append("## 抓取页面")
    for p in fetched_pages:
        lines.append(f"- [{p['title'] or p['url']}]({p['url']}) ({p['chars']} chars)")

    (raw_dir / "fetch-report.md").write_text("\n".join(lines), encoding="utf-8")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def load_config(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _read_queries_json(path):
    """Read and validate queries from a JSON file or stdin ("-") for local
    mode. The caller (not an LLM panel) supplies the queries directly, so
    this is the only place that shapes/validates that input."""
    try:
        if path == "-":
            raw = sys.stdin.read()
        else:
            raw = Path(path).read_text(encoding="utf-8")
    except FileNotFoundError:
        print(f"error: queries file not found: {path}", file=sys.stderr)
        sys.exit(1)
    except OSError as e:
        print(f"error: cannot read queries file: {e}", file=sys.stderr)
        sys.exit(1)
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"error: invalid JSON in queries file: {e}", file=sys.stderr)
        sys.exit(1)
    queries = data.get("queries") if isinstance(data, dict) else None
    if not isinstance(queries, list) or not queries:
        print('error: queries file must contain a non-empty list in {"queries": [...]}', file=sys.stderr)
        sys.exit(1)
    return queries


def cmd_run_local(args, config):
    """Local mode: search + fetch only, no LLM gateway calls at all -- the
    caller (e.g. an interactive agent) supplies queries directly and does
    its own reasoning/citation over the fetched pages. Reuses the same
    project/goal/state-file plumbing as cmd_run() so check_project() and the
    on-disk layout stay uniform between the two modes; citation
    verification is deferred to the separate `verify-local` subcommand
    since there are no panel-produced claims to verify here."""
    raw_dir = Path(args.out)
    project_dir_arg = getattr(args, "project_dir", None)
    if project_dir_arg:
        project_dir = Path(project_dir_arg).resolve()
        pipeline_dir = project_dir / "pipeline"
        verify_dir = pipeline_dir / "verification"
    else:
        pipeline_dir = raw_dir.parent
        project_dir = pipeline_dir.parent
        verify_dir = pipeline_dir / "verification"

    canonical_goal_file = resolve_goal_file(project_dir)
    if canonical_goal_file is None:
        print(f"error: no goal file found under {project_dir} "
              f"(checked {GOAL_FILE_CONVENTIONAL_DIR}/{GOAL_FILE_NAME} and {GOAL_FILE_NAME}); "
              "a goal file is required before running harvest", file=sys.stderr)
        sys.exit(1)

    goal_path = Path(args.goal_file).resolve()
    canonical_goal_file = canonical_goal_file.resolve()
    if goal_path != canonical_goal_file:
        print(f"error: --goal-file {goal_path} does not match the conventionally-resolved "
              f"goal file {canonical_goal_file} for this project; pass the canonical path so "
              "goal_file_sha256 is anchored to the text harvest actually runs on", file=sys.stderr)
        sys.exit(1)

    goal_text = canonical_goal_file.read_text(encoding="utf-8")
    goal_hash = hashlib.sha256(canonical_goal_file.read_bytes()).hexdigest()

    cleanup_stale_state(pipeline_dir, verify_dir, raw_dir)
    write_tombstone(verify_dir, goal_hash)

    install_ssrf_guard()

    queries = _read_queries_json(args.queries_json)
    search_backends, fetch_backends = build_backends(config)

    journal = []
    all_urls = []
    for query in queries:
        result_json = do_search(query, "auto", search_backends, journal, config)
        results = json.loads(result_json).get("results", [])
        for r in results:
            all_urls.append((r["url"], r.get("title", "")))

    url_counts = Counter(url for url, _ in all_urls)
    seen = set()
    ranked = []
    for url, title in all_urls:
        if url not in seen:
            seen.add(url)
            ranked.append({"url": url, "title": title, "count": url_counts[url]})
    ranked.sort(key=lambda x: x["count"], reverse=True)

    max_fetch = config.get("limits", {}).get("max_fetch_urls", 15)
    top_urls = ranked[:max_fetch]
    if not top_urls:
        print("error: all searches returned no usable URLs", file=sys.stderr)
        abort_unavailable(verify_dir, goal_hash, "no usable URLs from search")

    fetched_pages = []
    harvest_dir = raw_dir / HARVEST_SUBDIR / "local"
    fetched_dir = harvest_dir / "fetched"
    fetched_dir.mkdir(parents=True, exist_ok=True)

    for i, item in enumerate(top_urls):
        # do_fetch returns the raw truncated content string on success, or a
        # json.dumps({"error": ...}) string on failure -- sniffing the return
        # value itself is ambiguous (fetched prose can legitimately start
        # with "{"), so read the journal entry do_fetch just appended
        # instead; its "content" field uses the same None-on-failure
        # convention build_fetch_index() already relies on elsewhere.
        do_fetch(item["url"], fetch_backends, journal, config)
        content = journal[-1].get("content")
        if content:
            page_file = fetched_dir / f"page_{i + 1:03d}.txt"
            page_file.write_text(content, encoding="utf-8")
            fetched_pages.append({
                "url": item["url"],
                "title": item["title"],
                "content_path": str(page_file.relative_to(raw_dir)),
                "chars": len(content),
            })

    if not fetched_pages:
        print("error: all fetches failed", file=sys.stderr)
        abort_unavailable(verify_dir, goal_hash, "all fetches failed")

    harvest_dir.mkdir(parents=True, exist_ok=True)

    with (harvest_dir / "journal_local.jsonl").open("w", encoding="utf-8") as f:
        for entry in journal:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")

    (harvest_dir / "findings.json").write_text(
        json.dumps({"claims": [], "status": "LOCAL_DELEGATE", "mode": "local"}, indent=2),
        encoding="utf-8")

    manifest = {
        "mode": "local",
        "timestamp": time.time(),
        "goal_hash": goal_hash,
        "queries": queries,
        "fetched_pages": fetched_pages,
        "stats": {
            "queries_executed": len(queries),
            "pages_fetched": len(fetched_pages),
            "total_content_chars": sum(p["chars"] for p in fetched_pages),
        },
    }
    raw_dir.mkdir(parents=True, exist_ok=True)
    (raw_dir / "harvest-local.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")

    (raw_dir / MERGED_FINDINGS_FILE).write_text(
        json.dumps({"clusters": [], "coverage_gaps": [], "mode": "local", "delegate": True},
                   ensure_ascii=False, indent=2), encoding="utf-8")

    write_fetch_report_local(raw_dir, queries, fetched_pages, journal, goal_text)

    write_verify_json(verify_dir, goal_hash, "LOCAL", {
        "mode": "local",
        "pages_fetched": len(fetched_pages),
        "queries_executed": len(queries),
    })

    print(f"harvest local mode complete: {len(fetched_pages)} pages fetched")


def cmd_run(args):
    config = load_config(args.config)
    _check_curl_cffi_available(config)

    # getattr(...) rather than args.no_api/args.queries_json: same
    # back-compat rationale as args.project_dir above -- older test/caller
    # code building an args namespace without these new attributes must
    # keep working, taking the normal-mode path unchanged.
    no_api = getattr(args, "no_api", False)
    queries_json = getattr(args, "queries_json", None)
    if no_api:
        if not queries_json:
            print("error: local mode requires --queries-json", file=sys.stderr)
            sys.exit(1)
        cmd_run_local(args, config)
        return
    gw_api_key_env = config.get("gateway", {}).get("api_key_env", "")
    has_gateway_key = bool(os.environ.get(gw_api_key_env, ""))
    if not has_gateway_key:
        print("error: Gateway API key missing. To run in local mode, pass "
              "--no-api --queries-json <file>.", file=sys.stderr)
        sys.exit(3)

    raw_dir = Path(args.out)
    # getattr(...) rather than args.project_dir: keeps this importable by
    # older test/caller code that builds an args namespace without the new
    # attribute at all.
    project_dir_arg = getattr(args, "project_dir", None)
    if project_dir_arg:
        # Explicit --project-dir: pipeline_dir/verify_dir are re-anchored to
        # it directly, never derived from raw_dir. This is what makes a
        # supplementary run's --out (a subdirectory, e.g.
        # pipeline/1_raw/track_A) safe -- the old raw_dir.parent/.parent
        # derivation assumed --out was always exactly ".../pipeline/1_raw"
        # and silently miscomputed project_dir for anything nested deeper.
        project_dir = Path(project_dir_arg).resolve()
        pipeline_dir = project_dir / "pipeline"
        verify_dir = pipeline_dir / "verification"
        # Supplementary (backfill) run iff --out isn't the canonical primary
        # raw dir -- e.g. a subdirectory of it used to re-collect specific
        # coverage_gaps without disturbing the main track's state.
        is_supplementary = raw_dir.resolve() != (pipeline_dir / "1_raw").resolve()
    else:
        # Unchanged legacy derivation -- zero behavior change for existing
        # callers that never pass --project-dir.
        pipeline_dir = raw_dir.parent
        project_dir = pipeline_dir.parent
        verify_dir = pipeline_dir / "verification"
        is_supplementary = False

    # Supplementary runs get their own state file (track_<out-dir-name>.json)
    # so they never overwrite the primary track's gate verdict; the primary
    # gate (check_project()) only ever reads VERIFY_FILE.
    verify_filename = track_verify_filename(raw_dir) if is_supplementary else VERIFY_FILE

    # canonical_goal_file (single shared resolver, same one check_project()
    # uses) is the sole source of truth for both the hash and the text that
    # actually drives the panel -- run and check must never anchor
    # goal_file_sha256 to a different file than the one the run text came
    # from, or the audit trail lies about what was researched.
    canonical_goal_file = resolve_goal_file(project_dir)
    if canonical_goal_file is None:
        print(f"error: no goal file found under {project_dir} "
              f"(checked {GOAL_FILE_CONVENTIONAL_DIR}/{GOAL_FILE_NAME} and {GOAL_FILE_NAME}); "
              "a goal file is required before running harvest", file=sys.stderr)
        sys.exit(1)

    goal_path = Path(args.goal_file).resolve()
    canonical_goal_file = canonical_goal_file.resolve()
    if is_supplementary:
        # Framework principle 6: one project = 1 primary track + N
        # supplementary tracks, each a deep-dive into a DIFFERENT sub-question
        # with its own goal text and independent gate. A backfill run may
        # therefore run on its own goal-file rather than the canonical
        # research-goal.md -- goal_file_sha256 anchors to THAT file (recorded
        # in this track's own track_<out>.json), so the audit trail still
        # names the exact text the panel ran on, just not the canonical one.
        # The relaxation is bounded: the supplementary goal-file must exist
        # and live inside the project tree, so the anchor is always a
        # project-tracked artifact, never an arbitrary path on disk.
        if not goal_path.exists():
            print(f"error: --goal-file {goal_path} does not exist", file=sys.stderr)
            sys.exit(1)
        # goal_path and project_dir are both already .resolve()-d above;
        # reuse the existing sandbox helper rather than a near-duplicate.
        if not _is_relative_to(goal_path, project_dir):
            print(f"error: supplementary --goal-file {goal_path} is outside the project "
                  f"directory {project_dir}; a supplementary track's goal file must live "
                  "inside the project so goal_file_sha256 anchors to a project-tracked "
                  "artifact", file=sys.stderr)
            sys.exit(1)
        run_goal_file = goal_path
    else:
        # Primary track: goal-file must be the canonical research-goal.md, or
        # the panel would run on CLI-supplied text while goal_file_sha256 gets
        # anchored to a different file -- the audit trail would lie about what
        # was researched (#25). Unchanged hard check.
        if goal_path != canonical_goal_file:
            print(f"error: --goal-file {goal_path} does not match the conventionally-resolved "
                  f"goal file {canonical_goal_file} for this project; pass the canonical path so "
                  "goal_file_sha256 is anchored to the text harvest actually runs on", file=sys.stderr)
            sys.exit(1)
        run_goal_file = canonical_goal_file

    goal_text = run_goal_file.read_text(encoding="utf-8")
    goal_hash = hashlib.sha256(run_goal_file.read_bytes()).hexdigest()

    if is_supplementary:
        # Never cleanup_stale_state() here -- that function unconditionally
        # unlinks the PRIMARY VERIFY_FILE/EXEMPTION, which would erase the
        # main track's already-recorded gate verdict. Scoped equivalent
        # touches only this track's own state file + its own --out dir.
        cleanup_stale_supplementary_state(verify_dir, raw_dir, verify_filename)
    else:
        cleanup_stale_state(pipeline_dir, verify_dir, raw_dir)
    write_tombstone(verify_dir, goal_hash, verify_filename=verify_filename)

    try:
        install_ssrf_guard()

        # Fall back to the config-declared convention dir when the CLI flag
        # is omitted, so "local_sources.enabled: true" doesn't silently
        # no-op just because --local-dir wasn't also passed. A relative
        # path is resolved against project_dir either way (not the
        # invocation's CWD) so behavior doesn't depend on where the
        # command happens to be run from.
        local_dir = args.local_dir or config.get("local_sources", {}).get("dir")
        if local_dir:
            local_path = Path(local_dir)
            local_dir = str(local_path if local_path.is_absolute() else project_dir / local_path)
        local_manifest = []
        if local_dir and config.get("local_sources", {}).get("enabled"):
            local_manifest = build_local_manifest(local_dir, config)

        client_factory = make_client_factory(config)
        results, alive, quorum_met = run_panel(config, goal_text, local_manifest, local_dir, client_factory)

        harvest_dir = raw_dir / HARVEST_SUBDIR
        harvest_dir.mkdir(parents=True, exist_ok=True)
        for r in results:
            model_dir = harvest_dir / r.alias
            model_dir.mkdir(parents=True, exist_ok=True)
            findings_out = r.findings if r.findings is not None else {"claims": [], "status": r.status, "reason": r.reason}
            (model_dir / "findings.json").write_text(json.dumps(findings_out, ensure_ascii=False, indent=2), encoding="utf-8")
            with (model_dir / f"journal_{r.alias}.jsonl").open("w", encoding="utf-8") as f:
                for entry in r.journal:
                    f.write(json.dumps(entry, ensure_ascii=False) + "\n")
            (model_dir / "rejected_claims.json").write_text(
                json.dumps(r.rejected_claims, ensure_ascii=False, indent=2), encoding="utf-8")

        if not quorum_met:
            abort_unavailable(verify_dir, goal_hash, "quorum not met",
                               {"quorum_met": False, "models_alive": [r.alias for r in alive]},
                               verify_filename=verify_filename)

        worker_findings_by_alias = {r.alias: r.findings for r in alive}
        judge_data, judge_err = run_judge_with_fallback(config, client_factory, worker_findings_by_alias, config["panel_models"])
        if judge_data is None:
            abort_unavailable(verify_dir, goal_hash, f"judge failed: {judge_err}",
                               {"quorum_met": True, "models_alive": [r.alias for r in alive]},
                               verify_filename=verify_filename)

        merged = merge_findings(worker_findings_by_alias, judge_data)

        total_claims = sum(len(d["claims"]) for d in worker_findings_by_alias.values())
        invalid_total = sum(r.findings.get("invalid_claim_count", 0) for r in alive)
        denom = total_claims + invalid_total
        invalid_rate = (invalid_total / denom) if denom > 0 else 0.0

        if total_claims == 0:
            abort_unavailable(verify_dir, goal_hash, "quorum met but zero valid claims",
                               verify_filename=verify_filename)

        raw_dir.mkdir(parents=True, exist_ok=True)
        (raw_dir / MERGED_FINDINGS_FILE).write_text(json.dumps(merged, ensure_ascii=False, indent=2), encoding="utf-8")
        write_fetch_report(raw_dir, results, alive, invalid_total, invalid_rate, local_manifest, goal_text,
                            quorum_required=config["limits"]["quorum"])

        verdict = "OK"
        write_verify_json(verify_dir, goal_hash, verdict, {
            "quorum_met": quorum_met,
            "models_alive": [r.alias for r in alive],
            "invalid_citation_rate": invalid_rate,
            "invalid_claim_count": invalid_total,
            "total_claims": total_claims,
        }, verify_filename=verify_filename)
        print(f"harvest run complete: verdict={verdict}")
    except SystemExit:
        raise
    except Exception as e:
        abort_unavailable(verify_dir, goal_hash, f"unexpected error: {e}", verify_filename=verify_filename)


_VERDICT_EXIT_CODES = {"PASS": 0, "FAIL": 1, "N_A": 2}


def cmd_check(args):
    verdict, reason = check_project(args.project_dir)
    print(f"{verdict}: {reason}")
    sys.exit(_VERDICT_EXIT_CODES[verdict])


def cmd_verify_local(args):
    """Deterministic citation verification for local-mode claims: no LLM
    judgment, just a set-membership check of each claim's URL (normalized)
    against the manifest's fetched_pages -- the same URL-level trust model
    validate_claims() applies to panel-produced claims, just running
    out-of-process against caller-supplied claims instead of a journal."""
    try:
        claims_raw = Path(args.claims).read_text(encoding="utf-8")
    except FileNotFoundError:
        print(f"error: claims file not found: {args.claims}", file=sys.stderr)
        sys.exit(1)
    except OSError as e:
        print(f"error: cannot read claims file: {e}", file=sys.stderr)
        sys.exit(1)
    try:
        claims = json.loads(claims_raw)
    except json.JSONDecodeError as e:
        print(f"error: invalid JSON in claims file: {e}", file=sys.stderr)
        sys.exit(1)
    if not isinstance(claims, list):
        print("error: claims must be a list of objects with 'url' field", file=sys.stderr)
        sys.exit(1)
    for i, c in enumerate(claims):
        if not isinstance(c, dict) or not isinstance(c.get("url"), str):
            print(f"error: claims[{i}] must be an object with a string 'url' field", file=sys.stderr)
            sys.exit(1)

    try:
        manifest_raw = Path(args.manifest).read_text(encoding="utf-8")
    except FileNotFoundError:
        print(f"error: manifest file not found: {args.manifest}", file=sys.stderr)
        sys.exit(1)
    except OSError as e:
        print(f"error: cannot read manifest file: {e}", file=sys.stderr)
        sys.exit(1)
    try:
        manifest = json.loads(manifest_raw)
    except json.JSONDecodeError as e:
        print(f"error: invalid JSON in manifest file: {e}", file=sys.stderr)
        sys.exit(1)

    fetched_urls = set()
    for page in manifest.get("fetched_pages", []):
        url = page.get("url", "")
        if url:
            fetched_urls.add(normalize_url(url))

    valid, invalid = [], []
    for c in claims:
        normalized = normalize_url(c["url"])
        if normalized in fetched_urls:
            valid.append(c)
        else:
            invalid.append({"claim": c.get("claim", ""), "url": c["url"],
                             "reject_reason": "url_not_in_fetched_pages"})

    total = len(valid) + len(invalid)
    invalid_rate = len(invalid) / total if total > 0 else 0.0

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    (out_dir / "rejected_claims.json").write_text(
        json.dumps(invalid, ensure_ascii=False, indent=2), encoding="utf-8")

    if len(valid) == 0 or invalid_rate > 0.05:
        verdict = "UNAVAILABLE"
        reason = f"invalid_rate={invalid_rate:.2%}, valid={len(valid)}, invalid={len(invalid)}"
    else:
        verdict = "OK"
        reason = None

    goal_hash = manifest.get("goal_hash", "")
    payload = {
        "mode": "local",
        "invalid_citation_rate": invalid_rate,
        "invalid_claim_count": len(invalid),
        "total_claims": total,
    }
    if reason:
        payload["reason"] = reason
    write_verify_json(out_dir, goal_hash, verdict, payload)

    if verdict == "OK":
        print(f"verify-local: PASS (valid={len(valid)}, invalid={len(invalid)}, rate={invalid_rate:.2%})")
        sys.exit(0)
    else:
        print(f"verify-local: FAIL ({reason})", file=sys.stderr)
        sys.exit(1)


def build_arg_parser():
    parser = argparse.ArgumentParser(prog="harvest.py")
    sub = parser.add_subparsers(dest="command", required=True)

    run_p = sub.add_parser("run")
    run_p.add_argument("--goal-file", required=True)
    run_p.add_argument("--out", required=True)
    run_p.add_argument("--config", default=str(Path(__file__).with_name("harvest.config.json")))
    run_p.add_argument("--local-dir", default=None)
    run_p.add_argument("--project-dir", default=None,
                        help="Explicit project root; pipeline_dir/verify_dir are anchored to it "
                             "instead of being derived from --out's parent directories. Required "
                             "for a supplementary/backfill run where --out is a subdirectory of "
                             "the primary pipeline/1_raw (otherwise the old raw_dir.parent.parent "
                             "derivation miscomputes the project root).")
    run_p.add_argument("--no-api", action="store_true",
                        help="Local mode: search+fetch only via this script's backends, no LLM "
                             "gateway calls. Requires --queries-json; citation verification is "
                             "deferred to the separate verify-local subcommand.")
    run_p.add_argument("--queries-json", default=None,
                        help="Path to a JSON file (or '-' for stdin) with {\"queries\": [...]}, "
                             "required when --no-api is set.")
    run_p.set_defaults(func=cmd_run)

    check_p = sub.add_parser("check")
    check_p.add_argument("project_dir")
    check_p.set_defaults(func=cmd_check)

    verify_local_p = sub.add_parser("verify-local")
    verify_local_p.add_argument("--claims", required=True)
    verify_local_p.add_argument("--manifest", required=True)
    verify_local_p.add_argument("--out", required=True)
    verify_local_p.set_defaults(func=cmd_verify_local)

    return parser


def main():
    parser = build_arg_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
