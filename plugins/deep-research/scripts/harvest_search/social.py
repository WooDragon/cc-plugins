"""harvest_search.social - social-media search as an independent, degradable
tool chain, distinct from the general web-search chain in harvest_search's
own do_search(). Mirrors do_search's first-success-across-backends shape,
but never blocks the panel worker: an empty/misconfigured social chain, or
every backend failing, degrades to an error-carrying JSON payload rather
than raising -- exactly like do_search's own "all search backends failed"
tail, just under its own tool name (search_social) so it can be routed,
config'd, and journaled independently of web search.

Only one backend type exists today (grok-x, X/Twitter search via the local
grok CLI), but the chain shape is deliberately backend-agnostic so a future
second social backend (e.g. a different platform or provider) slots in next
to it without a call_social_backend rewrite.

Journal entries from this module record `"tool": "search_social"` (not
"search") so a journal reader can tell a social-search hit apart from a
general web-search hit -- harvest.build_journal_url_set explicitly
recognizes both tool names when collecting "urls the model has seen" (see
that function's docstring), so this distinction doesn't change what counts
as journaled for citation-verification purposes.
"""
import json
import urllib.parse

import harvest_safety
from harvest_clients.grok_exec import run_grok_plain, parse_embedded_json

# Query text is untrusted (model-controlled) input embedded directly into a
# CLI prompt -- bounded to a sane length so a pathological/adversarial query
# can't blow up the prompt size or grok's own context budget.
_MAX_QUERY_LEN = 500

_GROK_X_ALLOWED_HOSTS = {"x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"}

_GROK_X_PROMPT_TEMPLATE = (
    "搜索 X/Twitter 上关于「{query}」的讨论，尽量一次合并关键词减少往返；"
    "只返回实际搜到的帖子，不编造；只输出一个 JSON 对象 "
    '{{"results":[{{"url":"...","title":"...","snippet":"..."}}]}}，'
    "不要前置空对象/markdown/解释文本。"
)


def _search_grok_x(cfg, query, timeout):
    model = cfg.get("model", "grok-4.5")
    effort = cfg.get("effort", "low")
    prompt = _GROK_X_PROMPT_TEMPLATE.format(query=query[:_MAX_QUERY_LEN])
    stdout_text = run_grok_plain(prompt, model, effort, timeout, rules=None)
    parsed = parse_embedded_json(stdout_text)
    items = parsed.get("results") if isinstance(parsed, dict) else None
    if not isinstance(items, list):
        return None, "grok-x: no 'results' array in output"

    filtered = []
    for item in items:
        if not isinstance(item, dict):
            continue
        url = item.get("url") or ""
        if not isinstance(url, str) or not url:
            continue
        url = url.strip()
        # Lowercase-copy check only, so the scheme test never mutates/loses
        # the original casing of a url that already had a scheme.
        if not url.lower().startswith(("http://", "https://")):
            candidate = "https://" + url
        else:
            candidate = url
        host = (urllib.parse.urlsplit(candidate).hostname or "").lower().rstrip(".")
        if host not in _GROK_X_ALLOWED_HOSTS:
            continue
        filtered.append({"url": candidate, "title": item.get("title", ""), "snippet": item.get("snippet", "")})

    if not filtered:
        return None, "grok-x: no x.com/twitter.com results after domain filtering"
    return filtered, None


def call_social_backend(backend_cfg, limiter, query, timeout):
    """Dispatch by backend type and always return (results_or_None, reason).
    This is the terminus for exceptions raised by the underlying CLI/HTTP
    call (including grok_exec.run_grok_plain's FileNotFoundError/RuntimeError)
    -- a social backend failing must never propagate up into do_social_search
    and take down the whole search_social tool call."""
    limiter.acquire()
    btype = backend_cfg.get("type")
    try:
        if btype == "grok-x":
            return _search_grok_x(backend_cfg, query, timeout)
        return None, f"unknown social backend type: {btype}"
    except Exception as e:
        return None, f"{btype}: unexpected error: {e}"


def do_social_search(query, lang, social_backends, journal, config):
    if not social_backends:
        return json.dumps({"error": "social search is not configured"})

    blacklist = config.get("blacklist_domains", [])
    timeout = config.get("limits", {}).get("call_timeout_s", 180)
    attempts = []
    for backend_cfg, limiter in social_backends:
        backend_timeout = backend_cfg.get("timeout_s", timeout)
        results, reason = call_social_backend(backend_cfg, limiter, query, backend_timeout)
        if not results:
            attempts.append({"backend": backend_cfg.get("type"), "error": reason or "no results"})
            continue
        filtered = [r for r in results if not harvest_safety.is_blacklisted(r["url"], blacklist)]
        if not filtered:
            attempts.append({"backend": backend_cfg.get("type"), "error": "all results filtered by blacklist"})
            continue
        journal.append({"tool": "search_social", "query": query, "lang": lang,
                         "backend": backend_cfg.get("type"), "urls": [r["url"] for r in filtered],
                         "attempts": attempts})
        return json.dumps({"results": filtered}, ensure_ascii=False)

    journal.append({"tool": "search_social", "query": query, "lang": lang, "backend": None, "urls": [], "attempts": attempts})
    reasons = "; ".join(a["error"] for a in attempts) if attempts else "no backends attempted"
    return json.dumps({"results": [], "error": f"all social backends failed: {reasons}"}, ensure_ascii=False)
