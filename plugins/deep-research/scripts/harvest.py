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
import contextlib
import gzip
import hashlib
import html
import http.client
import ipaddress
import json
import os
import re
import shutil
import socket
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

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
        "name": "search_social",
        "description": "Search social media for community opinions/discussion "
                        "(e.g. X/Twitter), as a reference frame distinct from general web search.",
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


_progress_lock = threading.Lock()


def _emit(event, **kw):
    """Thread-safe NDJSON progress line to stderr. Never raises."""
    try:
        kw["event"] = event
        kw["t"] = round(time.time(), 1)
        line = json.dumps(kw, default=str)
        with _progress_lock:
            sys.stderr.write(line + "\n")
            sys.stderr.flush()
    except Exception:
        pass


import harvest_handoff
from harvest_safety import (  # re-export: safety layer moved to its own module
    RateLimiter,
    SSRFBlocked,
    install_ssrf_guard,
    tool_request_guard,
    _ssrf_validate_and_resolve,
    _ssrf_precheck,
    is_blacklisted,
    _is_relative_to,
    normalize_url,
    _guarded_getaddrinfo,
)

from _sanitize import sanitize_text  # anti-injection cleaner shared with render.py


def resolve_local_path(local_dir, rel_path):
    """Sandbox check on the *resolved* final path, not the join operation --
    catches '../', absolute paths, and literal '~' alike."""
    base = Path(local_dir).resolve()
    target = (base / rel_path).resolve()
    if not _is_relative_to(target, base):
        return None
    return target


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
    # "search_social" is harvest_search.social's own journal tool name
    # (distinct from plain web "search" so a journal reader can tell social
    # hits apart from web hits) -- it's recognized here alongside "search"
    # so a social-search url still counts as "seen" and a claim citing it
    # still needs an explicit fetch/read_local before it can be considered
    # actually retrieved; see build_fetch_index, which intentionally does
    # NOT recognize search_social (or search) at all.
    urls = set()
    for entry in journal:
        if entry.get("tool") in ("search", "search_social"):
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
# HTTP/SSE/client infrastructure -- extracted to harvest_clients/ (pure
# refactor, zero behavior change). Re-imported here so every existing
# harvest.<name> call site and test reference keeps working unchanged.
# ---------------------------------------------------------------------------
import harvest_clients.base
from harvest_clients import (
    GatewayClient,
    AnthropicGatewayClient,
    ResponsesGatewayClient,
    GeminiNativeGatewayClient,
    GrokCliClient,
    make_client_factory,
)
from harvest_clients.base import (
    _read_http_error_body,
    _maybe_decompress,
    _http_json_post,
    _GATEWAY_RETRY_BACKOFFS_TRANSIENT,
    _GATEWAY_RETRY_BACKOFFS_OTHER_4XX,
    _COMPLETION_RETRY_BACKOFFS,
    _http_json_post_with_retry,
    StreamIdleTimeout,
    StreamConnectionLost,
    StreamNotSupportedError,
    _get_raw_socket,
    _STREAM_READ_EXCEPTIONS,
    _http_stream_post,
    _STREAM_RETRYABLE_EXCEPTIONS,
    _run_stream_attempt_with_retry,
    curl_cffi_requests,
    CurlCffiOpt,
    _HAS_CURL_CFFI,
    _check_curl_cffi_available,
)
from harvest_clients.anthropic import (
    _anthropic_post_with_retry,
    _oai_tools_to_anthropic,
    _assistant_to_anthropic_content,
    _oai_messages_to_anthropic,
    _append_user_blocks,
    _anthropic_resp_to_oai,
    _CACHE_CONTROL,
    _mark_block_list_tail,
    _mark_message_tail,
    _inject_cache_control,
)
from harvest_clients.responses import (
    _oai_tools_to_responses,
    _oai_messages_to_responses,
    _responses_resp_to_oai,
)
from harvest_clients.gemini import (
    _gemini_generate_content_url,
    _gemini_stream_generate_content_url,
    _oai_tools_to_gemini,
    _append_gemini_user_parts,
    _gemini_tool_response_payload,
    _oai_messages_to_gemini,
    _gemini_resp_to_oai,
)


from harvest_search import (
    _ddg_extract_target_url, _search_duckduckgo,
    _search_tavily, _resolve_grounding_redirect, _search_gemini_grounding,
    _no_redirect_opener, call_search_backend, do_search,
)
import harvest_search  # for qualified do_search() calls in body (facade-penetration guard)


from harvest_fetch import (
    _fetch_tavily_extract, _fetch_jina_reader, _strip_html_to_text,
    _looks_like_challenge_page, _fetch_curl_cffi, _fetch_urllib_ua,
    call_fetch_backend, do_fetch,
)
import harvest_fetch  # for qualified do_fetch() calls in body (facade-penetration guard)
import harvest_journal


# ---------------------------------------------------------------------------
# read_local tool
# ---------------------------------------------------------------------------

def do_read_local(path, offset, journal, config, local_dir):
    local_cfg = config.get("local_sources", {})
    if not local_cfg.get("enabled"):
        harvest_journal.jappend(journal, {"tool": "read_local", "url": f"local://{path}", "blocked": "disabled", "content": None})
        return json.dumps({"error": "local_sources disabled"})
    if not local_dir:
        harvest_journal.jappend(journal, {"tool": "read_local", "url": f"local://{path}", "blocked": "no_dir", "content": None})
        return json.dumps({"error": "no local_dir configured"})
    resolved = resolve_local_path(local_dir, path)
    if resolved is None or not resolved.is_file():
        harvest_journal.jappend(journal, {"tool": "read_local", "url": f"local://{path}", "blocked": "sandbox", "content": None})
        return json.dumps({"error": "path rejected by sandbox"})
    try:
        text = resolved.read_text(encoding="utf-8", errors="replace")
    except OSError:
        harvest_journal.jappend(journal, {"tool": "read_local", "url": f"local://{path}", "blocked": "read_error", "content": None})
        return json.dumps({"error": "read error"})
    offset = offset or 0
    max_chars = config["limits"]["fetch_max_chars"]
    chunk = text[offset:offset + max_chars]
    harvest_journal.jappend(journal, {"tool": "read_local", "url": f"local://{path}", "content": chunk})
    return chunk


def execute_tool_call(tc, search_backends, social_backends, fetch_backends, journal, config, local_dir):
    fn_info = tc.get("function", {})
    name = fn_info.get("name", "")
    try:
        args = json.loads(fn_info.get("arguments") or "{}")
    except json.JSONDecodeError:
        args = {}
    if name == "search":
        return harvest_search.do_search(args.get("query", ""), args.get("lang", ""), search_backends, journal, config)
    if name == "search_social":
        return harvest_search.do_social_search(args.get("query", ""), args.get("lang", ""), social_backends, journal, config)
    if name == "fetch":
        return harvest_fetch.do_fetch(args.get("url", ""), fetch_backends, journal, config)
    if name == "read_local":
        return do_read_local(args.get("path", ""), args.get("offset", 0), journal, config, local_dir)
    return json.dumps({"error": f"unknown tool {name}"})


_PARALLEL_FETCH_MAX_WORKERS = 3


def _run_fetch_calls_parallel(tool_calls, search_backends, social_backends, fetch_backends, journal, config, local_dir):
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
            pool.submit(execute_tool_call, tc, search_backends, social_backends, fetch_backends, journal, config, local_dir): i
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
    # Social search is also a quota-limited external call (like web search),
    # but grok CLI's own call latency dwarfs typical web-search backends --
    # independent key with a fallback to search's interval, same back-compat
    # pattern as fetch_interval above.
    social_interval = limits.get("social_min_interval_s", search_interval)

    raw_search_backends = list(config.get("search_backends", []))
    web_backends = []
    migrated_social = []
    for b in raw_search_backends:
        if b.get("type") == "x-search":
            # Back-compat migration for pre-refactor configs that still
            # declare the old "x-search" web-search-backend entry: rebuild
            # it as a fresh dict under social_search_backends' "grok-x" type
            # rather than mutating the original config dict/list in place
            # (the caller may hold other references to that same config
            # object across multiple build_backends() calls).
            migrated_social.append({
                "type": "grok-x",
                "model": b.get("model", "grok-4.5"),
                "effort": b.get("effort", "low"),
                "timeout_s": b.get("timeout_s", 90),
            })
        else:
            web_backends.append(b)

    search_backends = [(b, limiter_for(f"search:{i}", search_interval))
                        for i, b in enumerate(web_backends)]

    # De-dupe by type before availability-filtering: an old config that
    # still declares the pre-refactor "x-search" entry AND a fresh config
    # that already declares its migrated "grok-x" equivalent under
    # social_search_backends must not both survive into raw_social_backends
    # -- that would run the same grok-x social backend twice per query. The
    # explicitly-configured social_search_backends entry wins; the migrated
    # one is dropped when its type is already present.
    raw_social_backends = list(config.get("social_search_backends", []))
    existing_social_types = {b.get("type") for b in raw_social_backends}
    for b in migrated_social:
        if b.get("type") not in existing_social_types:
            raw_social_backends.append(b)
            existing_social_types.add(b.get("type"))

    # grok-* social backends (currently just "grok-x") are driven through
    # the local `grok` CLI (see harvest_search.social._search_grok_x), not a
    # gateway HTTP endpoint. Unlike a gateway backend going down transiently,
    # a missing `grok` binary never heals itself mid-run -- probe once here
    # and drop grok-backed social backends up front so do_social_search's
    # existing "no backends configured" short-circuit handles the rest,
    # instead of every query burning a FileNotFoundError round-trip through
    # call_social_backend.
    if raw_social_backends and not shutil.which("grok"):
        before = len(raw_social_backends)
        raw_social_backends = [b for b in raw_social_backends if not str(b.get("type", "")).startswith("grok")]
        if len(raw_social_backends) != before:
            print("grok CLI not found, skipping grok social search backend(s)", file=sys.stderr)

    social_backends = [(b, limiter_for(f"social:{i}", social_interval))
                        for i, b in enumerate(raw_social_backends)]

    fetch_backends = [(b, limiter_for(f"fetch:{i}", fetch_interval))
                       for i, b in enumerate(config.get("fetch_backends", []))]
    return search_backends, social_backends, fetch_backends

# ---------------------------------------------------------------------------
# Panel worker driver
# ---------------------------------------------------------------------------

def build_system_prompt(goal_text, local_manifest, alias, max_steps, has_social_backends=False):
    tools_line = "Tools: search(query, lang), fetch(url), read_local(path, offset)."
    if has_social_backends:
        tools_line = ("Tools: search(query, lang), search_social(query, lang) -- use search_social "
                       "for community opinions/discussion (e.g. X/Twitter) as a reference frame "
                       "distinct from general web search, fetch(url), read_local(path, offset).")
    lines = [
        "You are one member of a multi-model research panel. Decompose the "
        "research goal independently and collect evidence with the tools.",
        tools_line,
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
    def __init__(self, alias, model_id, status, findings, journal, reason=None, rejected_claims=None,
                 wall_clock_s=None, completion_wall_s=0.0):
        self.alias = alias
        self.model_id = model_id
        self.status = status
        self.findings = findings
        self.journal = journal
        self.reason = reason
        self.rejected_claims = rejected_claims or []
        self.wall_clock_s = wall_clock_s
        self.completion_wall_s = completion_wall_s


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


def run_worker(alias, model_id, client, config, search_backends, social_backends, fetch_backends,
                goal_text, local_manifest, local_dir):
    t0 = time.monotonic()
    completion_wall = [0.0]  # mutable box so inner can accumulate
    r = _run_worker_inner(alias, model_id, client, config, search_backends, social_backends, fetch_backends,
                           goal_text, local_manifest, local_dir, completion_wall)
    r.wall_clock_s = round(time.monotonic() - t0, 2)
    r.completion_wall_s = round(completion_wall[0], 2)
    return r


def _run_worker_inner(alias, model_id, client, config, search_backends, social_backends, fetch_backends,
                       goal_text, local_manifest, local_dir, completion_wall):
    journal = []
    try:
        limits = config["limits"]
        max_steps = limits["max_steps_per_model"]
        deadline = time.monotonic() + limits["wall_clock_s"]
        messages = [
            {"role": "system", "content": build_system_prompt(goal_text, local_manifest, alias,
                                                                limits["max_steps_per_model"],
                                                                has_social_backends=bool(social_backends))},
            {"role": "user", "content": goal_text},
        ]
        parse_retry_used = False
        citation_retry_used = False
        for step in range(max_steps):
            if time.monotonic() > deadline:
                return WorkerResult(alias, model_id, "FAILED", None, journal, "wall_clock_exceeded")
            _cs = time.monotonic()
            try:
                resp = client.complete(messages=messages, tools=TOOL_SCHEMAS)
            except Exception:
                break
            finally:
                completion_wall[0] += time.monotonic() - _cs
            message = _extract_message(resp)
            if message is None:
                return WorkerResult(alias, model_id, "FAILED", None, journal, "bad_response")
            messages.append(message)
            tool_calls = message.get("tool_calls") or []
            if tool_calls:
                tool_names = ["?"]
                target = ""
                try:
                    tool_names = [tc.get("function", {}).get("name", "?") for tc in tool_calls]
                    if len(tool_calls) == 1:
                        a = json.loads(tool_calls[0].get("function", {}).get("arguments", "{}"))
                        target = str(a.get("query", a.get("url", "")))[:80]
                except Exception:
                    pass
                _emit("worker_step", alias=alias, step=step, tools=tool_names, target=target)
                is_all_fetch = len(tool_calls) > 1 and all(
                    tc.get("function", {}).get("name") == "fetch" for tc in tool_calls
                )
                if is_all_fetch:
                    results = _run_fetch_calls_parallel(tool_calls, search_backends, social_backends, fetch_backends,
                                                          journal, config, local_dir)
                    for tc, result_text in zip(tool_calls, results):
                        messages.append({"role": "tool", "tool_call_id": tc.get("id", ""), "content": result_text})
                else:
                    for tc in tool_calls:
                        result_text = execute_tool_call(tc, search_backends, social_backends, fetch_backends, journal, config, local_dir)
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
                    _emit("worker_converging", alias=alias, remaining=remaining)
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
        _cs = time.monotonic()
        try:
            resp = client.complete(messages=messages, tools=TOOL_SCHEMAS)
        except Exception as e:
            return WorkerResult(alias, model_id, "FAILED", None, journal,
                                f"synthesis_failed ({type(e).__name__}): {e}")
        finally:
            completion_wall[0] += time.monotonic() - _cs
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
            _cs = time.monotonic()
            try:
                resp = client.complete(messages=messages, tools=TOOL_SCHEMAS)
            except Exception as e:
                return WorkerResult(alias, model_id, "FAILED", None, journal,
                                    f"synthesis_retry_failed ({type(e).__name__}): {e}")
            finally:
                completion_wall[0] += time.monotonic() - _cs
            message = _extract_message(resp)
            content = (message.get("content") or "") if message else ""
            data, err = parse_findings_json(content)
        if err:
            return WorkerResult(alias, model_id, "FAILED", None, journal, f"synthesis_parse_failed: {err}")
        return finalize_findings(alias, model_id, data, journal)
    except Exception as e:
        return WorkerResult(alias, model_id, "FAILED", None, journal, f"exception: {e}")


def _filter_available_panel_models(panel_models):
    """Drop grok-* entries from `panel_models` when the local `grok` CLI is
    not on PATH. Mirrors build_backends' grok-x social-backend availability
    probe: a grok-* panel model is driven through GrokCliClient, which
    shells out to the `grok` binary (see harvest_clients.grok_cli) rather
    than calling a gateway HTTP endpoint -- a missing binary never heals
    itself mid-run, so without this filter every grok-* worker would just
    burn a step budget hitting FileNotFoundError and report FAILED instead
    of the panel gracefully running with its remaining (gateway-backed)
    models. Non-grok panel_models are returned unchanged and in order."""
    if not any(str(m).startswith("grok") for m in panel_models):
        return list(panel_models)
    if shutil.which("grok"):
        return list(panel_models)
    filtered = [m for m in panel_models if not str(m).startswith("grok")]
    print("grok CLI not found, skipping grok panel model(s)", file=sys.stderr)
    return filtered


def run_panel(config, goal_text, local_manifest, local_dir, client_factory):
    search_backends, social_backends, fetch_backends = build_backends(config)
    panel_models = _filter_available_panel_models(config["panel_models"])
    quorum = config["limits"]["quorum"]
    results = []
    with ThreadPoolExecutor(max_workers=len(panel_models)) as pool:
        futures = {}
        for i, model_id in enumerate(panel_models):
            alias = f"m{i + 1}"
            client = client_factory(model_id)
            fut = pool.submit(run_worker, alias, model_id, client, config,
                               search_backends, social_backends, fetch_backends, goal_text, local_manifest, local_dir)
            futures[fut] = alias
        for fut in as_completed(futures):
            alias = futures[fut]
            try:
                r = fut.result()
                results.append(r)
            except Exception as e:
                r = WorkerResult(alias, "?", "FAILED", None, [], f"executor_exception: {e}")
                results.append(r)
            claims_count = 0
            try:
                claims = r.findings.get("claims") if isinstance(r.findings, dict) else None
                claims_count = len(claims) if isinstance(claims, list) else 0
            except Exception:
                pass
            _emit("worker_done", alias=r.alias, model_id=r.model_id, status=r.status, claims=claims_count,
                  wall_clock_s=r.wall_clock_s, completion_wall_s=r.completion_wall_s)
    alive = [r for r in results if r.status == "OK"]
    _emit("panel_done", alive=[r.alias for r in alive], quorum_met=len(alive) >= quorum)
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
    all_candidates = list(dict.fromkeys([preferred] + list(panel_models)))
    # grok-* models are driven through GrokCliClient, a single-shot research
    # agent that fakes run_worker's tool-use contract (see grok_cli.py's
    # module docstring) -- it is not a general chat-completions client and
    # cannot serve judge_clusters' plain complete(messages, tools=None) call:
    # the last message it sees is role=user, so GrokCliClient.complete
    # routes it into Phase 1's findings-JSON research flow instead of a
    # judge verdict, which then either fails to parse as judge JSON or burns
    # a full grok CLI timeout for nothing. Judge candidates are filtered to
    # exclude grok-* up front rather than letting it fail through the retry
    # loop.
    candidates = [m for m in all_candidates if not m.startswith("grok")]
    if not candidates:
        # Every candidate (preferred + full panel) is grok-* -- nothing
        # judge-capable is configured. Fall back to the raw judge_model
        # config value (even though it's grok) so the caller gets an
        # explicit, attributable failure out of judge_clusters rather than
        # an empty-candidates silent no-op.
        candidates = [preferred]
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
    source_of = {}
    for alias, data in worker_findings_by_alias.items():
        for c in data["claims"]:
            all_claims[c["_id"]] = c
            source_of[c["_id"]] = alias

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
                "source_model": source_of[cid],
            })
        clusters_out.append({
            "cluster_id": f"c{len(clusters_out) + 1:03d}",
            "summary": summary,
            "relation": relation,
            "claims": assembled,
        })

    unique_insights = [cid for cid in judge_data.get("unique_insights", []) if cid in all_claims]
    unclustered_claim_ids = sorted(cid for cid in all_claims if cid not in claimed_ids)
    unclustered_claims = []
    for cid in unclustered_claim_ids:
        c = all_claims[cid]
        unclustered_claims.append({
            "id": cid,
            "claim": c.get("claim", ""),
            "excerpt": c.get("excerpt", ""),
            "url": c.get("url", ""),
            "language": c.get("language", "unknown"),
            "credibility": c.get("credibility", 3),
            "source_model": source_of[cid],
        })
    return {
        "clusters": clusters_out,
        "coverage_gaps": judge_data.get("coverage_gaps", []),
        "unique_insights": unique_insights,
        "blind_spots": judge_data.get("blind_spots", []),
        "contradictions": contradictions,
        "dedup_notes": dedup_notes,
        "unclustered_claim_ids": unclustered_claim_ids,
        "unclustered_claims": unclustered_claims,
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
    _unlink_handoff_artifacts(pipeline_dir / "2_cleaned")


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
    _unlink_handoff_artifacts(_cleaned_dir_from_raw(raw_dir), track_name=raw_dir.name)


def _cleaned_dir_from_raw(raw_dir):
    """pipeline/2_cleaned next to 1_raw, even when --out is nested under 1_raw."""
    node = Path(raw_dir)
    while node.name and node.name != "pipeline":
        if node.parent == node:
            return None
        node = node.parent
    if node.name == "pipeline":
        return node / "2_cleaned"
    return None


def _unlink_handoff_artifacts(cleaned_dir, track_name=None):
    if cleaned_dir is None:
        return
    target = Path(cleaned_dir)
    names = harvest_handoff.artifact_names(track_name)
    for name in names.values():
        path = target / name
        if path.is_file():
            path.unlink()


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

    # Handoff negotiation only runs on OK records, after exemption / missing
    # / unreadable / UNAVAILABLE / LOCAL / not-OK. Three fields all absent
    # keeps the historical path byte-for-byte.
    negotiated = _negotiate_handoff(project_dir, data)
    if negotiated is not None:
        return negotiated
    return _evaluate_ok_verify(project_dir, data)


def _evaluate_ok_verify(project_dir, data):
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


_HANDOFF_KEYS = ("handoff_version", "handoff_required", "handoff_status")


def _negotiate_handoff(project_dir, data):
    present = [key for key in _HANDOFF_KEYS if key in data]
    if not present:
        return None
    if len(present) != 3:
        return "FAIL", "handoff marker incomplete"
    if data.get("handoff_version") != 1:
        return "FAIL", "handoff_version must be 1"
    if data.get("handoff_required") is not True:
        return "FAIL", "handoff_required must be true"
    status = data.get("handoff_status")
    if status == "PENDING_SANITIZATION":
        return "FAIL", "handoff pending sanitization"
    if status != "READY":
        return "FAIL", f"handoff_status not READY: {status!r}"
    legacy = _evaluate_ok_verify(project_dir, data)
    if legacy[0] != "PASS":
        return legacy
    return _check_primary_handoff_ready(project_dir, data)


def _check_primary_handoff_ready(project_dir, data):
    """Primary artifacts only — never track_*. Delegates schema/hash to harvest_handoff."""
    try:
        return _check_primary_handoff_ready_inner(project_dir, data)
    except harvest_handoff.HandoffError as exc:
        return "FAIL", str(exc)
    except (json.JSONDecodeError, OSError, UnicodeDecodeError) as exc:
        return "FAIL", f"handoff artifact unreadable: {exc}"


def _check_primary_handoff_ready_inner(project_dir, data):
    pipeline = Path(project_dir) / "pipeline"
    raw_path = pipeline / "1_raw" / MERGED_FINDINGS_FILE
    man_path = pipeline / "2_cleaned" / "harvest-manifest.json"
    ev_path = pipeline / "2_cleaned" / "harvest-evidence.jsonl"
    for path, label in ((raw_path, "merged-findings.json"),
                        (man_path, "harvest-manifest.json"),
                        (ev_path, "harvest-evidence.jsonl")):
        if not path.is_file():
            return "FAIL", f"handoff artifact missing: {label}"
    try:
        raw = json.loads(raw_path.read_text(encoding="utf-8"))
        manifest = json.loads(man_path.read_text(encoding="utf-8"))
        evidence_text = ev_path.read_text(encoding="utf-8")
    except (json.JSONDecodeError, OSError, UnicodeDecodeError) as exc:
        return "FAIL", f"handoff artifact unreadable: {exc}"
    goal_file = resolve_goal_file(project_dir)
    goal_hash = hashlib.sha256(goal_file.read_bytes()).hexdigest() if goal_file is not None else data.get("goal_file_sha256", "")
    harvest_handoff.check_ready_payloads(
        verify=data,
        raw=raw,
        manifest=manifest,
        evidence_text=evidence_text,
        goal_sha256=goal_hash,
        raw_sha256=harvest_handoff.file_sha256(raw_path),
        manifest_sha256=harvest_handoff.file_sha256(man_path),
        evidence_sha256=harvest_handoff.file_sha256(ev_path),
    )
    harvest_handoff.check_ready_invariants(raw, manifest, evidence_text)
    return "PASS", "ok"


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
        # p['title'] is an untrusted external search-result label -- sanitize
        # before it lands in a checked-in artifact (zero-width/bidi-control
        # stripping + quote-spoof normalization, same cleaner render.py runs
        # its own output through; see _sanitize.py).
        title = sanitize_text(p["title"]) or p["url"]
        lines.append(f"- [{title}]({p['url']}) ({p['chars']} chars)")

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
    search_backends, social_backends, fetch_backends = build_backends(config)
    _local_t0 = time.monotonic()

    journal = []
    all_urls = []
    for query in queries:
        result_json = harvest_search.do_search(query, "auto", search_backends, journal, config)
        results = json.loads(result_json).get("results", [])
        for r in results:
            all_urls.append((r["url"], r.get("title", "")))
        # Social search is best-effort here too: only attempted when the
        # config actually declares a social backend, and its results feed
        # into the same URL pool -- a failure/empty chain never blocks the
        # rest of this query's (or later queries') local-mode collection.
        if social_backends:
            social_json = harvest_search.do_social_search(query, "auto", social_backends, journal, config)
            social_results = json.loads(social_json).get("results", [])
            for r in social_results:
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
        abort_unavailable(verify_dir, goal_hash, "no usable URLs from search",
                          {"harvest_wall_s": round(time.monotonic() - _local_t0, 2)})

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
        harvest_fetch.do_fetch(item["url"], fetch_backends, journal, config)
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
        abort_unavailable(verify_dir, goal_hash, "all fetches failed",
                          {"harvest_wall_s": round(time.monotonic() - _local_t0, 2)})

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
        "harvest_wall_s": round(time.monotonic() - _local_t0, 2),
    })

    print(f"harvest local mode complete: {len(fetched_pages)} pages fetched")


def _resolve_run_paths(args):
    """Derive all run directories + resolve/validate the goal file for a
    normal (API) harvest run. Extracted verbatim from cmd_run -- the sys.exit
    validation paths and every comment are unchanged, so behavior is identical.

    Returns: (raw_dir, project_dir, pipeline_dir, verify_dir, is_supplementary,
              verify_filename, goal_text, goal_hash)
    """
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

    return (raw_dir, project_dir, pipeline_dir, verify_dir, is_supplementary,
            verify_filename, goal_text, goal_hash)


def _persist_worker_outputs(raw_dir, results):
    """Write each worker's findings.json / journal_<alias>.jsonl /
    rejected_claims.json under raw_dir/HARVEST_SUBDIR/<alias>/. Extracted
    verbatim from cmd_run -- pure disk IO, no behavior change."""
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


def cmd_run(args):
    config = load_config(args.config)
    harvest_clients.base._check_curl_cffi_available(config)

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

    (raw_dir, project_dir, pipeline_dir, verify_dir, is_supplementary,
     verify_filename, goal_text, goal_hash) = _resolve_run_paths(args)

    if is_supplementary:
        # Never cleanup_stale_state() here -- that function unconditionally
        # unlinks the PRIMARY VERIFY_FILE/EXEMPTION, which would erase the
        # main track's already-recorded gate verdict. Scoped equivalent
        # touches only this track's own state file + its own --out dir.
        cleanup_stale_supplementary_state(verify_dir, raw_dir, verify_filename)
    else:
        cleanup_stale_state(pipeline_dir, verify_dir, raw_dir)
    write_tombstone(verify_dir, goal_hash, verify_filename=verify_filename)

    _harvest_t0 = None
    harvest_wall_s = None
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
        _emit("run_start", models=config["panel_models"],
              max_steps=config["limits"]["max_steps_per_model"],
              wall_clock_s=config["limits"]["wall_clock_s"])
        _harvest_t0 = time.monotonic()
        results, alive, quorum_met = run_panel(config, goal_text, local_manifest, local_dir, client_factory)
        harvest_wall_s = round(time.monotonic() - _harvest_t0, 2)

        _persist_worker_outputs(raw_dir, results)

        if not quorum_met:
            abort_unavailable(verify_dir, goal_hash, "quorum not met",
                               {"quorum_met": False, "models_alive": [r.alias for r in alive],
                                "harvest_wall_s": harvest_wall_s},
                               verify_filename=verify_filename)

        worker_findings_by_alias = {r.alias: r.findings for r in alive}
        _emit("judge_start", model_id=config.get("judge_model") or config["panel_models"][0])
        judge_data, judge_err = run_judge_with_fallback(config, client_factory, worker_findings_by_alias, config["panel_models"])
        _emit("judge_done", clusters=len(judge_data.get("clusters", [])) if judge_data else 0,
              err=judge_err)
        if judge_data is None:
            abort_unavailable(verify_dir, goal_hash, f"judge failed: {judge_err}",
                               {"quorum_met": True, "models_alive": [r.alias for r in alive],
                                "harvest_wall_s": harvest_wall_s},
                               verify_filename=verify_filename)

        merged = merge_findings(worker_findings_by_alias, judge_data)

        total_claims = sum(len(d["claims"]) for d in worker_findings_by_alias.values())
        invalid_total = sum(r.findings.get("invalid_claim_count", 0) for r in alive)
        denom = total_claims + invalid_total
        invalid_rate = (invalid_total / denom) if denom > 0 else 0.0

        if total_claims == 0:
            abort_unavailable(verify_dir, goal_hash, "quorum met but zero valid claims",
                               {"harvest_wall_s": harvest_wall_s},
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
            "harvest_wall_s": harvest_wall_s,
            "handoff_version": 1,
            "handoff_required": True,
            "handoff_status": "PENDING_SANITIZATION",
        }, verify_filename=verify_filename)
        _emit("run_done", verdict=verdict, total_claims=total_claims, invalid_rate=round(invalid_rate, 4))
        print(f"harvest run complete: verdict={verdict}")
    except SystemExit:
        raise
    except Exception as e:
        extra = {}
        if harvest_wall_s is not None:
            extra["harvest_wall_s"] = harvest_wall_s
        elif _harvest_t0 is not None:
            extra["harvest_wall_s"] = round(time.monotonic() - _harvest_t0, 2)
        abort_unavailable(verify_dir, goal_hash, f"unexpected error: {e}", extra, verify_filename=verify_filename)


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


def _resolve_handoff_paths(project_dir, raw_dir):
    """Primary vs supplementary + verify filename, without goal-file matching."""
    project_dir = Path(project_dir).resolve()
    raw_dir = Path(raw_dir)
    pipeline_dir = project_dir / "pipeline"
    verify_dir = pipeline_dir / "verification"
    is_supplementary = raw_dir.resolve() != (pipeline_dir / "1_raw").resolve()
    verify_filename = track_verify_filename(raw_dir) if is_supplementary else VERIFY_FILE
    return project_dir, pipeline_dir, verify_dir, is_supplementary, verify_filename


def _assert_inside_project(path, project_dir, label):
    resolved = Path(path).resolve()
    if not _is_relative_to(resolved, project_dir):
        raise harvest_handoff.HandoffError(f"{label} outside project: {resolved}")
    return resolved


def _assert_finalize_verify(verify):
    """Refuse finalize unless this verify is an OK record awaiting or already READY."""
    if not isinstance(verify, dict):
        raise harvest_handoff.HandoffError("verify must be an object")
    verdict = verify.get("verdict")
    if verdict != "OK":
        raise harvest_handoff.HandoffError(
            f"finalize requires verdict OK, got {verdict!r}"
        )
    present = [key for key in _HANDOFF_KEYS if key in verify]
    if len(present) != 3:
        raise harvest_handoff.HandoffError("handoff marker incomplete")
    status = verify.get("handoff_status")
    if status not in ("PENDING_SANITIZATION", "READY"):
        raise harvest_handoff.HandoffError(
            f"finalize requires PENDING_SANITIZATION or READY, got {status!r}"
        )


def cmd_finalize_handoff(args):
    """Publish WIP → evidence + manifest, then bind READY hashes on verify."""
    try:
        _finalize_handoff(args)
    except harvest_handoff.HandoffError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)


def _finalize_handoff(args):
    project_dir, pipeline_dir, verify_dir, is_supplementary, verify_filename = (
        _resolve_handoff_paths(args.project_dir, args.out)
    )
    raw_dir = Path(args.out)
    cleaned_dir = pipeline_dir / "2_cleaned"
    track_name = raw_dir.name if is_supplementary else None
    if is_supplementary and track_name in ("", ".", ".."):
        raise harvest_handoff.HandoffError("invalid supplementary track_name")
    names = harvest_handoff.artifact_names(track_name)

    wip_path = _assert_inside_project(args.wip, project_dir, "wip")
    cleaned_dir = _assert_inside_project(cleaned_dir, project_dir, "cleaned")
    raw_merged = _assert_inside_project(raw_dir / MERGED_FINDINGS_FILE, project_dir, "raw")
    verify_path = _assert_inside_project(verify_dir / verify_filename, project_dir, "verify")
    manifest_path = cleaned_dir / names["manifest"]
    evidence_path = cleaned_dir / names["evidence"]
    _assert_inside_project(manifest_path, project_dir, "manifest")
    _assert_inside_project(evidence_path, project_dir, "evidence")

    raw = json.loads(raw_merged.read_text(encoding="utf-8"))
    wip = json.loads(wip_path.read_text(encoding="utf-8"))
    verify = json.loads(verify_path.read_text(encoding="utf-8"))
    _assert_finalize_verify(verify)
    harvest_handoff.validate_wip(wip)
    harvest_handoff.check_coverage(wip, raw)

    goal_hash = verify.get("goal_file_sha256") or ""
    goal_file = resolve_goal_file(project_dir)
    if goal_file is not None:
        current_hash = hashlib.sha256(goal_file.read_bytes()).hexdigest()
        if current_hash != goal_hash:
            raise harvest_handoff.HandoffError("goal_file_sha256 mismatch")
    raw_hash = harvest_handoff.file_sha256(raw_merged)
    alive = list(verify.get("models_alive") or [])

    harvest_handoff.publish_handoff(
        cleaned_dir, wip, raw,
        goal_file_sha256=goal_hash,
        raw_merged_sha256=raw_hash,
        alive_models=alive,
        track_name=track_name,
    )
    evidence_hash = harvest_handoff.file_sha256(evidence_path)
    manifest_hash = harvest_handoff.file_sha256(manifest_path)

    extra = dict(verify)
    extra.update({
        "handoff_version": 1,
        "handoff_required": True,
        "handoff_status": "READY",
        "manifest_sha256": manifest_hash,
        "evidence_sha256": evidence_hash,
        "raw_merged_sha256": raw_hash,
    })
    extra.pop("verdict", None)
    extra.pop("goal_file_sha256", None)
    extra.pop("run_timestamp", None)
    write_verify_json(verify_dir, goal_hash, verify.get("verdict", "OK"), extra,
                      verify_filename=verify_filename)
    if wip_path.exists():
        wip_path.unlink()
    print(f"handoff finalized: {manifest_path.name}")


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

    finalize_p = sub.add_parser("finalize-handoff")
    finalize_p.add_argument("--project-dir", required=True)
    finalize_p.add_argument("--out", required=True,
                            help="raw_dir; same primary vs supplementary rule as run")
    finalize_p.add_argument("--wip", required=True)
    finalize_p.set_defaults(func=cmd_finalize_handoff)

    return parser


def main():
    parser = build_arg_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
