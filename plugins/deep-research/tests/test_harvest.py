import io
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import harvest  # noqa: E402

_FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def base_config(**overrides):
    cfg = {
        "gateway": {"base_url": "https://gw.example.com/v1", "api_key_env": "TEST_GATEWAY_KEY"},
        "panel_models": ["model-a", "model-b", "model-c"],
        "judge_model": "model-judge",
        "search_backends": [{"type": "gemini-cli", "model": "gemini-3.5-flash"}],
        "fetch_backends": [{"type": "urllib-ua"}],
        "local_sources": {"enabled": False, "dir": "intake/local_sources"},
        "limits": {"max_steps_per_model": 6, "call_timeout_s": 5, "wall_clock_s": 60,
                   "quorum": 2, "search_min_interval_s": 0, "fetch_max_chars": 20000,
                   "fetch_connect_timeout_s": 5, "fetch_low_speed_bytes_s": 512,
                   "fetch_low_speed_window_s": 10,
                   # ADR-013: keep the existing test suite on the deterministic
                   # non-streaming path (which the existing HTTP-level mocks
                   # target). Streaming behavior gets its own dedicated test
                   # classes that construct clients directly with
                   # stream_enabled=True.
                   "anthropic_stream": False, "gpt_stream": False,
                   "gemini_stream": False, "gateway_stream": False,
                   "gateway_stream_options": False},
        "blacklist_domains": ["blog.csdn.net", "cloud.baidu.com", "aliyun.com"],
    }
    cfg.update(overrides)
    return cfg


class ScriptedClient:
    """Fake OpenAI-compatible client: returns canned responses in order.
    Also records a shallow snapshot of the messages list passed to each
    complete() call (message dicts are appended-only past this point, never
    mutated in place after being recorded here -- except by
    append_or_merge_user's in-place merge, which by construction only ever
    touches the *last* message and only runs before this snapshot is taken,
    so the snapshot always reflects what the model actually received)."""

    def __init__(self, responses):
        self._responses = list(responses)
        self.calls = 0
        self.messages_log = []

    def complete(self, messages, tools):
        resp = self._responses[self.calls]
        self.calls += 1
        self.messages_log.append(list(messages))
        if callable(resp):
            return resp(messages, tools)
        return resp


def assistant_tool_call(tool_id, name, arguments):
    return {"choices": [{"message": {
        "role": "assistant", "content": None,
        "tool_calls": [{"id": tool_id, "function": {"name": name, "arguments": json.dumps(arguments)}}],
    }}]}


def assistant_final(content):
    return {"choices": [{"message": {"role": "assistant", "content": content}}]}


def findings_block(claims, zh=None, en=None):
    payload = {"claims": claims, "keywords_used": {"zh": zh or [], "en": en or []}, "term_map": []}
    return "```json\n" + json.dumps(payload, ensure_ascii=False) + "\n```"


class FakeHTTPResponse:
    """Minimal urlopen()-compatible context manager for mocking HTTP GETs."""

    def __init__(self, body_bytes, content_encoding=""):
        self._body = body_bytes
        self.headers = {"Content-Encoding": content_encoding}

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self, *args, **kwargs):
        return self._body


class FakeCurlResponse:
    """Minimal curl_cffi.requests.Response stand-in: .status_code, .headers
    (plain dict, matching curl_cffi's case-insensitive-but-dict-like Headers
    enough for .get("location")), and .text."""

    def __init__(self, status_code=200, text="", location=None):
        self.status_code = status_code
        self.text = text
        self.headers = {"location": location} if location else {}


# ---------------------------------------------------------------------------
# RateLimiter
# ---------------------------------------------------------------------------

class TestRateLimiter(unittest.TestCase):
    def test_spaces_calls_by_min_interval(self):
        limiter = harvest.RateLimiter(0.05)
        t0 = time.monotonic()
        limiter.acquire()
        limiter.acquire()
        elapsed = time.monotonic() - t0
        self.assertGreaterEqual(elapsed, 0.04)

    def test_concurrent_callers_all_spaced(self):
        # RateLimiter reserves monotonically increasing time slots under the
        # lock; individual observed gaps can jitter under real thread
        # scheduling (GIL contention delays one wakeup, letting the next
        # reservation land almost immediately after) -- the invariant that
        # actually holds is on the *aggregate* span, not each pairwise gap.
        limiter = harvest.RateLimiter(0.02)
        timestamps = []
        lock = __import__("threading").Lock()

        def worker():
            limiter.acquire()
            with lock:
                timestamps.append(time.monotonic())

        threads = [__import__("threading").Thread(target=worker) for _ in range(5)]
        t_start = time.monotonic()
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        timestamps.sort()
        total_span = timestamps[-1] - t_start
        self.assertGreaterEqual(total_span, 4 * 0.02 * 0.6)


class TestBuildBackendsFetchInterval(unittest.TestCase):
    """Defect 2 (rate-limit decoupling): fetch backends must get their own
    fetch_min_interval_s, not search's -- with a fallback to the search
    interval so an older config missing the new key doesn't KeyError."""

    def test_fetch_backend_uses_independent_interval_when_key_present(self):
        config = base_config(
            search_backends=[{"type": "duckduckgo"}],
            fetch_backends=[{"type": "urllib-ua"}],
        )
        config["limits"]["search_min_interval_s"] = 2.0
        config["limits"]["fetch_min_interval_s"] = 0.5
        _, fetch_backends = harvest.build_backends(config)
        limiter = fetch_backends[0][1]
        self.assertEqual(limiter._min_interval, 0.5)

    def test_fetch_backend_falls_back_to_search_interval_when_key_absent(self):
        # Older config with no fetch_min_interval_s key at all -- must not
        # KeyError, must fall back to the existing search interval so
        # pre-upgrade behavior is unchanged.
        config = base_config(
            search_backends=[{"type": "duckduckgo"}],
            fetch_backends=[{"type": "urllib-ua"}],
        )
        config["limits"]["search_min_interval_s"] = 2.0
        self.assertNotIn("fetch_min_interval_s", config["limits"])
        _, fetch_backends = harvest.build_backends(config)
        limiter = fetch_backends[0][1]
        self.assertEqual(limiter._min_interval, 2.0)

    def test_search_backend_interval_unaffected_by_fetch_key(self):
        config = base_config(
            search_backends=[{"type": "duckduckgo"}],
            fetch_backends=[{"type": "urllib-ua"}],
        )
        config["limits"]["search_min_interval_s"] = 2.0
        config["limits"]["fetch_min_interval_s"] = 0.5
        search_backends, _ = harvest.build_backends(config)
        limiter = search_backends[0][1]
        self.assertEqual(limiter._min_interval, 2.0)


class TestRunFetchCallsParallel(unittest.TestCase):
    """Defect 2 (parallel fetch): a raising future must still yield exactly
    one tool response per tool_call_id, in the original call order -- not
    the arrival order as_completed() would otherwise produce."""

    def test_parallel_fetch_exception_still_yields_tool_response(self):
        config = base_config(fetch_backends=[{"type": "urllib-ua"}])
        journal = []
        tool_calls = [
            {"id": "c1", "function": {"name": "fetch", "arguments": json.dumps({"url": "https://a.com/1"})}},
            {"id": "c2", "function": {"name": "fetch", "arguments": json.dumps({"url": "https://a.com/2"})}},
            {"id": "c3", "function": {"name": "fetch", "arguments": json.dumps({"url": "https://a.com/3"})}},
        ]

        def fake_execute(tc, search_backends, fetch_backends, journal, config, local_dir):
            args = json.loads(tc["function"]["arguments"])
            if args["url"] == "https://a.com/2":
                raise RuntimeError("boom")
            return json.dumps({"content": args["url"]})

        with mock.patch("harvest.execute_tool_call", side_effect=fake_execute):
            results = harvest._run_fetch_calls_parallel(tool_calls, [], [], journal, config, None)

        self.assertEqual(len(results), 3)
        self.assertEqual(json.loads(results[0])["content"], "https://a.com/1")
        error_payload = json.loads(results[1])
        self.assertIn("error", error_payload)
        self.assertIn("boom", error_payload["error"])
        self.assertEqual(json.loads(results[2])["content"], "https://a.com/3")


# ---------------------------------------------------------------------------
# SSRF guard
# ---------------------------------------------------------------------------

class TestSSRFGuard(unittest.TestCase):
    def setUp(self):
        self._orig_getaddrinfo = socket.getaddrinfo
        self._orig_real = harvest._real_getaddrinfo

    def tearDown(self):
        socket.getaddrinfo = self._orig_getaddrinfo
        harvest._real_getaddrinfo = self._orig_real

    def _install_fake_dns(self, ip):
        harvest._real_getaddrinfo = lambda host, *a, **kw: [(2, 1, 6, "", (ip, 0))]

    def test_private_ip_blocked_inside_tool_context(self):
        self._install_fake_dns("127.0.0.1")
        harvest.install_ssrf_guard()
        with self.assertRaises(harvest.SSRFBlocked):
            with harvest.tool_request_guard():
                socket.getaddrinfo("evil.internal", 80)

    def test_link_local_blocked(self):
        self._install_fake_dns("169.254.169.254")
        harvest.install_ssrf_guard()
        with self.assertRaises(harvest.SSRFBlocked):
            with harvest.tool_request_guard():
                socket.getaddrinfo("metadata.internal", 80)

    def test_public_ip_allowed_inside_tool_context(self):
        self._install_fake_dns("93.184.216.34")
        harvest.install_ssrf_guard()
        with harvest.tool_request_guard():
            result = socket.getaddrinfo("example.com", 80)
        self.assertEqual(result[0][4][0], "93.184.216.34")

    def test_no_whitelist_for_private_ip_even_if_gateway_like(self):
        # no bypass exists regardless of hostname -- gateway calls simply
        # never enter tool_request_guard.
        self._install_fake_dns("10.0.0.5")
        harvest.install_ssrf_guard()
        with self.assertRaises(harvest.SSRFBlocked):
            with harvest.tool_request_guard():
                socket.getaddrinfo("my-internal-gateway.local", 80)

    def test_outside_tool_context_not_blocked(self):
        self._install_fake_dns("127.0.0.1")
        harvest.install_ssrf_guard()
        result = socket.getaddrinfo("internal-gateway.local", 80)
        self.assertEqual(result[0][4][0], "127.0.0.1")

    def test_module_import_has_zero_side_effect_on_getaddrinfo(self):
        proc = subprocess.run(
            [sys.executable, "-c",
             "import socket, sys; sys.path.insert(0, %r); import harvest; "
             "assert socket.getaddrinfo is not harvest._guarded_getaddrinfo, "
             "'import must not monkeypatch socket.getaddrinfo'"
             % str(Path(__file__).resolve().parent.parent / "scripts")],
            capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)


# ---------------------------------------------------------------------------
# Blacklist domain matching
# ---------------------------------------------------------------------------

class TestBlacklist(unittest.TestCase):
    def setUp(self):
        self.domains = ["blog.csdn.net", "cloud.baidu.com", "aliyun.com"]

    def test_exact_match(self):
        self.assertTrue(harvest.is_blacklisted("https://blog.csdn.net/foo", self.domains))

    def test_subdomain_match(self):
        self.assertTrue(harvest.is_blacklisted("https://sub.aliyun.com/x", self.domains))

    def test_similar_but_different_domain_not_blocked(self):
        self.assertFalse(harvest.is_blacklisted("https://myaliyun.com/x", self.domains))

    def test_port_does_not_bypass_blacklist(self):
        self.assertTrue(harvest.is_blacklisted("https://blog.csdn.net:443/x", self.domains))

    def test_trailing_dot_fqdn_does_not_bypass(self):
        self.assertTrue(harvest.is_blacklisted("https://blog.csdn.net./x", self.domains))

    def test_unrelated_domain_not_blocked(self):
        self.assertFalse(harvest.is_blacklisted("https://example.com/x", self.domains))

    def test_ipv6_host_with_port_not_misparsed(self):
        # copilot review on #25: manual netloc.split(":")[0] breaks on IPv6
        # literals (colons inside the address) -- urlsplit(...).hostname
        # handles brackets/port stripping correctly. An IPv6 host is never
        # in the domain blacklist, so this must resolve False, not crash or
        # mis-derive a bogus host like "[".
        self.assertFalse(harvest.is_blacklisted("https://[::1]:8080/x", self.domains))

    def test_ipv6_host_matches_when_actually_blacklisted(self):
        self.assertTrue(harvest.is_blacklisted("https://[2001:db8::1]:443/x", ["2001:db8::1"]))

    def test_no_netloc_url_not_blocked(self):
        self.assertFalse(harvest.is_blacklisted("local://notes/a.md", self.domains))


# ---------------------------------------------------------------------------
# Local path sandbox
# ---------------------------------------------------------------------------

class TestSandbox(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.base = Path(self.tmpdir.name)
        (self.base / "a.md").write_text("hello", encoding="utf-8")

    def tearDown(self):
        self.tmpdir.cleanup()

    def test_normal_relative_path_allowed(self):
        resolved = harvest.resolve_local_path(self.base, "a.md")
        self.assertIsNotNone(resolved)

    def test_traversal_rejected(self):
        resolved = harvest.resolve_local_path(self.base, "../../../etc/passwd")
        self.assertIsNone(resolved)

    def test_absolute_path_rejected(self):
        resolved = harvest.resolve_local_path(self.base, "/etc/passwd")
        self.assertIsNone(resolved)

    def test_tilde_not_expanded_and_stays_sandboxed(self):
        resolved = harvest.resolve_local_path(self.base, "~/secrets.txt")
        # '~' is treated as a literal path segment, not expanded -- so it
        # resolves *inside* the sandbox (and simply doesn't exist).
        self.assertIsNotNone(resolved)
        self.assertTrue(str(resolved).startswith(str(self.base.resolve())))


# ---------------------------------------------------------------------------
# URL / whitespace normalization
# ---------------------------------------------------------------------------

class TestNormalization(unittest.TestCase):
    def test_trailing_slash_ignored(self):
        self.assertEqual(harvest.normalize_url("https://a.com/x/"), harvest.normalize_url("https://a.com/x"))

    def test_case_insensitive_netloc(self):
        self.assertEqual(harvest.normalize_url("https://A.com/x"), harvest.normalize_url("https://a.com/x"))

    def test_fragment_stripped(self):
        self.assertEqual(harvest.normalize_url("https://a.com/x#section"), harvest.normalize_url("https://a.com/x"))

    def test_query_preserved(self):
        self.assertNotEqual(harvest.normalize_url("https://a.com/x?q=1"), harvest.normalize_url("https://a.com/x"))

    def test_local_url_normalized(self):
        self.assertEqual(harvest.normalize_url("local://foo/bar/"), harvest.normalize_url("local://foo/bar"))

    def test_malformed_url_does_not_raise(self):
        # copilot review on #25: an unclosed IPv6 bracket makes urlsplit()
        # raise ValueError. Model output or a search backend result can
        # hand normalize_url() arbitrary garbage -- it must degrade to a
        # non-matching key, not crash the calling worker.
        self.assertEqual(harvest.normalize_url("http://[::1"), "http://[::1")


# ---------------------------------------------------------------------------
# Findings / judge JSON parsing
# ---------------------------------------------------------------------------

class TestFindingsParsing(unittest.TestCase):
    def test_single_fenced_block(self):
        text = findings_block([{"claim": "x", "excerpt": "y", "url": "https://a.com"}])
        data, err = harvest.parse_findings_json(text)
        self.assertIsNone(err)
        self.assertEqual(len(data["claims"]), 1)

    def test_multiple_fenced_blocks_takes_last(self):
        first = "```json\n{\"claims\": []}\n```"
        second = findings_block([{"claim": "x", "excerpt": "y", "url": "https://a.com"}])
        text = f"here's an example:\n{first}\nand here's the real answer:\n{second}"
        data, err = harvest.parse_findings_json(text)
        self.assertIsNone(err)
        self.assertEqual(len(data["claims"]), 1)

    def test_bracket_fallback_object(self):
        text = 'some preamble {"claims": [{"claim":"x","excerpt":"y","url":"https://a.com"}]} trailing'
        data, err = harvest.parse_findings_json(text)
        self.assertIsNone(err)

    def test_top_level_list_rejected(self):
        text = "```json\n[1,2,3]\n```"
        data, err = harvest.parse_findings_json(text)
        self.assertIsNone(data)
        self.assertIsNotNone(err)

    def test_claims_null_rejected(self):
        text = '```json\n{"claims": null}\n```'
        data, err = harvest.parse_findings_json(text)
        self.assertIsNone(data)

    def test_claims_string_rejected(self):
        text = '```json\n{"claims": "oops"}\n```'
        data, err = harvest.parse_findings_json(text)
        self.assertIsNone(data)

    def test_malformed_claim_entry_rejected(self):
        text = '```json\n{"claims": [{"claim": "x"}]}\n```'  # missing excerpt/url
        data, err = harvest.parse_findings_json(text)
        self.assertIsNone(data)

    def test_claim_entry_not_dict_rejected(self):
        text = '```json\n{"claims": ["not-a-dict"]}\n```'
        data, err = harvest.parse_findings_json(text)
        self.assertIsNone(data)

    def test_totally_invalid_json_rejected(self):
        data, err = harvest.parse_findings_json("not json at all")
        self.assertIsNone(data)
        self.assertIsNotNone(err)

    def test_judge_json_parses_clusters(self):
        text = '```json\n{"clusters": [{"summary": "s", "source_claim_ids": ["m1-1"], "relation": "agree"}]}\n```'
        data, err = harvest.parse_judge_json(text)
        self.assertIsNone(err)
        self.assertEqual(len(data["clusters"]), 1)

    def test_judge_json_missing_clusters_rejected(self):
        data, err = harvest.parse_judge_json('```json\n{"foo": 1}\n```')
        self.assertIsNone(data)


# ---------------------------------------------------------------------------
# Citation validation
# ---------------------------------------------------------------------------

class TestCitationValidation(unittest.TestCase):
    def _validate(self, journal, claims):
        idx = harvest.build_fetch_index(journal)
        urls = harvest.build_journal_url_set(journal)
        return harvest.validate_claims(claims, idx, urls)

    def test_hallucinated_url_never_seen_rejected_as_not_in_journal(self):
        journal = [{"tool": "fetch", "url": "https://a.com/x", "content": "The quick brown fox."}]
        claims = harvest.assign_claim_ids("m1", [
            {"claim": "c", "excerpt": "quick brown fox", "url": "https://a.com/NEVER-SEEN"}])
        valid, invalid = self._validate(journal, claims)
        self.assertEqual(valid, [])
        self.assertEqual(len(invalid), 1)
        self.assertEqual(invalid[0][1], "url_not_in_journal")

    def test_url_fetched_accepted_regardless_of_excerpt_content(self):
        # Citation verification is URL-level only: any excerpt text is
        # accepted as long as the URL was actually fetched.
        journal = [{"tool": "fetch", "url": "https://a.com/x", "content": "The quick brown fox."}]
        claims = harvest.assign_claim_ids("m1", [
            {"claim": "c", "excerpt": "the slow red fox (not verbatim at all)", "url": "https://a.com/x"}])
        valid, invalid = self._validate(journal, claims)
        self.assertEqual(len(valid), 1)
        self.assertEqual(invalid, [])

    def test_url_seen_in_search_but_never_fetched_rejected_as_not_fetched(self):
        journal = [{"tool": "search", "query": "q", "lang": "en", "backend": "gemini-cli",
                    "urls": ["https://a.com/only-searched"]}]
        claims = harvest.assign_claim_ids("m1", [
            {"claim": "c", "excerpt": "anything", "url": "https://a.com/only-searched"}])
        valid, invalid = self._validate(journal, claims)
        self.assertEqual(valid, [])
        self.assertEqual(invalid[0][1], "url_not_fetched")

    def test_local_and_web_share_same_validation_path(self):
        journal = [{"tool": "read_local", "url": "local://notes/a.md", "content": "internal fact X"}]
        claims = harvest.assign_claim_ids("m1", [
            {"claim": "c", "excerpt": "internal fact X", "url": "local://notes/a.md"}])
        valid, invalid = self._validate(journal, claims)
        self.assertEqual(len(valid), 1)
        self.assertEqual(invalid, [])

    def test_valid_web_citation_accepted(self):
        journal = [{"tool": "fetch", "url": "https://a.com/x/", "content": "Rayleigh scattering explains it."}]
        claims = harvest.assign_claim_ids("m1", [
            {"claim": "c", "excerpt": "Rayleigh scattering explains it", "url": "https://a.com/x"}])
        valid, invalid = self._validate(journal, claims)
        self.assertEqual(len(valid), 1)

    def test_rejected_claims_record_shape(self):
        journal = [{"tool": "fetch", "url": "https://a.com/x", "content": "The quick brown fox."}]
        claims = harvest.assign_claim_ids("m1", [
            {"claim": "c", "excerpt": "the slow red fox", "url": "https://a.com/NEVER-SEEN"}])
        _, invalid = self._validate(journal, claims)
        records = harvest.build_rejected_claims(invalid)
        self.assertEqual(records, [{"claim": "c", "url": "https://a.com/NEVER-SEEN", "excerpt": "the slow red fox",
                                     "reject_reason": "url_not_in_journal", "matched_url_normalized": None}])

    def test_rejected_claims_record_no_matched_url_when_not_fetched(self):
        journal = [{"tool": "fetch", "url": "https://a.com/x", "content": "The quick brown fox."}]
        claims = harvest.assign_claim_ids("m1", [
            {"claim": "c", "excerpt": "quick brown fox", "url": "https://a.com/NEVER-SEEN"}])
        _, invalid = self._validate(journal, claims)
        records = harvest.build_rejected_claims(invalid)
        self.assertIsNone(records[0]["matched_url_normalized"])


# ---------------------------------------------------------------------------
# gzip decompression safety
# ---------------------------------------------------------------------------

class TestGzipHandling(unittest.TestCase):
    def test_non_gzip_response_passes_through(self):
        class FakeResp:
            headers = {"Content-Encoding": ""}
        raw = b"plain text"
        self.assertEqual(harvest._maybe_decompress(raw, FakeResp()), raw)

    def test_gzip_response_decompressed(self):
        import gzip as gz
        class FakeResp:
            headers = {"Content-Encoding": "gzip"}
        raw = gz.compress(b"hello world")
        result = harvest._maybe_decompress(raw, FakeResp())
        self.assertEqual(result, b"hello world")

    def test_malformed_gzip_does_not_crash(self):
        class FakeResp:
            headers = {"Content-Encoding": "gzip"}
        raw = b"not actually gzip"
        result = harvest._maybe_decompress(raw, FakeResp())
        self.assertEqual(result, raw)


# ---------------------------------------------------------------------------
# duckduckgo search backend (zero-key HTML scraping)
# ---------------------------------------------------------------------------

_DDG_SAMPLE_HTML = """
<div class="result results_links results_links_deep web-result">
  <div class="links_main links_deep result__body">
    <h2 class="result__title">
      <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage%3Fa%3D1&amp;rut=abc123">
        Example &amp; Title <b>highlighted</b>
      </a>
    </h2>
  </div>
  <div class="links_main links_deep result__body">
    <h2 class="result__title">
      <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fblog.csdn.net%2Fx&amp;rut=def456">
        Blocked Result
      </a>
    </h2>
  </div>
  <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage%3Fa%3D1&amp;rut=abc123">A snippet, not a result title.</a>
</div>
"""


class TestDuckDuckGoSearch(unittest.TestCase):
    def setUp(self):
        # Force urllib path so HTML-parsing tests stay isolated from curl-cffi.
        self._patch = mock.patch.object(harvest, "_HAS_CURL_CFFI", False)
        self._patch.start()

    def tearDown(self):
        self._patch.stop()

    def test_parses_result_links_and_unwraps_uddg_redirect(self):
        with mock.patch("harvest.urllib.request.urlopen",
                         return_value=FakeHTTPResponse(_DDG_SAMPLE_HTML.encode("utf-8"))):
            results, reason = harvest._search_duckduckgo({}, "query", 5)
        self.assertIsNone(reason)
        urls = [r["url"] for r in results]
        self.assertIn("https://example.com/page?a=1", urls)
        self.assertIn("https://blog.csdn.net/x", urls)  # blacklist filtering happens in do_search, not here

    def test_title_html_entities_and_tags_stripped(self):
        with mock.patch("harvest.urllib.request.urlopen",
                         return_value=FakeHTTPResponse(_DDG_SAMPLE_HTML.encode("utf-8"))):
            results, _ = harvest._search_duckduckgo({}, "query", 5)
        titles = [r["title"] for r in results]
        self.assertTrue(any("Example & Title highlighted" == t for t in titles))

    def test_non_result_anchor_ignored(self):
        with mock.patch("harvest.urllib.request.urlopen",
                         return_value=FakeHTTPResponse(_DDG_SAMPLE_HTML.encode("utf-8"))):
            results, _ = harvest._search_duckduckgo({}, "query", 5)
        self.assertEqual(len(results), 2)  # the result__snippet anchor is not counted

    def test_empty_page_returns_none_with_no_result_links_reason(self):
        with mock.patch("harvest.urllib.request.urlopen",
                         return_value=FakeHTTPResponse(b"<html><body>no results</body></html>")):
            result, reason = harvest._search_duckduckgo({}, "query", 5)
        self.assertIsNone(result)
        self.assertIn("no result links found", reason)

    def test_network_failure_returns_none_with_reason(self):
        with mock.patch("harvest.urllib.request.urlopen", side_effect=OSError("network down")):
            result, reason = harvest._search_duckduckgo({}, "query", 5)
        self.assertIsNone(result)
        self.assertIn("request failed", reason)

    def test_requires_no_api_key(self):
        # cfg has no api_key_env at all -- must not raise or require one.
        with mock.patch("harvest.urllib.request.urlopen",
                         return_value=FakeHTTPResponse(_DDG_SAMPLE_HTML.encode("utf-8"))):
            results, _ = harvest._search_duckduckgo({}, "query", 5)
        self.assertIsNotNone(results)

    def test_full_do_search_filters_ddg_results_by_blacklist(self):
        journal = []
        cfg = base_config()
        backends = [({"type": "duckduckgo"}, harvest.RateLimiter(0))]
        with mock.patch("harvest.urllib.request.urlopen",
                         return_value=FakeHTTPResponse(_DDG_SAMPLE_HTML.encode("utf-8"))):
            result = harvest.do_search("query", "en", backends, journal, cfg)
        data = json.loads(result)
        urls = [r["url"] for r in data["results"]]
        self.assertIn("https://example.com/page?a=1", urls)
        self.assertNotIn("https://blog.csdn.net/x", urls)

    def test_extract_target_url_does_not_double_decode_percent_literal(self):
        # Target URL contains a literal "%25" escape (representing a '%'
        # character in the real page path). DDG's redirect wraps it by
        # percent-encoding the whole target once when embedding it as the
        # `uddg` query value -- so the query string on the wire has each
        # '%' from the target doubled to "%25", e.g. "%2525" for a target
        # containing "%25". parse_qs() undoes exactly that one encoding
        # layer; a second unquote() would wrongly decode the remaining
        # "%25" down to "%", corrupting the URL.
        target = "https://example.com/search?q=100%25done"
        wire_value = urllib.parse.quote(target, safe="")
        href = f"//duckduckgo.com/l/?uddg={wire_value}&rut=abc123"
        self.assertEqual(harvest._ddg_extract_target_url(href), target)

    def test_extract_target_url_passes_through_non_redirect_href(self):
        href = "https://example.com/direct-link"
        self.assertEqual(harvest._ddg_extract_target_url(href), href)

    def test_extract_target_url_does_not_match_lookalike_host_via_substring(self):
        # copilot review round 5 on #25: "duckduckgo.com" in netloc was a
        # substring check, so a lookalike host like
        # "duckduckgo.com.evil.com" would also be (wrongly) treated as a
        # genuine DDG redirect wrapper. Must pass through unchanged.
        href = "https://duckduckgo.com.evil.com/l/?uddg=https%3A%2F%2Fattacker.example%2Fx"
        self.assertEqual(harvest._ddg_extract_target_url(href), href)

    def test_extract_target_url_matches_duckduckgo_subdomain(self):
        target = "https://example.com/page"
        wire_value = urllib.parse.quote(target, safe="")
        href = f"//lite.duckduckgo.com/l/?uddg={wire_value}"
        self.assertEqual(harvest._ddg_extract_target_url(href), target)

    def test_real_bot_check_page_detected_and_distinguished(self):
        # Real HTML snapshot captured from https://html.duckduckgo.com/html/?q=sqlite+wal
        # on this machine -- DuckDuckGo returns its anti-bot interstitial
        # ("Select all squares containing a duck") instead of results. This
        # must be reported as a distinct, diagnosable reason, not a generic
        # "no results" -- it's an IP-reputation block, not a parser bug.
        fixture = _FIXTURES_DIR / "ddg_anomaly_real.html"
        raw = fixture.read_bytes()
        with mock.patch("harvest.urllib.request.urlopen", return_value=FakeHTTPResponse(raw)):
            result, reason = harvest._search_duckduckgo({}, "sqlite wal", 5)
        self.assertIsNone(result)
        self.assertIn("bot-check challenge page", reason)
        self.assertIn("IP-reputation block", reason)


class TestDuckDuckGoSearchCurlCffi(unittest.TestCase):
    """Tests for the curl-cffi path of _search_duckduckgo (when _HAS_CURL_CFFI=True)."""

    def test_curl_cffi_success_parses_results(self):
        fake_resp = mock.Mock()
        fake_resp.status_code = 200
        fake_resp.text = _DDG_SAMPLE_HTML
        with mock.patch.object(harvest, "_HAS_CURL_CFFI", True), \
             mock.patch("harvest.curl_cffi_requests") as mock_curl:
            mock_curl.get.return_value = fake_resp
            results, reason = harvest._search_duckduckgo({}, "query", 5)
        self.assertIsNone(reason)
        self.assertTrue(len(results) > 0)
        mock_curl.get.assert_called_once()

    def test_curl_cffi_non_200_returns_error(self):
        fake_resp = mock.Mock()
        fake_resp.status_code = 403
        with mock.patch.object(harvest, "_HAS_CURL_CFFI", True), \
             mock.patch("harvest.curl_cffi_requests") as mock_curl:
            mock_curl.get.return_value = fake_resp
            result, reason = harvest._search_duckduckgo({}, "query", 5)
        self.assertIsNone(result)
        self.assertIn("HTTP 403", reason)

    def test_curl_cffi_exception_returns_error(self):
        with mock.patch.object(harvest, "_HAS_CURL_CFFI", True), \
             mock.patch("harvest.curl_cffi_requests") as mock_curl:
            mock_curl.get.side_effect = RuntimeError("connection reset")
            result, reason = harvest._search_duckduckgo({}, "query", 5)
        self.assertIsNone(result)
        self.assertIn("curl-cffi request failed", reason)

    def test_curl_cffi_uses_impersonate_from_cfg(self):
        fake_resp = mock.Mock()
        fake_resp.status_code = 200
        fake_resp.text = "<html></html>"
        with mock.patch.object(harvest, "_HAS_CURL_CFFI", True), \
             mock.patch("harvest.curl_cffi_requests") as mock_curl:
            mock_curl.get.return_value = fake_resp
            harvest._search_duckduckgo({"impersonate": "safari"}, "q", 5)
        call_kwargs = mock_curl.get.call_args[1]
        self.assertEqual(call_kwargs["impersonate"], "safari")


class TestSearchBackendMissingKeySkips(unittest.TestCase):
    def test_tavily_missing_key_returns_none_not_raise(self):
        result, reason = harvest._search_tavily({"api_key_env": "NONEXISTENT_TAVILY_KEY_VAR"}, "q", 5)
        self.assertIsNone(result)
        self.assertIn("not set", reason)

    def test_gemini_grounding_missing_key_returns_none_not_raise(self):
        cfg = base_config()
        cfg["gateway"]["api_key_env"] = "NONEXISTENT_GATEWAY_KEY_VAR"
        result, reason = harvest._search_gemini_grounding({"model": "g"}, "q", 5, cfg)
        self.assertIsNone(result)
        self.assertIn("not set", reason)
        self.assertIn("gemini-grounding", reason)

    def test_missing_key_backend_falls_through_to_next_in_do_search(self):
        journal = []
        cfg = base_config()
        backends = [
            ({"type": "tavily", "api_key_env": "NONEXISTENT_TAVILY_KEY_VAR"}, harvest.RateLimiter(0)),
            ({"type": "duckduckgo"}, harvest.RateLimiter(0)),
        ]
        with mock.patch("harvest.urllib.request.urlopen",
                         return_value=FakeHTTPResponse(_DDG_SAMPLE_HTML.encode("utf-8"))):
            result = harvest.do_search("query", "en", backends, journal, cfg)
        data = json.loads(result)
        self.assertTrue(data["results"])
        self.assertEqual(journal[0]["backend"], "duckduckgo")
        self.assertEqual(len(journal[0]["attempts"]), 1)
        self.assertEqual(journal[0]["attempts"][0]["backend"], "tavily")
        self.assertIn("not set", journal[0]["attempts"][0]["error"])


# ---------------------------------------------------------------------------
# gemini-grounding search backend (real Gemini-native grounding, replaces
# the old fake gateway-gemini which asked the model to recall/invent URLs)
# ---------------------------------------------------------------------------

def _grounding_chunk(uri, title):
    return {"web": {"uri": uri, "title": title}}


def _grounding_response(chunks):
    return {"candidates": [{"content": {}, "groundingMetadata": {"groundingChunks": chunks}}]}


class TestGeminiGroundingSearch(unittest.TestCase):
    def test_resolves_redirect_chunks_to_real_urls(self):
        cfg = base_config()
        chunks = [
            _grounding_chunk("https://vertexaisearch.cloud.google.com/grounding-api-redirect/1", "example.com"),
            _grounding_chunk("https://vertexaisearch.cloud.google.com/grounding-api-redirect/2", "other.com"),
        ]
        with mock.patch.dict(os.environ, {"TEST_GATEWAY_KEY": "fake-key"}), \
             mock.patch("harvest._http_json_post", return_value=_grounding_response(chunks)), \
             mock.patch("harvest._resolve_grounding_redirect",
                         side_effect=["https://example.com/real", "https://other.com/real"]):
            results, reason = harvest._search_gemini_grounding({"model": "gemini-3.5-flash"}, "q", 5, cfg)
        self.assertIsNone(reason)
        self.assertEqual([r["url"] for r in results], ["https://example.com/real", "https://other.com/real"])
        self.assertEqual(results[0]["title"], "example.com")
        self.assertEqual(results[0]["snippet"], "example.com")

    def test_derives_native_endpoint_and_google_search_payload(self):
        # Locks the exact code path the PR fixes (the rstrip('/v1') trap):
        # origin is derived via urlsplit and the /v1 path is dropped, the
        # native generateContent endpoint is targeted, and the payload carries
        # the built-in google_search tool. A regression mangling any of these
        # would otherwise pass the whole suite (other cases only inspect the
        # parsed result, never what was sent).
        cfg = base_config()  # gateway.base_url == "https://gw.example.com/v1"
        chunks = [_grounding_chunk(
            "https://vertexaisearch.cloud.google.com/grounding-api-redirect/1", "example.com")]
        with mock.patch.dict(os.environ, {"TEST_GATEWAY_KEY": "fake-key"}), \
             mock.patch("harvest._http_json_post", return_value=_grounding_response(chunks)) as post_mock, \
             mock.patch("harvest._resolve_grounding_redirect", return_value="https://example.com/real"):
            harvest._search_gemini_grounding({"model": "gemini-3.5-flash"}, "q", 5, cfg)
        sent_url, sent_payload = post_mock.call_args.args[0], post_mock.call_args.args[1]
        self.assertEqual(
            sent_url, "https://gw.example.com/v1beta/models/gemini-3.5-flash:generateContent")
        self.assertEqual(sent_payload["tools"], [{"google_search": {}}])
        self.assertEqual(sent_payload["contents"][0]["role"], "user")

    def test_missing_grounding_metadata_degrades_with_reason(self):
        cfg = base_config()
        with mock.patch.dict(os.environ, {"TEST_GATEWAY_KEY": "fake-key"}), \
             mock.patch("harvest._http_json_post", return_value={"candidates": [{"content": {}}]}):
            result, reason = harvest._search_gemini_grounding({"model": "g"}, "q", 5, cfg)
        self.assertIsNone(result)
        self.assertIn("no grounding chunks", reason)

    def test_unresolvable_chunk_skipped_others_kept(self):
        cfg = base_config()
        chunks = [
            _grounding_chunk("https://vertexaisearch.cloud.google.com/grounding-api-redirect/1", "dead.com"),
            _grounding_chunk("https://vertexaisearch.cloud.google.com/grounding-api-redirect/2", "alive.com"),
        ]
        with mock.patch.dict(os.environ, {"TEST_GATEWAY_KEY": "fake-key"}), \
             mock.patch("harvest._http_json_post", return_value=_grounding_response(chunks)), \
             mock.patch("harvest._resolve_grounding_redirect", side_effect=[None, "https://alive.com/real"]):
            results, reason = harvest._search_gemini_grounding({"model": "g"}, "q", 5, cfg)
        self.assertIsNone(reason)
        self.assertEqual([r["url"] for r in results], ["https://alive.com/real"])

    def test_all_chunks_unresolvable_returns_none_with_reason(self):
        cfg = base_config()
        chunks = [_grounding_chunk("https://vertexaisearch.cloud.google.com/grounding-api-redirect/1", "dead.com")]
        with mock.patch.dict(os.environ, {"TEST_GATEWAY_KEY": "fake-key"}), \
             mock.patch("harvest._http_json_post", return_value=_grounding_response(chunks)), \
             mock.patch("harvest._resolve_grounding_redirect", return_value=None):
            result, reason = harvest._search_gemini_grounding({"model": "g"}, "q", 5, cfg)
        self.assertIsNone(result)
        self.assertIn("no resolvable source URLs", reason)

    def test_missing_key_returns_none_not_raise(self):
        cfg = base_config()
        cfg["gateway"]["api_key_env"] = "NONEXISTENT_GATEWAY_KEY_VAR"
        with mock.patch("harvest._http_json_post") as m:
            result, reason = harvest._search_gemini_grounding({"model": "g"}, "q", 5, cfg)
        self.assertIsNone(result)
        self.assertIn("not set", reason)
        m.assert_not_called()


class TestResolveGroundingRedirect(unittest.TestCase):
    def test_non_grounding_host_rejected_without_any_network_call(self):
        with mock.patch("harvest._no_redirect_opener.open") as m:
            result = harvest._resolve_grounding_redirect("http://169.254.169.254/", 5)
        self.assertIsNone(result)
        m.assert_not_called()

    def test_localhost_host_rejected_without_any_network_call(self):
        with mock.patch("harvest._no_redirect_opener.open") as m:
            result = harvest._resolve_grounding_redirect("http://127.0.0.1/", 5)
        self.assertIsNone(result)
        m.assert_not_called()

    def test_grounding_host_redirect_returns_location(self):
        uri = "https://vertexaisearch.cloud.google.com/grounding-api-redirect/1"
        err = harvest.urllib.error.HTTPError(
            url=uri, code=302, msg="Found",
            hdrs={"Location": "https://real.example.com/article"}, fp=io.BytesIO(b""))
        with mock.patch("harvest._no_redirect_opener.open", side_effect=err):
            result = harvest._resolve_grounding_redirect(uri, 5)
        self.assertEqual(result, "https://real.example.com/article")

    def test_grounding_host_network_error_returns_none(self):
        uri = "https://vertexaisearch.cloud.google.com/grounding-api-redirect/1"
        with mock.patch("harvest._no_redirect_opener.open",
                         side_effect=harvest.urllib.error.URLError("connection refused")):
            result = harvest._resolve_grounding_redirect(uri, 5)
        self.assertIsNone(result)

    def test_malformed_uri_returns_none_without_raising(self):
        # uri is model-controlled grounding output; an unterminated IPv6
        # literal makes urlsplit raise ValueError -- must be swallowed and
        # dropped, never propagated to abort the whole backend.
        with mock.patch("harvest._no_redirect_opener.open") as m:
            result = harvest._resolve_grounding_redirect("http://[::1", 5)
        self.assertIsNone(result)
        m.assert_not_called()

    def test_grounding_host_non_redirect_200_returns_none_and_closes(self):
        # A genuine 200 (short link resolved to nothing citable) -> drop the
        # chunk (None) and close the response rather than leak it.
        uri = "https://vertexaisearch.cloud.google.com/grounding-api-redirect/1"
        fake_resp = mock.Mock()
        with mock.patch("harvest._no_redirect_opener.open", return_value=fake_resp):
            result = harvest._resolve_grounding_redirect(uri, 5)
        self.assertIsNone(result)
        fake_resp.close.assert_called_once()


class TestGeminiGroundingFallThrough(unittest.TestCase):
    def test_primary_backend_failure_falls_through_to_real_gemini_grounding(self):
        # Regression for the fake-gateway-gemini removal: primary backend
        # failing must land on gemini-grounding's real retrieved results,
        # not get masked by a fake always-succeeds fallback.
        journal = []
        cfg = base_config()
        backends = [
            ({"type": "tavily", "api_key_env": "TAVILY_API_KEY"}, harvest.RateLimiter(0)),
            ({"type": "gemini-grounding", "model": "g"}, harvest.RateLimiter(0)),
        ]
        real_results = [{"url": "https://real.example.com/article", "title": "t", "snippet": "s"}]
        with mock.patch("harvest.call_search_backend", side_effect=[None, real_results]):
            result = harvest.do_search("q", "en", backends, journal, cfg)
        data = json.loads(result)
        self.assertEqual(data["results"][0]["url"], "https://real.example.com/article")
        search_entries = [e for e in journal if e.get("tool") == "search"]
        self.assertEqual(search_entries[0]["backend"], "gemini-grounding")


# ---------------------------------------------------------------------------
# S1: grounding prompt asks for the complete source set, never a hard
# "you MUST search" constraint (measured: the completeness line took the
# hit rate from ~60% to 100%; the hard constraint was tested and dropped --
# no measured gain, added thinking-token latency).
# ---------------------------------------------------------------------------

class TestGroundingPromptCompleteness(unittest.TestCase):
    def test_prompt_demands_complete_source_set(self):
        prompt = harvest._GROUNDING_SEARCH_PROMPT
        self.assertIn("COMPLETE set", prompt)
        self.assertIn("do not truncate", prompt)

    def test_prompt_has_no_hard_must_call_constraint(self):
        self.assertNotIn("You MUST", harvest._GROUNDING_SEARCH_PROMPT)


# ---------------------------------------------------------------------------
# S2: thinkingBudget is opt-in via backend config ("thinking_budget") and
# strictly back-compat -- omitting the key must send byte-for-byte the same
# payload as before (no generationConfig field at all), never a payload with
# an implicit default value.
# ---------------------------------------------------------------------------

class TestGroundingThinkingBudget(unittest.TestCase):
    def _run(self, cfg_overrides):
        cfg = base_config()
        chunk = _grounding_chunk(
            "https://vertexaisearch.cloud.google.com/grounding-api-redirect/1", "example.com")
        backend_cfg = {"model": "gemini-3.5-flash", **cfg_overrides}
        with mock.patch.dict(os.environ, {"TEST_GATEWAY_KEY": "fake-key"}), \
             mock.patch("harvest._http_json_post", return_value=_grounding_response([chunk])) as post_mock, \
             mock.patch("harvest._resolve_grounding_redirect", return_value="https://example.com/real"):
            harvest._search_gemini_grounding(backend_cfg, "q", 5, cfg)
        return post_mock.call_args.args[1]

    def test_thinking_budget_configured_adds_generation_config(self):
        payload = self._run({"thinking_budget": 0})
        self.assertEqual(payload["generationConfig"]["thinkingConfig"]["thinkingBudget"], 0)

    def test_thinking_budget_absent_omits_generation_config_entirely(self):
        # Not "defaults to something" -- the key must be fully absent from
        # the payload so a pre-upgrade config sends an identical request.
        payload = self._run({})
        self.assertNotIn("generationConfig", payload)


# ---------------------------------------------------------------------------
# S3: redirect resolution runs in parallel (measured 18.2s serial -> 2.5s
# parallel for 16 chunks) but must preserve chunk submission order in the
# final result set and must not let one raising uri take down the others --
# mirrors _run_fetch_calls_parallel's index-preallocate +
# future-to-index + as_completed-fills-by-original-index pattern exactly.
# ---------------------------------------------------------------------------

class TestGroundingRedirectResolutionParallel(unittest.TestCase):
    def test_parallel_resolution_preserves_order_dedups_and_skips_exceptions(self):
        cfg = base_config()
        uri1 = "https://vertexaisearch.cloud.google.com/grounding-api-redirect/1"
        uri2 = "https://vertexaisearch.cloud.google.com/grounding-api-redirect/2"
        uri3 = "https://vertexaisearch.cloud.google.com/grounding-api-redirect/3"
        uri4 = "https://vertexaisearch.cloud.google.com/grounding-api-redirect/4"
        chunks = [
            _grounding_chunk(uri1, "a.com"),
            _grounding_chunk(uri2, "raises.com"),
            _grounding_chunk(uri3, "b.com"),
            _grounding_chunk(uri4, "dup-of-a.com"),
        ]

        # Keyed by uri, not by call order -- as_completed's scheduling order
        # is not deterministic, so the fake must resolve correctly regardless
        # of which thread finishes first. uri2 raises to prove a single bad
        # chunk can't take down the whole backend; uri4 resolves to the same
        # real URL as uri1 to prove dedup runs on the order-restored array.
        def fake_resolve(uri, timeout):
            return {
                uri1: "https://a.com/real",
                uri2: RuntimeError("boom"),
                uri3: "https://b.com/real",
                uri4: "https://a.com/real",
            }[uri]

        def fake_resolve_side_effect(uri, timeout):
            result = fake_resolve(uri, timeout)
            if isinstance(result, Exception):
                raise result
            return result

        with mock.patch.dict(os.environ, {"TEST_GATEWAY_KEY": "fake-key"}), \
             mock.patch("harvest._http_json_post", return_value=_grounding_response(chunks)), \
             mock.patch("harvest._resolve_grounding_redirect", side_effect=fake_resolve_side_effect):
            results, reason = harvest._search_gemini_grounding({"model": "g"}, "q", 5, cfg)

        self.assertIsNone(reason)
        # chunk2 (exception) dropped, chunk4 (dedup of chunk1's real url)
        # dropped -- submission order (1, 3) survives untouched.
        self.assertEqual([r["url"] for r in results], ["https://a.com/real", "https://b.com/real"])


# ---------------------------------------------------------------------------
# gateway chat/completions retry (shared by panel loop and judge)
# ---------------------------------------------------------------------------

def _http_error(code):
    import io
    return harvest.urllib.error.HTTPError(url="http://gw/chat/completions", code=code, msg="err",
                                           hdrs=None, fp=io.BytesIO(b""))


class TestGatewayRetry(unittest.TestCase):
    def test_503_then_503_then_200_recovers(self):
        ok_response = {"choices": [{"message": {"role": "assistant", "content": "hi"}}]}
        with mock.patch("harvest_clients.base._http_json_post", side_effect=[_http_error(503), _http_error(503), ok_response]) as m, \
             mock.patch("harvest_clients.base.time.sleep") as sleep_mock:
            result = harvest._http_json_post_with_retry("http://gw/chat/completions", {}, {}, 5)
        self.assertEqual(result, ok_response)
        self.assertEqual(m.call_count, 3)
        sleep_mock.assert_has_calls([mock.call(5), mock.call(15)])

    def test_403_persistent_failure_retries_once_then_gives_up(self):
        with mock.patch("harvest_clients.base._http_json_post", side_effect=[_http_error(403), _http_error(403)]) as m, \
             mock.patch("harvest_clients.base.time.sleep") as sleep_mock:
            with self.assertRaises(RuntimeError) as ctx:
                harvest._http_json_post_with_retry("http://gw/chat/completions", {}, {}, 5)
        self.assertEqual(m.call_count, 2)  # 1 retry -> 2 attempts total
        sleep_mock.assert_called_once_with(5)
        self.assertIn("HTTP 403 after 2 attempts", str(ctx.exception))

    def test_429_backs_off_and_recovers(self):
        ok_response = {"choices": [{"message": {"role": "assistant", "content": "hi"}}]}
        with mock.patch("harvest_clients.base._http_json_post", side_effect=[_http_error(429), ok_response]) as m, \
             mock.patch("harvest_clients.base.time.sleep") as sleep_mock:
            result = harvest._http_json_post_with_retry("http://gw/chat/completions", {}, {}, 5)
        self.assertEqual(result, ok_response)
        self.assertEqual(m.call_count, 2)
        sleep_mock.assert_called_once_with(5)  # first backoff in the transient schedule

    def test_5xx_exhausted_after_three_attempts_raises_with_status_and_count(self):
        with mock.patch("harvest_clients.base._http_json_post", side_effect=[_http_error(503), _http_error(503), _http_error(503)]) as m, \
             mock.patch("harvest_clients.base.time.sleep"):
            with self.assertRaises(RuntimeError) as ctx:
                harvest._http_json_post_with_retry("http://gw/chat/completions", {}, {}, 5)
        self.assertEqual(m.call_count, 3)
        self.assertIn("HTTP 503 after 3 attempts", str(ctx.exception))

    def test_no_lock_held_across_retry_sleep(self):
        # The retry path has no RateLimiter/lock in its call chain at all --
        # assert sleep is reached and returns without any lock object ever
        # entering the picture (structural guarantee, not just a mock check).
        calls = []

        def fake_sleep(seconds):
            calls.append(seconds)

        with mock.patch("harvest_clients.base._http_json_post", side_effect=[_http_error(503), {"choices": [{"message": {"content": "ok"}}]}]), \
             mock.patch("harvest_clients.base.time.sleep", side_effect=fake_sleep):
            harvest._http_json_post_with_retry("http://gw/chat/completions", {}, {}, 5)
        self.assertEqual(calls, [5])

    def test_worker_records_http_status_and_attempt_count_in_reason(self):
        # Every call.complete() exhausts its own 3-attempt 503 retry budget,
        # so both the main loop's call (caught, breaks to forced synthesis)
        # and the forced-synthesis call itself raise -- landing on
        # synthesis_failed with the underlying HTTP detail preserved.
        class FlakyClient:
            def complete(self, messages, tools):
                url = "http://gw/chat/completions"
                return harvest._http_json_post_with_retry(url, {}, {}, 5)

        with mock.patch("harvest_clients.base._http_json_post",
                         side_effect=[_http_error(503), _http_error(503), _http_error(503),
                                      _http_error(503), _http_error(503), _http_error(503)]), \
             mock.patch("harvest_clients.base.time.sleep"):
            result = harvest.run_worker("m1", "model-a", FlakyClient(), base_config(), [], [], "goal", [], None)
        self.assertEqual(result.status, "FAILED")
        self.assertTrue(result.reason.startswith("synthesis_failed (RuntimeError):"), result.reason)
        self.assertIn("HTTP 503 after 3 attempts", result.reason)

    def test_gateway_client_complete_uses_retry_wrapper(self):
        client = harvest.GatewayClient("http://gw", "key", "model-x", 5)
        ok_response = {"choices": [{"message": {"content": "hi"}}]}
        with mock.patch("harvest_clients.base._http_json_post_with_retry", return_value=ok_response) as m:
            result = client.complete(messages=[{"role": "user", "content": "x"}], tools=None)
        self.assertEqual(result, ok_response)
        m.assert_called_once()

    def test_socket_timeout_retries_then_recovers(self):
        # A network-layer timeout (no HTTP status at all) must be retried
        # under the same transient backoff schedule as a 5xx, not raised
        # straight through on the first failure.
        ok_response = {"choices": [{"message": {"role": "assistant", "content": "hi"}}]}
        with mock.patch("harvest_clients.base._http_json_post", side_effect=[socket.timeout("timed out"), ok_response]) as m, \
             mock.patch("harvest_clients.base.time.sleep") as sleep_mock:
            result = harvest._http_json_post_with_retry("http://gw/chat/completions", {}, {}, 5)
        self.assertEqual(result, ok_response)
        self.assertEqual(m.call_count, 2)
        sleep_mock.assert_called_once_with(5)  # first backoff in the transient schedule

    def test_socket_timeout_exhausted_raises_runtime_error(self):
        with mock.patch("harvest_clients.base._http_json_post",
                         side_effect=[socket.timeout("t1"), socket.timeout("t2"), socket.timeout("t3")]) as m, \
             mock.patch("harvest_clients.base.time.sleep"):
            with self.assertRaises(RuntimeError) as ctx:
                harvest._http_json_post_with_retry("http://gw/chat/completions", {}, {}, 5)
        self.assertEqual(m.call_count, 3)
        self.assertIn("after 3 attempts", str(ctx.exception))

    def test_urlerror_without_status_also_retried(self):
        # urllib.error.URLError (e.g. connection refused / DNS failure) has
        # no .code at all -- must be classified transient, same as timeout.
        ok_response = {"choices": [{"message": {"role": "assistant", "content": "hi"}}]}
        with mock.patch("harvest_clients.base._http_json_post",
                         side_effect=[harvest.urllib.error.URLError("connection refused"), ok_response]) as m, \
             mock.patch("harvest_clients.base.time.sleep") as sleep_mock:
            result = harvest._http_json_post_with_retry("http://gw/chat/completions", {}, {}, 5)
        self.assertEqual(result, ok_response)
        self.assertEqual(m.call_count, 2)
        sleep_mock.assert_called_once_with(5)


# ---------------------------------------------------------------------------
# search / fetch backend degradation + read_local
# ---------------------------------------------------------------------------

class TestBackendDegradation(unittest.TestCase):
    def setUp(self):
        self.config = base_config()
        self._orig_getaddrinfo = socket.getaddrinfo
        self._orig_real = harvest._real_getaddrinfo
        harvest._real_getaddrinfo = lambda host, *a, **kw: [(2, 1, 6, "", ("93.184.216.34", 0))]
        harvest.install_ssrf_guard()

    def tearDown(self):
        socket.getaddrinfo = self._orig_getaddrinfo
        harvest._real_getaddrinfo = self._orig_real

    def test_search_falls_through_to_second_backend(self):
        journal = []
        backends = [
            ({"type": "gemini-cli", "model": "x"}, harvest.RateLimiter(0)),
            ({"type": "duckduckgo"}, harvest.RateLimiter(0)),
        ]
        with mock.patch("harvest.call_search_backend", side_effect=[None, [{"url": "https://a.com", "title": "t", "snippet": "s"}]]):
            result = harvest.do_search("q", "en", backends, journal, self.config)
        data = json.loads(result)
        self.assertEqual(data["results"][0]["url"], "https://a.com")
        self.assertEqual(journal[0]["backend"], "duckduckgo")

    def test_search_all_backends_fail(self):
        journal = []
        backends = [({"type": "gemini-cli", "model": "x"}, harvest.RateLimiter(0))]
        with mock.patch("harvest.call_search_backend", return_value=None):
            result = harvest.do_search("q", "en", backends, journal, self.config)
        data = json.loads(result)
        self.assertEqual(data["results"], [])
        self.assertIn("error", data)

    def test_search_falls_through_when_first_backend_results_all_blacklisted(self):
        # copilot review on #25: a backend whose results are entirely
        # blacklisted must be treated as a degrade-worthy failure, not a
        # genuine empty answer -- the chain must still try the next backend.
        journal = []
        backends = [
            ({"type": "gemini-cli", "model": "x"}, harvest.RateLimiter(0)),
            ({"type": "duckduckgo"}, harvest.RateLimiter(0)),
        ]
        with mock.patch("harvest.call_search_backend", side_effect=[
            [{"url": "https://blog.csdn.net/x", "title": "t", "snippet": "s"}],
            [{"url": "https://good.com/y", "title": "t2", "snippet": "s2"}],
        ]):
            result = harvest.do_search("q", "en", backends, journal, self.config)
        data = json.loads(result)
        self.assertEqual([r["url"] for r in data["results"]], ["https://good.com/y"])
        self.assertEqual(journal[0]["backend"], "duckduckgo")

    def test_search_results_filtered_by_blacklist(self):
        journal = []
        backends = [({"type": "gemini-cli", "model": "x"}, harvest.RateLimiter(0))]
        results = [{"url": "https://blog.csdn.net/x", "title": "t", "snippet": "s"},
                   {"url": "https://good.com/x", "title": "t", "snippet": "s"}]
        with mock.patch("harvest.call_search_backend", return_value=results):
            result = harvest.do_search("q", "en", backends, journal, self.config)
        data = json.loads(result)
        urls = [r["url"] for r in data["results"]]
        self.assertNotIn("https://blog.csdn.net/x", urls)
        self.assertIn("https://good.com/x", urls)

    def test_fetch_falls_through_to_second_backend(self):
        journal = []
        backends = [
            ({"type": "tavily-extract", "api_key_env": "X"}, harvest.RateLimiter(0)),
            ({"type": "urllib-ua"}, harvest.RateLimiter(0)),
        ]
        with mock.patch("harvest.call_fetch_backend", side_effect=[None, "full page text"]):
            result = harvest.do_fetch("https://good.com/x", backends, journal, self.config)
        self.assertEqual(result, "full page text")
        self.assertEqual(journal[0]["backend"], "urllib-ua")

    def test_fetch_all_backends_fail(self):
        journal = []
        backends = [({"type": "urllib-ua"}, harvest.RateLimiter(0))]
        with mock.patch("harvest.call_fetch_backend", return_value=None):
            result = harvest.do_fetch("https://good.com/x", backends, journal, self.config)
        data = json.loads(result)
        self.assertIn("error", data)

    def test_fetch_blacklisted_domain_rejected_before_backends(self):
        journal = []
        backends = [({"type": "urllib-ua"}, harvest.RateLimiter(0))]
        with mock.patch("harvest.call_fetch_backend") as m:
            result = harvest.do_fetch("https://blog.csdn.net/x", backends, journal, self.config)
        m.assert_not_called()
        self.assertEqual(journal[0]["blocked"], "blacklist")

    def test_fetch_ssrf_private_ip_rejected(self):
        harvest._real_getaddrinfo = lambda host, *a, **kw: [(2, 1, 6, "", ("127.0.0.1", 0))]
        harvest.install_ssrf_guard()
        journal = []
        backends = [({"type": "urllib-ua"}, harvest.RateLimiter(0))]
        with mock.patch("harvest.call_fetch_backend") as m:
            result = harvest.do_fetch("http://internal.local/x", backends, journal, self.config)
        m.assert_not_called()
        self.assertEqual(journal[0]["blocked"], "ssrf")

    def test_fetch_truncates_to_max_chars(self):
        journal = []
        cfg = base_config()
        cfg["limits"]["fetch_max_chars"] = 5
        backends = [({"type": "urllib-ua"}, harvest.RateLimiter(0))]
        with mock.patch("harvest.call_fetch_backend", return_value="0123456789"):
            result = harvest.do_fetch("https://good.com/x", backends, journal, cfg)
        self.assertEqual(result, "01234")

    def test_search_journal_records_failed_attempts_before_success(self):
        # Exercises the real call_search_backend dispatch (not mocked out),
        # so each failed backend's (result, reason) actually populates the
        # attempts list threaded through do_search.
        journal = []
        backends = [
            ({"type": "tavily", "api_key_env": "NONEXISTENT_TAVILY_KEY_VAR"}, harvest.RateLimiter(0)),
            ({"type": "duckduckgo"}, harvest.RateLimiter(0)),
        ]
        with mock.patch("harvest.urllib.request.urlopen",
                         return_value=FakeHTTPResponse(_DDG_SAMPLE_HTML.encode("utf-8"))):
            result = harvest.do_search("q", "en", backends, journal, self.config)
        data = json.loads(result)
        self.assertTrue(data["results"])
        attempts = journal[0]["attempts"]
        self.assertEqual(len(attempts), 1)
        self.assertEqual(attempts[0]["backend"], "tavily")
        self.assertIn("not set", attempts[0]["error"])

    def test_search_journal_records_all_attempts_on_total_failure(self):
        journal = []
        backends = [
            ({"type": "tavily", "api_key_env": "NONEXISTENT_TAVILY_KEY_VAR"}, harvest.RateLimiter(0)),
            ({"type": "duckduckgo"}, harvest.RateLimiter(0)),
        ]
        with mock.patch.object(harvest, "_HAS_CURL_CFFI", False), \
             mock.patch("harvest.urllib.request.urlopen", side_effect=OSError("network down")):
            harvest.do_search("q", "en", backends, journal, self.config)
        attempts = journal[0]["attempts"]
        self.assertEqual(len(attempts), 2)
        self.assertEqual([a["backend"] for a in attempts], ["tavily", "duckduckgo"])

    def test_fetch_journal_records_failed_attempts_before_success(self):
        journal = []
        backends = [
            ({"type": "tavily-extract", "api_key_env": "NONEXISTENT_TAVILY_KEY_VAR"}, harvest.RateLimiter(0)),
            ({"type": "urllib-ua"}, harvest.RateLimiter(0)),
        ]
        with mock.patch("harvest.urllib.request.urlopen",
                         return_value=FakeHTTPResponse(b"full page text")):
            result = harvest.do_fetch("https://good.com/x", backends, journal, self.config)
        self.assertEqual(result, "full page text")
        attempts = journal[0]["attempts"]
        self.assertEqual(len(attempts), 1)
        self.assertEqual(attempts[0]["backend"], "tavily-extract")
        self.assertIn("not set", attempts[0]["error"])


class TestUrllibUaHtmlStripping(unittest.TestCase):
    def _fetch(self, html_body, max_chars=20000):
        with mock.patch("harvest.urllib.request.urlopen",
                         return_value=FakeHTTPResponse(html_body.encode("utf-8"))):
            return harvest._fetch_urllib_ua({}, "https://a.com/x", 5, max_chars)

    def test_tags_stripped_from_output(self):
        content, reason = self._fetch("<html><body><p>Hello <b>world</b>.</p></body></html>")
        self.assertIsNone(reason)
        self.assertNotIn("<", content)
        self.assertIn("Hello world", content)

    def test_script_and_style_block_contents_removed_not_just_tags(self):
        content, _ = self._fetch(
            "<html><head><style>.x{color:red}</style></head>"
            "<body><script>var x = 1;</script><p>Real text.</p></body></html>")
        self.assertNotIn("color:red", content)
        self.assertNotIn("var x", content)
        self.assertIn("Real text.", content)

    def test_html_entities_decoded(self):
        content, _ = self._fetch("<p>Fish &amp; chips &mdash; a &quot;classic&quot;.</p>")
        self.assertIn('Fish & chips', content)
        self.assertIn('"classic"', content)

    def test_cross_tag_excerpt_matches_after_stripping(self):
        # Regression for the real smoke-test failure: an excerpt spanning
        # an inline <a> tag boundary must match once tags are stripped,
        # even though the raw HTML has markup breaking up the sentence.
        journal = [{"tool": "fetch", "url": "https://a.com/x",
                    "content": self._fetch(
                        "<p>SQLite uses the <a href=\"/wal\">WAL</a> file for durability.</p>")[0]}]
        claims = harvest.assign_claim_ids("m1", [
            {"claim": "c", "excerpt": "SQLite uses the WAL file for durability", "url": "https://a.com/x"}])
        idx = harvest.build_fetch_index(journal)
        urls = harvest.build_journal_url_set(journal)
        valid, invalid = harvest.validate_claims(claims, idx, urls)
        self.assertEqual(len(valid), 1)
        self.assertEqual(invalid, [])

    def test_truncation_happens_after_stripping_not_before(self):
        # fetch_max_chars must be spent on prose, not on markup that gets
        # discarded anyway -- strip first, then do_fetch() truncates.
        html_body = "<div>" + "<span></span>" * 500 + "keep this text" + "</div>"
        journal = []
        cfg = base_config()
        cfg["limits"]["fetch_max_chars"] = 200
        backends = [({"type": "urllib-ua"}, harvest.RateLimiter(0))]
        orig_getaddrinfo = socket.getaddrinfo
        orig_real_getaddrinfo = harvest._real_getaddrinfo
        harvest._real_getaddrinfo = lambda host, *a, **kw: [(2, 1, 6, "", ("93.184.216.34", 0))]
        harvest.install_ssrf_guard()
        try:
            with mock.patch("harvest.urllib.request.urlopen",
                             return_value=FakeHTTPResponse(html_body.encode("utf-8"))):
                result = harvest.do_fetch("https://a.com/x", backends, journal, cfg)
        finally:
            harvest._real_getaddrinfo = orig_real_getaddrinfo
            socket.getaddrinfo = orig_getaddrinfo
        self.assertIn("keep this text", result)


@unittest.skipUnless(
    harvest._HAS_CURL_CFFI,
    "curl_cffi not installed: harvest.curl_cffi_requests is None, so "
    "mock.patch('harvest.curl_cffi_requests.get') cannot attach. These tests "
    "exercise the curl-cffi fetch backend and require the optional dependency.",
)
class TestCurlCffiFetch(unittest.TestCase):
    """curl-cffi is a soft dependency: libcurl (which it wraps) does its own
    C-layer DNS resolution, bypassing the Python-level SSRF guard entirely
    unless we resolve+pin every hop ourselves (see _fetch_curl_cffi())."""

    def setUp(self):
        self._orig_getaddrinfo = socket.getaddrinfo
        self._orig_real = harvest._real_getaddrinfo
        self._orig_has = harvest._HAS_CURL_CFFI
        harvest._HAS_CURL_CFFI = True
        harvest._real_getaddrinfo = lambda host, *a, **kw: [(2, 1, 6, "", ("93.184.216.34", 0))]
        harvest.install_ssrf_guard()

    def tearDown(self):
        socket.getaddrinfo = self._orig_getaddrinfo
        harvest._real_getaddrinfo = self._orig_real
        harvest._HAS_CURL_CFFI = self._orig_has

    def _fetch(self, url, timeout=5, max_chars=20000, config=None):
        with harvest.tool_request_guard():
            return harvest._fetch_curl_cffi({}, url, timeout, max_chars, config or base_config())

    def test_normal_fetch_strips_html_and_pins_resolved_ip(self):
        with mock.patch("harvest.curl_cffi_requests.get",
                         return_value=FakeCurlResponse(200, "<p>Hello <b>world</b>.</p>")) as m:
            result, reason = self._fetch("https://a.com/x")
        self.assertIsNone(reason)
        self.assertNotIn("<", result)
        self.assertIn("Hello world", result)
        kwargs = m.call_args.kwargs
        pin_list = kwargs["curl_options"][harvest.CurlCffiOpt.RESOLVE]
        self.assertEqual(pin_list, ["a.com:443:93.184.216.34"])
        self.assertFalse(kwargs["allow_redirects"])

    def test_private_host_blocked_before_any_curl_call(self):
        harvest._real_getaddrinfo = lambda host, *a, **kw: [(2, 1, 6, "", ("127.0.0.1", 0))]
        with mock.patch("harvest.curl_cffi_requests.get") as m:
            with self.assertRaises(harvest.SSRFBlocked):
                self._fetch("http://internal.local/x")
        m.assert_not_called()

    def test_redirect_hop_to_private_host_blocked(self):
        # First hop resolves fine (public IP from setUp); the Location it
        # redirects to must be independently re-resolved and re-guarded --
        # a compromised/malicious first hop can't smuggle an internal
        # target through by pointing a redirect at it.
        def fake_resolve(host, *a, **kw):
            if host == "internal.local":
                return [(2, 1, 6, "", ("127.0.0.1", 0))]
            return [(2, 1, 6, "", ("93.184.216.34", 0))]
        harvest._real_getaddrinfo = fake_resolve
        with mock.patch("harvest.curl_cffi_requests.get",
                         return_value=FakeCurlResponse(302, location="http://internal.local/x")):
            with self.assertRaises(harvest.SSRFBlocked):
                self._fetch("https://a.com/start")

    def test_redirect_hop_to_blacklisted_domain_rejected(self):
        with mock.patch("harvest.curl_cffi_requests.get",
                         return_value=FakeCurlResponse(302, location="https://blog.csdn.net/x")):
            result, reason = self._fetch("https://a.com/start")
        self.assertIsNone(result)
        self.assertIn("blacklisted", reason)

    def test_redirect_chain_follows_relative_location(self):
        responses = [
            FakeCurlResponse(301, location="/next"),
            FakeCurlResponse(200, "final content"),
        ]
        with mock.patch("harvest.curl_cffi_requests.get", side_effect=responses):
            result, reason = self._fetch("https://a.com/start")
        self.assertIsNone(reason)
        self.assertIn("final content", result)

    def test_exceeds_max_redirect_hops_fails(self):
        responses = [FakeCurlResponse(302, location=f"/hop{i}") for i in range(10)]
        with mock.patch("harvest.curl_cffi_requests.get", side_effect=responses):
            result, reason = self._fetch("https://a.com/start")
        self.assertIsNone(result)
        self.assertIn("max redirect hops", reason)

    def test_redirect_missing_location_header_fails(self):
        with mock.patch("harvest.curl_cffi_requests.get", return_value=FakeCurlResponse(302)):
            result, reason = self._fetch("https://a.com/start")
        self.assertIsNone(result)
        self.assertIn("Location", reason)

    def test_request_exception_degrades_with_reason(self):
        with mock.patch("harvest.curl_cffi_requests.get", side_effect=RuntimeError("boom")):
            result, reason = self._fetch("https://a.com/x")
        self.assertIsNone(result)
        self.assertIn("request failed", reason)

    def test_call_fetch_backend_dispatches_to_curl_cffi(self):
        cfg = base_config()
        with mock.patch("harvest._fetch_curl_cffi", return_value=("clean text", None)) as m:
            content = harvest.call_fetch_backend({"type": "curl-cffi"}, harvest.RateLimiter(0), "https://a.com/x", cfg)
        self.assertEqual(content, "clean text")
        m.assert_called_once()

    def test_low_speed_options_set_from_config(self):
        cfg = base_config()
        cfg["limits"]["fetch_low_speed_bytes_s"] = 999
        cfg["limits"]["fetch_low_speed_window_s"] = 7
        with mock.patch("harvest.curl_cffi_requests.get",
                         return_value=FakeCurlResponse(200, "<p>ok</p>")) as m:
            self._fetch("https://a.com/x", config=cfg)
        curl_options = m.call_args.kwargs["curl_options"]
        self.assertEqual(curl_options[harvest.CurlCffiOpt.LOW_SPEED_LIMIT], 999)
        self.assertEqual(curl_options[harvest.CurlCffiOpt.LOW_SPEED_TIME], 7)

    def test_timeout_tuple_connect_plus_read_equals_remaining_budget(self):
        # curl_cffi 0.15.0 sums (connect, read) into CURLOPT_TIMEOUT_MS for
        # non-stream calls -- so the read component must be
        # `remaining - connect`, not `remaining`, or the effective total
        # would be connect + remaining (over budget).
        with mock.patch("harvest.time.monotonic", side_effect=[0.0, 0.0]), \
             mock.patch("harvest.curl_cffi_requests.get",
                         return_value=FakeCurlResponse(200, "<p>ok</p>")) as m:
            self._fetch("https://a.com/x", timeout=20)
        conn, read = m.call_args.kwargs["timeout"]
        self.assertAlmostEqual(conn + read, 20, places=3)
        self.assertEqual(conn, 5)  # default fetch_connect_timeout_s

    def test_timeout_tuple_small_budget_selects_remaining_minus_epsilon(self):
        # When remaining < fetch_connect_timeout_s (here remaining=2 vs the
        # default connect cap of 5), `min(connect_timeout_s, remaining-0.1)`
        # must pick the second operand -- conn = remaining - 0.1, read =
        # 0.1. This locks down the epsilon fallback so it can't be
        # "simplified" to conn = remaining (which would zero out the read
        # component and reintroduce the libcurl 0ms-means-infinite hang).
        with mock.patch("harvest.time.monotonic", side_effect=[0.0, 0.0]), \
             mock.patch("harvest.curl_cffi_requests.get",
                         return_value=FakeCurlResponse(200, "<p>ok</p>")) as m:
            self._fetch("https://a.com/x", timeout=2)
        conn, read = m.call_args.kwargs["timeout"]
        self.assertAlmostEqual(conn, 1.9, places=3)
        self.assertAlmostEqual(read, 0.1, places=3)
        self.assertAlmostEqual(conn + read, 2, places=3)

    def test_cross_hop_deadline_exceeded_aborts_before_next_hop(self):
        # First hop resolves within budget and redirects; by the time the
        # second hop would fire, the shared deadline has less than 1s left
        # -- it must abort there instead of issuing another curl call.
        with mock.patch("harvest.time.monotonic", side_effect=[0.0, 0.0, 4.5]), \
             mock.patch("harvest.curl_cffi_requests.get",
                         return_value=FakeCurlResponse(302, location="/next")) as m:
            result, reason = self._fetch("https://a.com/start", timeout=5)
        self.assertIsNone(result)
        self.assertIn("deadline exceeded", reason)
        m.assert_called_once()

    def test_unmigrated_config_missing_new_limit_keys_still_works(self):
        # A config predating this change has none of the 3 new limits keys.
        # .get()+default must keep curl-cffi working rather than KeyError
        # -> swallowed by call_fetch_backend's broad except into a silent,
        # permanent "unexpected error".
        cfg = base_config()
        cfg["limits"] = {k: v for k, v in cfg["limits"].items()
                          if k not in ("fetch_connect_timeout_s", "fetch_low_speed_bytes_s",
                                       "fetch_low_speed_window_s")}
        with mock.patch("harvest.curl_cffi_requests.get",
                         return_value=FakeCurlResponse(200, "<p>legacy ok</p>")):
            result, reason = self._fetch("https://a.com/x", config=cfg)
        self.assertIsNone(reason)
        self.assertIn("legacy ok", result)

    def test_non_2xx_terminal_status_degrades_without_returning_body(self):
        # No challenge marker in the body -- this is gate 2 (plain HTTP
        # error), not gate 1. The body text must not leak into the reason.
        with mock.patch("harvest.curl_cffi_requests.get",
                         return_value=FakeCurlResponse(403, "<html>Access Denied</html>")):
            result, reason = self._fetch("https://a.com/x")
        self.assertIsNone(result)
        self.assertIn("HTTP 403", reason)
        self.assertNotIn("Access Denied", reason)

    def test_cloudflare_challenge_200_degrades(self):
        body = "<html><body><script src='/cdn-cgi/challenge-platform/h/g'></script></body></html>"
        with mock.patch("harvest.curl_cffi_requests.get",
                         return_value=FakeCurlResponse(200, body)):
            result, reason = self._fetch("https://a.com/x")
        self.assertIsNone(result)
        self.assertIn("challenge", reason)

    def test_cloudflare_challenge_403_reports_challenge_not_http_error(self):
        # Locks down gate ordering: challenge detection (gate 1) must fire
        # before the generic HTTP-status gate (gate 2), even on a 403.
        body = "<html><body><script src='/cdn-cgi/challenge-platform/h/g'></script></body></html>"
        with mock.patch("harvest.curl_cffi_requests.get",
                         return_value=FakeCurlResponse(403, body)):
            result, reason = self._fetch("https://a.com/x")
        self.assertIsNone(result)
        self.assertIn("challenge", reason)
        self.assertNotIn("HTTP 403", reason)

    def test_datadome_challenge_degrades(self):
        body = "<html><body><script src='https://ct.captcha-delivery.com/c.js'></script></body></html>"
        with mock.patch("harvest.curl_cffi_requests.get",
                         return_value=FakeCurlResponse(200, body)):
            result, reason = self._fetch("https://a.com/x")
        self.assertIsNone(result)
        self.assertIn("challenge", reason)

    def test_perimeterx_challenge_degrades(self):
        body = "<html><body><div id='px-captcha'></div></body></html>"
        with mock.patch("harvest.curl_cffi_requests.get",
                         return_value=FakeCurlResponse(200, body)):
            result, reason = self._fetch("https://a.com/x")
        self.assertIsNone(result)
        self.assertIn("challenge", reason)

    def test_imperva_challenge_degrades(self):
        # Mixed case in the source, verifying marker matching is
        # case-insensitive.
        body = "<html><body><div id='_Incapsula_Resource'></div></body></html>"
        with mock.patch("harvest.curl_cffi_requests.get",
                         return_value=FakeCurlResponse(200, body)):
            result, reason = self._fetch("https://a.com/x")
        self.assertIsNone(result)
        self.assertIn("challenge", reason)

    def test_large_page_with_marker_not_flagged(self):
        # A long-form article discussing Cloudflare Turnstile (e.g. a
        # deep-research task investigating WAF bypass techniques) must not
        # be misdetected as a challenge page just because it mentions
        # "cf-turnstile" -- the size gate lets anything >= 100KB through.
        body = "<p>" + "Cloudflare Turnstile 分析。" * 20000 + " cf-turnstile </p>"
        self.assertGreaterEqual(len(body), 100 * 1024)
        with mock.patch("harvest.curl_cffi_requests.get",
                         return_value=FakeCurlResponse(200, body)):
            result, reason = self._fetch("https://a.com/x")
        self.assertIsNone(reason)
        self.assertIn("Cloudflare Turnstile", result)

    def test_empty_body_does_not_crash(self):
        with mock.patch("harvest.curl_cffi_requests.get",
                         return_value=FakeCurlResponse(200, "")):
            result, reason = self._fetch("https://a.com/x")
        self.assertIsNone(reason)
        self.assertEqual(result, "")
        self.assertFalse(harvest._looks_like_challenge_page(None))
        self.assertFalse(harvest._looks_like_challenge_page(""))

    def test_small_page_quoting_challenge_prose_not_flagged(self):
        # Human-readable phrases like "just a moment" or vendor names like
        # "datadome" appearing in ordinary prose must not trigger a false
        # positive -- only the literal script/DOM/CDN artifacts do.
        body = "<p>Just a moment while we discuss the datadome product review.</p>"
        with mock.patch("harvest.curl_cffi_requests.get",
                         return_value=FakeCurlResponse(200, body)):
            result, reason = self._fetch("https://a.com/x")
        self.assertIsNone(reason)
        self.assertIn("Just a moment", result)


class TestCurlCffiStartupCheck(unittest.TestCase):
    """_check_curl_cffi_available() is the fail-fast gate: if the backend is
    configured but not installed, `run` must exit 4 with an actionable
    message before touching any state (cleanup/tombstone) or making an API
    call -- not silently degrade to the next fetch backend."""

    def setUp(self):
        self._orig_has = harvest._HAS_CURL_CFFI

    def tearDown(self):
        harvest._HAS_CURL_CFFI = self._orig_has

    def test_configured_but_missing_exits_4_with_install_instructions(self):
        harvest._HAS_CURL_CFFI = False
        cfg = base_config(fetch_backends=[{"type": "curl-cffi"}, {"type": "urllib-ua"}])
        with self.assertRaises(SystemExit) as ctx:
            with mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
                harvest._check_curl_cffi_available(cfg)
        self.assertEqual(ctx.exception.code, 4)
        self.assertIn("pip3 install --user curl_cffi", stderr.getvalue())

    def test_configured_and_installed_does_not_exit(self):
        harvest._HAS_CURL_CFFI = True
        cfg = base_config(fetch_backends=[{"type": "curl-cffi"}])
        harvest._check_curl_cffi_available(cfg)  # must not raise

    def test_not_configured_never_exits_regardless_of_install_state(self):
        harvest._HAS_CURL_CFFI = False
        cfg = base_config(fetch_backends=[{"type": "urllib-ua"}])
        harvest._check_curl_cffi_available(cfg)  # must not raise


class TestCallFetchBackendPerBackendTimeout(unittest.TestCase):
    """call_fetch_backend must read a per-backend `timeout_s` override before
    falling back to the shared call_timeout_s -- raw fetch (curl-cffi/
    urllib-ua) should be capped fast, while server-side renderers (jina/
    tavily) get more slack, without a one-size-fits-all timeout misjudging
    either."""

    def test_backend_with_timeout_s_uses_its_own_value(self):
        cfg = base_config()
        with mock.patch("harvest._fetch_curl_cffi", return_value=("text", None)) as m:
            harvest.call_fetch_backend({"type": "curl-cffi", "timeout_s": 25},
                                        harvest.RateLimiter(0), "https://a.com/x", cfg)
        self.assertEqual(m.call_args.args[2], 25)

    def test_jina_backend_with_timeout_s_uses_its_own_value(self):
        cfg = base_config()
        with mock.patch("harvest._fetch_jina_reader", return_value=("text", None)) as m:
            harvest.call_fetch_backend({"type": "jina-reader", "timeout_s": 60},
                                        harvest.RateLimiter(0), "https://a.com/x", cfg)
        self.assertEqual(m.call_args.args[2], 60)

    def test_backend_without_timeout_s_falls_back_to_call_timeout_s(self):
        cfg = base_config()  # call_timeout_s: 5, from base_config()
        with mock.patch("harvest._fetch_urllib_ua", return_value=("text", None)) as m:
            harvest.call_fetch_backend({"type": "urllib-ua"},
                                        harvest.RateLimiter(0), "https://a.com/x", cfg)
        self.assertEqual(m.call_args.args[2], cfg["limits"]["call_timeout_s"])


class TestFetchBackendsRealConfigChain(unittest.TestCase):
    """The shipped harvest.config.json is the actual chain used in
    production -- assert its shape directly so a future edit to the file
    can't silently break the curl-cffi -> jina-reader fallback order or
    drop the per-backend timeout_s fields these tests exercise elsewhere."""

    def setUp(self):
        config_path = Path(__file__).resolve().parent.parent / "scripts" / "harvest.config.json"
        self.config = harvest.load_config(config_path)

    def test_jina_reader_is_first_fallback_after_curl_cffi(self):
        types = [b["type"] for b in self.config["fetch_backends"]]
        self.assertEqual(types[0], "curl-cffi")
        self.assertEqual(types[1], "jina-reader")

    def test_all_backends_declare_timeout_s(self):
        for backend in self.config["fetch_backends"]:
            self.assertIn("timeout_s", backend, backend["type"])

    def test_raw_fetch_backends_capped_shorter_than_server_side_renderers(self):
        by_type = {b["type"]: b["timeout_s"] for b in self.config["fetch_backends"]}
        self.assertLess(by_type["curl-cffi"], by_type["jina-reader"])
        self.assertLess(by_type["urllib-ua"], by_type["tavily-extract"])

    def test_new_low_speed_limits_present_with_expected_defaults(self):
        limits = self.config["limits"]
        self.assertEqual(limits["fetch_connect_timeout_s"], 5)
        self.assertEqual(limits["fetch_low_speed_bytes_s"], 512)
        self.assertEqual(limits["fetch_low_speed_window_s"], 10)
        self.assertEqual(limits["call_timeout_s"], 180)  # unchanged, still used by LLM/search calls


class TestJinaReaderAuthHeader(unittest.TestCase):
    """_fetch_jina_reader's Authorization header must track JINA_API_KEY
    presence/absence -- guards against a regression when the fetch chain
    reorder (variant 2) promotes jina to the first fallback slot."""

    def _fetch(self, env):
        with mock.patch.dict(os.environ, env, clear=False), \
             mock.patch("harvest.urllib.request.urlopen",
                         return_value=FakeHTTPResponse(b"page text")) as m:
            harvest._fetch_jina_reader({"api_key_env": "JINA_API_KEY"}, "https://a.com/x", 5, 20000)
        return m.call_args.args[0]

    def test_authorization_header_present_when_key_set(self):
        req = self._fetch({"JINA_API_KEY": "secret-key"})
        self.assertEqual(req.headers.get("Authorization"), "Bearer secret-key")

    def test_authorization_header_absent_when_key_unset(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("JINA_API_KEY", None)
            req = self._fetch({})
        self.assertNotIn("Authorization", req.headers)

    def test_user_agent_header_present_with_key(self):
        # r.jina.ai 403s the default "Python-urllib/3.x" UA regardless of the
        # API key -- the UA must be sent even when authenticated.
        req = self._fetch({"JINA_API_KEY": "secret-key"})
        self.assertEqual(req.headers.get("User-agent"),
                         "Mozilla/5.0 (compatible; harvest.py/1.0)")

    def test_user_agent_header_present_without_key(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("JINA_API_KEY", None)
            req = self._fetch({})
        self.assertEqual(req.headers.get("User-agent"),
                         "Mozilla/5.0 (compatible; harvest.py/1.0)")


# ---------------------------------------------------------------------------
# SSRF guard scope narrowing: only urllib-ua's direct, model-steered
# connection is a real SSRF surface. Backends with a fixed, config-defined
# destination host (search backends incl. gemini-grounding; tavily-extract;
# jina-reader -- the actual fetch of the model's URL happens on *their*
# servers, not this machine) must never be blocked by the guard, since the
# user's own gateway/API may legitimately live on an internal network.
# ---------------------------------------------------------------------------

_ORIG_TOOL_REQUEST_GUARD = harvest.tool_request_guard


class TestSSRFGuardScopeNarrowing(unittest.TestCase):
    def setUp(self):
        self._orig_getaddrinfo = socket.getaddrinfo
        self._orig_real = harvest._real_getaddrinfo

    def tearDown(self):
        socket.getaddrinfo = self._orig_getaddrinfo
        harvest._real_getaddrinfo = self._orig_real

    def _spy_guard(self, calls):
        class SpyGuard(_ORIG_TOOL_REQUEST_GUARD):
            def __enter__(inner_self):
                calls.append("enter")
                return super().__enter__()
        return SpyGuard

    def test_search_backends_never_enter_guard(self):
        calls = []
        backends = [({"type": "gemini-grounding", "model": "g"}, harvest.RateLimiter(0))]
        with mock.patch("harvest.tool_request_guard", self._spy_guard(calls)), \
             mock.patch("harvest.call_search_backend", return_value=[{"url": "https://a.com", "title": "t", "snippet": "s"}]):
            harvest.do_search("q", "en", backends, [], base_config())
        self.assertEqual(calls, [])

    def test_tavily_extract_backend_never_enters_guard(self):
        calls = []
        backends = [({"type": "tavily-extract", "api_key_env": "X"}, harvest.RateLimiter(0))]
        with mock.patch("harvest.tool_request_guard", self._spy_guard(calls)), \
             mock.patch("harvest.call_fetch_backend", return_value="content"):
            harvest.do_fetch("https://a.com/x", backends, [], base_config())
        self.assertEqual(calls, [])

    def test_jina_reader_backend_never_enters_guard(self):
        calls = []
        backends = [({"type": "jina-reader", "api_key_env": "X"}, harvest.RateLimiter(0))]
        with mock.patch("harvest.tool_request_guard", self._spy_guard(calls)), \
             mock.patch("harvest.call_fetch_backend", return_value="content"):
            harvest.do_fetch("https://a.com/x", backends, [], base_config())
        self.assertEqual(calls, [])

    def test_urllib_ua_backend_still_enters_guard(self):
        calls = []
        backends = [({"type": "urllib-ua"}, harvest.RateLimiter(0))]
        with mock.patch("harvest.tool_request_guard", self._spy_guard(calls)), \
             mock.patch("harvest._ssrf_precheck"), \
             mock.patch("harvest.call_fetch_backend", return_value="content"):
            harvest.do_fetch("https://a.com/x", backends, [], base_config())
        self.assertGreaterEqual(len(calls), 1)

    def test_curl_cffi_backend_still_enters_guard(self):
        # curl-cffi is the other backend whose connection target is
        # model-controlled (unlike tavily-extract/jina-reader, which only
        # take `url` as a request parameter to a fixed API host).
        calls = []
        backends = [({"type": "curl-cffi"}, harvest.RateLimiter(0))]
        with mock.patch("harvest.tool_request_guard", self._spy_guard(calls)), \
             mock.patch("harvest._ssrf_precheck"), \
             mock.patch("harvest.call_fetch_backend", return_value="content"):
            harvest.do_fetch("https://a.com/x", backends, [], base_config())
        self.assertGreaterEqual(len(calls), 1)

    def test_search_backend_reaching_private_host_not_blocked(self):
        # Fake DNS resolves the search backend's target to a private IP --
        # since search is unguarded, this must NOT raise SSRFBlocked (an
        # internally-hosted gateway/API must keep working).
        harvest._real_getaddrinfo = lambda host, *a, **kw: [(2, 1, 6, "", ("10.0.0.5", 0))]
        harvest.install_ssrf_guard()
        backends = [({"type": "gemini-grounding", "model": "g"}, harvest.RateLimiter(0))]
        with mock.patch("harvest.call_search_backend", return_value=[{"url": "https://a.com", "title": "t", "snippet": "s"}]):
            result = harvest.do_search("q", "en", backends, [], base_config())
        data = json.loads(result)
        self.assertEqual(data["results"][0]["url"], "https://a.com")

    def test_tavily_extract_reaching_private_host_not_blocked(self):
        harvest._real_getaddrinfo = lambda host, *a, **kw: [(2, 1, 6, "", ("10.0.0.5", 0))]
        harvest.install_ssrf_guard()
        backends = [({"type": "tavily-extract", "api_key_env": "X"}, harvest.RateLimiter(0))]
        with mock.patch("harvest.call_fetch_backend", return_value="internal gateway content"):
            result = harvest.do_fetch("https://internal-gateway.local/x", backends, [], base_config())
        self.assertEqual(result, "internal gateway content")

    def test_urllib_ua_private_host_still_rejected(self):
        harvest._real_getaddrinfo = lambda host, *a, **kw: [(2, 1, 6, "", ("127.0.0.1", 0))]
        harvest.install_ssrf_guard()
        journal = []
        backends = [({"type": "urllib-ua"}, harvest.RateLimiter(0))]
        with mock.patch("harvest.call_fetch_backend") as m:
            result = harvest.do_fetch("http://internal.local/x", backends, journal, base_config())
        m.assert_not_called()
        self.assertEqual(journal[0]["blocked"], "ssrf")
        data = json.loads(result)
        self.assertIn("error", data)

    def test_curl_cffi_private_host_still_rejected(self):
        harvest._real_getaddrinfo = lambda host, *a, **kw: [(2, 1, 6, "", ("127.0.0.1", 0))]
        harvest.install_ssrf_guard()
        journal = []
        backends = [({"type": "curl-cffi"}, harvest.RateLimiter(0))]
        with mock.patch("harvest.call_fetch_backend") as m:
            result = harvest.do_fetch("http://internal.local/x", backends, journal, base_config())
        m.assert_not_called()
        self.assertEqual(journal[0]["blocked"], "ssrf")
        data = json.loads(result)
        self.assertIn("error", data)


class TestReadLocal(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.base = Path(self.tmpdir.name)
        (self.base / "notes.md").write_text("internal secret fact", encoding="utf-8")

    def tearDown(self):
        self.tmpdir.cleanup()

    def test_disabled_by_default_rejected(self):
        journal = []
        cfg = base_config()
        result = harvest.do_read_local("notes.md", 0, journal, cfg, str(self.base))
        data = json.loads(result)
        self.assertIn("error", data)
        self.assertEqual(journal[0]["blocked"], "disabled")

    def test_enabled_reads_content(self):
        journal = []
        cfg = base_config(local_sources={"enabled": True, "dir": str(self.base)})
        result = harvest.do_read_local("notes.md", 0, journal, cfg, str(self.base))
        self.assertEqual(result, "internal secret fact")
        self.assertEqual(journal[0]["url"], "local://notes.md")

    def test_traversal_rejected(self):
        journal = []
        cfg = base_config(local_sources={"enabled": True, "dir": str(self.base)})
        result = harvest.do_read_local("../../../etc/passwd", 0, journal, cfg, str(self.base))
        data = json.loads(result)
        self.assertIn("error", data)
        self.assertEqual(journal[0]["blocked"], "sandbox")

    def test_offset_chunking(self):
        journal = []
        cfg = base_config(local_sources={"enabled": True, "dir": str(self.base)})
        result = harvest.do_read_local("notes.md", 9, journal, cfg, str(self.base))
        self.assertEqual(result, "secret fact")


# ---------------------------------------------------------------------------
# subprocess safety (static assertion on source)
# ---------------------------------------------------------------------------

class TestSubprocessSafety(unittest.TestCase):
    def test_no_shell_true_in_source(self):
        source = Path(harvest.__file__).read_text(encoding="utf-8")
        self.assertNotIn("shell=True", source)

    def test_gemini_cli_uses_list_args_and_devnull_stdin(self):
        source = Path(harvest.__file__).read_text(encoding="utf-8")
        self.assertIn("stdin=subprocess.DEVNULL", source)
        self.assertIn('["gemini", "-m"', source)

    def test_all_urlopen_calls_have_explicit_timeout(self):
        source = Path(harvest.__file__).read_text(encoding="utf-8")
        import re as _re
        for m in _re.finditer(r"urlopen\(([^)]*)\)", source):
            self.assertIn("timeout=", m.group(1), f"urlopen call missing timeout: {m.group(0)}")


# ---------------------------------------------------------------------------
# worker driver (agentic loop) via fake client
# ---------------------------------------------------------------------------

class TestWorkerDriver(unittest.TestCase):
    def setUp(self):
        self.config = base_config()
        self.search_backends = []
        self.fetch_backends = [({"type": "urllib-ua"}, harvest.RateLimiter(0))]
        patcher = mock.patch("harvest._ssrf_precheck")  # SSRF DNS resolution not under test here
        patcher.start()
        self.addCleanup(patcher.stop)

    def _run(self, client):
        with mock.patch("harvest.call_fetch_backend", return_value="Rayleigh scattering explains the blue sky."):
            return harvest.run_worker("m1", "model-a", client, self.config, self.search_backends,
                                       self.fetch_backends, "why is the sky blue?", [], None)

    def test_happy_path_produces_valid_findings(self):
        client = ScriptedClient([
            assistant_tool_call("c1", "fetch", {"url": "https://a.com/x"}),
            assistant_final(findings_block([
                {"claim": "瑞利散射解释了天空为什么是蓝色", "excerpt": "Rayleigh scattering explains the blue sky.",
                 "url": "https://a.com/x", "credibility": 4, "language": "en"}],
                zh=["瑞利散射"], en=["Rayleigh scattering"])),
        ])
        result = self._run(client)
        self.assertEqual(result.status, "OK")
        self.assertEqual(len(result.findings["claims"]), 1)
        self.assertEqual(result.findings["claims"][0]["_id"], "m1-1")

    def test_invalid_citation_retried_then_dropped(self):
        client = ScriptedClient([
            assistant_tool_call("c1", "fetch", {"url": "https://a.com/x"}),
            assistant_final(findings_block([
                {"claim": "c", "excerpt": "never actually fetched", "url": "https://a.com/NEVER-SEEN"}])),
            assistant_final(findings_block([
                {"claim": "c", "excerpt": "still a hallucinated url", "url": "https://a.com/NEVER-SEEN"}])),
        ])
        result = self._run(client)
        self.assertEqual(result.status, "OK")
        self.assertEqual(result.findings["claims"], [])
        self.assertEqual(result.findings["invalid_claim_count"], 1)
        self.assertEqual(len(result.rejected_claims), 1)
        self.assertEqual(result.rejected_claims[0]["reject_reason"], "url_not_in_journal")
        self.assertEqual(result.rejected_claims[0]["excerpt"], "still a hallucinated url")

    def test_citation_retry_recovers_on_second_attempt(self):
        client = ScriptedClient([
            assistant_tool_call("c1", "fetch", {"url": "https://a.com/x"}),
            assistant_final(findings_block([
                {"claim": "c", "excerpt": "anything", "url": "https://a.com/NEVER-SEEN"}])),
            assistant_final(findings_block([
                {"claim": "c", "excerpt": "Rayleigh scattering explains the blue sky.", "url": "https://a.com/x"}])),
        ])
        result = self._run(client)
        self.assertEqual(result.status, "OK")
        self.assertEqual(len(result.findings["claims"]), 1)
        self.assertEqual(result.findings["invalid_claim_count"], 0)
        self.assertEqual(result.rejected_claims, [])

    def test_parse_failure_retried_then_fails(self):
        client = ScriptedClient([
            assistant_final("not json garbage"),
            assistant_final("still not json"),
        ])
        result = self._run(client)
        self.assertEqual(result.status, "FAILED")
        self.assertIn("parse_failed", result.reason)

    def test_parse_failure_recovers_on_retry(self):
        client = ScriptedClient([
            assistant_final("not json garbage"),
            assistant_tool_call("c1", "fetch", {"url": "https://a.com/x"}),
            assistant_final(findings_block([
                {"claim": "c", "excerpt": "Rayleigh scattering explains the blue sky.", "url": "https://a.com/x"}])),
        ])
        result = self._run(client)
        self.assertEqual(result.status, "OK")

    def test_step_limit_triggers_forced_synthesis_returns_ok(self):
        # Budget exhausted after two fetch-only rounds must no longer throw
        # the already-fetched evidence away -- the forced no-tools
        # synthesis call (the 3rd client.complete()) gets one last chance
        # to turn it into findings, and here it does.
        cfg = base_config()
        cfg["limits"]["max_steps_per_model"] = 2
        fact = "Rayleigh scattering explains the blue sky."
        client = ScriptedClient([
            assistant_tool_call("c1", "fetch", {"url": "https://a.com/1"}),
            assistant_tool_call("c2", "fetch", {"url": "https://a.com/2"}),
            assistant_final(findings_block([
                {"claim": "c", "excerpt": fact, "url": "https://a.com/2", "credibility": 4, "language": "en"}])),
        ])
        with mock.patch("harvest.call_fetch_backend", return_value=fact):
            result = harvest.run_worker("m1", "model-a", client, cfg, [], self.fetch_backends, "goal", [], None)
        self.assertEqual(client.calls, 3)
        self.assertEqual(result.status, "OK")
        self.assertEqual(len(result.findings["claims"]), 1)
        self.assertEqual(result.findings["invalid_claim_count"], 0)

    def test_forced_synthesis_still_empty_stays_failed(self):
        # Forced synthesis gets exactly one retry (see #68 dual-branch
        # retry), not an unbounded loop -- if the retry also comes back
        # invalid, the worker fails with a specific reason so callers can
        # tell "never even tried to synthesize" apart from "tried and
        # failed", instead of the old generic step_limit_no_synthesis for
        # every forced-synthesis failure mode.
        cfg = base_config()
        cfg["limits"]["max_steps_per_model"] = 2
        client = ScriptedClient([
            assistant_tool_call("c1", "fetch", {"url": "https://a.com/1"}),
            assistant_tool_call("c2", "fetch", {"url": "https://a.com/2"}),
            assistant_final("not valid json"),
            assistant_final("still not valid json"),
        ])
        with mock.patch("harvest.call_fetch_backend", return_value="text"):
            result = harvest.run_worker("m1", "model-a", client, cfg, [], self.fetch_backends, "goal", [], None)
        self.assertEqual(client.calls, 4)
        self.assertEqual(result.status, "FAILED")
        self.assertTrue(result.reason.startswith("synthesis_parse_failed:"), result.reason)

    def test_forced_synthesis_after_retry_no_consecutive_user(self):
        # If the step budget runs out right after a citation-retry nudge
        # (which leaves messages[-1] as role=user), the forced-synthesis
        # prompt must merge into that message rather than append a second
        # consecutive user turn -- most gateways 400 on that.
        cfg = base_config()
        cfg["limits"]["max_steps_per_model"] = 1
        client = ScriptedClient([
            assistant_final(findings_block([
                {"claim": "c", "excerpt": "never fetched text", "url": "https://a.com/x"}])),
            assistant_final(findings_block([])),
        ])
        result = harvest.run_worker("m1", "model-a", client, cfg, [], self.fetch_backends, "goal", [], None)
        self.assertEqual(result.status, "OK")
        forced_messages = client.messages_log[1]
        roles = [m["role"] for m in forced_messages]
        for i in range(len(roles) - 1):
            self.assertFalse(roles[i] == "user" and roles[i + 1] == "user",
                              f"consecutive user turns at index {i}: {forced_messages}")
        self.assertEqual(forced_messages[-1]["role"], "user")
        self.assertIn("citation verification", forced_messages[-1]["content"])
        self.assertIn("Tool-use budget exhausted", forced_messages[-1]["content"])

    def test_worker_exception_isolated_not_raised(self):
        # An always-raising client never propagates out of run_worker -- the
        # main loop's except breaks to forced synthesis, which raises again
        # and is caught there too, so the worker returns FAILED instead of
        # letting the exception escape.
        class ExplodingClient:
            def complete(self, messages, tools):
                raise RuntimeError("network exploded")
        result = harvest.run_worker("m1", "model-a", ExplodingClient(), self.config, [], self.fetch_backends, "goal", [], None)
        self.assertEqual(result.status, "FAILED")
        self.assertIn("network exploded", result.reason)

    def test_bad_response_shape_handled(self):
        client = ScriptedClient([{"unexpected": "shape"}])
        result = harvest.run_worker("m1", "model-a", client, self.config, [], self.fetch_backends, "goal", [], None)
        self.assertEqual(result.status, "FAILED")
        self.assertEqual(result.reason, "bad_response")

    def test_missing_optional_fields_default_without_crashing(self):
        client = ScriptedClient([
            assistant_tool_call("c1", "fetch", {"url": "https://a.com/x"}),
            assistant_final('```json\n{"claims": [{"claim": "c", "excerpt": '
                             '"Rayleigh scattering explains the blue sky.", "url": "https://a.com/x"}]}\n```'),
        ])
        result = self._run(client)
        self.assertEqual(result.status, "OK")
        claim = result.findings["claims"][0]
        self.assertNotIn("language", claim)  # absent optional field not injected at worker level

    def test_mixed_valid_and_invalid_claims_stripped_not_failed(self):
        # 10 valid claims (citing the fetched URL) + 3 invalid (citing a url
        # never fetched) in the same findings JSON, on the very first turn --
        # citation_retry_used is still False so this triggers the one nudge,
        # and the model's retry response repeats the same 3 invalid claims
        # unchanged. The worker must not FAIL: finalize_findings() strips
        # the 3 invalid claims per-claim and ships the 10 valid ones, status
        # OK, invalid_claim_count == 3.
        fact = "Rayleigh scattering explains the blue sky."
        valid_claims = [{"claim": f"valid claim {i}", "excerpt": fact, "url": "https://a.com/x"}
                        for i in range(10)]
        invalid_claims = [{"claim": f"invalid claim {i}", "excerpt": f"never fetched text {i}",
                            "url": "https://a.com/NEVER-SEEN"} for i in range(3)]
        client = ScriptedClient([
            assistant_tool_call("c1", "fetch", {"url": "https://a.com/x"}),
            assistant_final(findings_block(valid_claims + invalid_claims)),
            assistant_final(findings_block(valid_claims + invalid_claims)),
        ])
        result = self._run(client)
        self.assertEqual(result.status, "OK")
        self.assertEqual(len(result.findings["claims"]), 10)
        self.assertEqual(result.findings["invalid_claim_count"], 3)
        self.assertEqual(len(result.rejected_claims), 3)
        self.assertTrue(all(rc["reject_reason"] == "url_not_in_journal" for rc in result.rejected_claims))


class TestAppendOrMergeUser(unittest.TestCase):
    """Direct unit tests for the append_or_merge_user helper -- covers both
    content shapes a message can carry (plain string, and a list of
    OpenAI-style content blocks) independent of run_worker's own retry
    plumbing."""

    def test_appends_new_user_turn_when_last_is_not_user(self):
        messages = [{"role": "system", "content": "sys"}, {"role": "assistant", "content": "hi"}]
        harvest.append_or_merge_user(messages, "nudge")
        self.assertEqual(len(messages), 3)
        self.assertEqual(messages[-1], {"role": "user", "content": "nudge"})

    def test_appends_new_user_turn_when_messages_empty(self):
        messages = []
        harvest.append_or_merge_user(messages, "nudge")
        self.assertEqual(messages, [{"role": "user", "content": "nudge"}])

    def test_merges_into_trailing_user_str_content(self):
        messages = [{"role": "user", "content": "first nudge"}]
        harvest.append_or_merge_user(messages, "second nudge")
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0]["content"], "first nudge\nsecond nudge")

    def test_merges_into_trailing_user_list_content_without_typeerror(self):
        messages = [{"role": "user", "content": [{"type": "text", "text": "first nudge"}]}]
        harvest.append_or_merge_user(messages, "second nudge")
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0]["content"], [
            {"type": "text", "text": "first nudge"},
            {"type": "text", "text": "second nudge"},
        ])


# ---------------------------------------------------------------------------
# panel-level quorum
# ---------------------------------------------------------------------------

class TestPanelQuorum(unittest.TestCase):
    def test_two_of_three_alive_meets_quorum(self):
        config = base_config()

        def factory(model_id):
            if model_id == "model-c":
                class Dead:
                    def complete(self, messages, tools):
                        raise RuntimeError("down")
                return Dead()
            return ScriptedClient([
                assistant_final(findings_block([
                    {"claim": "c", "excerpt": "e", "url": "local://x"}]))
            ])

        with mock.patch("harvest.build_fetch_index", return_value={"local://x": ["e"]}):
            results, alive, quorum_met = harvest.run_panel(config, "goal", [], None, factory)
        self.assertTrue(quorum_met)
        self.assertEqual(len(alive), 2)

    def test_below_quorum_reported(self):
        config = base_config()

        class Dead:
            def complete(self, messages, tools):
                raise RuntimeError("down")

        def factory(model_id):
            return Dead()

        results, alive, quorum_met = harvest.run_panel(config, "goal", [], None, factory)
        self.assertFalse(quorum_met)
        self.assertEqual(len(alive), 0)


# ---------------------------------------------------------------------------
# merge / judge
# ---------------------------------------------------------------------------

class TestMergeFindings(unittest.TestCase):
    def setUp(self):
        self.worker_findings = {
            "m1": {"claims": [{"_id": "m1-1", "claim": "A", "excerpt": "eA", "url": "u1",
                                "credibility": 4, "language": "en"}]},
            "m2": {"claims": [{"_id": "m2-1", "claim": "A2", "excerpt": "eA2", "url": "u2",
                                "credibility": 3, "language": "en"}]},
            "m3": {"claims": [{"_id": "m3-1", "claim": "A3", "excerpt": "eA3", "url": "u3",
                                "credibility": 5, "language": "zh"}]},
        }

    def test_disputed_relation(self):
        judge = {"clusters": [{"summary": "s", "source_claim_ids": ["m1-1", "m2-1"], "relation": "contradict"}],
                 "coverage_gaps": [], "unique_insights": [], "blind_spots": []}
        merged = harvest.merge_findings(self.worker_findings, judge)
        self.assertIn("s", merged["contradictions"])

    def test_hallucinated_claim_id_dropped(self):
        judge = {"clusters": [{"summary": "s", "source_claim_ids": ["m1-1", "m9-99"], "relation": "agree"}],
                 "coverage_gaps": [], "unique_insights": ["m9-99"], "blind_spots": []}
        merged = harvest.merge_findings(self.worker_findings, judge)
        ids = [c["id"] for c in merged["clusters"][0]["claims"]]
        self.assertNotIn("m9-99", ids)
        self.assertNotIn("m9-99", merged["unique_insights"])

    def test_assembled_claim_matches_worker_original_verbatim(self):
        judge = {"clusters": [{"summary": "s", "source_claim_ids": ["m1-1"], "relation": "agree"}],
                 "coverage_gaps": [], "unique_insights": [], "blind_spots": []}
        merged = harvest.merge_findings(self.worker_findings, judge)
        assembled = merged["clusters"][0]["claims"][0]
        original = self.worker_findings["m1"]["claims"][0]
        self.assertEqual(assembled["excerpt"], original["excerpt"])
        self.assertEqual(assembled["url"], original["url"])

    def test_gaps_and_blind_spots_preserved(self):
        judge = {"clusters": [], "coverage_gaps": ["gap1"], "unique_insights": [], "blind_spots": ["blind1"]}
        merged = harvest.merge_findings(self.worker_findings, judge)
        self.assertEqual(merged["coverage_gaps"], ["gap1"])
        self.assertEqual(merged["blind_spots"], ["blind1"])

    def test_claim_in_two_clusters_kept_only_in_first(self):
        # Reproduces the real smoke-test defect: m2-1 assigned to both
        # cluster1 and cluster6 by the judge. First assignment wins.
        judge = {"clusters": [
            {"summary": "first", "source_claim_ids": ["m1-1", "m2-1"], "relation": "agree"},
            {"summary": "second", "source_claim_ids": ["m2-1", "m3-1"], "relation": "agree"},
        ], "coverage_gaps": [], "unique_insights": [], "blind_spots": []}
        merged = harvest.merge_findings(self.worker_findings, judge)
        first_ids = [c["id"] for c in merged["clusters"][0]["claims"]]
        second_ids = [c["id"] for c in merged["clusters"][1]["claims"]]
        self.assertIn("m2-1", first_ids)
        self.assertNotIn("m2-1", second_ids)

    def test_dropped_duplicate_recorded_in_dedup_notes(self):
        judge = {"clusters": [
            {"summary": "first", "source_claim_ids": ["m1-1", "m2-1"], "relation": "agree"},
            {"summary": "second", "source_claim_ids": ["m2-1", "m3-1"], "relation": "agree"},
        ], "coverage_gaps": [], "unique_insights": [], "blind_spots": []}
        merged = harvest.merge_findings(self.worker_findings, judge)
        self.assertEqual(len(merged["dedup_notes"]), 1)
        note = merged["dedup_notes"][0]
        self.assertEqual(note["claim_id"], "m2-1")
        self.assertEqual(note["dropped_from_cluster"], "second")

    def test_no_duplicates_yields_empty_dedup_notes(self):
        judge = {"clusters": [{"summary": "s", "source_claim_ids": ["m1-1"], "relation": "agree"}],
                 "coverage_gaps": [], "unique_insights": [], "blind_spots": []}
        merged = harvest.merge_findings(self.worker_findings, judge)
        self.assertEqual(merged["dedup_notes"], [])

    def test_cluster_left_empty_by_dedup_is_dropped(self):
        # If every ID in a later cluster was already claimed, that cluster
        # itself must not appear (no empty-claims clusters in output).
        judge = {"clusters": [
            {"summary": "first", "source_claim_ids": ["m1-1"], "relation": "agree"},
            {"summary": "second", "source_claim_ids": ["m1-1"], "relation": "agree"},
        ], "coverage_gaps": [], "unique_insights": [], "blind_spots": []}
        merged = harvest.merge_findings(self.worker_findings, judge)
        self.assertEqual(len(merged["clusters"]), 1)
        self.assertEqual(merged["clusters"][0]["summary"], "first")


class TestJudgeFallback(unittest.TestCase):
    def test_judge_falls_back_to_next_panel_model_on_failure(self):
        config = base_config()
        worker_findings = {"m1": {"claims": [{"_id": "m1-1", "claim": "A", "excerpt": "e", "url": "u"}]}}

        good_judge_content = findings_block  # placeholder unused
        judge_ok_text = '```json\n{"clusters": [{"summary": "s", "source_claim_ids": ["m1-1"], "relation": "agree"}]}\n```'

        def factory(model_id):
            if model_id == "model-judge":
                class Dead:
                    def complete(self, messages, tools):
                        raise RuntimeError("judge gateway down")
                return Dead()
            return ScriptedClient([assistant_final(judge_ok_text)])

        data, err = harvest.run_judge_with_fallback(config, factory, worker_findings, config["panel_models"])
        self.assertIsNotNone(data)
        self.assertIsNone(err)

    def test_judge_all_candidates_exhausted(self):
        config = base_config()
        worker_findings = {"m1": {"claims": [{"_id": "m1-1", "claim": "A", "excerpt": "e", "url": "u"}]}}

        class Dead:
            def complete(self, messages, tools):
                raise RuntimeError("down")

        def factory(model_id):
            return Dead()

        data, err = harvest.run_judge_with_fallback(config, factory, worker_findings, config["panel_models"])
        self.assertIsNone(data)
        self.assertIsNotNone(err)


# ---------------------------------------------------------------------------
# check_project (three-state mechanical gate)
# ---------------------------------------------------------------------------

class TestCheckProject(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.project_dir = Path(self.tmpdir.name)
        self.verify_dir = self.project_dir / "pipeline" / "verification"
        self.verify_dir.mkdir(parents=True)

    def tearDown(self):
        self.tmpdir.cleanup()

    def _write_verify(self, **fields):
        payload = {"verdict": "OK", "goal_file_sha256": "abc", "run_timestamp": time.time(),
                   "quorum_met": True, "total_claims": 3, "invalid_citation_rate": 0.0}
        payload.update(fields)
        (self.verify_dir / harvest.VERIFY_FILE).write_text(json.dumps(payload), encoding="utf-8")

    def test_never_enabled_is_na(self):
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "N_A")

    def test_pass_when_all_conditions_met(self):
        self._write_verify()
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "PASS")

    def test_running_tombstone_is_fail_not_na(self):
        self._write_verify(verdict="RUNNING")
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "FAIL")

    def test_unavailable_is_fail(self):
        self._write_verify(verdict="UNAVAILABLE")
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "FAIL")

    def test_unknown_verdict_is_fail(self):
        self._write_verify(verdict="BOGUS")
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "FAIL")

    def test_exemption_overrides_unavailable(self):
        self._write_verify(verdict="UNAVAILABLE")
        (self.verify_dir / harvest.LEGACY_EXEMPTION_FILE).write_text("approved 2026-07-02", encoding="utf-8")
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "N_A")

    def test_exemption_overrides_everything(self):
        (self.verify_dir / harvest.LEGACY_EXEMPTION_FILE).write_text("approved", encoding="utf-8")
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "N_A")

    def test_zero_claims_fails_without_zerodiv(self):
        self._write_verify(total_claims=0, invalid_citation_rate=0.0)
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "FAIL")

    def test_unreadable_verify_json_reason_names_actual_filename(self):
        # copilot review on #25: message said "verify.json" but the real
        # file is harvest-verify.json -- assert the reason string matches
        # the actual on-disk filename users would need to look for.
        (self.verify_dir / harvest.VERIFY_FILE).write_text("not json", encoding="utf-8")
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "FAIL")
        self.assertIn(harvest.VERIFY_FILE, reason)

    def test_corrupted_total_claims_type_fails_cleanly_not_typeerror(self):
        # copilot review on #25: a hand-edited/corrupted-but-valid-JSON
        # verify.json with a string total_claims must not raise TypeError
        # from the "<=" comparison -- it must resolve to a clean FAIL.
        self._write_verify(total_claims="not-a-number")
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "FAIL")

    def test_corrupted_invalid_citation_rate_type_fails_cleanly_not_typeerror(self):
        self._write_verify(invalid_citation_rate="not-a-number")
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "FAIL")

    def test_quorum_not_met_fails(self):
        self._write_verify(quorum_met=False)
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "FAIL")

    def test_invalid_rate_above_threshold_with_systematic_count_fails(self):
        self._write_verify(invalid_citation_rate=0.5, invalid_claim_count=5)
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "FAIL")

    def test_invalid_rate_above_threshold_but_isolated_single_rejection_passes(self):
        # A small-claims run where exactly one claim got rejected (already
        # excluded from the merged output by the retry loop) can blow the
        # 5% rate without being systematic fabrication -- must not FAIL on
        # rate alone.
        self._write_verify(invalid_citation_rate=0.5, invalid_claim_count=1)
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "PASS")

    def test_invalid_rate_above_threshold_with_exactly_two_rejections_fails(self):
        self._write_verify(invalid_citation_rate=0.06, invalid_claim_count=2)
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "FAIL")

    def test_invalid_count_high_but_rate_within_threshold_passes(self):
        self._write_verify(invalid_citation_rate=0.05, invalid_claim_count=10)
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "PASS")

    def test_invalid_claim_count_bad_type_fails(self):
        self._write_verify(invalid_citation_rate=0.5, invalid_claim_count="five")
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "FAIL")
        self.assertIn("invalid_claim_count", reason)

    def test_goal_hash_mismatch_fails(self):
        goal_file = self.project_dir / harvest.GOAL_FILE_NAME
        goal_file.write_text("research goal content", encoding="utf-8")
        self._write_verify(goal_file_sha256="deadbeef")
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "FAIL")

    def test_goal_hash_match_passes(self):
        goal_file = self.project_dir / harvest.GOAL_FILE_NAME
        goal_file.write_text("research goal content", encoding="utf-8")
        import hashlib
        h = hashlib.sha256(goal_file.read_bytes()).hexdigest()
        self._write_verify(goal_file_sha256=h)
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "PASS")

    def test_goal_hash_checked_against_conventional_intake_path(self):
        goal_dir = self.project_dir / "intake" / "requirements"
        goal_dir.mkdir(parents=True)
        goal_file = goal_dir / harvest.GOAL_FILE_NAME
        goal_file.write_text("research goal content", encoding="utf-8")
        import hashlib
        h = hashlib.sha256(goal_file.read_bytes()).hexdigest()
        self._write_verify(goal_file_sha256=h)
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "PASS")

    def test_conventional_intake_path_takes_priority_over_root_fallback(self):
        goal_dir = self.project_dir / "intake" / "requirements"
        goal_dir.mkdir(parents=True)
        (goal_dir / harvest.GOAL_FILE_NAME).write_text("intake content", encoding="utf-8")
        (self.project_dir / harvest.GOAL_FILE_NAME).write_text("root content", encoding="utf-8")
        import hashlib
        h_intake = hashlib.sha256(b"intake content").hexdigest()
        self._write_verify(goal_file_sha256=h_intake)
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "PASS")  # matched intake path, not root

    def test_goal_file_missing_entirely_skips_hash_check_without_failing(self):
        self._write_verify()  # no goal file anywhere
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "PASS")
        self.assertIn("hash check skipped", reason)

    def test_resolve_goal_file_returns_none_when_absent(self):
        self.assertIsNone(harvest.resolve_goal_file(self.project_dir))

    def test_resolve_goal_file_prefers_intake_over_root(self):
        goal_dir = self.project_dir / "intake" / "requirements"
        goal_dir.mkdir(parents=True)
        intake_file = goal_dir / harvest.GOAL_FILE_NAME
        intake_file.write_text("x", encoding="utf-8")
        (self.project_dir / harvest.GOAL_FILE_NAME).write_text("y", encoding="utf-8")
        self.assertEqual(harvest.resolve_goal_file(self.project_dir), intake_file)

    def test_resolve_goal_file_falls_back_to_root(self):
        root_file = self.project_dir / harvest.GOAL_FILE_NAME
        root_file.write_text("y", encoding="utf-8")
        self.assertEqual(harvest.resolve_goal_file(self.project_dir), root_file)


class TestCmdCheckExitCodes(unittest.TestCase):
    def test_verdict_exit_code_mapping(self):
        self.assertEqual(harvest._VERDICT_EXIT_CODES, {"PASS": 0, "FAIL": 1, "N_A": 2})


# ---------------------------------------------------------------------------
# state cleanup / tombstones
# ---------------------------------------------------------------------------

class TestStateCleanup(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.project_dir = Path(self.tmpdir.name)
        self.pipeline_dir = self.project_dir / "pipeline"
        self.verify_dir = self.pipeline_dir / "verification"
        self.raw_dir = self.pipeline_dir / "1_raw"
        self.verify_dir.mkdir(parents=True)
        self.raw_dir.mkdir(parents=True)

    def tearDown(self):
        self.tmpdir.cleanup()

    def test_cleanup_removes_stale_verify_and_exemption(self):
        (self.verify_dir / harvest.VERIFY_FILE).write_text("{}", encoding="utf-8")
        (self.verify_dir / harvest.LEGACY_EXEMPTION_FILE).write_text("old exemption", encoding="utf-8")
        (self.raw_dir / harvest.MERGED_FINDINGS_FILE).write_text("{}", encoding="utf-8")
        (self.raw_dir / harvest.HARVEST_SUBDIR).mkdir()
        (self.raw_dir / harvest.HARVEST_SUBDIR / "leftover.txt").write_text("x", encoding="utf-8")

        harvest.cleanup_stale_state(self.pipeline_dir, self.verify_dir, self.raw_dir)

        self.assertFalse((self.verify_dir / harvest.VERIFY_FILE).exists())
        self.assertFalse((self.verify_dir / harvest.LEGACY_EXEMPTION_FILE).exists())
        self.assertFalse((self.raw_dir / harvest.MERGED_FINDINGS_FILE).exists())
        self.assertFalse((self.raw_dir / harvest.HARVEST_SUBDIR).exists())

    def test_cleanup_no_op_when_nothing_present(self):
        harvest.cleanup_stale_state(self.pipeline_dir, self.verify_dir, self.raw_dir)  # must not raise

    def test_tombstone_written_before_work_starts(self):
        goal_hash = "h" * 64
        harvest.write_tombstone(self.verify_dir, goal_hash)
        data = json.loads((self.verify_dir / harvest.VERIFY_FILE).read_text(encoding="utf-8"))
        self.assertEqual(data["verdict"], "RUNNING")
        self.assertEqual(data["goal_file_sha256"], goal_hash)

    def test_abort_unavailable_writes_tombstone_and_exits_3(self):
        with self.assertRaises(SystemExit) as ctx:
            harvest.abort_unavailable(self.verify_dir, "h" * 64, "boom", {"quorum_met": False})
        self.assertEqual(ctx.exception.code, 3)
        data = json.loads((self.verify_dir / harvest.VERIFY_FILE).read_text(encoding="utf-8"))
        self.assertEqual(data["verdict"], "UNAVAILABLE")
        self.assertEqual(data["reason"], "boom")


# ---------------------------------------------------------------------------
# module import purity (check_project importable without side effects)
# ---------------------------------------------------------------------------

class TestModuleImportPurity(unittest.TestCase):
    def test_check_project_importable_and_pure(self):
        proc = subprocess.run(
            [sys.executable, "-c",
             "import sys; sys.path.insert(0, %r); "
             "from harvest import check_project; "
             "print(check_project('/nonexistent-project-dir-xyz'))"
             % str(Path(__file__).resolve().parent.parent / "scripts")],
            capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("N_A", proc.stdout)


# ---------------------------------------------------------------------------
# end-to-end cmd_run happy path (fully faked network)
# ---------------------------------------------------------------------------

class TestCmdRunEndToEnd(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.project_dir = Path(self.tmpdir.name)
        self.pipeline_dir = self.project_dir / "pipeline"
        self.raw_dir = self.pipeline_dir / "1_raw"
        self.raw_dir.mkdir(parents=True)
        self.goal_file = self.project_dir / harvest.GOAL_FILE_NAME
        self.goal_file.write_text("why is the sky blue?", encoding="utf-8")

        self._orig_real = harvest._real_getaddrinfo
        self._orig_getaddrinfo = socket.getaddrinfo
        harvest._real_getaddrinfo = lambda host, *a, **kw: [(2, 1, 6, "", ("93.184.216.34", 0))]

        # cmd_run's new gateway-key gate (--no-api local mode) fires before
        # any of the normal-mode logic these tests exercise -- fake key
        # present, same TEST_GATEWAY_KEY name base_config()'s api_key_env
        # already points at, keeps every existing normal-mode test on the
        # gated path it always ran.
        self._env_patch = mock.patch.dict(os.environ, {"TEST_GATEWAY_KEY": "fake-key"})
        self._env_patch.start()

    def tearDown(self):
        self._env_patch.stop()
        harvest._real_getaddrinfo = self._orig_real
        socket.getaddrinfo = self._orig_getaddrinfo
        self.tmpdir.cleanup()

    def test_full_run_produces_pass_able_verify_json(self):
        fact = "Rayleigh scattering explains why the sky looks blue."
        panel_scripts = {
            model_id: ScriptedClient([
                assistant_tool_call("c1", "fetch", {"url": "https://example.com/page1"}),
                assistant_final(findings_block([
                    {"claim": f"claim from {model_id}", "excerpt": fact, "url": "https://example.com/page1",
                     "credibility": 4, "language": "en"}])),
            ])
            for model_id in ["model-a", "model-b", "model-c"]
        }
        judge_text = ('```json\n{"clusters": [{"summary": "blue sky consensus", '
                      '"source_claim_ids": ["m1-1", "m2-1", "m3-1"], "relation": "agree"}], '
                      '"coverage_gaps": [], "unique_insights": [], "blind_spots": []}\n```')
        judge_client = ScriptedClient([assistant_final(judge_text)])

        def factory(model_id):
            if model_id == "model-judge":
                return judge_client
            return panel_scripts[model_id]

        config = base_config()

        args = argparse_ns(goal_file=str(self.goal_file), out=str(self.raw_dir), config="unused", local_dir=None)

        with mock.patch("harvest.load_config", return_value=config), \
             mock.patch("harvest.make_client_factory", return_value=factory), \
             mock.patch("harvest.call_fetch_backend", return_value=fact):
            harvest.cmd_run(args)

        verify_file = self.pipeline_dir / "verification" / harvest.VERIFY_FILE
        self.assertTrue(verify_file.exists())
        data = json.loads(verify_file.read_text(encoding="utf-8"))
        self.assertEqual(data["verdict"], "OK")
        self.assertTrue(data["quorum_met"])
        self.assertEqual(data["total_claims"], 3)
        self.assertEqual(data["invalid_citation_rate"], 0.0)

        merged_file = self.raw_dir / harvest.MERGED_FINDINGS_FILE
        self.assertTrue(merged_file.exists())
        merged = json.loads(merged_file.read_text(encoding="utf-8"))
        self.assertEqual(len(merged["clusters"]), 1)

        self.assertTrue((self.raw_dir / "fetch-report.md").exists())
        for alias in ("m1", "m2", "m3"):
            self.assertTrue((self.raw_dir / "harvest" / alias / "findings.json").exists())
            self.assertTrue((self.raw_dir / "harvest" / alias / f"journal_{alias}.jsonl").exists())
            rejected_file = self.raw_dir / "harvest" / alias / "rejected_claims.json"
            self.assertTrue(rejected_file.exists())
            self.assertEqual(json.loads(rejected_file.read_text(encoding="utf-8")), [])

        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "PASS", reason)

    def test_zero_valid_claims_aborts_unavailable(self):
        # Quorum is met (all three workers return status OK) but every
        # claim cites a url the worker never fetched -- finalize_findings
        # strips them all, leaving total_claims == 0. cmd_run must treat
        # that as UNAVAILABLE (exit 3), not silently write an OK verdict
        # over an empty merged-findings file.
        bad_claim = {"claim": "c", "excerpt": "hallucinated", "url": "https://a.com/NEVER-SEEN"}
        panel_scripts = {
            model_id: ScriptedClient([
                assistant_tool_call("c1", "fetch", {"url": "https://example.com/page1"}),
                assistant_final(findings_block([bad_claim])),
                assistant_final(findings_block([bad_claim])),
            ])
            for model_id in ["model-a", "model-b", "model-c"]
        }
        judge_text = ('```json\n{"clusters": [], "coverage_gaps": [], '
                      '"unique_insights": [], "blind_spots": []}\n```')
        judge_client = ScriptedClient([assistant_final(judge_text)])

        def factory(model_id):
            if model_id == "model-judge":
                return judge_client
            return panel_scripts[model_id]

        config = base_config()
        args = argparse_ns(goal_file=str(self.goal_file), out=str(self.raw_dir), config="unused", local_dir=None)

        with mock.patch("harvest.load_config", return_value=config), \
             mock.patch("harvest.make_client_factory", return_value=factory), \
             mock.patch("harvest.call_fetch_backend", return_value="irrelevant fetched text"):
            with self.assertRaises(SystemExit) as ctx:
                harvest.cmd_run(args)
        self.assertEqual(ctx.exception.code, 3)

        verify_file = self.pipeline_dir / "verification" / harvest.VERIFY_FILE
        data = json.loads(verify_file.read_text(encoding="utf-8"))
        self.assertEqual(data["verdict"], "UNAVAILABLE")

        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "FAIL")

    def test_partial_failure_yields_ok(self):
        # 2 of 3 models alive (one dead outright) still meets quorum(2) and
        # must produce verdict OK -- there is no "DEGRADED" tier anymore.
        fact = "Rayleigh scattering explains why the sky looks blue."

        def good_script(model_id):
            return ScriptedClient([
                assistant_tool_call("c1", "fetch", {"url": "https://example.com/page1"}),
                assistant_final(findings_block([
                    {"claim": f"claim from {model_id}", "excerpt": fact, "url": "https://example.com/page1",
                     "credibility": 4, "language": "en"}])),
            ])

        class Dead:
            def complete(self, messages, tools):
                raise RuntimeError("down")

        judge_text = ('```json\n{"clusters": [{"summary": "blue sky", '
                      '"source_claim_ids": ["m1-1", "m2-1"], "relation": "agree"}], '
                      '"coverage_gaps": [], "unique_insights": [], "blind_spots": []}\n```')
        judge_client = ScriptedClient([assistant_final(judge_text)])

        def factory(model_id):
            if model_id == "model-judge":
                return judge_client
            if model_id == "model-c":
                return Dead()
            return good_script(model_id)

        config = base_config()
        args = argparse_ns(goal_file=str(self.goal_file), out=str(self.raw_dir), config="unused", local_dir=None)

        with mock.patch("harvest.load_config", return_value=config), \
             mock.patch("harvest.make_client_factory", return_value=factory), \
             mock.patch("harvest.call_fetch_backend", return_value=fact):
            harvest.cmd_run(args)

        verify_file = self.pipeline_dir / "verification" / harvest.VERIFY_FILE
        data = json.loads(verify_file.read_text(encoding="utf-8"))
        self.assertEqual(data["verdict"], "OK")
        self.assertTrue(data["quorum_met"])
        self.assertEqual(set(data["models_alive"]), {"m1", "m2"})
        self.assertEqual(data["total_claims"], 2)

        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "PASS", reason)

    def test_local_dir_falls_back_to_config_when_cli_flag_omitted(self):
        # local_sources.enabled=True + a configured relative dir, but the
        # CLI --local-dir flag is omitted (local_dir=None): must not
        # silently skip local material, must resolve the configured dir
        # relative to project_dir and pick it up.
        (self.project_dir / "intake" / "local_sources").mkdir(parents=True)
        (self.project_dir / "intake" / "local_sources" / "note.md").write_text(
            "internal note first line", encoding="utf-8")

        fact = "Rayleigh scattering explains why the sky looks blue."
        panel_scripts = {
            model_id: ScriptedClient([
                assistant_tool_call("c1", "fetch", {"url": "https://example.com/page1"}),
                assistant_final(findings_block([
                    {"claim": f"claim from {model_id}", "excerpt": fact, "url": "https://example.com/page1",
                     "credibility": 4, "language": "en"}])),
            ])
            for model_id in ["model-a", "model-b", "model-c"]
        }
        judge_text = ('```json\n{"clusters": [{"summary": "blue sky consensus", '
                      '"source_claim_ids": ["m1-1", "m2-1", "m3-1"], "relation": "agree"}], '
                      '"coverage_gaps": [], "unique_insights": [], "blind_spots": []}\n```')
        judge_client = ScriptedClient([assistant_final(judge_text)])

        def factory(model_id):
            if model_id == "model-judge":
                return judge_client
            return panel_scripts[model_id]

        config = base_config(local_sources={"enabled": True, "dir": "intake/local_sources"})
        args = argparse_ns(goal_file=str(self.goal_file), out=str(self.raw_dir), config="unused", local_dir=None)

        with mock.patch("harvest.load_config", return_value=config), \
             mock.patch("harvest.make_client_factory", return_value=factory), \
             mock.patch("harvest.call_fetch_backend", return_value=fact):
            harvest.cmd_run(args)

        report = (self.raw_dir / "fetch-report.md").read_text(encoding="utf-8")
        self.assertIn("note.md: internal note first line", report)

    def test_local_dir_cli_relative_path_resolves_against_project_dir_not_cwd(self):
        # copilot review round 6 on #25: a relative --local-dir was resolved
        # against the process CWD while the config-fallback path (added in
        # an earlier round) was resolved against project_dir -- same
        # relative string, two different anchors depending on which one
        # supplied it. Both must now anchor to project_dir regardless of
        # the test runner's CWD (which is not self.project_dir here).
        (self.project_dir / "intake" / "local_sources").mkdir(parents=True)
        (self.project_dir / "intake" / "local_sources" / "note.md").write_text(
            "internal note first line", encoding="utf-8")

        fact = "Rayleigh scattering explains why the sky looks blue."
        panel_scripts = {
            model_id: ScriptedClient([
                assistant_tool_call("c1", "fetch", {"url": "https://example.com/page1"}),
                assistant_final(findings_block([
                    {"claim": f"claim from {model_id}", "excerpt": fact, "url": "https://example.com/page1",
                     "credibility": 4, "language": "en"}])),
            ])
            for model_id in ["model-a", "model-b", "model-c"]
        }
        judge_text = ('```json\n{"clusters": [{"summary": "blue sky consensus", '
                      '"source_claim_ids": ["m1-1", "m2-1", "m3-1"], "relation": "agree"}], '
                      '"coverage_gaps": [], "unique_insights": [], "blind_spots": []}\n```')
        judge_client = ScriptedClient([assistant_final(judge_text)])

        def factory(model_id):
            if model_id == "model-judge":
                return judge_client
            return panel_scripts[model_id]

        config = base_config(local_sources={"enabled": True, "dir": "intake/local_sources"})
        # Relative --local-dir supplied directly via the CLI flag (not the
        # config fallback path).
        args = argparse_ns(goal_file=str(self.goal_file), out=str(self.raw_dir), config="unused",
                            local_dir="intake/local_sources")

        with mock.patch("harvest.load_config", return_value=config), \
             mock.patch("harvest.make_client_factory", return_value=factory), \
             mock.patch("harvest.call_fetch_backend", return_value=fact):
            harvest.cmd_run(args)

        report = (self.raw_dir / "fetch-report.md").read_text(encoding="utf-8")
        self.assertIn("note.md: internal note first line", report)

    def test_quorum_not_met_aborts_with_exit_3_and_tombstone(self):
        class Dead:
            def complete(self, messages, tools):
                raise RuntimeError("down")

        def factory(model_id):
            return Dead()

        config = base_config()
        args = argparse_ns(goal_file=str(self.goal_file), out=str(self.raw_dir), config="unused", local_dir=None)

        with mock.patch("harvest.load_config", return_value=config), \
             mock.patch("harvest.make_client_factory", return_value=factory):
            with self.assertRaises(SystemExit) as ctx:
                harvest.cmd_run(args)
        self.assertEqual(ctx.exception.code, 3)

        verify_file = self.pipeline_dir / "verification" / harvest.VERIFY_FILE
        data = json.loads(verify_file.read_text(encoding="utf-8"))
        self.assertEqual(data["verdict"], "UNAVAILABLE")

        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "FAIL")

    def test_rerun_clears_previous_exemption(self):
        verify_dir = self.pipeline_dir / "verification"
        verify_dir.mkdir(parents=True)
        (verify_dir / harvest.LEGACY_EXEMPTION_FILE).write_text("old exemption, no longer valid", encoding="utf-8")

        class Dead:
            def complete(self, messages, tools):
                raise RuntimeError("down")

        def factory(model_id):
            return Dead()

        config = base_config()
        args = argparse_ns(goal_file=str(self.goal_file), out=str(self.raw_dir), config="unused", local_dir=None)
        with mock.patch("harvest.load_config", return_value=config), \
             mock.patch("harvest.make_client_factory", return_value=factory):
            with self.assertRaises(SystemExit):
                harvest.cmd_run(args)

        self.assertFalse((verify_dir / harvest.LEGACY_EXEMPTION_FILE).exists())


class TestCmdRunGoalFileResolution(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.project_dir = Path(self.tmpdir.name)
        self.pipeline_dir = self.project_dir / "pipeline"
        self.raw_dir = self.pipeline_dir / "1_raw"
        self.raw_dir.mkdir(parents=True)

        # Same gateway-key gate rationale as TestCmdRunEndToEnd.setUp.
        self._env_patch = mock.patch.dict(os.environ, {"TEST_GATEWAY_KEY": "fake-key"})
        self._env_patch.start()

    def tearDown(self):
        self._env_patch.stop()
        self.tmpdir.cleanup()

    def test_no_resolvable_goal_file_aborts_before_any_state_write(self):
        # --goal-file points to a real file, but it's nowhere under the
        # repo-convention locations relative to project_dir -- run must
        # refuse rather than silently recording an unverifiable hash.
        stray_goal = Path(self.tmpdir.name) / "elsewhere.md"
        stray_goal.write_text("goal text", encoding="utf-8")
        config = base_config()
        args = argparse_ns(goal_file=str(stray_goal), out=str(self.raw_dir), config="unused", local_dir=None)
        with mock.patch("harvest.load_config", return_value=config):
            with self.assertRaises(SystemExit) as ctx:
                harvest.cmd_run(args)
        self.assertEqual(ctx.exception.code, 1)
        verify_file = self.pipeline_dir / "verification" / harvest.VERIFY_FILE
        self.assertFalse(verify_file.exists())  # no tombstone written -- aborted before cleanup/tombstone

    def test_goal_file_at_intake_requirements_resolves_for_run(self):
        goal_dir = self.project_dir / "intake" / "requirements"
        goal_dir.mkdir(parents=True)
        goal_file = goal_dir / harvest.GOAL_FILE_NAME
        goal_file.write_text("why is the sky blue?", encoding="utf-8")

        class Dead:
            def complete(self, messages, tools):
                raise RuntimeError("down")

        config = base_config()
        args = argparse_ns(goal_file=str(goal_file), out=str(self.raw_dir), config="unused", local_dir=None)
        with mock.patch("harvest.load_config", return_value=config), \
             mock.patch("harvest.make_client_factory", return_value=lambda model_id: Dead()):
            with self.assertRaises(SystemExit) as ctx:
                harvest.cmd_run(args)
        self.assertEqual(ctx.exception.code, 3)  # got past goal resolution, failed later on quorum
        verify_file = self.pipeline_dir / "verification" / harvest.VERIFY_FILE
        self.assertTrue(verify_file.exists())
        data = json.loads(verify_file.read_text(encoding="utf-8"))
        import hashlib
        self.assertEqual(data["goal_file_sha256"], hashlib.sha256(goal_file.read_bytes()).hexdigest())

    def test_goal_file_flag_mismatching_canonical_location_aborts_before_state_write(self):
        # copilot review on #25: a real, resolvable canonical goal file
        # exists, but --goal-file points at a *different* real file. Without
        # a hard check, the panel would run on the CLI-supplied text while
        # goal_file_sha256 gets anchored to the (different) canonical file's
        # hash -- the audit trail would lie about what was actually
        # researched. Must abort before any state write, not silently diverge.
        goal_dir = self.project_dir / "intake" / "requirements"
        goal_dir.mkdir(parents=True)
        canonical_goal_file = goal_dir / harvest.GOAL_FILE_NAME
        canonical_goal_file.write_text("why is the sky blue?", encoding="utf-8")

        other_goal_file = self.project_dir / "some-other-goal.md"
        other_goal_file.write_text("unrelated different text", encoding="utf-8")

        config = base_config()
        args = argparse_ns(goal_file=str(other_goal_file), out=str(self.raw_dir), config="unused", local_dir=None)
        with mock.patch("harvest.load_config", return_value=config):
            with self.assertRaises(SystemExit) as ctx:
                harvest.cmd_run(args)
        self.assertEqual(ctx.exception.code, 1)
        verify_file = self.pipeline_dir / "verification" / harvest.VERIFY_FILE
        self.assertFalse(verify_file.exists())


class TestSupplementaryRunIsolation(unittest.TestCase):
    """Defect 3: --project-dir re-anchoring + supplementary (backfill) run
    isolation. A supplementary run's --out is not the canonical
    pipeline/1_raw -- it must never write to, or clean up, the primary
    track's VERIFY_FILE/LEGACY_EXEMPTION_FILE."""

    class Dead:
        """client.complete() raises -> run_worker catches it as FAILED for
        every model -> alive=[] -> quorum not met -> abort_unavailable, the
        same early-exit path TestCmdRunGoalFileResolution already relies on
        to observe state-file writes without a real model call."""
        def complete(self, messages, tools):
            raise RuntimeError("down")

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.project_dir = Path(self.tmpdir.name) / "project"
        goal_dir = self.project_dir / "intake" / "requirements"
        goal_dir.mkdir(parents=True)
        self.goal_file = goal_dir / harvest.GOAL_FILE_NAME
        self.goal_file.write_text("why is the sky blue?", encoding="utf-8")
        self.config = base_config()

        # Same gateway-key gate rationale as TestCmdRunEndToEnd.setUp.
        self._env_patch = mock.patch.dict(os.environ, {"TEST_GATEWAY_KEY": "fake-key"})
        self._env_patch.start()

    def tearDown(self):
        self._env_patch.stop()
        self.tmpdir.cleanup()

    def _run(self, raw_dir, project_dir_arg, goal_file_arg=None):
        kwargs = dict(goal_file=str(goal_file_arg or self.goal_file), out=str(raw_dir), config="unused", local_dir=None)
        if project_dir_arg is not None:
            kwargs["project_dir"] = str(project_dir_arg)
        args = argparse_ns(**kwargs)
        with mock.patch("harvest.load_config", return_value=self.config), \
             mock.patch("harvest.make_client_factory", return_value=lambda model_id: self.Dead()):
            with self.assertRaises(SystemExit) as ctx:
                harvest.cmd_run(args)
        return ctx.exception.code

    def test_project_dir_reanchors_verify_dir(self):
        # --out deliberately nested outside the pipeline/1_raw convention --
        # the legacy reverse-derivation (raw_dir.parent.parent) would anchor
        # verify_dir under project_dir/custom/nested/verification, which is
        # wrong. With --project-dir given explicitly, verify_dir must land
        # at project_dir/pipeline/verification regardless of where --out
        # physically sits.
        raw_dir = self.project_dir / "custom" / "nested" / "out"
        code = self._run(raw_dir, self.project_dir)
        self.assertEqual(code, 3)  # past goal resolution, aborted on quorum

        wrong_verify_dir = self.project_dir / "custom" / "nested" / "verification"
        self.assertFalse(wrong_verify_dir.exists())

        # raw_dir != project_dir/pipeline/1_raw -> supplementary -> its own
        # track_<name>.json under the correctly-anchored verify_dir.
        correct_verify_dir = self.project_dir / "pipeline" / "verification"
        track_file = correct_verify_dir / harvest.track_verify_filename(raw_dir)
        self.assertTrue(track_file.exists())

    def test_supplementary_run_does_not_clobber_main_verify(self):
        # Primary track already has a recorded gate verdict from a prior
        # real run -- the supplementary backfill run below must leave it
        # byte-for-byte untouched.
        primary_raw_dir = self.project_dir / "pipeline" / "1_raw"
        primary_raw_dir.mkdir(parents=True)
        primary_verify_dir = self.project_dir / "pipeline" / "verification"
        primary_verify_dir.mkdir(parents=True)
        primary_verify_file = primary_verify_dir / harvest.VERIFY_FILE
        primary_payload = json.dumps({"verdict": "OK", "goal_file_sha256": "deadbeef"}, ensure_ascii=False)
        primary_verify_file.write_text(primary_payload, encoding="utf-8")

        supplementary_raw_dir = primary_raw_dir / "track_gap_A"
        code = self._run(supplementary_raw_dir, self.project_dir)
        self.assertEqual(code, 3)

        # Primary VERIFY_FILE must be exactly what it was before -- never
        # overwritten with the supplementary run's own RUNNING/UNAVAILABLE
        # tombstone.
        self.assertEqual(primary_verify_file.read_text(encoding="utf-8"), primary_payload)

        # The supplementary run's own state landed in its own track file.
        track_file = primary_verify_dir / harvest.track_verify_filename(supplementary_raw_dir)
        self.assertTrue(track_file.exists())
        track_payload = json.loads(track_file.read_text(encoding="utf-8"))
        self.assertEqual(track_payload["verdict"], "UNAVAILABLE")

    def test_supplementary_cleanup_never_touches_main_state(self):
        # Unit-test cleanup_stale_supplementary_state() directly against a
        # primary track that has real artifacts + a legacy exemption, plus
        # stale artifacts of its own -- confirms the scoped cleanup only
        # ever removes its own track file / its own --out subdirectory.
        primary_raw_dir = self.project_dir / "pipeline" / "1_raw"
        primary_raw_dir.mkdir(parents=True)
        verify_dir = self.project_dir / "pipeline" / "verification"
        verify_dir.mkdir(parents=True)

        primary_verify_file = verify_dir / harvest.VERIFY_FILE
        primary_verify_file.write_text("{}", encoding="utf-8")
        primary_exemption_file = verify_dir / harvest.LEGACY_EXEMPTION_FILE
        primary_exemption_file.write_text("exempt", encoding="utf-8")
        primary_merged = primary_raw_dir / harvest.MERGED_FINDINGS_FILE
        primary_merged.write_text("{}", encoding="utf-8")
        primary_harvest_dir = primary_raw_dir / harvest.HARVEST_SUBDIR
        primary_harvest_dir.mkdir()
        (primary_harvest_dir / "marker.txt").write_text("keep me", encoding="utf-8")

        supplementary_raw_dir = primary_raw_dir / "track_gap_A"
        supplementary_raw_dir.mkdir()
        verify_filename = harvest.track_verify_filename(supplementary_raw_dir)
        stale_track_file = verify_dir / verify_filename
        stale_track_file.write_text('{"verdict": "RUNNING"}', encoding="utf-8")
        stale_merged = supplementary_raw_dir / harvest.MERGED_FINDINGS_FILE
        stale_merged.write_text("{}", encoding="utf-8")
        stale_harvest_dir = supplementary_raw_dir / harvest.HARVEST_SUBDIR
        stale_harvest_dir.mkdir()

        harvest.cleanup_stale_supplementary_state(verify_dir, supplementary_raw_dir, verify_filename)

        # Own stale state gone.
        self.assertFalse(stale_track_file.exists())
        self.assertFalse(stale_merged.exists())
        self.assertFalse(stale_harvest_dir.exists())

        # Primary state never touched.
        self.assertTrue(primary_verify_file.exists())
        self.assertTrue(primary_exemption_file.exists())
        self.assertTrue(primary_merged.exists())
        self.assertTrue((primary_harvest_dir / "marker.txt").exists())

    def test_no_project_dir_preserves_legacy_reverse_derivation(self):
        # No --project-dir at all (attribute absent from the args namespace,
        # matching every pre-existing caller) -- getattr fallback must keep
        # the old raw_dir.parent / raw_dir.parent.parent derivation and the
        # plain (non-track-prefixed) VERIFY_FILE untouched.
        raw_dir = self.project_dir / "pipeline" / "1_raw"
        code = self._run(raw_dir, project_dir_arg=None)
        self.assertEqual(code, 3)

        verify_file = self.project_dir / "pipeline" / "verification" / harvest.VERIFY_FILE
        self.assertTrue(verify_file.exists())
        track_glob = list((self.project_dir / "pipeline" / "verification").glob("track_*.json"))
        self.assertEqual(track_glob, [])

    def test_supplementary_run_accepts_own_goal_file_and_anchors_its_hash(self):
        # Framework principle 6: a project is 1 primary track + N supplementary
        # tracks, each a deep-dive into a DIFFERENT sub-question (its own goal
        # text), each independently gated. A supplementary run must therefore
        # accept its own goal-file (distinct from the canonical
        # research-goal.md) and anchor goal_file_sha256 to THAT file -- the
        # audit trail stays honest because it records the text the panel
        # actually ran on, just not the canonical one. The canonical hard
        # check is a primary-track rule only.
        import hashlib
        track_goal = self.project_dir / "intake" / "requirements" / "supplement-goal-brand.md"
        track_goal.write_text("does brand tuning differ for astigmatism?", encoding="utf-8")

        supplementary_raw_dir = self.project_dir / "pipeline" / "1_raw" / "track_brand"
        code = self._run(supplementary_raw_dir, self.project_dir, goal_file_arg=track_goal)
        self.assertEqual(code, 3)  # past goal resolution, aborted later on quorum -- NOT exit 1

        # Its own track state file anchors the supplementary goal-file's hash,
        # never the canonical research-goal.md's.
        verify_dir = self.project_dir / "pipeline" / "verification"
        track_file = verify_dir / harvest.track_verify_filename(supplementary_raw_dir)
        self.assertTrue(track_file.exists())
        data = json.loads(track_file.read_text(encoding="utf-8"))
        self.assertEqual(data["goal_file_sha256"], hashlib.sha256(track_goal.read_bytes()).hexdigest())
        self.assertNotEqual(data["goal_file_sha256"], hashlib.sha256(self.goal_file.read_bytes()).hexdigest())

    def test_supplementary_goal_file_outside_project_still_aborts(self):
        # The canonical relaxation is scoped: a supplementary run may use its
        # own goal-file, but that file must still live inside the project
        # (so the audit trail anchors to a project-tracked artifact, not some
        # arbitrary path on disk). A goal-file outside project_dir aborts
        # before any state write -- same audit-integrity guarantee as the
        # primary-track canonical check.
        stray_goal = Path(self.tmpdir.name) / "outside-project.md"
        stray_goal.write_text("stray goal text", encoding="utf-8")

        supplementary_raw_dir = self.project_dir / "pipeline" / "1_raw" / "track_stray"
        code = self._run(supplementary_raw_dir, self.project_dir, goal_file_arg=stray_goal)
        self.assertEqual(code, 1)  # rejected before state write

        verify_dir = self.project_dir / "pipeline" / "verification"
        track_file = verify_dir / harvest.track_verify_filename(supplementary_raw_dir)
        self.assertFalse(track_file.exists())

    def test_primary_run_still_rejects_noncanonical_goal_file(self):
        # Regression guard for #25: the canonical hard check must remain
        # intact on the PRIMARY track (no --project-dir OR --out is the
        # canonical 1_raw). Relaxing it for supplementary runs must not open
        # a hole in the primary-track audit guarantee.
        other_goal = self.project_dir / "intake" / "requirements" / "not-canonical.md"
        other_goal.write_text("different primary goal text", encoding="utf-8")

        primary_raw_dir = self.project_dir / "pipeline" / "1_raw"
        code = self._run(primary_raw_dir, self.project_dir, goal_file_arg=other_goal)
        self.assertEqual(code, 1)  # primary track: non-canonical goal-file still hard-aborts

        verify_file = self.project_dir / "pipeline" / "verification" / harvest.VERIFY_FILE
        self.assertFalse(verify_file.exists())


class TestFetchReportRealStats(unittest.TestCase):
    def test_count_blacklist_hits_aggregates_across_workers(self):
        r1 = harvest.WorkerResult("m1", "model-a", "OK", {"claims": []},
                                   [{"tool": "fetch", "url": "https://blog.csdn.net/x", "blocked": "blacklist", "content": None},
                                    {"tool": "fetch", "url": "https://good.com/y", "backend": "urllib-ua", "content": "ok"}])
        r2 = harvest.WorkerResult("m2", "model-b", "OK", {"claims": []},
                                   [{"tool": "fetch", "url": "https://cloud.baidu.com/z", "blocked": "blacklist", "content": None}])
        r3 = harvest.WorkerResult("m3", "model-c", "FAILED", None, [])
        hits = harvest.count_blacklist_hits([r1, r2, r3])
        self.assertEqual(sorted(hits), ["https://blog.csdn.net/x", "https://cloud.baidu.com/z"])

    def test_count_blacklist_hits_empty_when_none_blocked(self):
        r1 = harvest.WorkerResult("m1", "model-a", "OK", {"claims": []},
                                   [{"tool": "fetch", "url": "https://good.com/y", "backend": "urllib-ua", "content": "ok"}])
        self.assertEqual(harvest.count_blacklist_hits([r1]), [])

    def test_write_fetch_report_reflects_real_blacklist_count(self):
        tmpdir = tempfile.TemporaryDirectory()
        try:
            raw_dir = Path(tmpdir.name)
            r1 = harvest.WorkerResult("m1", "model-a", "OK", {"claims": [], "keywords_used": {"zh": [], "en": []}},
                                       [{"tool": "fetch", "url": "https://blog.csdn.net/x", "blocked": "blacklist", "content": None}])
            harvest.write_fetch_report(raw_dir, [r1], [r1], 0, 0.0, [])
            report = (raw_dir / "fetch-report.md").read_text(encoding="utf-8")
            self.assertIn("屏蔽源命中: 1", report)
            self.assertIn("blog.csdn.net", report)
        finally:
            tmpdir.cleanup()

    def test_write_fetch_report_shows_rejection_distribution_by_model_and_reason(self):
        tmpdir = tempfile.TemporaryDirectory()
        try:
            raw_dir = Path(tmpdir.name)
            r1 = harvest.WorkerResult(
                "m1", "model-a", "OK", {"claims": [], "keywords_used": {"zh": [], "en": []}}, [],
                rejected_claims=[
                    {"claim": "c1", "url": "u1", "excerpt": "e1", "reject_reason": "url_not_fetched", "matched_url_normalized": None},
                    {"claim": "c2", "url": "u2", "excerpt": "e2", "reject_reason": "url_not_in_journal", "matched_url_normalized": None},
                ])
            r2 = harvest.WorkerResult(
                "m2", "model-b", "OK", {"claims": [], "keywords_used": {"zh": [], "en": []}}, [],
                rejected_claims=[
                    {"claim": "c3", "url": "u3", "excerpt": "e3", "reject_reason": "url_not_fetched", "matched_url_normalized": None},
                ])
            harvest.write_fetch_report(raw_dir, [r1, r2], [r1, r2], 3, 1.0, [])
            report = (raw_dir / "fetch-report.md").read_text(encoding="utf-8")
            self.assertIn("按模型分布: {'m1': 2, 'm2': 1}", report)
            self.assertIn("'url_not_fetched': 2", report)
            self.assertIn("'url_not_in_journal': 1", report)
        finally:
            tmpdir.cleanup()

    def test_write_fetch_report_quorum_status_uses_configured_threshold_not_hardcoded_two(self):
        tmpdir = tempfile.TemporaryDirectory()
        try:
            raw_dir = Path(tmpdir.name)
            r1 = harvest.WorkerResult("m1", "model-a", "OK", {"claims": [], "keywords_used": {"zh": [], "en": []}}, [])
            # 1 alive model with default quorum_required=2 -> "not met".
            harvest.write_fetch_report(raw_dir, [r1], [r1], 0, 0.0, [])
            self.assertIn("法定人数状态: not met",
                           (raw_dir / "fetch-report.md").read_text(encoding="utf-8"))

            # Same 1 alive model, but limits.quorum=1 -> must report "met",
            # not the hardcoded-2 "not met".
            harvest.write_fetch_report(raw_dir, [r1], [r1], 0, 0.0, [],
                                        quorum_required=1)
            self.assertIn("法定人数状态: met",
                           (raw_dir / "fetch-report.md").read_text(encoding="utf-8"))
        finally:
            tmpdir.cleanup()

    def test_write_fetch_report_candidate_completeness_is_explicit_pending(self):
        tmpdir = tempfile.TemporaryDirectory()
        try:
            raw_dir = Path(tmpdir.name)
            r1 = harvest.WorkerResult("m1", "model-a", "OK", {"claims": [], "keywords_used": {"zh": [], "en": []}}, [])
            harvest.write_fetch_report(raw_dir, [r1], [r1], 0, 0.0, [])
            report = (raw_dir / "fetch-report.md").read_text(encoding="utf-8")
            self.assertIn("PENDING", report)
            self.assertNotIn("候选集完备性\n- N/A", report)
        finally:
            tmpdir.cleanup()

    def test_detect_research_type_non_selection(self):
        self.assertEqual(harvest.detect_research_type("研究类型\nnon-selection（事实核验类）"), "non-selection")

    def test_detect_research_type_selection(self):
        self.assertEqual(harvest.detect_research_type("研究类型\nselection（选型类）"), "selection")

    def test_detect_research_type_undetected_returns_none(self):
        self.assertIsNone(harvest.detect_research_type("研究类型\n未声明"))

    def test_detect_research_type_empty_returns_none(self):
        self.assertIsNone(harvest.detect_research_type(""))

    def test_write_fetch_report_non_selection_goal_shows_na(self):
        tmpdir = tempfile.TemporaryDirectory()
        try:
            raw_dir = Path(tmpdir.name)
            r1 = harvest.WorkerResult("m1", "model-a", "OK", {"claims": [], "keywords_used": {"zh": [], "en": []}}, [])
            harvest.write_fetch_report(raw_dir, [r1], [r1], 0, 0.0, [],
                                        goal_text="研究类型\nnon-selection（事实核验类）")
            report = (raw_dir / "fetch-report.md").read_text(encoding="utf-8")
            self.assertIn("N/A（non-selection）", report)
            self.assertNotIn("PENDING", report)
        finally:
            tmpdir.cleanup()

    def test_write_fetch_report_selection_goal_shows_mandatory_pending(self):
        tmpdir = tempfile.TemporaryDirectory()
        try:
            raw_dir = Path(tmpdir.name)
            r1 = harvest.WorkerResult("m1", "model-a", "OK", {"claims": [], "keywords_used": {"zh": [], "en": []}}, [])
            harvest.write_fetch_report(raw_dir, [r1], [r1], 0, 0.0, [],
                                        goal_text="研究类型\nselection（选型类）")
            report = (raw_dir / "fetch-report.md").read_text(encoding="utf-8")
            self.assertIn("PENDING——harvester 须补填（selection 类必填）", report)
        finally:
            tmpdir.cleanup()


# ---------------------------------------------------------------------------
# Anthropic-native client: OpenAI <-> Anthropic protocol conversion
# ---------------------------------------------------------------------------

class TestAnthropicConversion(unittest.TestCase):
    def test_system_hoisted_to_top_level(self):
        msgs = [{"role": "system", "content": "SYS"}, {"role": "user", "content": "hi"}]
        system, anth = harvest._oai_messages_to_anthropic(msgs)
        self.assertEqual(system, "SYS")
        self.assertEqual(anth, [{"role": "user", "content": [{"type": "text", "text": "hi"}]}])

    def test_no_system_yields_none(self):
        system, anth = harvest._oai_messages_to_anthropic([{"role": "user", "content": "hi"}])
        self.assertIsNone(system)

    def test_assistant_tool_calls_become_tool_use_blocks(self):
        msgs = [{"role": "assistant", "content": None,
                 "tool_calls": [{"id": "tc1", "function": {"name": "search",
                                 "arguments": json.dumps({"query": "中文"})}}]}]
        _system, anth = harvest._oai_messages_to_anthropic(msgs)
        self.assertEqual(anth[0]["role"], "assistant")
        blocks = anth[0]["content"]
        self.assertEqual(len(blocks), 1)  # no empty text block prepended
        self.assertEqual(blocks[0]["type"], "tool_use")
        self.assertEqual(blocks[0]["id"], "tc1")
        self.assertEqual(blocks[0]["input"], {"query": "中文"})

    def test_assistant_text_plus_tool_call(self):
        msgs = [{"role": "assistant", "content": "thinking",
                 "tool_calls": [{"id": "t", "function": {"name": "fetch", "arguments": "{}"}}]}]
        _s, anth = harvest._oai_messages_to_anthropic(msgs)
        blocks = anth[0]["content"]
        self.assertEqual(blocks[0], {"type": "text", "text": "thinking"})
        self.assertEqual(blocks[1]["type"], "tool_use")

    def test_plain_assistant_returns_string(self):
        _s, anth = harvest._oai_messages_to_anthropic([{"role": "assistant", "content": "answer"}])
        self.assertEqual(anth[0]["content"], "answer")

    def test_consecutive_tool_messages_merged_into_one_user_turn(self):
        msgs = [
            {"role": "assistant", "content": None, "tool_calls": [
                {"id": "a", "function": {"name": "search", "arguments": "{}"}},
                {"id": "b", "function": {"name": "fetch", "arguments": "{}"}}]},
            {"role": "tool", "tool_call_id": "a", "content": "resA"},
            {"role": "tool", "tool_call_id": "b", "content": "resB"},
        ]
        _s, anth = harvest._oai_messages_to_anthropic(msgs)
        self.assertEqual(len(anth), 2)  # assistant + single merged user
        self.assertEqual(anth[1]["role"], "user")
        results = anth[1]["content"]
        self.assertEqual([r["tool_use_id"] for r in results], ["a", "b"])
        self.assertTrue(all(r["type"] == "tool_result" for r in results))

    def test_empty_user_content_produces_no_empty_text_block(self):
        # Anthropic rejects empty text blocks; an empty/None user turn must
        # contribute nothing rather than {"type":"text","text":""}.
        for empty in ("", None):
            _s, anth = harvest._oai_messages_to_anthropic([{"role": "user", "content": empty}])
            for m in anth:
                blocks = m["content"] if isinstance(m["content"], list) else []
                for b in blocks:
                    self.assertFalse(b.get("type") == "text" and b.get("text") == "",
                                     f"empty text block leaked for content={empty!r}")

    def test_empty_user_after_tool_result_does_not_append_empty_block(self):
        # Merging an empty user turn into a trailing tool_result user turn must
        # not tack on an empty text block.
        msgs = [
            {"role": "tool", "tool_call_id": "a", "content": "res"},
            {"role": "user", "content": ""},
        ]
        _s, anth = harvest._oai_messages_to_anthropic(msgs)
        user_blocks = anth[-1]["content"]
        self.assertEqual([b["type"] for b in user_blocks], ["tool_result"])

    def test_no_two_consecutive_user_turns(self):
        # A tool-result user turn immediately followed by a user message must
        # merge, not produce back-to-back user turns (Anthropic 400).
        msgs = [
            {"role": "tool", "tool_call_id": "a", "content": "res"},
            {"role": "user", "content": "nudge"},
        ]
        _s, anth = harvest._oai_messages_to_anthropic(msgs)
        user_turns = [m for m in anth if m["role"] == "user"]
        self.assertEqual(len(user_turns), 1)
        types = [b["type"] for b in user_turns[0]["content"]]
        self.assertEqual(types, ["tool_result", "text"])

    def test_tools_none_returns_none(self):
        self.assertIsNone(harvest._oai_tools_to_anthropic(None))
        self.assertIsNone(harvest._oai_tools_to_anthropic([]))

    def test_tools_converted_to_input_schema(self):
        anth = harvest._oai_tools_to_anthropic(harvest.TOOL_SCHEMAS)
        self.assertEqual(len(anth), len(harvest.TOOL_SCHEMAS))
        self.assertEqual(anth[0]["name"], "search")
        self.assertIn("input_schema", anth[0])
        self.assertNotIn("parameters", anth[0])

    def test_outbound_text_only_content_is_string(self):
        resp = {"content": [{"type": "text", "text": "hello"}], "stop_reason": "end_turn"}
        oai = harvest._anthropic_resp_to_oai(resp)
        msg = oai["choices"][0]["message"]
        self.assertEqual(msg["content"], "hello")
        self.assertNotIn("tool_calls", msg)
        self.assertEqual(oai["choices"][0]["finish_reason"], "end_turn")

    def test_outbound_tool_use_only_content_none(self):
        resp = {"content": [{"type": "tool_use", "id": "x", "name": "search",
                             "input": {"query": "q"}}], "stop_reason": "tool_use"}
        msg = harvest._anthropic_resp_to_oai(resp)["choices"][0]["message"]
        self.assertIsNone(msg["content"])
        self.assertEqual(msg["tool_calls"][0]["id"], "x")
        self.assertEqual(json.loads(msg["tool_calls"][0]["function"]["arguments"]), {"query": "q"})

    def test_outbound_extract_message_compatible(self):
        # _extract_message must read the converted shape unchanged.
        resp = {"content": [{"type": "text", "text": "j"}], "stop_reason": "end_turn"}
        oai = harvest._anthropic_resp_to_oai(resp)
        self.assertEqual(harvest._extract_message(oai), oai["choices"][0]["message"])

    def test_roundtrip_tool_use_idempotent(self):
        # outbound -> append -> inbound must preserve id/name/input.
        resp = {"content": [{"type": "tool_use", "id": "rid", "name": "fetch",
                             "input": {"url": "http://x", "q": "中文查询"}},
                            {"type": "text", "text": "note"}], "stop_reason": "tool_use"}
        msg = harvest._anthropic_resp_to_oai(resp)["choices"][0]["message"]
        _s, anth = harvest._oai_messages_to_anthropic([msg])
        blocks = anth[0]["content"]
        # text block first (non-empty), then tool_use with restored input
        self.assertEqual(blocks[0], {"type": "text", "text": "note"})
        tu = blocks[1]
        self.assertEqual(tu["id"], "rid")
        self.assertEqual(tu["name"], "fetch")
        self.assertEqual(tu["input"], {"url": "http://x", "q": "中文查询"})

    def test_cache_control_on_tools_tail_only(self):
        tools = [{"name": "a", "input_schema": {}}, {"name": "b", "input_schema": {}}]
        harvest._inject_cache_control(None, tools, [])
        self.assertNotIn("cache_control", tools[0])
        self.assertEqual(tools[1]["cache_control"], {"type": "ephemeral"})

    def test_cache_control_promotes_system_string_to_block(self):
        system = harvest._inject_cache_control("SYS", None, [])
        self.assertEqual(system, [{"type": "text", "text": "SYS",
                                   "cache_control": {"type": "ephemeral"}}])

    def test_cache_control_empty_system_untouched(self):
        self.assertIsNone(harvest._inject_cache_control(None, None, []))
        self.assertEqual(harvest._inject_cache_control("", None, []), "")

    def test_cache_control_on_message_tail_string_content(self):
        msgs = [{"role": "user", "content": "hi"}]
        harvest._inject_cache_control(None, None, msgs)
        self.assertEqual(msgs[0]["content"],
                         [{"type": "text", "text": "hi", "cache_control": {"type": "ephemeral"}}])

    def test_cache_control_on_message_tail_block_list(self):
        msgs = [{"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "a", "content": "r1"},
            {"type": "tool_result", "tool_use_id": "b", "content": "r2"}]}]
        harvest._inject_cache_control(None, None, msgs)
        blocks = msgs[0]["content"]
        self.assertNotIn("cache_control", blocks[0])
        self.assertEqual(blocks[1]["cache_control"], {"type": "ephemeral"})

    def test_cache_control_skips_empty_tail_text_block(self):
        # An empty text block cannot carry cache_control; mark the prior real
        # block instead.
        blocks = [{"type": "text", "text": "real"}, {"type": "text", "text": ""}]
        harvest._mark_block_list_tail(blocks)
        self.assertEqual(blocks[0]["cache_control"], {"type": "ephemeral"})
        self.assertNotIn("cache_control", blocks[1])

    def test_empty_message_content_not_marked(self):
        msgs = [{"role": "user", "content": ""}]
        harvest._inject_cache_control(None, None, msgs)
        self.assertEqual(msgs[0]["content"], "")  # untouched, no empty block created


# ---------------------------------------------------------------------------
# ADR-011: panel three-way KV-cache optimization -- gpt via Responses API,
# claude effort configuration. Mirrors TestAnthropicConversion's structure
# for the new Responses protocol conversion pure functions.
# ---------------------------------------------------------------------------

class TestResponsesConversion(unittest.TestCase):
    def test_system_hoisted_to_instructions(self):
        msgs = [{"role": "system", "content": "SYS"}, {"role": "user", "content": "hi"}]
        instructions, items = harvest._oai_messages_to_responses(msgs)
        self.assertEqual(instructions, "SYS")
        self.assertEqual(items, [{"role": "user", "content": [{"type": "input_text", "text": "hi"}]}])

    def test_no_system_yields_none_instructions(self):
        instructions, _items = harvest._oai_messages_to_responses([{"role": "user", "content": "hi"}])
        self.assertIsNone(instructions)

    def test_plain_assistant_text_becomes_message_item(self):
        _i, items = harvest._oai_messages_to_responses([{"role": "assistant", "content": "answer"}])
        self.assertEqual(items, [{"role": "assistant", "content": [{"type": "output_text", "text": "answer"}]}])

    def test_assistant_tool_calls_become_function_call_items(self):
        msgs = [{"role": "assistant", "content": None,
                 "tool_calls": [{"id": "tc1", "function": {"name": "search",
                                 "arguments": json.dumps({"query": "中文"})}}]}]
        _i, items = harvest._oai_messages_to_responses(msgs)
        self.assertEqual(len(items), 1)  # no empty text item for null content
        self.assertEqual(items[0]["type"], "function_call")
        self.assertEqual(items[0]["call_id"], "tc1")
        self.assertEqual(items[0]["name"], "search")
        self.assertEqual(json.loads(items[0]["arguments"]), {"query": "中文"})

    def test_assistant_text_plus_single_tool_call(self):
        msgs = [{"role": "assistant", "content": "thinking",
                 "tool_calls": [{"id": "t", "function": {"name": "fetch", "arguments": "{}"}}]}]
        _i, items = harvest._oai_messages_to_responses(msgs)
        self.assertEqual(items[0], {"role": "assistant", "content": [{"type": "output_text", "text": "thinking"}]})
        self.assertEqual(items[1]["type"], "function_call")

    def test_assistant_parallel_tool_calls_become_separate_items(self):
        msgs = [{"role": "assistant", "content": None, "tool_calls": [
            {"id": "a", "function": {"name": "search", "arguments": json.dumps({"query": "q1"})}},
            {"id": "b", "function": {"name": "search", "arguments": json.dumps({"query": "q2"})}}]}]
        _i, items = harvest._oai_messages_to_responses(msgs)
        self.assertEqual(len(items), 2)
        self.assertEqual([it["call_id"] for it in items], ["a", "b"])
        self.assertTrue(all(it["type"] == "function_call" for it in items))

    def test_tool_message_becomes_function_call_output(self):
        msgs = [{"role": "tool", "tool_call_id": "a", "content": "resA"}]
        _i, items = harvest._oai_messages_to_responses(msgs)
        self.assertEqual(items, [{"type": "function_call_output", "call_id": "a", "output": "resA"}])

    def test_parallel_tool_results_become_separate_items_no_merge(self):
        # Unlike the Anthropic conversion (which must merge consecutive tool
        # messages into one user turn), Responses' flat input list needs no
        # such merge -- each tool result is independently addressable by
        # call_id.
        msgs = [
            {"role": "assistant", "content": None, "tool_calls": [
                {"id": "a", "function": {"name": "search", "arguments": "{}"}},
                {"id": "b", "function": {"name": "fetch", "arguments": "{}"}}]},
            {"role": "tool", "tool_call_id": "a", "content": "resA"},
            {"role": "tool", "tool_call_id": "b", "content": "resB"},
        ]
        _i, items = harvest._oai_messages_to_responses(msgs)
        outputs = [it for it in items if it["type"] == "function_call_output"]
        self.assertEqual(len(outputs), 2)
        self.assertEqual([o["call_id"] for o in outputs], ["a", "b"])
        self.assertEqual([o["output"] for o in outputs], ["resA", "resB"])

    def test_empty_user_content_produces_no_item(self):
        for empty in ("", None):
            _i, items = harvest._oai_messages_to_responses([{"role": "user", "content": empty}])
            self.assertEqual(items, [], f"empty user content leaked an item for content={empty!r}")

    def test_tools_none_returns_none(self):
        self.assertIsNone(harvest._oai_tools_to_responses(None))
        self.assertIsNone(harvest._oai_tools_to_responses([]))

    def test_tools_converted_to_flat_responses_shape(self):
        resp_tools = harvest._oai_tools_to_responses(harvest.TOOL_SCHEMAS)
        self.assertEqual(len(resp_tools), len(harvest.TOOL_SCHEMAS))
        self.assertEqual(resp_tools[0]["type"], "function")
        self.assertEqual(resp_tools[0]["name"], "search")
        self.assertIn("parameters", resp_tools[0])
        self.assertNotIn("function", resp_tools[0])  # flat, not nested like chat/completions

    def test_outbound_text_only_content_is_string(self):
        resp = {"output": [{"type": "message", "content": [{"type": "output_text", "text": "hello"}]}],
                "status": "completed"}
        oai = harvest._responses_resp_to_oai(resp)
        msg = oai["choices"][0]["message"]
        self.assertEqual(msg["content"], "hello")
        self.assertNotIn("tool_calls", msg)
        self.assertEqual(oai["choices"][0]["finish_reason"], "completed")

    def test_outbound_function_call_only_content_none(self):
        resp = {"output": [{"type": "function_call", "call_id": "x", "name": "search",
                            "arguments": json.dumps({"query": "q"})}], "status": "completed"}
        msg = harvest._responses_resp_to_oai(resp)["choices"][0]["message"]
        self.assertIsNone(msg["content"])
        self.assertEqual(msg["tool_calls"][0]["id"], "x")
        self.assertEqual(json.loads(msg["tool_calls"][0]["function"]["arguments"]), {"query": "q"})

    def test_outbound_extract_message_compatible(self):
        resp = {"output": [{"type": "message", "content": [{"type": "output_text", "text": "j"}]}],
                "status": "completed"}
        oai = harvest._responses_resp_to_oai(resp)
        self.assertEqual(harvest._extract_message(oai), oai["choices"][0]["message"])

    def test_roundtrip_single_function_call_idempotent(self):
        resp = {"output": [{"type": "function_call", "call_id": "rid", "name": "fetch",
                            "arguments": json.dumps({"url": "http://x", "q": "中文查询"})}],
                "status": "completed"}
        msg = harvest._responses_resp_to_oai(resp)["choices"][0]["message"]
        _i, items = harvest._oai_messages_to_responses([msg])
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["call_id"], "rid")
        self.assertEqual(items[0]["name"], "fetch")
        self.assertEqual(json.loads(items[0]["arguments"]), {"url": "http://x", "q": "中文查询"})

    def test_roundtrip_parallel_function_calls_idempotent(self):
        resp = {"output": [
            {"type": "function_call", "call_id": "r1", "name": "search", "arguments": json.dumps({"query": "a"})},
            {"type": "function_call", "call_id": "r2", "name": "search", "arguments": json.dumps({"query": "b"})},
        ], "status": "completed"}
        msg = harvest._responses_resp_to_oai(resp)["choices"][0]["message"]
        self.assertEqual(len(msg["tool_calls"]), 2)
        _i, items = harvest._oai_messages_to_responses([msg])
        self.assertEqual([it["call_id"] for it in items], ["r1", "r2"])

    def test_roundtrip_tool_result_feedback(self):
        # Simulate a full round: function_call from the model, then the
        # worker's tool_call_id-keyed reply, converted to Responses items.
        resp = {"output": [{"type": "function_call", "call_id": "rid", "name": "fetch",
                            "arguments": json.dumps({"url": "http://x"})}], "status": "completed"}
        msg = harvest._responses_resp_to_oai(resp)["choices"][0]["message"]
        tool_msg = {"role": "tool", "tool_call_id": "rid", "content": "fetched body"}
        _i, items = harvest._oai_messages_to_responses([msg, tool_msg])
        self.assertEqual(items[0]["type"], "function_call")
        self.assertEqual(items[1], {"type": "function_call_output", "call_id": "rid", "output": "fetched body"})


class TestResponsesGatewayClient(unittest.TestCase):
    def test_complete_posts_to_responses_endpoint(self):
        client = harvest.ResponsesGatewayClient("http://gw", "key", "gpt-5.4", 5, 16384)
        ok_response = {"output": [{"type": "message", "content": [{"type": "output_text", "text": "hi"}]}],
                       "status": "completed"}
        with mock.patch("harvest_clients.base._http_json_post_with_retry", return_value=ok_response) as m:
            result = client.complete(messages=[{"role": "user", "content": "x"}], tools=None)
        self.assertEqual(result["choices"][0]["message"]["content"], "hi")
        url = m.call_args[0][0]
        self.assertTrue(url.endswith("/responses"))

    def test_complete_sets_max_output_tokens(self):
        client = harvest.ResponsesGatewayClient("http://gw", "key", "gpt-5.4", 5, 9999)
        ok_response = {"output": [], "status": "completed"}
        with mock.patch("harvest_clients.base._http_json_post_with_retry", return_value=ok_response) as m:
            client.complete(messages=[{"role": "user", "content": "x"}], tools=None)
        payload = m.call_args[0][1]
        self.assertEqual(payload["max_output_tokens"], 9999)

    def test_truncated_output_surfaces_as_incomplete_not_silently_swallowed(self):
        # plan-review MUST FIX-2: a findings JSON cut off by an output cap
        # must be *observable* (finish_reason carries "incomplete", the
        # chopped text is still returned) rather than silently dropped --
        # parse_findings_json then legitimately fails on the truncated
        # candidate, same failure mode the Anthropic path already has via
        # stop_reason="max_tokens".
        client = harvest.ResponsesGatewayClient("http://gw", "key", "gpt-5.4", 5, 64)
        truncated_response = {
            "output": [{"type": "message", "content": [
                {"type": "output_text", "text": '{"claims": [{"claim": "A", "excerpt": "e", "url": "u'}
            ]}],
            "status": "incomplete",
        }
        with mock.patch("harvest_clients.base._http_json_post_with_retry", return_value=truncated_response) as m:
            result = client.complete(messages=[{"role": "user", "content": "x"}], tools=harvest.TOOL_SCHEMAS)
        self.assertEqual(m.call_args[0][1]["max_output_tokens"], 64)
        self.assertEqual(result["choices"][0]["finish_reason"], "incomplete")
        content = result["choices"][0]["message"]["content"]
        data, err = harvest.parse_findings_json(content)
        self.assertIsNone(data)
        self.assertIsNotNone(err)

    def test_complete_omits_tools_field_when_none(self):
        # Judge path (judge_clusters) calls complete(messages, tools=None) --
        # the Responses payload must not carry a tools key at all.
        client = harvest.ResponsesGatewayClient("http://gw", "key", "gpt-5.4", 5, 16384)
        ok_response = {"output": [{"type": "message", "content": [{"type": "output_text", "text": "j"}]}],
                       "status": "completed"}
        with mock.patch("harvest_clients.base._http_json_post_with_retry", return_value=ok_response) as m:
            client.complete(messages=[{"role": "system", "content": "sys"},
                                       {"role": "user", "content": "judge input"}], tools=None)
        payload = m.call_args[0][1]
        self.assertNotIn("tools", payload)
        self.assertEqual(payload["instructions"], "sys")

    def test_complete_includes_tools_when_present(self):
        client = harvest.ResponsesGatewayClient("http://gw", "key", "gpt-5.4", 5, 16384)
        ok_response = {"output": [], "status": "completed"}
        with mock.patch("harvest_clients.base._http_json_post_with_retry", return_value=ok_response) as m:
            client.complete(messages=[{"role": "user", "content": "x"}], tools=harvest.TOOL_SCHEMAS)
        payload = m.call_args[0][1]
        self.assertEqual(len(payload["tools"]), len(harvest.TOOL_SCHEMAS))
        self.assertEqual(payload["tools"][0]["type"], "function")

    def test_judge_clusters_end_to_end_with_responses_client(self):
        # judge_clusters(judge_client, ...) passes tools=None -- exercise the
        # real call path (not just complete()) to prove the judge's
        # nothing-but-text round-trip survives a ResponsesGatewayClient.
        client = harvest.ResponsesGatewayClient("http://gw", "key", "gpt-5.4", 5, 16384)
        judge_text = '```json\n{"clusters": [{"summary": "s", "source_claim_ids": ["m1-1"], "relation": "agree"}]}\n```'
        ok_response = {"output": [{"type": "message", "content": [{"type": "output_text", "text": judge_text}]}],
                       "status": "completed"}
        worker_findings = {"m1": {"claims": [{"_id": "m1-1", "claim": "A", "excerpt": "e", "url": "u"}]}}
        with mock.patch("harvest_clients.base._http_json_post_with_retry", return_value=ok_response) as m:
            data, err = harvest.judge_clusters(client, worker_findings)
        self.assertIsNone(err)
        self.assertEqual(data["clusters"][0]["source_claim_ids"], ["m1-1"])
        payload = m.call_args[0][1]
        self.assertNotIn("tools", payload)


class TestAnthropicEffortInjection(unittest.TestCase):
    def test_effort_none_omits_output_config(self):
        client = harvest.AnthropicGatewayClient("http://gw", "key", "claude-sonnet-5", 5, 16384, effort=None)
        ok_response = {"content": [{"type": "text", "text": "hi"}], "stop_reason": "end_turn"}
        with mock.patch("harvest_clients.anthropic._anthropic_post_with_retry", return_value=ok_response) as m:
            client.complete(messages=[{"role": "user", "content": "x"}], tools=None)
        payload = m.call_args[0][1]
        self.assertNotIn("output_config", payload)

    def test_effort_medium_injects_output_config(self):
        client = harvest.AnthropicGatewayClient("http://gw", "key", "claude-sonnet-5", 5, 16384, effort="medium")
        ok_response = {"content": [{"type": "text", "text": "hi"}], "stop_reason": "end_turn"}
        with mock.patch("harvest_clients.anthropic._anthropic_post_with_retry", return_value=ok_response) as m:
            client.complete(messages=[{"role": "user", "content": "x"}], tools=None)
        payload = m.call_args[0][1]
        self.assertEqual(payload["output_config"], {"effort": "medium"})

    def test_effort_high_injects_output_config_high(self):
        client = harvest.AnthropicGatewayClient("http://gw", "key", "claude-sonnet-5", 5, 16384, effort="high")
        ok_response = {"content": [{"type": "text", "text": "hi"}], "stop_reason": "end_turn"}
        with mock.patch("harvest_clients.anthropic._anthropic_post_with_retry", return_value=ok_response) as m:
            client.complete(messages=[{"role": "user", "content": "x"}], tools=None)
        payload = m.call_args[0][1]
        self.assertEqual(payload["output_config"], {"effort": "high"})


class TestMakeClientFactoryThreeWayDispatch(unittest.TestCase):
    def setUp(self):
        self.env_patcher = mock.patch.dict(os.environ, {"TEST_GATEWAY_KEY": "secret"})
        self.env_patcher.start()
        self.addCleanup(self.env_patcher.stop)

    def test_claude_dispatches_to_anthropic_client(self):
        factory = harvest.make_client_factory(base_config())
        client = factory("claude-sonnet-5")
        self.assertIsInstance(client, harvest.AnthropicGatewayClient)

    def test_gpt_dispatches_to_responses_client(self):
        factory = harvest.make_client_factory(base_config())
        client = factory("gpt-5.4")
        self.assertIsInstance(client, harvest.ResponsesGatewayClient)

    def test_gemini_dispatches_to_gemini_native_client(self):
        # research#40 / ADR-011 follow-up: gemini now defaults to the
        # Gemini-native generateContent path (see
        # TestMakeClientFactoryGeminiDispatch for full coverage of this
        # dispatch branch, including the chat_completions fallback). This
        # class's job is only to prove claude/gpt dispatch is unaffected by
        # that change -- see test_claude_dispatches_to_anthropic_client and
        # test_gpt_dispatches_to_responses_client above.
        factory = harvest.make_client_factory(base_config())
        client = factory("gemini-3.5-flash")
        self.assertIsInstance(client, harvest.GeminiNativeGatewayClient)
        self.assertNotIsInstance(client, harvest.ResponsesGatewayClient)

    def test_claude_effort_defaults_to_medium(self):
        # No limits.claude_effort key in base_config() at all -- this is the
        # "old config missing the new key" case ADR-011 calls out as a
        # deliberate global default *lowering* to medium, not a no-op.
        factory = harvest.make_client_factory(base_config())
        client = factory("claude-sonnet-5")
        self.assertEqual(client.effort, "medium")

    def test_claude_effort_explicit_config_value_respected(self):
        config = base_config()
        config["limits"] = dict(config["limits"], claude_effort="high")
        factory = harvest.make_client_factory(config)
        client = factory("claude-sonnet-5")
        self.assertEqual(client.effort, "high")

    def test_responses_client_max_output_tokens_mirrors_completion_max_tokens(self):
        config = base_config()
        config["limits"] = dict(config["limits"], completion_max_tokens=12345)
        factory = harvest.make_client_factory(config)
        client = factory("gpt-5.4")
        self.assertEqual(client.max_output_tokens, 12345)

    def test_gpt_endpoint_config_switch_falls_back_to_chat_completions(self):
        config = base_config()
        config["limits"] = dict(config["limits"], gpt_endpoint="chat_completions")
        factory = harvest.make_client_factory(config)
        client = factory("gpt-5.4")
        self.assertIsInstance(client, harvest.GatewayClient)
        self.assertNotIsInstance(client, harvest.ResponsesGatewayClient)

    def test_old_config_missing_all_new_keys_does_not_raise(self):
        # base_config()'s "limits" dict has neither claude_effort nor
        # gpt_endpoint -- constructing all three client types must not
        # KeyError.
        config = base_config()
        self.assertNotIn("claude_effort", config["limits"])
        self.assertNotIn("gpt_endpoint", config["limits"])
        factory = harvest.make_client_factory(config)
        factory("claude-sonnet-5")
        factory("gpt-5.4")
        factory("gemini-3.5-flash")

    def test_judge_fallback_mixes_responses_client_with_tools_none(self):
        # run_judge_with_fallback can route a candidate to a gpt model ->
        # ResponsesGatewayClient with tools=None (judge_clusters never
        # passes tools) -- exercise that combination through the real
        # dispatch+call path.
        config = base_config(judge_model="gpt-5.4", panel_models=["gpt-5.4", "model-b"])
        factory = harvest.make_client_factory(config)
        judge_text = '```json\n{"clusters": [{"summary": "s", "source_claim_ids": ["m1-1"], "relation": "agree"}]}\n```'
        ok_response = {"output": [{"type": "message", "content": [{"type": "output_text", "text": judge_text}]}],
                       "status": "completed"}
        worker_findings = {"m1": {"claims": [{"_id": "m1-1", "claim": "A", "excerpt": "e", "url": "u"}]}}
        with mock.patch("harvest_clients.base._http_json_post_with_retry", return_value=ok_response):
            data, err = harvest.run_judge_with_fallback(config, factory, worker_findings, config["panel_models"])
        self.assertIsNone(err)
        self.assertEqual(data["clusters"][0]["source_claim_ids"], ["m1-1"])


# ---------------------------------------------------------------------------
# research#40 / ADR-011 follow-up: gemini via Gemini-native generateContent,
# mirroring TestAnthropicConversion / TestResponsesConversion's structure for
# the new Gemini protocol conversion pure functions.
# ---------------------------------------------------------------------------

class TestGeminiGenerateContentUrl(unittest.TestCase):
    def test_default_config_base_url(self):
        url = harvest._gemini_generate_content_url("https://aapi.tbps.one/v1", "gemini-3.5-flash")
        self.assertEqual(url, "https://aapi.tbps.one/v1beta/models/gemini-3.5-flash:generateContent")

    def test_multi_level_path_prefix_preserved(self):
        url = harvest._gemini_generate_content_url("https://gateway.corp.com/ai-proxy/v1", "gemini-3.5-flash")
        self.assertEqual(url, "https://gateway.corp.com/ai-proxy/v1beta/models/gemini-3.5-flash:generateContent")

    def test_no_v1_suffix_not_mis_truncated(self):
        url = harvest._gemini_generate_content_url("https://gw.example.com", "gemini-3.5-flash")
        self.assertEqual(url, "https://gw.example.com/v1beta/models/gemini-3.5-flash:generateContent")

    def test_trailing_slash_stripped(self):
        url = harvest._gemini_generate_content_url("https://aapi.tbps.one/v1/", "gemini-3.5-flash")
        self.assertEqual(url, "https://aapi.tbps.one/v1beta/models/gemini-3.5-flash:generateContent")


class TestGeminiToolsConversion(unittest.TestCase):
    def test_tools_none_returns_none(self):
        self.assertIsNone(harvest._oai_tools_to_gemini(None))
        self.assertIsNone(harvest._oai_tools_to_gemini([]))

    def test_tools_converted_to_function_declarations(self):
        gemini_tools = harvest._oai_tools_to_gemini(harvest.TOOL_SCHEMAS)
        self.assertEqual(len(gemini_tools), 1)
        declarations = gemini_tools[0]["functionDeclarations"]
        self.assertEqual(len(declarations), len(harvest.TOOL_SCHEMAS))
        self.assertEqual(declarations[0]["name"], harvest.TOOL_SCHEMAS[0]["function"]["name"])
        self.assertIn("parameters", declarations[0])


class TestGeminiMessagesConversion(unittest.TestCase):
    def test_system_hoisted_to_system_instruction(self):
        msgs = [{"role": "system", "content": "SYS"}, {"role": "user", "content": "hi"}]
        system, contents = harvest._oai_messages_to_gemini(msgs)
        self.assertEqual(system, {"parts": [{"text": "SYS"}]})
        self.assertEqual(contents, [{"role": "user", "parts": [{"text": "hi"}]}])

    def test_no_system_yields_none(self):
        system, _contents = harvest._oai_messages_to_gemini([{"role": "user", "content": "hi"}])
        self.assertIsNone(system)

    def test_multiple_system_messages_merged_not_overwritten(self):
        msgs = [
            {"role": "system", "content": "first rule"},
            {"role": "system", "content": "second rule"},
            {"role": "user", "content": "hi"},
        ]
        system, _contents = harvest._oai_messages_to_gemini(msgs)
        self.assertEqual(system, {"parts": [{"text": "first rule\n\nsecond rule"}]})

    def test_assistant_text_plus_function_call(self):
        msgs = [{"role": "assistant", "content": "thinking",
                 "tool_calls": [{"id": "t1", "function": {"name": "search",
                                 "arguments": json.dumps({"query": "q"})}}]}]
        _s, contents = harvest._oai_messages_to_gemini(msgs)
        self.assertEqual(contents[0]["role"], "model")
        parts = contents[0]["parts"]
        self.assertEqual(parts[0], {"text": "thinking"})
        self.assertEqual(parts[1]["functionCall"], {"name": "search", "args": {"query": "q"}})

    def test_assistant_function_call_with_signature_replayed_as_sibling_key(self):
        msgs = [{"role": "assistant", "content": None,
                 "tool_calls": [{"id": "t1", "function": {"name": "search",
                                 "arguments": json.dumps({"query": "q"})},
                                 "thought_signature": "sig-xyz"}]}]
        _s, contents = harvest._oai_messages_to_gemini(msgs)
        part = contents[0]["parts"][0]
        self.assertEqual(part["functionCall"], {"name": "search", "args": {"query": "q"}})
        self.assertEqual(part["thoughtSignature"], "sig-xyz")

    def test_assistant_function_call_without_signature_omits_key(self):
        msgs = [{"role": "assistant", "content": None,
                 "tool_calls": [{"id": "t1", "function": {"name": "search",
                                 "arguments": json.dumps({"query": "q"})}}]}]
        _s, contents = harvest._oai_messages_to_gemini(msgs)
        part = contents[0]["parts"][0]
        self.assertNotIn("thoughtSignature", part)

    def test_round_trip_response_to_replay_preserves_signature(self):
        # Direct regression test for the "position 2" HTTP 400: the signature
        # must survive raw response -> internal OAI shape -> replayed Gemini
        # contents unbroken, or turn 2 of a multi-round tool-call conversation
        # gets rejected server-side.
        resp = {"candidates": [{"finishReason": "STOP", "content": {"parts": [
            {"functionCall": {"name": "search", "args": {"q": "x"}}, "thoughtSignature": "sig-roundtrip"},
        ]}}]}
        oai = harvest._gemini_resp_to_oai(resp)
        assistant_msg = oai["choices"][0]["message"]
        messages = [
            assistant_msg,
            {"role": "tool", "tool_call_id": assistant_msg["tool_calls"][0]["id"],
             "content": json.dumps({"result": "ok"})},
        ]
        _s, contents = harvest._oai_messages_to_gemini(messages)
        model_turn = next(c for c in contents if c["role"] == "model")
        fc_part = next(p for p in model_turn["parts"] if "functionCall" in p)
        self.assertEqual(fc_part["thoughtSignature"], "sig-roundtrip")

    def test_tool_role_resolves_name_from_prior_assistant_call(self):
        msgs = [
            {"role": "assistant", "content": None,
             "tool_calls": [{"id": "c1", "function": {"name": "search", "arguments": "{}"}}]},
            {"role": "tool", "tool_call_id": "c1", "content": json.dumps({"result": "ok"})},
        ]
        _s, contents = harvest._oai_messages_to_gemini(msgs)
        self.assertEqual(contents[1]["role"], "user")
        fr = contents[1]["parts"][0]["functionResponse"]
        self.assertEqual(fr["name"], "search")
        self.assertEqual(fr["response"], {"result": "ok"})

    def test_tool_content_non_json_wrapped_as_result_string(self):
        msgs = [
            {"role": "assistant", "content": None,
             "tool_calls": [{"id": "c1", "function": {"name": "fetch", "arguments": "{}"}}]},
            {"role": "tool", "tool_call_id": "c1", "content": "plain text, not json"},
        ]
        _s, contents = harvest._oai_messages_to_gemini(msgs)
        fr = contents[1]["parts"][0]["functionResponse"]
        self.assertEqual(fr["response"], {"result": "plain text, not json"})

    def test_tool_content_valid_json_non_dict_wrapped_as_result(self):
        for raw, expected in ((json.dumps([1, 2, 3]), [1, 2, 3]),
                               (json.dumps(True), True),
                               (json.dumps(42), 42)):
            msgs = [
                {"role": "assistant", "content": None,
                 "tool_calls": [{"id": "c1", "function": {"name": "fetch", "arguments": "{}"}}]},
                {"role": "tool", "tool_call_id": "c1", "content": raw},
            ]
            _s, contents = harvest._oai_messages_to_gemini(msgs)
            fr = contents[1]["parts"][0]["functionResponse"]
            self.assertEqual(fr["response"], {"result": expected})

    def test_tool_call_id_not_found_raises(self):
        msgs = [{"role": "tool", "tool_call_id": "ghost", "content": "{}"}]
        with self.assertRaises(ValueError):
            harvest._oai_messages_to_gemini(msgs)

    def test_parallel_tool_calls_each_resolve_correct_name(self):
        msgs = [
            {"role": "assistant", "content": None, "tool_calls": [
                {"id": "a", "function": {"name": "search", "arguments": "{}"}},
                {"id": "b", "function": {"name": "fetch", "arguments": "{}"}}]},
            {"role": "tool", "tool_call_id": "a", "content": json.dumps({"r": "A"})},
            {"role": "tool", "tool_call_id": "b", "content": json.dumps({"r": "B"})},
        ]
        _s, contents = harvest._oai_messages_to_gemini(msgs)
        # both tool results collapse into one merged user turn
        self.assertEqual(len(contents), 2)
        self.assertEqual(contents[1]["role"], "user")
        names = [p["functionResponse"]["name"] for p in contents[1]["parts"]]
        self.assertEqual(names, ["search", "fetch"])
        responses = [p["functionResponse"]["response"] for p in contents[1]["parts"]]
        self.assertEqual(responses, [{"r": "A"}, {"r": "B"}])

    def test_user_turn_after_tool_results_merges_not_consecutive(self):
        msgs = [
            {"role": "assistant", "content": None,
             "tool_calls": [{"id": "a", "function": {"name": "search", "arguments": "{}"}}]},
            {"role": "tool", "tool_call_id": "a", "content": "{}"},
            {"role": "user", "content": "nudge"},
        ]
        _s, contents = harvest._oai_messages_to_gemini(msgs)
        user_turns = [c for c in contents if c["role"] == "user"]
        self.assertEqual(len(user_turns), 1)
        self.assertEqual(len(user_turns[0]["parts"]), 2)

    def _assert_valid_gemini_part(self, part, where):
        # A Gemini content part is a oneof: exactly one of text / functionCall /
        # functionResponse must be present AND initialized. The original #99
        # 400 ("parts[N].data: required oneof field 'data' must have one
        # initialized field") is precisely the shape this guards against, so
        # the assertion checks oneof presence directly rather than only
        # `part.get("text") != ""` -- the latter passes vacuously for a part
        # that carries NO oneof key at all (e.g. a degenerate {}), which is the
        # exact uninitialized-oneof shape Gemini rejects. Verified against the
        # live gateway (aapi.tbps.one, gemini-3.5-flash): {"text": ""} -> HTTP
        # 400 with that exact message, {"text": " "} -> HTTP 200.
        oneof_keys = [k for k in ("text", "functionCall", "functionResponse") if k in part]
        self.assertEqual(len(oneof_keys), 1,
                         f"{where}: part must carry exactly one oneof key, got {list(part)}: {part}")
        key = oneof_keys[0]
        if key == "text":
            # An empty string is an *uninitialized* text oneof to Gemini.
            self.assertNotEqual(part["text"], "", f"{where}: empty text oneof (rejected by Gemini): {part}")
        else:
            self.assertTrue(part[key], f"{where}: empty {key} oneof: {part}")

    def test_empty_assistant_turn_yields_valid_nonempty_oneof_part(self):
        # Regression for #99: a degenerate assistant message -- empty content
        # AND no tool_calls (a thinking model that spent its whole output
        # budget on thoughts, or a safety-stripped candidate whose only
        # product is content="") -- must NOT serialize to {"text": ""}.
        # Gemini rejects an empty text part as an uninitialized oneof
        # (contents[N].parts[0].data: required oneof field 'data' must have
        # one initialized field -> HTTP 400), which crashed the forced-
        # synthesis retry. The fallback part must be a valid, non-empty oneof,
        # mirroring anthropic's non-empty-content fallback (anthropic.py:82).
        for empty in ("", None):
            _s, contents = harvest._oai_messages_to_gemini([{"role": "assistant", "content": empty}])
            self.assertEqual(len(contents), 1)
            self.assertEqual(contents[0]["role"], "model")
            parts = contents[0]["parts"]
            self.assertEqual(len(parts), 1, f"empty content={empty!r} must yield exactly one placeholder part")
            self._assert_valid_gemini_part(parts[0], f"empty content={empty!r}")

    def test_forced_synthesis_retry_history_produces_only_valid_oneof_parts(self):
        # Scenario reproduction of #99's exact failure (see also the live-
        # gateway E2E recorded in the issue): the forced-synthesis else-branch
        # (harvest.py) keeps a parse-failed assistant message in history then
        # appends a user reminder. When that assistant message is empty
        # (content=""), EVERY replayed part must be a valid non-empty oneof --
        # not just "no empty text part": a content entry with zero parts, or a
        # part missing all oneof keys, is rejected by Gemini identically to an
        # empty text part, so the whole payload is validated part-by-part.
        messages = [
            {"role": "system", "content": "SYS"},
            {"role": "user", "content": "goal"},
            {"role": "assistant", "content": None,
             "tool_calls": [{"id": "c1", "function": {"name": "search", "arguments": "{}"}}]},
            {"role": "tool", "tool_call_id": "c1", "content": json.dumps({"r": "A"})},
            {"role": "assistant", "content": None,
             "tool_calls": [{"id": "c2", "function": {"name": "search", "arguments": "{}"}}]},
            {"role": "tool", "tool_call_id": "c2", "content": json.dumps({"r": "B"})},
            {"role": "assistant", "content": ""},  # forced-synthesis empty attempt
            {"role": "user", "content": "JSON parse error: ... Re-output valid findings JSON."},
        ]
        _s, contents = harvest._oai_messages_to_gemini(messages)
        for i, c in enumerate(contents):
            self.assertTrue(c["parts"], f"contents[{i}] has zero parts (rejected by Gemini): {c}")
            for j, part in enumerate(c["parts"]):
                self._assert_valid_gemini_part(part, f"contents[{i}].parts[{j}]")


class TestGeminiRespToOai(unittest.TestCase):
    def test_plain_text_stop_maps_to_stop(self):
        resp = {"candidates": [{"finishReason": "STOP",
                                "content": {"parts": [{"text": "hello"}]}}]}
        oai = harvest._gemini_resp_to_oai(resp)
        msg = oai["choices"][0]["message"]
        self.assertEqual(msg["content"], "hello")
        self.assertIsNone(msg["tool_calls"])
        self.assertEqual(oai["choices"][0]["finish_reason"], "stop")

    def test_single_function_call_maps_to_tool_calls_ignoring_raw_finish(self):
        resp = {"candidates": [{"finishReason": "STOP",
                                "content": {"parts": [{"functionCall": {"name": "search", "args": {"q": "x"}}}]}}]}
        oai = harvest._gemini_resp_to_oai(resp)
        msg = oai["choices"][0]["message"]
        self.assertEqual(len(msg["tool_calls"]), 1)
        self.assertEqual(msg["tool_calls"][0]["function"]["name"], "search")
        self.assertEqual(json.loads(msg["tool_calls"][0]["function"]["arguments"]), {"q": "x"})
        self.assertEqual(oai["choices"][0]["finish_reason"], "tool_calls")

    def test_parallel_function_calls_all_present_with_unique_ids(self):
        resp = {"candidates": [{"content": {"parts": [
            {"functionCall": {"name": "search", "args": {"q": "1"}}},
            {"functionCall": {"name": "fetch", "args": {"url": "u"}}},
        ]}}]}
        oai = harvest._gemini_resp_to_oai(resp)
        tool_calls = oai["choices"][0]["message"]["tool_calls"]
        self.assertEqual(len(tool_calls), 2)
        ids = [tc["id"] for tc in tool_calls]
        self.assertEqual(len(set(ids)), 2)

    def test_function_call_with_thought_signature_captured(self):
        resp = {"candidates": [{"content": {"parts": [
            {"functionCall": {"name": "search", "args": {"q": "x"}}, "thoughtSignature": "sig-abc"},
        ]}}]}
        oai = harvest._gemini_resp_to_oai(resp)
        tool_calls = oai["choices"][0]["message"]["tool_calls"]
        self.assertEqual(tool_calls[0]["thought_signature"], "sig-abc")

    def test_function_call_without_thought_signature_key_absent_not_none(self):
        resp = {"candidates": [{"content": {"parts": [
            {"functionCall": {"name": "search", "args": {"q": "x"}}},
        ]}}]}
        oai = harvest._gemini_resp_to_oai(resp)
        tool_calls = oai["choices"][0]["message"]["tool_calls"]
        self.assertNotIn("thought_signature", tool_calls[0])

    def test_parallel_function_calls_only_first_has_signature(self):
        resp = {"candidates": [{"content": {"parts": [
            {"functionCall": {"name": "search", "args": {"q": "1"}}, "thoughtSignature": "sig-1"},
            {"functionCall": {"name": "fetch", "args": {"url": "u"}}},
        ]}}]}
        oai = harvest._gemini_resp_to_oai(resp)
        tool_calls = oai["choices"][0]["message"]["tool_calls"]
        self.assertEqual(tool_calls[0]["thought_signature"], "sig-1")
        self.assertNotIn("thought_signature", tool_calls[1])

    def test_signature_on_detached_thought_part_bound_to_function_call(self):
        # Robustness: a thinking-state signature delivered on its own part
        # (no functionCall in that part) must still be bound to the
        # functionCall's tool_call, not dropped. Guards the streaming layouts
        # the official docs warn about, exercised here through the shared
        # collector via the blocking parser.
        resp = {"candidates": [{"content": {"parts": [
            {"functionCall": {"name": "search", "args": {"q": "x"}}},
            {"text": "", "thoughtSignature": "sig-detached"},
        ]}}]}
        oai = harvest._gemini_resp_to_oai(resp)
        tool_calls = oai["choices"][0]["message"]["tool_calls"]
        self.assertEqual(len(tool_calls), 1)
        self.assertEqual(tool_calls[0]["thought_signature"], "sig-detached")

    def test_signature_on_standalone_part_no_text_no_fc_bound(self):
        # A part carrying ONLY thoughtSignature (neither text nor
        # functionCall) is not silently dropped -- its signature binds to the
        # functionCall's tool_call.
        resp = {"candidates": [{"content": {"parts": [
            {"functionCall": {"name": "search", "args": {"q": "x"}}},
            {"thoughtSignature": "sig-standalone"},
        ]}}]}
        oai = harvest._gemini_resp_to_oai(resp)
        tool_calls = oai["choices"][0]["message"]["tool_calls"]
        self.assertEqual(tool_calls[0]["thought_signature"], "sig-standalone")

    def test_detached_signature_before_function_call_still_bound(self):
        # Arrival order independence: a detached signature part that appears
        # BEFORE its functionCall part is still attached (floating sigs are
        # placed after the whole part walk completes).
        resp = {"candidates": [{"content": {"parts": [
            {"thoughtSignature": "sig-early"},
            {"functionCall": {"name": "search", "args": {"q": "x"}}},
        ]}}]}
        oai = harvest._gemini_resp_to_oai(resp)
        tool_calls = oai["choices"][0]["message"]["tool_calls"]
        self.assertEqual(tool_calls[0]["thought_signature"], "sig-early")

    def test_floating_signature_not_assigned_to_parallel_slot_when_first_signed(self):
        # Gemini 3 contract: within a step only the FIRST functionCall carries
        # a signature; parallel calls at slots 1..N legitimately have none and
        # the server rejects a replay that puts a signature there. So when
        # slot 0 already holds its own sibling signature, a stray detached
        # signature must be DROPPED, never spilled onto the second call --
        # doing so would fabricate a signature in the position the contract
        # forbids.
        resp = {"candidates": [{"content": {"parts": [
            {"functionCall": {"name": "search", "args": {"q": "1"}}, "thoughtSignature": "sig-own"},
            {"functionCall": {"name": "fetch", "args": {"url": "u"}}},
            {"thoughtSignature": "sig-floating"},
        ]}}]}
        oai = harvest._gemini_resp_to_oai(resp)
        tool_calls = oai["choices"][0]["message"]["tool_calls"]
        self.assertEqual(tool_calls[0]["thought_signature"], "sig-own")
        self.assertNotIn("thought_signature", tool_calls[1])

    def test_floating_signature_binds_only_to_first_call_not_second(self):
        # Detached signature + two parallel calls, neither with a sibling
        # signature: the floating signature binds to slot 0 ONLY; slot 1 stays
        # unsigned per contract.
        resp = {"candidates": [{"content": {"parts": [
            {"functionCall": {"name": "search", "args": {"q": "1"}}},
            {"functionCall": {"name": "fetch", "args": {"url": "u"}}},
            {"thoughtSignature": "sig-floating"},
        ]}}]}
        oai = harvest._gemini_resp_to_oai(resp)
        tool_calls = oai["choices"][0]["message"]["tool_calls"]
        self.assertEqual(tool_calls[0]["thought_signature"], "sig-floating")
        self.assertNotIn("thought_signature", tool_calls[1])

    def test_pure_text_turn_floating_signature_not_surfaced(self):
        # A pure-text response (no functionCall) whose signature rides a
        # trailing empty-text part has no tool_call to receive it; the message
        # is plain text with no tool_calls, and nothing crashes.
        resp = {"candidates": [{"finishReason": "STOP", "content": {"parts": [
            {"text": "the answer"},
            {"text": "", "thoughtSignature": "sig-orphan"},
        ]}}]}
        oai = harvest._gemini_resp_to_oai(resp)
        msg = oai["choices"][0]["message"]
        self.assertEqual(msg["content"], "the answer")
        self.assertIsNone(msg["tool_calls"])

    def test_max_tokens_maps_to_length(self):
        resp = {"candidates": [{"finishReason": "MAX_TOKENS",
                                "content": {"parts": [{"text": "cut off"}]}}]}
        oai = harvest._gemini_resp_to_oai(resp)
        self.assertEqual(oai["choices"][0]["finish_reason"], "length")

    def test_unknown_finish_reason_lowercased_not_forged_to_stop(self):
        resp = {"candidates": [{"finishReason": "RECITATION",
                                "content": {"parts": [{"text": "x"}]}}]}
        oai = harvest._gemini_resp_to_oai(resp)
        self.assertEqual(oai["choices"][0]["finish_reason"], "recitation")

    def test_candidate_level_safety_block_no_crash_empty_content(self):
        resp = {"candidates": [{"finishReason": "SAFETY"}]}  # no "content" key
        oai = harvest._gemini_resp_to_oai(resp)
        msg = oai["choices"][0]["message"]
        self.assertEqual(msg["content"], "")
        self.assertIsNone(msg["tool_calls"])

    def test_prompt_level_block_missing_candidates_key_no_crash(self):
        resp = {"promptFeedback": {"blockReason": "SAFETY"}}
        oai = harvest._gemini_resp_to_oai(resp)
        msg = oai["choices"][0]["message"]
        self.assertEqual(msg["content"], "")
        self.assertIsNone(msg["tool_calls"])
        self.assertEqual(oai["choices"][0]["finish_reason"], "prompt_blocked")
        self.assertEqual(oai["usage"]["prompt_block_reason"], "SAFETY")

    def test_prompt_level_block_empty_candidates_list_no_crash(self):
        resp = {"candidates": [], "promptFeedback": {"blockReason": "OTHER"}}
        oai = harvest._gemini_resp_to_oai(resp)
        self.assertEqual(oai["choices"][0]["finish_reason"], "prompt_blocked")
        self.assertEqual(oai["usage"]["prompt_block_reason"], "OTHER")

    def test_tool_call_ids_unique_across_two_calls(self):
        resp = {"candidates": [{"content": {"parts": [
            {"functionCall": {"name": "search", "args": {}}}]}}]}
        oai1 = harvest._gemini_resp_to_oai(resp)
        oai2 = harvest._gemini_resp_to_oai(resp)
        id1 = oai1["choices"][0]["message"]["tool_calls"][0]["id"]
        id2 = oai2["choices"][0]["message"]["tool_calls"][0]["id"]
        self.assertNotEqual(id1, id2)

    def test_outbound_extract_message_compatible(self):
        resp = {"candidates": [{"finishReason": "STOP",
                                "content": {"parts": [{"text": "j"}]}}]}
        oai = harvest._gemini_resp_to_oai(resp)
        self.assertEqual(harvest._extract_message(oai), oai["choices"][0]["message"])


class TestGeminiNativeGatewayClient(unittest.TestCase):
    def test_complete_posts_to_generate_content_endpoint(self):
        client = harvest.GeminiNativeGatewayClient("https://gw.example.com/v1", "key", "gemini-3.5-flash", 5, 16384)
        ok_response = {"candidates": [{"finishReason": "STOP", "content": {"parts": [{"text": "hi"}]}}]}
        with mock.patch("harvest_clients.base._http_json_post_with_retry", return_value=ok_response) as m:
            result = client.complete(messages=[{"role": "user", "content": "x"}], tools=None)
        self.assertEqual(result["choices"][0]["message"]["content"], "hi")
        url = m.call_args[0][0]
        self.assertTrue(url.endswith("/v1beta/models/gemini-3.5-flash:generateContent"))

    def test_complete_sets_max_output_tokens_in_generation_config(self):
        client = harvest.GeminiNativeGatewayClient("https://gw.example.com/v1", "key", "gemini-3.5-flash", 5, 9999)
        ok_response = {"candidates": [{"finishReason": "STOP", "content": {"parts": [{"text": "hi"}]}}]}
        with mock.patch("harvest_clients.base._http_json_post_with_retry", return_value=ok_response) as m:
            client.complete(messages=[{"role": "user", "content": "x"}], tools=None)
        payload = m.call_args[0][1]
        self.assertEqual(payload["generationConfig"]["maxOutputTokens"], 9999)

    def test_complete_omits_tools_field_when_none(self):
        client = harvest.GeminiNativeGatewayClient("https://gw.example.com/v1", "key", "gemini-3.5-flash", 5, 16384)
        ok_response = {"candidates": [{"finishReason": "STOP", "content": {"parts": [{"text": "j"}]}}]}
        with mock.patch("harvest_clients.base._http_json_post_with_retry", return_value=ok_response) as m:
            client.complete(messages=[{"role": "system", "content": "sys"},
                                       {"role": "user", "content": "judge input"}], tools=None)
        payload = m.call_args[0][1]
        self.assertNotIn("tools", payload)
        self.assertEqual(payload["systemInstruction"], {"parts": [{"text": "sys"}]})

    def test_complete_includes_tools_when_present(self):
        client = harvest.GeminiNativeGatewayClient("https://gw.example.com/v1", "key", "gemini-3.5-flash", 5, 16384)
        ok_response = {"candidates": [{"finishReason": "STOP", "content": {"parts": [{"text": "j"}]}}]}
        with mock.patch("harvest_clients.base._http_json_post_with_retry", return_value=ok_response) as m:
            client.complete(messages=[{"role": "user", "content": "x"}], tools=harvest.TOOL_SCHEMAS)
        payload = m.call_args[0][1]
        self.assertEqual(len(payload["tools"][0]["functionDeclarations"]), len(harvest.TOOL_SCHEMAS))

    def test_complete_parses_function_call_response(self):
        client = harvest.GeminiNativeGatewayClient("https://gw.example.com/v1", "key", "gemini-3.5-flash", 5, 16384)
        ok_response = {"candidates": [{"content": {"parts": [
            {"functionCall": {"name": "search", "args": {"query": "x"}}}]}}]}
        with mock.patch("harvest_clients.base._http_json_post_with_retry", return_value=ok_response):
            result = client.complete(messages=[{"role": "user", "content": "x"}], tools=harvest.TOOL_SCHEMAS)
        message = result["choices"][0]["message"]
        self.assertEqual(message["tool_calls"][0]["function"]["name"], "search")
        self.assertEqual(result["choices"][0]["finish_reason"], "tool_calls")


class TestMakeClientFactoryGeminiDispatch(unittest.TestCase):
    """Extends TestMakeClientFactoryThreeWayDispatch's dispatch coverage to
    the fourth (Gemini-native) client type, without touching the existing
    three-way test class -- claude/gpt dispatch behavior must not regress."""

    def setUp(self):
        self.env_patcher = mock.patch.dict(os.environ, {"TEST_GATEWAY_KEY": "secret"})
        self.env_patcher.start()
        self.addCleanup(self.env_patcher.stop)

    def test_gemini_native_default_dispatches_to_gemini_native_client(self):
        factory = harvest.make_client_factory(base_config())
        client = factory("gemini-3.5-flash")
        self.assertIsInstance(client, harvest.GeminiNativeGatewayClient)

    def test_gemini_endpoint_chat_completions_falls_back_to_plain_gateway_client(self):
        config = base_config()
        config["limits"] = dict(config["limits"], gemini_endpoint="chat_completions")
        factory = harvest.make_client_factory(config)
        client = factory("gemini-3.5-flash")
        self.assertIsInstance(client, harvest.GatewayClient)
        self.assertNotIsInstance(client, harvest.GeminiNativeGatewayClient)

    def test_old_config_missing_gemini_endpoint_key_defaults_to_native(self):
        config = base_config()
        self.assertNotIn("gemini_endpoint", config["limits"])
        factory = harvest.make_client_factory(config)
        client = factory("gemini-3.5-flash")
        self.assertIsInstance(client, harvest.GeminiNativeGatewayClient)

    def test_claude_and_gpt_dispatch_unaffected_by_gemini_endpoint_change(self):
        config = base_config()
        config["limits"] = dict(config["limits"], gemini_endpoint="chat_completions")
        factory = harvest.make_client_factory(config)
        self.assertIsInstance(factory("claude-sonnet-5"), harvest.AnthropicGatewayClient)
        self.assertIsInstance(factory("gpt-5.4"), harvest.ResponsesGatewayClient)

    def test_gemini_native_max_output_tokens_mirrors_completion_max_tokens(self):
        config = base_config()
        config["limits"] = dict(config["limits"], completion_max_tokens=12345)
        factory = harvest.make_client_factory(config)
        client = factory("gemini-3.5-flash")
        self.assertEqual(client.max_output_tokens, 12345)

    def test_judge_fallback_mixes_gemini_native_client_with_tools_none(self):
        config = base_config(judge_model="gemini-3.5-flash", panel_models=["gemini-3.5-flash", "model-b"])
        factory = harvest.make_client_factory(config)
        judge_text = '```json\n{"clusters": [{"summary": "s", "source_claim_ids": ["m1-1"], "relation": "agree"}]}\n```'
        ok_response = {"candidates": [{"finishReason": "STOP", "content": {"parts": [{"text": judge_text}]}}]}
        worker_findings = {"m1": {"claims": [{"_id": "m1-1", "claim": "A", "excerpt": "e", "url": "u"}]}}
        with mock.patch("harvest_clients.base._http_json_post_with_retry", return_value=ok_response):
            data, err = harvest.run_judge_with_fallback(config, factory, worker_findings, config["panel_models"])
        self.assertIsNone(err)
        self.assertEqual(data["clusters"][0]["source_claim_ids"], ["m1-1"])


# ---------------------------------------------------------------------------
# #64: completion-call retry schedule + forced-synthesis recovery on
# exhausted retries
# ---------------------------------------------------------------------------

def _raise_network_error(messages, tools):
    raise RuntimeError("network error after 5 attempts: Connection reset")


class TestCompletionRetryAndForcedSynthesisRecovery(unittest.TestCase):
    def setUp(self):
        self.config = base_config()
        self.fetch_backends = [({"type": "urllib-ua"}, harvest.RateLimiter(0))]
        patcher = mock.patch("harvest._ssrf_precheck")
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_retry_with_completion_backoffs_recovers_after_two_transient_failures(self):
        ok_response = {"choices": [{"message": {"role": "assistant", "content": "hi"}}]}
        with mock.patch("harvest_clients.base._http_json_post",
                         side_effect=[harvest.urllib.error.URLError("connection reset"),
                                      harvest.urllib.error.URLError("connection reset"),
                                      ok_response]) as m, \
             mock.patch("harvest_clients.base.time.sleep") as sleep_mock:
            result = harvest._http_json_post_with_retry(
                "http://gw/chat/completions", {}, {}, 5,
                transient_backoffs=harvest._COMPLETION_RETRY_BACKOFFS)
        self.assertEqual(result, ok_response)
        self.assertEqual(m.call_count, 3)
        sleep_mock.assert_has_calls([mock.call(2), mock.call(5)])

    def test_transient_failure_mid_loop_recovers_via_forced_synthesis(self):
        # First round does real search/fetch work and lands in the journal;
        # the second round's completion call exhausts its retry budget and
        # raises -- run_worker's existing `except Exception: break` drops out
        # of the main loop (not straight to FAILED) and the forced-synthesis
        # call that follows successfully turns the round-1 evidence into OK
        # findings.
        fact = "Rayleigh scattering explains the blue sky."
        client = ScriptedClient([
            assistant_tool_call("c1", "fetch", {"url": "https://a.com/x"}),
            _raise_network_error,
            assistant_final(findings_block([
                {"claim": "c", "excerpt": fact, "url": "https://a.com/x",
                 "credibility": 4, "language": "en"}])),
        ])
        with mock.patch("harvest.call_fetch_backend", return_value=fact):
            result = harvest.run_worker("m1", "model-a", client, self.config, [],
                                         self.fetch_backends, "goal", [], None)
        self.assertEqual(result.status, "OK")
        self.assertEqual(len(result.findings["claims"]), 1)
        self.assertTrue(any(e.get("tool") == "fetch" and e.get("url") == "https://a.com/x"
                             for e in result.journal))

    def test_persistent_failure_gives_synthesis_failed_reason(self):
        class AlwaysFails:
            def complete(self, messages, tools):
                raise RuntimeError("network error after 5 attempts: Connection reset")

        result = harvest.run_worker("m1", "model-a", AlwaysFails(), self.config, [],
                                     self.fetch_backends, "goal", [], None)
        self.assertEqual(result.status, "FAILED")
        self.assertTrue(result.reason.startswith("synthesis_failed (RuntimeError):"),
                         result.reason)


# ---------------------------------------------------------------------------
# #63/#68: gemini-grounding search results are injected into the journal as
# "search_grounding" entries (URL the model *saw*, not full text it fetched)
# -- a claim citing one of these URLs without an explicit fetch() call must
# fail citation validation (url_not_fetched), not silently pass. This closed
# a hole where the old "fetch"-typed injection let citations through on
# nothing more than a domain-name string.
# ---------------------------------------------------------------------------

class TestGeminiGroundingJournalInjection(unittest.TestCase):
    def _grounding_results(self):
        return [
            {"url": "https://example.com/page1", "title": "Page One", "snippet": "Page One"},
            {"url": "https://example.com/page2", "title": "", "snippet": ""},
        ]

    def test_search_injects_search_grounding_entries_not_fetch(self):
        journal = []
        cfg = base_config()
        backends = [({"type": "gemini-grounding", "model": "g"}, harvest.RateLimiter(0))]
        with mock.patch("harvest.call_search_backend", return_value=self._grounding_results()):
            harvest.do_search("q", "en", backends, journal, cfg)

        # No "fetch"-typed entries at all from grounding -- they must be
        # "search_grounding", distinct from a real fetch.
        self.assertEqual([e for e in journal if e.get("tool") == "fetch"], [])
        grounding_entries = [e for e in journal if e.get("tool") == "search_grounding"]
        self.assertEqual(len(grounding_entries), 2)
        self.assertTrue(all(e["backend"] == "grounding" for e in grounding_entries))
        self.assertTrue(all(e["content"] is None for e in grounding_entries))
        by_url = {e["url"]: e["title"] for e in grounding_entries}
        self.assertEqual(by_url["https://example.com/page1"], "Page One")
        self.assertEqual(by_url["https://example.com/page2"], "https://example.com/page2")

    def test_grounding_only_citation_fails_url_not_fetched(self):
        # This is the bug-fix assertion: citing a grounding URL that was
        # never actually fetch()'d must be rejected as url_not_fetched (the
        # model saw it in search, but never retrieved real content) -- not
        # silently pass, and not the more severe url_not_in_journal (which
        # would wrongly imply the model never even saw the URL).
        journal = []
        cfg = base_config()
        backends = [({"type": "gemini-grounding", "model": "g"}, harvest.RateLimiter(0))]
        with mock.patch("harvest.call_search_backend", return_value=self._grounding_results()):
            harvest.do_search("q", "en", backends, journal, cfg)

        claims = harvest.assign_claim_ids("m1", [
            {"claim": "c1", "excerpt": "Page One", "url": "https://example.com/page1"},
            {"claim": "c2", "excerpt": "https://example.com/page2", "url": "https://example.com/page2"},
        ])
        idx = harvest.build_fetch_index(journal)
        urls = harvest.build_journal_url_set(journal)
        valid, invalid = harvest.validate_claims(claims, idx, urls)
        self.assertEqual(valid, [])
        self.assertEqual(len(invalid), 2)
        self.assertTrue(all(reason == "url_not_fetched" for _c, reason, _matched in invalid))

    def test_grounding_citation_passes_after_explicit_fetch(self):
        # If the model actually calls fetch() on a grounding-surfaced URL,
        # the real fetch entry (not the search_grounding one) satisfies
        # citation validation normally.
        journal = []
        cfg = base_config()
        backends = [({"type": "gemini-grounding", "model": "g"}, harvest.RateLimiter(0))]
        with mock.patch("harvest.call_search_backend", return_value=self._grounding_results()):
            harvest.do_search("q", "en", backends, journal, cfg)
        journal.append({"tool": "fetch", "url": "https://example.com/page1",
                         "backend": "urllib-ua", "content": "Full real page text."})

        claims = harvest.assign_claim_ids("m1", [
            {"claim": "c1", "excerpt": "Full real page text.", "url": "https://example.com/page1"},
        ])
        idx = harvest.build_fetch_index(journal)
        urls = harvest.build_journal_url_set(journal)
        valid, invalid = harvest.validate_claims(claims, idx, urls)
        self.assertEqual(len(valid), 1)
        self.assertEqual(invalid, [])


# ---------------------------------------------------------------------------
# #68: two-layer convergence architecture -- progressive budget nudges in the
# main loop, and a parse-first dual-branch retry in forced synthesis so a
# model that keeps returning tool_calls (or malformed JSON) after the step
# budget is exhausted gets one real chance to converge instead of an
# immediate, generic step_limit_no_synthesis failure.
# ---------------------------------------------------------------------------

class TestBudgetNudgeAndForcedSynthesisConvergence(unittest.TestCase):
    def setUp(self):
        self.config = base_config()
        self.config["limits"]["max_steps_per_model"] = 6
        self.fetch_backends = [({"type": "urllib-ua"}, harvest.RateLimiter(0))]
        patcher = mock.patch("harvest._ssrf_precheck")
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_nudge_injected_at_correct_steps(self):
        # max_steps=6: tool_calls on every round (steps 0..5), so the loop
        # never reaches a normal finalize and always exhausts the budget.
        # remaining = max_steps - (step+1); nudges fire at remaining==3
        # (after step index 2, i.e. the 3rd tool_calls round) and
        # remaining==1 (after step index 4, the 5th round).
        fact = "Rayleigh scattering explains the blue sky."
        client = ScriptedClient([
            assistant_tool_call("c1", "fetch", {"url": "https://a.com/1"}),
            assistant_tool_call("c2", "fetch", {"url": "https://a.com/2"}),
            assistant_tool_call("c3", "fetch", {"url": "https://a.com/3"}),
            assistant_tool_call("c4", "fetch", {"url": "https://a.com/4"}),
            assistant_tool_call("c5", "fetch", {"url": "https://a.com/5"}),
            assistant_tool_call("c6", "fetch", {"url": "https://a.com/6"}),
            assistant_final(findings_block([
                {"claim": "c", "excerpt": fact, "url": "https://a.com/6", "credibility": 4, "language": "en"}])),
        ])
        with mock.patch("harvest.call_fetch_backend", return_value=fact):
            harvest.run_worker("m1", "model-a", client, self.config, [],
                                self.fetch_backends, "goal", [], None)

        def has_budget_text(call_index, needle):
            msgs = client.messages_log[call_index]
            return any(m.get("role") == "user" and needle in (m.get("content") or "")
                       for m in msgs)

        # Call index 3 is the request sent right after round index 2's
        # tool_calls were processed (remaining == 3); call index 5 is right
        # after round index 4 (remaining == 1).
        self.assertTrue(has_budget_text(3, "[BUDGET] 3 rounds remaining"))
        self.assertTrue(has_budget_text(5, "[BUDGET] Last chance"))
        # No nudge text leaks into the very first call (nothing to nudge yet).
        self.assertFalse(has_budget_text(0, "[BUDGET]"))

    def test_forced_synthesis_extracts_content_ignoring_tool_calls(self):
        # Forced-synthesis response carries BOTH tool_calls and valid JSON
        # text content (e.g. a Claude-shaped response with a stray tool_use
        # block alongside real text) -- the worker must use the text content
        # and succeed without dispatching the tool_calls.
        cfg = base_config()
        cfg["limits"]["max_steps_per_model"] = 2
        fact = "Rayleigh scattering explains the blue sky."
        findings_text = findings_block([
            {"claim": "c", "excerpt": fact, "url": "https://a.com/2", "credibility": 4, "language": "en"}])

        def synthesis_with_stray_tool_call(messages, tools):
            return {"choices": [{"message": {
                "role": "assistant", "content": findings_text,
                "tool_calls": [{"id": "stray", "function": {"name": "search", "arguments": "{}"}}],
            }}]}

        client = ScriptedClient([
            assistant_tool_call("c1", "fetch", {"url": "https://a.com/1"}),
            assistant_tool_call("c2", "fetch", {"url": "https://a.com/2"}),
            synthesis_with_stray_tool_call,
        ])
        with mock.patch("harvest.call_fetch_backend", return_value=fact):
            result = harvest.run_worker("m1", "model-a", client, cfg, [], self.fetch_backends, "goal", [], None)
        self.assertEqual(client.calls, 3)
        self.assertEqual(result.status, "OK")
        self.assertEqual(len(result.findings["claims"]), 1)

    def test_forced_synthesis_retries_on_pure_tool_calls(self):
        # Forced-synthesis response is pure tool_calls (content=None) --
        # the worker must retry once with a forward-looking reminder and
        # succeed if the retry produces valid JSON.
        cfg = base_config()
        cfg["limits"]["max_steps_per_model"] = 2
        fact = "Rayleigh scattering explains the blue sky."
        client = ScriptedClient([
            assistant_tool_call("c1", "fetch", {"url": "https://a.com/1"}),
            assistant_tool_call("c2", "fetch", {"url": "https://a.com/2"}),
            assistant_tool_call("c3", "search", {"query": "more"}),  # pure tool_calls, no text
            assistant_final(findings_block([
                {"claim": "c", "excerpt": fact, "url": "https://a.com/2", "credibility": 4, "language": "en"}])),
        ])
        with mock.patch("harvest.call_fetch_backend", return_value=fact):
            result = harvest.run_worker("m1", "model-a", client, cfg, [], self.fetch_backends, "goal", [], None)
        self.assertEqual(client.calls, cfg["limits"]["max_steps_per_model"] + 2)
        self.assertEqual(result.status, "OK")
        self.assertEqual(len(result.findings["claims"]), 1)
        # Retry prompt must be forward-looking, not reference the dropped response.
        retry_call_messages = client.messages_log[-1]
        self.assertTrue(any(
            m.get("role") == "user" and "Do not use tools" in (m.get("content") or "")
            for m in retry_call_messages))

    def test_forced_synthesis_parse_failure_returns_descriptive_error(self):
        # Forced-synthesis response is text but not valid JSON, with no
        # tool_calls at all -- retry once, still not valid JSON -> FAILED
        # with a specific, non-generic reason.
        cfg = base_config()
        cfg["limits"]["max_steps_per_model"] = 2
        client = ScriptedClient([
            assistant_tool_call("c1", "fetch", {"url": "https://a.com/1"}),
            assistant_tool_call("c2", "fetch", {"url": "https://a.com/2"}),
            assistant_final("this is not json at all"),
            assistant_final("still not json"),
        ])
        with mock.patch("harvest.call_fetch_backend", return_value="text"):
            result = harvest.run_worker("m1", "model-a", client, cfg, [], self.fetch_backends, "goal", [], None)
        self.assertEqual(client.calls, 4)
        self.assertEqual(result.status, "FAILED")
        self.assertTrue(result.reason.startswith("synthesis_parse_failed:"), result.reason)


class argparse_ns:
    def __init__(self, **kwargs):
        self.__dict__.update(kwargs)


# ---------------------------------------------------------------------------
# --no-api local mode: dispatch gating in cmd_run
# ---------------------------------------------------------------------------

class TestCmdRunLocalModeDispatch(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.project_dir = Path(self.tmpdir.name)
        self.pipeline_dir = self.project_dir / "pipeline"
        self.raw_dir = self.pipeline_dir / "1_raw"
        self.raw_dir.mkdir(parents=True)
        self.goal_file = self.project_dir / harvest.GOAL_FILE_NAME
        self.goal_file.write_text("why is the sky blue?", encoding="utf-8")

    def tearDown(self):
        self.tmpdir.cleanup()

    def test_no_api_without_queries_json_exits_1(self):
        config = base_config()
        args = argparse_ns(goal_file=str(self.goal_file), out=str(self.raw_dir), config="unused",
                            local_dir=None, no_api=True, queries_json=None)
        with mock.patch("harvest.load_config", return_value=config):
            with self.assertRaises(SystemExit) as ctx:
                harvest.cmd_run(args)
        self.assertEqual(ctx.exception.code, 1)

    def test_missing_gateway_key_without_no_api_exits_3(self):
        # TEST_GATEWAY_KEY deliberately absent from the environment here --
        # normal mode with no key and no --no-api must fail fast with a
        # message pointing at the local-mode escape hatch, before any
        # cleanup/tombstone/network activity.
        config = base_config()
        args = argparse_ns(goal_file=str(self.goal_file), out=str(self.raw_dir), config="unused",
                            local_dir=None, no_api=False, queries_json=None)
        with mock.patch.dict(os.environ, {}, clear=False), \
             mock.patch("harvest.load_config", return_value=config):
            os.environ.pop("TEST_GATEWAY_KEY", None)
            with self.assertRaises(SystemExit) as ctx:
                harvest.cmd_run(args)
        self.assertEqual(ctx.exception.code, 3)
        verify_file = self.pipeline_dir / "verification" / harvest.VERIFY_FILE
        self.assertFalse(verify_file.exists())

    def test_no_api_dispatches_to_local_mode_not_normal_mode(self):
        # With --no-api set, cmd_run must never touch make_client_factory /
        # run_panel (the normal-mode LLM path) even when a gateway key is
        # present -- local mode is a hard fork, not a fallback.
        config = base_config()
        queries_file = self.project_dir / "queries.json"
        queries_file.write_text(json.dumps({"queries": ["why is the sky blue"]}), encoding="utf-8")
        args = argparse_ns(goal_file=str(self.goal_file), out=str(self.raw_dir), config="unused",
                            local_dir=None, no_api=True, queries_json=str(queries_file))
        with mock.patch.dict(os.environ, {"TEST_GATEWAY_KEY": "fake-key"}), \
             mock.patch("harvest.load_config", return_value=config), \
             mock.patch("harvest.make_client_factory", side_effect=AssertionError("must not call normal-mode factory")), \
             mock.patch("harvest.do_search", return_value=json.dumps({"results": [{"url": "https://a.com/1", "title": "t"}]})), \
             mock.patch("harvest.do_fetch") as mock_do_fetch:
            def fake_fetch(url, fetch_backends, journal, config):
                journal.append({"tool": "fetch", "url": url, "backend": "urllib-ua", "content": "fetched body"})
                return "fetched body"
            mock_do_fetch.side_effect = fake_fetch
            harvest.cmd_run(args)

        verify_file = self.pipeline_dir / "verification" / harvest.VERIFY_FILE
        self.assertTrue(verify_file.exists())
        data = json.loads(verify_file.read_text(encoding="utf-8"))
        self.assertEqual(data["verdict"], "LOCAL")


# ---------------------------------------------------------------------------
# cmd_run_local: search + fetch only, no LLM, writes manifest/report/verify
# ---------------------------------------------------------------------------

class TestCmdRunLocalEndToEnd(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.project_dir = Path(self.tmpdir.name)
        self.pipeline_dir = self.project_dir / "pipeline"
        self.raw_dir = self.pipeline_dir / "1_raw"
        self.raw_dir.mkdir(parents=True)
        self.goal_file = self.project_dir / harvest.GOAL_FILE_NAME
        self.goal_file.write_text("why is the sky blue?", encoding="utf-8")
        self.config = base_config()

    def tearDown(self):
        self.tmpdir.cleanup()

    def _args(self, queries_json_path):
        return argparse_ns(goal_file=str(self.goal_file), out=str(self.raw_dir), config="unused",
                            local_dir=None, no_api=True, queries_json=str(queries_json_path))

    def test_happy_path_writes_manifest_report_and_local_verdict(self):
        queries_file = self.project_dir / "queries.json"
        queries_file.write_text(json.dumps({"queries": ["q1", "q2"]}), encoding="utf-8")

        search_results = json.dumps({"results": [
            {"url": "https://example.com/a", "title": "A"},
            {"url": "https://example.com/b", "title": "B"},
        ]})

        def fake_fetch(url, fetch_backends, journal, config):
            content = f"content for {url}"
            journal.append({"tool": "fetch", "url": url, "backend": "urllib-ua", "content": content})
            return content

        with mock.patch("harvest.do_search", return_value=search_results), \
             mock.patch("harvest.do_fetch", side_effect=fake_fetch):
            harvest.cmd_run_local(self._args(queries_file), self.config)

        verify_file = self.pipeline_dir / "verification" / harvest.VERIFY_FILE
        self.assertTrue(verify_file.exists())
        data = json.loads(verify_file.read_text(encoding="utf-8"))
        self.assertEqual(data["verdict"], "LOCAL")
        self.assertEqual(data["pages_fetched"], 2)
        self.assertEqual(data["queries_executed"], 2)

        manifest_file = self.raw_dir / "harvest-local.json"
        self.assertTrue(manifest_file.exists())
        manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
        self.assertEqual(manifest["mode"], "local")
        self.assertEqual(len(manifest["fetched_pages"]), 2)
        self.assertEqual(manifest["goal_hash"], data["goal_file_sha256"])

        for page in manifest["fetched_pages"]:
            page_path = self.raw_dir / page["content_path"]
            self.assertTrue(page_path.exists())

        self.assertTrue((self.raw_dir / "fetch-report.md").exists())
        self.assertTrue((self.raw_dir / harvest.MERGED_FINDINGS_FILE).exists())

        # check_project must treat a LOCAL verdict as N_A (delegated), not
        # PASS/FAIL -- gate is deferred to verify-local + caller judgment.
        verdict, reason = harvest.check_project(self.project_dir)
        self.assertEqual(verdict, "N_A")

    def test_no_search_results_aborts_unavailable(self):
        queries_file = self.project_dir / "queries.json"
        queries_file.write_text(json.dumps({"queries": ["q1"]}), encoding="utf-8")
        empty_results = json.dumps({"results": []})
        with mock.patch("harvest.do_search", return_value=empty_results):
            with self.assertRaises(SystemExit) as ctx:
                harvest.cmd_run_local(self._args(queries_file), self.config)
        self.assertEqual(ctx.exception.code, 3)
        verify_file = self.pipeline_dir / "verification" / harvest.VERIFY_FILE
        data = json.loads(verify_file.read_text(encoding="utf-8"))
        self.assertEqual(data["verdict"], "UNAVAILABLE")

    def test_all_fetches_fail_aborts_unavailable(self):
        queries_file = self.project_dir / "queries.json"
        queries_file.write_text(json.dumps({"queries": ["q1"]}), encoding="utf-8")
        search_results = json.dumps({"results": [{"url": "https://example.com/a", "title": "A"}]})

        def fake_fetch_fail(url, fetch_backends, journal, config):
            journal.append({"tool": "fetch", "url": url, "backend": None, "content": None})
            return json.dumps({"error": "all fetch backends failed"})

        with mock.patch("harvest.do_search", return_value=search_results), \
             mock.patch("harvest.do_fetch", side_effect=fake_fetch_fail):
            with self.assertRaises(SystemExit) as ctx:
                harvest.cmd_run_local(self._args(queries_file), self.config)
        self.assertEqual(ctx.exception.code, 3)
        verify_file = self.pipeline_dir / "verification" / harvest.VERIFY_FILE
        data = json.loads(verify_file.read_text(encoding="utf-8"))
        self.assertEqual(data["verdict"], "UNAVAILABLE")

    def test_ranks_urls_by_search_result_frequency(self):
        # url "b" appears in both query results, "a" only once -- ranked
        # (and therefore fetch-ordered) output must put "b" first.
        queries_file = self.project_dir / "queries.json"
        queries_file.write_text(json.dumps({"queries": ["q1", "q2"]}), encoding="utf-8")

        def fake_search(query, lang, search_backends, journal, config):
            if query == "q1":
                return json.dumps({"results": [{"url": "https://x.com/a", "title": "A"},
                                                 {"url": "https://x.com/b", "title": "B"}]})
            return json.dumps({"results": [{"url": "https://x.com/b", "title": "B"}]})

        fetch_order = []

        def fake_fetch(url, fetch_backends, journal, config):
            fetch_order.append(url)
            journal.append({"tool": "fetch", "url": url, "backend": "urllib-ua", "content": "c"})
            return "c"

        with mock.patch("harvest.do_search", side_effect=fake_search), \
             mock.patch("harvest.do_fetch", side_effect=fake_fetch):
            harvest.cmd_run_local(self._args(queries_file), self.config)

        self.assertEqual(fetch_order[0], "https://x.com/b")

    def test_respects_max_fetch_urls_limit(self):
        queries_file = self.project_dir / "queries.json"
        queries_file.write_text(json.dumps({"queries": ["q1"]}), encoding="utf-8")
        many_results = json.dumps({"results": [
            {"url": f"https://x.com/{i}", "title": str(i)} for i in range(5)
        ]})
        cfg = base_config()
        cfg["limits"]["max_fetch_urls"] = 2

        fetched = []

        def fake_fetch(url, fetch_backends, journal, config):
            fetched.append(url)
            journal.append({"tool": "fetch", "url": url, "backend": "urllib-ua", "content": "c"})
            return "c"

        with mock.patch("harvest.do_search", return_value=many_results), \
             mock.patch("harvest.do_fetch", side_effect=fake_fetch):
            harvest.cmd_run_local(self._args(queries_file), cfg)

        self.assertEqual(len(fetched), 2)


# ---------------------------------------------------------------------------
# _read_queries_json helper
# ---------------------------------------------------------------------------

class TestReadQueriesJson(unittest.TestCase):
    def test_missing_file_exits_1(self):
        with self.assertRaises(SystemExit) as ctx:
            harvest._read_queries_json("/nonexistent-queries-file-xyz.json")
        self.assertEqual(ctx.exception.code, 1)

    def test_invalid_json_exits_1(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "q.json"
            p.write_text("not json", encoding="utf-8")
            with self.assertRaises(SystemExit) as ctx:
                harvest._read_queries_json(str(p))
        self.assertEqual(ctx.exception.code, 1)

    def test_missing_queries_key_exits_1(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "q.json"
            p.write_text(json.dumps({"not_queries": []}), encoding="utf-8")
            with self.assertRaises(SystemExit) as ctx:
                harvest._read_queries_json(str(p))
        self.assertEqual(ctx.exception.code, 1)

    def test_empty_queries_list_exits_1(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "q.json"
            p.write_text(json.dumps({"queries": []}), encoding="utf-8")
            with self.assertRaises(SystemExit) as ctx:
                harvest._read_queries_json(str(p))
        self.assertEqual(ctx.exception.code, 1)

    def test_valid_file_returns_queries_list(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "q.json"
            p.write_text(json.dumps({"queries": ["a", "b"]}), encoding="utf-8")
            self.assertEqual(harvest._read_queries_json(str(p)), ["a", "b"])

    def test_stdin_dash_reads_from_stdin(self):
        with mock.patch("sys.stdin", io.StringIO(json.dumps({"queries": ["a"]}))):
            self.assertEqual(harvest._read_queries_json("-"), ["a"])


# ---------------------------------------------------------------------------
# cmd_verify_local: deterministic citation check for caller-supplied claims
# ---------------------------------------------------------------------------

class TestCmdVerifyLocal(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmpdir.name)

    def tearDown(self):
        self.tmpdir.cleanup()

    def _write(self, name, data):
        p = self.dir / name
        p.write_text(json.dumps(data), encoding="utf-8")
        return p

    def test_all_claims_valid_yields_ok_and_exit_0(self):
        manifest_path = self._write("manifest.json", {
            "goal_hash": "abc123",
            "fetched_pages": [{"url": "https://example.com/a"}, {"url": "https://example.com/b"}],
        })
        claims_path = self._write("claims.json", [
            {"claim": "c1", "url": "https://example.com/a"},
            {"claim": "c2", "url": "https://example.com/b"},
        ])
        out_dir = self.dir / "out"
        args = argparse_ns(claims=str(claims_path), manifest=str(manifest_path), out=str(out_dir))
        with self.assertRaises(SystemExit) as ctx:
            harvest.cmd_verify_local(args)
        self.assertEqual(ctx.exception.code, 0)

        verify_file = out_dir / harvest.VERIFY_FILE
        data = json.loads(verify_file.read_text(encoding="utf-8"))
        self.assertEqual(data["verdict"], "OK")
        self.assertEqual(data["goal_file_sha256"], "abc123")
        self.assertEqual(data["total_claims"], 2)
        self.assertEqual(data["invalid_claim_count"], 0)

        rejected = json.loads((out_dir / "rejected_claims.json").read_text(encoding="utf-8"))
        self.assertEqual(rejected, [])

    def test_claim_citing_unfetched_url_is_rejected(self):
        manifest_path = self._write("manifest.json", {
            "fetched_pages": [{"url": "https://example.com/a"}],
        })
        claims_path = self._write("claims.json", [
            {"claim": "c1", "url": "https://example.com/a"},
            {"claim": "c2", "url": "https://example.com/never-fetched"},
        ])
        out_dir = self.dir / "out"
        args = argparse_ns(claims=str(claims_path), manifest=str(manifest_path), out=str(out_dir))
        with self.assertRaises(SystemExit) as ctx:
            harvest.cmd_verify_local(args)
        # 1/2 invalid == 50% > 5% threshold -> UNAVAILABLE, exit 1.
        self.assertEqual(ctx.exception.code, 1)

        data = json.loads((out_dir / harvest.VERIFY_FILE).read_text(encoding="utf-8"))
        self.assertEqual(data["verdict"], "UNAVAILABLE")

        rejected = json.loads((out_dir / "rejected_claims.json").read_text(encoding="utf-8"))
        self.assertEqual(len(rejected), 1)
        self.assertEqual(rejected[0]["reject_reason"], "url_not_in_fetched_pages")

    def test_url_normalization_matches_trailing_slash_variants(self):
        # normalize_url() strips trailing slashes -- a claim citing the
        # slash-terminated form of a fetched URL must still match.
        manifest_path = self._write("manifest.json", {
            "fetched_pages": [{"url": "https://example.com/a/"}],
        })
        claims_path = self._write("claims.json", [
            {"claim": "c1", "url": "https://example.com/a"},
        ])
        out_dir = self.dir / "out"
        args = argparse_ns(claims=str(claims_path), manifest=str(manifest_path), out=str(out_dir))
        with self.assertRaises(SystemExit) as ctx:
            harvest.cmd_verify_local(args)
        self.assertEqual(ctx.exception.code, 0)

    def test_zero_claims_yields_unavailable(self):
        manifest_path = self._write("manifest.json", {"fetched_pages": []})
        claims_path = self._write("claims.json", [])
        out_dir = self.dir / "out"
        args = argparse_ns(claims=str(claims_path), manifest=str(manifest_path), out=str(out_dir))
        with self.assertRaises(SystemExit) as ctx:
            harvest.cmd_verify_local(args)
        self.assertEqual(ctx.exception.code, 1)
        data = json.loads((out_dir / harvest.VERIFY_FILE).read_text(encoding="utf-8"))
        self.assertEqual(data["verdict"], "UNAVAILABLE")

    def test_malformed_claim_missing_url_field_exits_1(self):
        manifest_path = self._write("manifest.json", {"fetched_pages": []})
        claims_path = self._write("claims.json", [{"claim": "c1"}])
        out_dir = self.dir / "out"
        args = argparse_ns(claims=str(claims_path), manifest=str(manifest_path), out=str(out_dir))
        with self.assertRaises(SystemExit) as ctx:
            harvest.cmd_verify_local(args)
        self.assertEqual(ctx.exception.code, 1)
        self.assertFalse((out_dir / harvest.VERIFY_FILE).exists())

    def test_claims_file_not_a_list_exits_1(self):
        manifest_path = self._write("manifest.json", {"fetched_pages": []})
        claims_path = self._write("claims.json", {"claims": []})
        out_dir = self.dir / "out"
        args = argparse_ns(claims=str(claims_path), manifest=str(manifest_path), out=str(out_dir))
        with self.assertRaises(SystemExit) as ctx:
            harvest.cmd_verify_local(args)
        self.assertEqual(ctx.exception.code, 1)

    def test_missing_claims_file_exits_1(self):
        manifest_path = self._write("manifest.json", {"fetched_pages": []})
        out_dir = self.dir / "out"
        args = argparse_ns(claims="/nonexistent-claims.json", manifest=str(manifest_path), out=str(out_dir))
        with self.assertRaises(SystemExit) as ctx:
            harvest.cmd_verify_local(args)
        self.assertEqual(ctx.exception.code, 1)

    def test_missing_manifest_file_exits_1(self):
        claims_path = self._write("claims.json", [])
        out_dir = self.dir / "out"
        args = argparse_ns(claims=str(claims_path), manifest="/nonexistent-manifest.json", out=str(out_dir))
        with self.assertRaises(SystemExit) as ctx:
            harvest.cmd_verify_local(args)
        self.assertEqual(ctx.exception.code, 1)


# ---------------------------------------------------------------------------
# check_project: LOCAL verdict handling
# ---------------------------------------------------------------------------

class TestCheckProjectLocalVerdict(unittest.TestCase):
    def test_local_verdict_yields_n_a(self):
        with tempfile.TemporaryDirectory() as d:
            project_dir = Path(d)
            verify_dir = project_dir / "pipeline" / "verification"
            verify_dir.mkdir(parents=True)
            (verify_dir / harvest.VERIFY_FILE).write_text(
                json.dumps({"verdict": "LOCAL", "goal_file_sha256": "x"}), encoding="utf-8")
            verdict, reason = harvest.check_project(project_dir)
        self.assertEqual(verdict, "N_A")
        self.assertIn("local mode", reason)


# ---------------------------------------------------------------------------
# _emit: progress reporting (NDJSON to stderr)
# ---------------------------------------------------------------------------

class TestProgressEmit(unittest.TestCase):
    def test_emit_produces_valid_ndjson(self):
        with mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
            harvest._emit("test_event", foo="bar", num=42)
        line = stderr.getvalue().strip()
        data = json.loads(line)
        self.assertEqual(data["event"], "test_event")
        self.assertEqual(data["foo"], "bar")
        self.assertEqual(data["num"], 42)
        self.assertIn("t", data)

    def test_emit_never_raises_on_unserializable(self):
        class Unserializable:
            def __str__(self):
                raise RuntimeError("no repr for you")

        with mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
            harvest._emit("bad_event", obj=Unserializable())  # must not raise
        output = stderr.getvalue()
        if output.strip():
            json.loads(output.strip())  # if anything was written, it's valid JSON

    def test_emit_default_str_serializes_exception(self):
        with mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
            harvest._emit("err", detail=ValueError("boom"))
        data = json.loads(stderr.getvalue().strip())
        self.assertIn("boom", data["detail"])

    def test_emit_thread_safety(self):
        with mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
            def worker(n):
                for i in range(100):
                    harvest._emit("concurrent", worker=n, i=i)

            threads = [threading.Thread(target=worker, args=(n,)) for n in range(10)]
            for t in threads:
                t.start()
            for t in threads:
                t.join()
            lines = stderr.getvalue().splitlines()
        self.assertEqual(len(lines), 1000)
        for line in lines:
            json.loads(line)  # every line must be independently valid JSON

    def test_worker_step_emitted_during_run_worker(self):
        client = ScriptedClient([
            assistant_tool_call("c1", "search", {"query": "q"}),
            assistant_final(findings_block([
                {"claim": "c", "excerpt": "Rayleigh scattering explains the blue sky.",
                 "url": "https://a.com/x", "credibility": 4, "language": "en"}])),
        ])
        search_backends = [({"type": "gemini-cli", "model": "x"}, harvest.RateLimiter(0))]
        with mock.patch("harvest.call_search_backend",
                         return_value=[{"url": "https://a.com/x", "title": "t", "snippet": "s"}]), \
             mock.patch("harvest.call_fetch_backend",
                         return_value="Rayleigh scattering explains the blue sky."), \
             mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
            harvest.run_worker("m1", "model-a", client, base_config(), search_backends, [],
                                "goal", [], None)
        events = [json.loads(line) for line in stderr.getvalue().splitlines()]
        worker_steps = [e for e in events if e["event"] == "worker_step"]
        self.assertTrue(worker_steps)
        self.assertEqual(worker_steps[0]["alias"], "m1")


# ---------------------------------------------------------------------------
# SSE streaming (ADR-013): shared fakes + per-provider streaming coverage.
# The four completion clients call _http_stream_post at a single boundary, so
# provider-level tests mock that boundary directly with a fake generator that
# reproduces its contract (yield resp first, then (event_type, data_str)
# frames). Only TestStreamPost drops down to the urllib.request.urlopen layer,
# since it exercises _http_stream_post's own SSE parsing.
# ---------------------------------------------------------------------------

class _RecordingSocket:
    """Fake raw socket whose settimeout() calls are recorded, so a test can
    assert the inter-token watchdog tightening fired exactly once."""

    def __init__(self):
        self.timeouts = []

    def settimeout(self, t):
        self.timeouts.append(t)


class _StreamRespStub:
    """Stand-in for the HTTPResponse _http_stream_post yields first. Exposes a
    .sock so _get_raw_socket() finds it via its ('sock',) probe chain (None ->
    _get_raw_socket returns None and the client skips watchdog tightening)."""

    def __init__(self, sock=None):
        self.sock = sock


def _stream_of(frames, sock=None):
    """side_effect factory: each invocation returns a fresh generator matching
    _http_stream_post's contract -- the resp stub first, then one
    (event_type, data_str) tuple per scripted frame. A factory (not a bare
    generator) so a retrying client gets a new, un-exhausted stream per
    attempt."""
    def factory(*args, **kwargs):
        def gen():
            yield _StreamRespStub(sock)
            for frame in frames:
                yield frame
        return gen()
    return factory


def _stream_raising(exc):
    """side_effect factory whose generator raises `exc` on first next() --
    simulates a TTFT/connect failure surfacing when the client calls
    next(stream) to obtain the response object."""
    def factory(*args, **kwargs):
        def gen():
            raise exc
            yield  # unreachable; marks gen() a generator function
        return gen()
    return factory


class FakeSSEHTTPResponse:
    """urlopen()-compatible fake for exercising _http_stream_post directly:
    a .headers dict (Content-Type lookup), .read(n) for the non-stream body
    probe, and .readline() draining a scripted list of raw SSE line bytes
    (b'' signals EOF, as a real HTTPResponse does)."""

    def __init__(self, lines=(), content_type="text/event-stream", body=b""):
        self._lines = list(lines)
        self.headers = {"Content-Type": content_type}
        self._body = body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self, *args):
        return self._body

    def readline(self):
        return self._lines.pop(0) if self._lines else b""


class TestStreamPost(unittest.TestCase):
    """_http_stream_post's generic SSE wire parsing (provider-agnostic)."""

    def _run(self, fake):
        with mock.patch("harvest_clients.base.urllib.request.urlopen", return_value=fake):
            stream = harvest._http_stream_post("http://gw/stream", {}, {}, 5)
            resp = next(stream)
            frames = list(stream)
        return resp, frames

    def test_parses_event_and_data_frame(self):
        fake = FakeSSEHTTPResponse([b"event: message\n", b"data: hello\n", b"\n"])
        _, frames = self._run(fake)
        self.assertEqual(frames, [("message", "hello")])

    def test_multiline_data_joined_with_newline(self):
        # SSE spec: multiple data: lines in one frame are newline-joined.
        fake = FakeSSEHTTPResponse([b"data: line1\n", b"data: line2\n", b"\n"])
        _, frames = self._run(fake)
        self.assertEqual(frames, [(None, "line1\nline2")])

    def test_comment_line_yields_heartbeat_tuple(self):
        # A bare comment (leading ':') is a heartbeat -> (None, None), and does
        # not merge into the following frame.
        fake = FakeSSEHTTPResponse([b": keep-alive\n", b"data: x\n", b"\n"])
        _, frames = self._run(fake)
        self.assertEqual(frames, [(None, None), (None, "x")])

    def test_done_sentinel_passes_through_as_data(self):
        fake = FakeSSEHTTPResponse([b"data: [DONE]\n", b"\n"])
        _, frames = self._run(fake)
        self.assertEqual(frames, [(None, "[DONE]")])

    def test_single_leading_space_after_data_colon_stripped(self):
        # Exactly one space after 'data:' is stripped; a second is preserved.
        fake = FakeSSEHTTPResponse([b"data:  two-spaces\n", b"\n"])
        _, frames = self._run(fake)
        self.assertEqual(frames, [(None, " two-spaces")])

    def test_non_2xx_reraises_httperror_with_body_stashed(self):
        # A non-2xx open is re-raised as-is (not wrapped) so the caller's retry
        # loop can classify by status; the body is stashed on stream_error_body
        # since e.read() is single-shot.
        err = harvest.urllib.error.HTTPError(
            url="http://gw/stream", code=503, msg="err", hdrs=None,
            fp=io.BytesIO(b"upstream unavailable"))
        with mock.patch("harvest_clients.base.urllib.request.urlopen", side_effect=err):
            stream = harvest._http_stream_post("http://gw/stream", {}, {}, 5)
            with self.assertRaises(harvest.urllib.error.HTTPError) as ctx:
                next(stream)
        self.assertEqual(ctx.exception.stream_error_body, "upstream unavailable")

    def test_non_event_stream_content_type_raises_not_supported(self):
        # HTTP 200 with a non-SSE Content-Type (a plain JSON error body) is a
        # permanent StreamNotSupportedError, never a transient stream failure.
        fake = FakeSSEHTTPResponse(content_type="application/json",
                                   body=b'{"error":"no streaming here"}')
        with mock.patch("harvest_clients.base.urllib.request.urlopen", return_value=fake):
            stream = harvest._http_stream_post("http://gw/stream", {}, {}, 5)
            with self.assertRaises(harvest.StreamNotSupportedError):
                next(stream)


class TestAnthropicStreaming(unittest.TestCase):
    """AnthropicGatewayClient._complete_streaming assembles the same
    OpenAI-shaped dict as the non-streaming _anthropic_resp_to_oai path."""

    def _client(self, sock=None):
        return harvest.AnthropicGatewayClient(
            "http://gw", "key", "claude-sonnet-5", 5, 16384,
            stream_enabled=True, ttft_timeout=5, inter_token_timeout=5)

    def test_text_and_tool_call_stream_assembled(self):
        frames = [
            ("message_start", json.dumps({"message": {"usage": {"input_tokens": 11}}})),
            ("content_block_start", json.dumps({"index": 0, "content_block": {"type": "text", "text": ""}})),
            ("content_block_delta", json.dumps({"index": 0, "delta": {"type": "text_delta", "text": "Hello "}})),
            ("content_block_delta", json.dumps({"index": 0, "delta": {"type": "text_delta", "text": "world"}})),
            ("content_block_stop", json.dumps({"index": 0})),
            ("content_block_start", json.dumps({"index": 1, "content_block": {"type": "tool_use", "id": "toolu_1", "name": "search"}})),
            ("content_block_delta", json.dumps({"index": 1, "delta": {"type": "input_json_delta", "partial_json": '{"query":'}})),
            ("content_block_delta", json.dumps({"index": 1, "delta": {"type": "input_json_delta", "partial_json": ' "sky"}'}})),
            ("content_block_stop", json.dumps({"index": 1})),
            ("message_delta", json.dumps({"delta": {"stop_reason": "tool_use"}, "usage": {"output_tokens": 7}})),
            ("message_stop", json.dumps({})),
        ]
        with mock.patch("harvest_clients.base._http_stream_post", side_effect=_stream_of(frames)):
            result = self._client().complete(messages=[{"role": "user", "content": "x"}], tools=harvest.TOOL_SCHEMAS)
        msg = result["choices"][0]["message"]
        self.assertEqual(msg["content"], "Hello world")
        self.assertEqual(len(msg["tool_calls"]), 1)
        tc = msg["tool_calls"][0]
        self.assertEqual(tc["id"], "toolu_1")
        self.assertEqual(tc["function"]["name"], "search")
        self.assertEqual(json.loads(tc["function"]["arguments"]), {"query": "sky"})
        self.assertEqual(result["choices"][0]["finish_reason"], "tool_use")
        self.assertEqual(result["usage"], {"input_tokens": 11, "output_tokens": 7})

    def test_text_only_stream_has_no_tool_calls(self):
        frames = [
            ("message_start", json.dumps({"message": {"usage": {"input_tokens": 3}}})),
            ("content_block_start", json.dumps({"index": 0, "content_block": {"type": "text", "text": ""}})),
            ("content_block_delta", json.dumps({"index": 0, "delta": {"type": "text_delta", "text": "just text"}})),
            ("content_block_stop", json.dumps({"index": 0})),
            ("message_delta", json.dumps({"delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 2}})),
            ("message_stop", json.dumps({})),
        ]
        with mock.patch("harvest_clients.base._http_stream_post", side_effect=_stream_of(frames)):
            result = self._client().complete(messages=[{"role": "user", "content": "x"}], tools=None)
        msg = result["choices"][0]["message"]
        self.assertEqual(msg["content"], "just text")
        self.assertNotIn("tool_calls", msg)
        self.assertEqual(result["choices"][0]["finish_reason"], "end_turn")


class TestResponsesStreaming(unittest.TestCase):
    """ResponsesGatewayClient._complete_streaming -> OpenAI-shaped dict."""

    def _client(self, sock=None):
        return harvest.ResponsesGatewayClient(
            "http://gw", "key", "gpt-5.4", 5, 16384,
            stream_enabled=True, ttft_timeout=5, inter_token_timeout=5)

    def test_text_delta_stream_assembled(self):
        frames = [
            (None, json.dumps({"type": "response.output_text.delta", "delta": "Hel"})),
            (None, json.dumps({"type": "response.output_text.delta", "delta": "lo"})),
            (None, json.dumps({"type": "response.completed",
                               "response": {"status": "completed", "usage": {"input_tokens": 5, "output_tokens": 2}}})),
        ]
        with mock.patch("harvest_clients.base._http_stream_post", side_effect=_stream_of(frames)):
            result = self._client().complete(messages=[{"role": "user", "content": "x"}], tools=None)
        msg = result["choices"][0]["message"]
        self.assertEqual(msg["content"], "Hello")
        self.assertNotIn("tool_calls", msg)
        self.assertEqual(result["choices"][0]["finish_reason"], "completed")
        self.assertEqual(result["usage"], {"input_tokens": 5, "output_tokens": 2})

    def test_function_call_stream_assembled(self):
        frames = [
            (None, json.dumps({"type": "response.output_item.added", "output_index": 0,
                               "item": {"type": "function_call", "call_id": "call_1", "name": "fetch"}})),
            (None, json.dumps({"type": "response.function_call_arguments.delta", "output_index": 0,
                               "delta": '{"url":'})),
            (None, json.dumps({"type": "response.function_call_arguments.delta", "output_index": 0,
                               "delta": ' "https://a.com"}'})),
            (None, json.dumps({"type": "response.output_item.done", "output_index": 0,
                               "item": {"type": "function_call", "call_id": "call_1", "name": "fetch",
                                        "arguments": '{"url": "https://a.com"}'}})),
            (None, json.dumps({"type": "response.completed",
                               "response": {"status": "completed", "usage": {"input_tokens": 4}}})),
        ]
        with mock.patch("harvest_clients.base._http_stream_post", side_effect=_stream_of(frames)):
            result = self._client().complete(messages=[{"role": "user", "content": "x"}], tools=harvest.TOOL_SCHEMAS)
        msg = result["choices"][0]["message"]
        self.assertEqual(len(msg["tool_calls"]), 1)
        tc = msg["tool_calls"][0]
        self.assertEqual(tc["id"], "call_1")
        self.assertEqual(tc["function"]["name"], "fetch")
        self.assertEqual(json.loads(tc["function"]["arguments"]), {"url": "https://a.com"})
        self.assertEqual(result["choices"][0]["finish_reason"], "completed")


class TestGeminiStreaming(unittest.TestCase):
    """GeminiNativeGatewayClient._complete_streaming -- each SSE frame is a
    full generateContent snapshot; parts accumulate, usage is the last frame's
    usageMetadata, logical end is the candidate finishReason."""

    def _client(self, sock=None):
        return harvest.GeminiNativeGatewayClient(
            "https://gw.example.com/v1", "key", "gemini-3.5-flash", 5, 16384,
            stream_enabled=True, ttft_timeout=5, inter_token_timeout=5)

    def test_text_snapshot_frames_assembled(self):
        frames = [
            (None, json.dumps({"candidates": [{"content": {"parts": [{"text": "Blue "}]}}],
                               "usageMetadata": {"promptTokenCount": 10}})),
            (None, json.dumps({"candidates": [{"content": {"parts": [{"text": "sky"}]}}],
                               "usageMetadata": {"promptTokenCount": 10, "candidatesTokenCount": 2}})),
            (None, json.dumps({"candidates": [{"content": {"parts": [{"text": "."}]}, "finishReason": "STOP"}],
                               "usageMetadata": {"promptTokenCount": 10, "candidatesTokenCount": 3}})),
        ]
        with mock.patch("harvest_clients.base._http_stream_post", side_effect=_stream_of(frames)):
            result = self._client().complete(messages=[{"role": "user", "content": "x"}], tools=None)
        msg = result["choices"][0]["message"]
        self.assertEqual(msg["content"], "Blue sky.")
        self.assertNotIn("tool_calls", msg)
        self.assertEqual(result["choices"][0]["finish_reason"], "stop")
        self.assertEqual(result["usage"], {"promptTokenCount": 10, "candidatesTokenCount": 3})

    def test_function_call_snapshot_frames_assembled(self):
        frames = [
            (None, json.dumps({"candidates": [{"content": {"parts": [
                {"functionCall": {"name": "search", "args": {"query": "sky"}}}]}, "finishReason": "STOP"}],
                "usageMetadata": {"promptTokenCount": 8}})),
        ]
        with mock.patch("harvest_clients.base._http_stream_post", side_effect=_stream_of(frames)):
            result = self._client().complete(messages=[{"role": "user", "content": "x"}], tools=harvest.TOOL_SCHEMAS)
        msg = result["choices"][0]["message"]
        self.assertEqual(msg["content"], "")
        self.assertEqual(len(msg["tool_calls"]), 1)
        tc = msg["tool_calls"][0]
        self.assertEqual(tc["function"]["name"], "search")
        self.assertEqual(json.loads(tc["function"]["arguments"]), {"query": "sky"})
        # A tool call forces finish_reason=tool_calls regardless of raw STOP.
        self.assertEqual(result["choices"][0]["finish_reason"], "tool_calls")

    def test_function_call_streaming_frame_captures_thought_signature(self):
        frames = [
            (None, json.dumps({"candidates": [{"content": {"parts": [
                {"functionCall": {"name": "search", "args": {"query": "sky"}},
                 "thoughtSignature": "sig-stream"}]}, "finishReason": "STOP"}],
                "usageMetadata": {"promptTokenCount": 8}})),
        ]
        with mock.patch("harvest_clients.base._http_stream_post", side_effect=_stream_of(frames)):
            result = self._client().complete(messages=[{"role": "user", "content": "x"}], tools=harvest.TOOL_SCHEMAS)
        msg = result["choices"][0]["message"]
        self.assertEqual(msg["tool_calls"][0]["thought_signature"], "sig-stream")

    def test_signature_in_frame_after_function_call_frame_bound(self):
        # Direct regression for the production "Corrupted thought signature."
        # 400: streamGenerateContent may deliver the thinking-state signature
        # on a LATER frame (an empty-text part) than the functionCall frame.
        # The old per-frame `if text elif functionCall` walk dropped that
        # part entirely, so the replayed functionCall carried no signature and
        # was rejected on the next turn. The signature must bind across frames.
        frames = [
            (None, json.dumps({"candidates": [{"content": {"parts": [
                {"functionCall": {"name": "search", "args": {"query": "france"}}}]}}]})),
            (None, json.dumps({"candidates": [{"content": {"parts": [
                {"text": "", "thoughtSignature": "sig-late-frame"}]}, "finishReason": "STOP"}],
                "usageMetadata": {"promptTokenCount": 9}})),
        ]
        with mock.patch("harvest_clients.base._http_stream_post", side_effect=_stream_of(frames)):
            result = self._client().complete(messages=[{"role": "user", "content": "x"}], tools=harvest.TOOL_SCHEMAS)
        tcs = result["choices"][0]["message"]["tool_calls"]
        self.assertEqual(len(tcs), 1)
        self.assertEqual(tcs[0]["function"]["name"], "search")
        self.assertEqual(tcs[0]["thought_signature"], "sig-late-frame")
        self.assertEqual(result["choices"][0]["finish_reason"], "tool_calls")

    def test_signature_on_standalone_part_frame_bound(self):
        # A frame whose part carries ONLY thoughtSignature (no text, no
        # functionCall) must not be dropped -- its signature binds to the
        # earlier functionCall's tool_call.
        frames = [
            (None, json.dumps({"candidates": [{"content": {"parts": [
                {"functionCall": {"name": "search", "args": {"query": "japan"}}}]}}]})),
            (None, json.dumps({"candidates": [{"content": {"parts": [
                {"thoughtSignature": "sig-standalone"}]}, "finishReason": "STOP"}]})),
        ]
        with mock.patch("harvest_clients.base._http_stream_post", side_effect=_stream_of(frames)):
            result = self._client().complete(messages=[{"role": "user", "content": "x"}], tools=harvest.TOOL_SCHEMAS)
        tcs = result["choices"][0]["message"]["tool_calls"]
        self.assertEqual(tcs[0]["thought_signature"], "sig-standalone")

    def test_streaming_round_trip_replays_cross_frame_signature(self):
        # End-to-end guard against the #93-style self-证 gap: the signature
        # must survive a REAL cross-frame streaming layout -> internal OAI
        # shape -> replayed Gemini contents, so turn 2 of a multi-round tool
        # conversation is accepted server-side. Mirrors the blocking
        # round-trip test but drives the streaming accumulator with a
        # detached-signature frame the old code would have dropped.
        frames = [
            (None, json.dumps({"candidates": [{"content": {"parts": [
                {"functionCall": {"name": "search", "args": {"q": "x"}}}]}}]})),
            (None, json.dumps({"candidates": [{"content": {"parts": [
                {"text": "", "thoughtSignature": "sig-roundtrip-stream"}]}, "finishReason": "STOP"}]})),
        ]
        with mock.patch("harvest_clients.base._http_stream_post", side_effect=_stream_of(frames)):
            result = self._client().complete(messages=[{"role": "user", "content": "x"}], tools=harvest.TOOL_SCHEMAS)
        assistant_msg = result["choices"][0]["message"]
        messages = [
            assistant_msg,
            {"role": "tool", "tool_call_id": assistant_msg["tool_calls"][0]["id"],
             "content": json.dumps({"result": "ok"})},
        ]
        _s, contents = harvest._oai_messages_to_gemini(messages)
        model_turn = next(c for c in contents if c["role"] == "model")
        fc_part = next(p for p in model_turn["parts"] if "functionCall" in p)
        self.assertEqual(fc_part["thoughtSignature"], "sig-roundtrip-stream")

    def test_parallel_calls_first_frame_signature_second_frame_none(self):
        # Parallel calls where only the first carries a signature (Gemini 3
        # contract) split across frames: first tool_call keeps its signature,
        # the second legitimately has none -- and no spurious floating
        # signature is invented for it.
        frames = [
            (None, json.dumps({"candidates": [{"content": {"parts": [
                {"functionCall": {"name": "search", "args": {"q": "1"}}, "thoughtSignature": "sig-first"}]}}]})),
            (None, json.dumps({"candidates": [{"content": {"parts": [
                {"functionCall": {"name": "fetch", "args": {"url": "u"}}}]}, "finishReason": "STOP"}]})),
        ]
        with mock.patch("harvest_clients.base._http_stream_post", side_effect=_stream_of(frames)):
            result = self._client().complete(messages=[{"role": "user", "content": "x"}], tools=harvest.TOOL_SCHEMAS)
        tcs = result["choices"][0]["message"]["tool_calls"]
        self.assertEqual(len(tcs), 2)
        self.assertEqual(tcs[0]["thought_signature"], "sig-first")
        self.assertNotIn("thought_signature", tcs[1])


class TestGatewayStreaming(unittest.TestCase):
    """GatewayClient._complete_streaming (OpenAI chat/completions SSE)."""

    def _client(self, sock=None):
        return harvest.GatewayClient(
            "http://gw", "key", "model-x", 5,
            stream_enabled=True, ttft_timeout=5, inter_token_timeout=5)

    def test_content_deltas_then_done_sentinel(self):
        frames = [
            (None, json.dumps({"choices": [{"delta": {"content": "Hel"}}]})),
            (None, json.dumps({"choices": [{"delta": {"content": "lo"}, "finish_reason": "stop"}]})),
            (None, "[DONE]"),
        ]
        with mock.patch("harvest_clients.base._http_stream_post", side_effect=_stream_of(frames)):
            result = self._client().complete(messages=[{"role": "user", "content": "x"}], tools=None)
        msg = result["choices"][0]["message"]
        self.assertEqual(msg["content"], "Hello")
        self.assertNotIn("tool_calls", msg)
        self.assertEqual(result["choices"][0]["finish_reason"], "stop")

    def test_usage_only_final_chunk_with_empty_choices(self):
        # stream_options.include_usage yields a trailing choices:[] usage-only
        # chunk after [DONE]-less finish -- usage must be captured, no crash on
        # the empty choices list.
        frames = [
            (None, json.dumps({"choices": [{"delta": {"content": "hi"}, "finish_reason": "stop"}]})),
            (None, json.dumps({"choices": [], "usage": {"prompt_tokens": 5, "completion_tokens": 1}})),
            (None, "[DONE]"),
        ]
        with mock.patch("harvest_clients.base._http_stream_post", side_effect=_stream_of(frames)):
            result = self._client().complete(messages=[{"role": "user", "content": "x"}], tools=None)
        self.assertEqual(result["choices"][0]["message"]["content"], "hi")
        self.assertEqual(result["usage"], {"prompt_tokens": 5, "completion_tokens": 1})

    def test_tool_call_delta_fragments_assembled(self):
        frames = [
            (None, json.dumps({"choices": [{"delta": {"tool_calls": [
                {"index": 0, "id": "call_1", "function": {"name": "fetch", "arguments": '{"url":'}}]}}]})),
            (None, json.dumps({"choices": [{"delta": {"tool_calls": [
                {"index": 0, "function": {"arguments": ' "https://a.com"}'}}]}, "finish_reason": "tool_calls"}]})),
            (None, "[DONE]"),
        ]
        with mock.patch("harvest_clients.base._http_stream_post", side_effect=_stream_of(frames)):
            result = self._client().complete(messages=[{"role": "user", "content": "x"}], tools=harvest.TOOL_SCHEMAS)
        tc = result["choices"][0]["message"]["tool_calls"][0]
        self.assertEqual(tc["id"], "call_1")
        self.assertEqual(tc["function"]["name"], "fetch")
        self.assertEqual(json.loads(tc["function"]["arguments"]), {"url": "https://a.com"})


def _no_retry(attempt_fn, backoffs=None):
    """Passthrough replacement for _run_stream_attempt_with_retry that runs a
    single attempt so a client's raw streaming exception (StreamConnectionLost
    etc.) propagates uncaught -- lets a test assert the exact exception the
    attempt raises instead of the RuntimeError the retry wrapper would wrap it
    in after exhausting backoffs."""
    return attempt_fn()


class TestStreamWatchdog(unittest.TestCase):
    """TTFT/inter-token fail-fast watchdog behavior."""

    def test_ttft_timeout_retries_then_raises_runtime_error(self):
        # A connect/first-frame timeout surfaces as socket.timeout when the
        # client calls next(stream); it is retryable, so the wrapper follows
        # the full _COMPLETION_RETRY_BACKOFFS schedule (4 sleeps, 5 attempts)
        # and then raises RuntimeError rather than hanging.
        client = harvest.GatewayClient("http://gw", "key", "model-x", 5,
                                       stream_enabled=True, ttft_timeout=5, inter_token_timeout=5)
        with mock.patch("harvest_clients.base._http_stream_post", side_effect=_stream_raising(socket.timeout("ttft"))), \
             mock.patch("harvest_clients.base.time.sleep") as sleep_mock:
            with self.assertRaises(RuntimeError):
                client.complete(messages=[{"role": "user", "content": "x"}], tools=None)
        self.assertEqual(sleep_mock.call_count, len(harvest._COMPLETION_RETRY_BACKOFFS))
        self.assertEqual([c.args[0] for c in sleep_mock.call_args_list],
                         list(harvest._COMPLETION_RETRY_BACKOFFS))

    def test_inter_token_tightening_fires_once_after_first_content(self):
        # Once the first content delta arrives, the client tightens the socket
        # from the generous TTFT window to inter_token_timeout, exactly once.
        sock = _RecordingSocket()
        frames = [
            (None, json.dumps({"choices": [{"delta": {"content": "a"}}]})),
            (None, json.dumps({"choices": [{"delta": {"content": "b"}, "finish_reason": "stop"}]})),
            (None, "[DONE]"),
        ]
        client = harvest.GatewayClient("http://gw", "key", "model-x", 5,
                                       stream_enabled=True, ttft_timeout=30, inter_token_timeout=7)
        with mock.patch("harvest_clients.base._http_stream_post", side_effect=_stream_of(frames, sock=sock)):
            client.complete(messages=[{"role": "user", "content": "x"}], tools=None)
        self.assertEqual(sock.timeouts, [7])


class TestStreamLogicalEnd(unittest.TestCase):
    """A stream that ends without its provider-specific logical-end marker must
    raise StreamConnectionLost (retryable) rather than return a truncated
    result. _run_stream_attempt_with_retry is stubbed to a single attempt so
    the raw exception is observable."""

    def test_gateway_missing_done_and_finish_reason(self):
        frames = [(None, json.dumps({"choices": [{"delta": {"content": "partial"}}]}))]
        client = harvest.GatewayClient("http://gw", "key", "model-x", 5,
                                       stream_enabled=True, ttft_timeout=5, inter_token_timeout=5)
        with mock.patch("harvest_clients.base._http_stream_post", side_effect=_stream_of(frames)), \
             mock.patch("harvest_clients.base._run_stream_attempt_with_retry", side_effect=_no_retry):
            with self.assertRaises(harvest.StreamConnectionLost):
                client.complete(messages=[{"role": "user", "content": "x"}], tools=None)

    def test_anthropic_missing_message_stop(self):
        frames = [
            ("content_block_start", json.dumps({"index": 0, "content_block": {"type": "text", "text": ""}})),
            ("content_block_delta", json.dumps({"index": 0, "delta": {"type": "text_delta", "text": "hi"}})),
        ]
        client = harvest.AnthropicGatewayClient("http://gw", "key", "claude-sonnet-5", 5, 16384,
                                                stream_enabled=True, ttft_timeout=5, inter_token_timeout=5)
        with mock.patch("harvest_clients.base._http_stream_post", side_effect=_stream_of(frames)), \
             mock.patch("harvest_clients.base._run_stream_attempt_with_retry", side_effect=_no_retry):
            with self.assertRaises(harvest.StreamConnectionLost):
                client.complete(messages=[{"role": "user", "content": "x"}], tools=None)

    def test_responses_missing_completed(self):
        frames = [(None, json.dumps({"type": "response.output_text.delta", "delta": "hi"}))]
        client = harvest.ResponsesGatewayClient("http://gw", "key", "gpt-5.4", 5, 16384,
                                                stream_enabled=True, ttft_timeout=5, inter_token_timeout=5)
        with mock.patch("harvest_clients.base._http_stream_post", side_effect=_stream_of(frames)), \
             mock.patch("harvest_clients.base._run_stream_attempt_with_retry", side_effect=_no_retry):
            with self.assertRaises(harvest.StreamConnectionLost):
                client.complete(messages=[{"role": "user", "content": "x"}], tools=None)

    def test_gemini_missing_finish_reason(self):
        frames = [(None, json.dumps({"candidates": [{"content": {"parts": [{"text": "hi"}]}}],
                                     "usageMetadata": {"promptTokenCount": 3}}))]
        client = harvest.GeminiNativeGatewayClient("https://gw.example.com/v1", "key", "gemini-3.5-flash", 5, 16384,
                                                   stream_enabled=True, ttft_timeout=5, inter_token_timeout=5)
        with mock.patch("harvest_clients.base._http_stream_post", side_effect=_stream_of(frames)), \
             mock.patch("harvest_clients.base._run_stream_attempt_with_retry", side_effect=_no_retry):
            with self.assertRaises(harvest.StreamConnectionLost):
                client.complete(messages=[{"role": "user", "content": "x"}], tools=None)


class TestStreamRetry(unittest.TestCase):
    """_run_stream_attempt_with_retry classification: retryable transient
    failures are retried under _COMPLETION_RETRY_BACKOFFS; StreamNotSupported
    propagates immediately without a retry or a sleep."""

    def test_retryable_failure_then_success(self):
        attempts = []

        def attempt_fn():
            attempts.append(1)
            if len(attempts) == 1:
                raise harvest.StreamConnectionLost("dropped")
            return {"ok": True}

        with mock.patch("harvest_clients.base.time.sleep") as sleep_mock:
            result = harvest._run_stream_attempt_with_retry(attempt_fn)
        self.assertEqual(result, {"ok": True})
        self.assertEqual(len(attempts), 2)
        # First retry sleeps the first backoff in the shared schedule.
        sleep_mock.assert_called_once_with(harvest._COMPLETION_RETRY_BACKOFFS[0])

    def test_stream_not_supported_propagates_without_retry(self):
        attempts = []

        def attempt_fn():
            attempts.append(1)
            raise harvest.StreamNotSupportedError("plain json body, not SSE")

        with mock.patch("harvest_clients.base.time.sleep") as sleep_mock:
            with self.assertRaises(harvest.StreamNotSupportedError):
                harvest._run_stream_attempt_with_retry(attempt_fn)
        self.assertEqual(len(attempts), 1)
        sleep_mock.assert_not_called()


# ---------------------------------------------------------------------------
# Supplementary streaming coverage: the fixtures above always terminate a
# frame with a trailing blank line before EOF, so the "flush a buffered
# partial frame at EOF" branch and the readline-level socket.timeout ->
# StreamIdleTimeout translation inside _http_stream_post itself were never
# exercised by a real (non-mocked-away) call. These classes close that gap
# without touching any pre-existing test.
# ---------------------------------------------------------------------------

class _RaisingSSEHTTPResponse:
    """Like FakeSSEHTTPResponse, but readline() raises `exc` once the
    scripted lines are exhausted instead of returning b'' (EOF) -- exercises
    _http_stream_post's own except clause around resp.readline(), rather than
    a test that mocks _http_stream_post away and injects the exception at the
    generator boundary."""

    def __init__(self, lines, exc, content_type="text/event-stream"):
        self._lines = list(lines)
        self._exc = exc
        self.headers = {"Content-Type": content_type}

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self, *args):
        return b""

    def readline(self):
        if self._lines:
            return self._lines.pop(0)
        raise self._exc


class TestStreamPostEOFAndTimeout(unittest.TestCase):
    """_http_stream_post: EOF-flush of an unterminated frame, and the
    readline-level socket.timeout -> StreamIdleTimeout translation."""

    def test_first_yield_is_the_response_object_itself(self):
        fake = FakeSSEHTTPResponse([b"data: x\n", b"\n"])
        with mock.patch("harvest_clients.base.urllib.request.urlopen", return_value=fake):
            stream = harvest._http_stream_post("http://gw/stream", {}, {}, 5)
            resp = next(stream)
        self.assertIs(resp, fake)

    def test_eof_without_trailing_blank_line_flushes_buffered_frame(self):
        # No terminating blank line before EOF (b"") -- the partial frame
        # sitting in data_lines/event_type must still be yielded, not
        # silently dropped.
        fake = FakeSSEHTTPResponse([b"event: message\n", b"data: partial\n"])
        with mock.patch("harvest_clients.base.urllib.request.urlopen", return_value=fake):
            stream = harvest._http_stream_post("http://gw/stream", {}, {}, 5)
            next(stream)
            frames = list(stream)
        self.assertEqual(frames, [("message", "partial")])

    def test_eof_with_no_buffered_content_yields_nothing(self):
        # Clean EOF right after a terminated frame -- no extra empty frame.
        fake = FakeSSEHTTPResponse([b"data: x\n", b"\n"])
        with mock.patch("harvest_clients.base.urllib.request.urlopen", return_value=fake):
            stream = harvest._http_stream_post("http://gw/stream", {}, {}, 5)
            next(stream)
            frames = list(stream)
        self.assertEqual(frames, [(None, "x")])

    def test_readline_socket_timeout_raises_stream_idle_timeout(self):
        # A real socket.timeout surfacing from readline() itself (e.g. the
        # inter-token watchdog firing) is translated to StreamIdleTimeout at
        # the _http_stream_post call site, not left as a bare socket.timeout.
        fake = _RaisingSSEHTTPResponse([b"data: x\n", b"\n"], socket.timeout("idle"))
        with mock.patch("harvest_clients.base.urllib.request.urlopen", return_value=fake):
            stream = harvest._http_stream_post("http://gw/stream", {}, {}, 5)
            next(stream)
            self.assertEqual(next(stream), (None, "x"))  # one complete frame, no raise yet
            with self.assertRaises(harvest.StreamIdleTimeout):
                next(stream)

    def test_readline_connection_reset_raises_stream_idle_timeout(self):
        # ConnectionResetError is in the same _STREAM_READ_EXCEPTIONS set and
        # collapses to StreamIdleTimeout exactly like socket.timeout does --
        # the caller's retry loop treats both as transient regardless of the
        # underlying exception type.
        fake = _RaisingSSEHTTPResponse([], ConnectionResetError("reset"))
        with mock.patch("harvest_clients.base.urllib.request.urlopen", return_value=fake):
            stream = harvest._http_stream_post("http://gw/stream", {}, {}, 5)
            next(stream)
            with self.assertRaises(harvest.StreamIdleTimeout):
                next(stream)


class TestAnthropicStreamingErrorEvent(unittest.TestCase):
    """AnthropicGatewayClient._complete_streaming: a mid-stream SSE `error`
    event is a hard signal from the provider, not a malformed frame -- must
    raise StreamConnectionLost so the retry wrapper reattempts rather than
    returning a truncated result."""

    def _client(self):
        return harvest.AnthropicGatewayClient(
            "http://gw", "key", "claude-sonnet-5", 5, 16384,
            stream_enabled=True, ttft_timeout=5, inter_token_timeout=5)

    def test_error_event_mid_stream_raises_stream_connection_lost(self):
        frames = [
            ("message_start", json.dumps({"message": {"usage": {"input_tokens": 5}}})),
            ("content_block_start", json.dumps({"index": 0, "content_block": {"type": "text", "text": ""}})),
            ("content_block_delta", json.dumps({"index": 0, "delta": {"type": "text_delta", "text": "hi"}})),
            ("error", json.dumps({"type": "error", "error": {"type": "overloaded_error", "message": "boom"}})),
        ]
        with mock.patch("harvest_clients.base._http_stream_post", side_effect=_stream_of(frames)), \
             mock.patch("harvest_clients.base._run_stream_attempt_with_retry", side_effect=_no_retry):
            with self.assertRaises(harvest.StreamConnectionLost):
                self._client().complete(messages=[{"role": "user", "content": "x"}], tools=None)


if __name__ == "__main__":
    unittest.main()
