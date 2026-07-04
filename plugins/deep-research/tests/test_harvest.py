import io
import json
import socket
import subprocess
import sys
import tempfile
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
        "search_backends": [{"type": "gemini-cli", "model": "gemini-2.5-flash"}],
        "fetch_backends": [{"type": "urllib-ua"}],
        "local_sources": {"enabled": False, "dir": "intake/local_sources"},
        "limits": {"max_steps_per_model": 6, "call_timeout_s": 5, "wall_clock_s": 60,
                   "quorum": 2, "search_min_interval_s": 0, "fetch_max_chars": 20000},
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

    def test_whitespace_normalization(self):
        self.assertEqual(harvest.normalize_citation_text("a   b\n\tc"), "a b c")

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

    def test_tampered_excerpt_rejected(self):
        journal = [{"tool": "fetch", "url": "https://a.com/x", "content": "The quick brown fox."}]
        claims = harvest.assign_claim_ids("m1", [
            {"claim": "c", "excerpt": "the slow red fox", "url": "https://a.com/x"}])
        valid, invalid = self._validate(journal, claims)
        self.assertEqual(valid, [])
        self.assertEqual(len(invalid), 1)
        self.assertEqual(invalid[0][1], "excerpt_not_substring")

    def test_translated_excerpt_rejected_with_verbatim_hint(self):
        journal = [{"tool": "fetch", "url": "https://a.com/x", "content": "白日依山尽，黄河入海流。"}]
        claims = harvest.assign_claim_ids("m1", [
            {"claim": "c", "excerpt": "The sun sets behind the mountains", "url": "https://a.com/x"}])
        valid, invalid = self._validate(journal, claims)
        self.assertEqual(valid, [])
        feedback = harvest.build_citation_feedback(invalid)
        self.assertIn("verbatim", feedback.lower())

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
            {"claim": "c", "excerpt": "the slow red fox", "url": "https://a.com/x"}])
        _, invalid = self._validate(journal, claims)
        records = harvest.build_rejected_claims(invalid)
        self.assertEqual(records, [{"claim": "c", "url": "https://a.com/x", "excerpt": "the slow red fox",
                                     "reject_reason": "excerpt_not_substring", "matched_url_normalized": "https://a.com/x"}])

    def test_rejected_claims_record_no_matched_url_when_not_fetched(self):
        journal = [{"tool": "fetch", "url": "https://a.com/x", "content": "The quick brown fox."}]
        claims = harvest.assign_claim_ids("m1", [
            {"claim": "c", "excerpt": "quick brown fox", "url": "https://a.com/NEVER-SEEN"}])
        _, invalid = self._validate(journal, claims)
        records = harvest.build_rejected_claims(invalid)
        self.assertIsNone(records[0]["matched_url_normalized"])


class TestCitationNormalization(unittest.TestCase):
    def _accepted(self, content, excerpt):
        journal = [{"tool": "fetch", "url": "https://a.com/x", "content": content}]
        claims = harvest.assign_claim_ids("m1", [{"claim": "c", "excerpt": excerpt, "url": "https://a.com/x"}])
        idx = harvest.build_fetch_index(journal)
        urls = harvest.build_journal_url_set(journal)
        valid, _ = harvest.validate_claims(claims, idx, urls)
        return len(valid) == 1

    def test_nbsp_folded_as_before(self):
        self.assertTrue(self._accepted("The quick\xa0brown fox.", "quick brown fox"))

    def test_smart_quotes_match_straight_quotes(self):
        self.assertTrue(self._accepted("She said “hello” to ‘Bob’.", 'She said "hello" to \'Bob\'.'))

    def test_straight_quotes_match_smart_quotes(self):
        self.assertTrue(self._accepted('She said "hello" to \'Bob\'.', "She said “hello” to ‘Bob’."))

    def test_em_dash_and_en_dash_match_ascii_hyphen(self):
        self.assertTrue(self._accepted("A—B and C–D.", "A-B and C-D."))

    def test_html_entity_residue_matches_decoded_text(self):
        self.assertTrue(self._accepted("Fish &amp; chips &quot;classic&quot;.", 'Fish & chips "classic".'))

    def test_ellipsis_truncation_still_rejected_not_a_false_positive(self):
        # A model-inserted "..." to skip words is a real verbatim violation,
        # not an encoding artifact -- normalization must NOT paper over it.
        self.assertFalse(self._accepted("The quick brown fox jumps over the lazy dog.",
                                         "The quick brown ... jumps over the lazy dog."))


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


class TestAgyCliSearch(unittest.TestCase):
    def _fake_proc(self, stdout="", returncode=0, stderr=""):
        proc = mock.Mock()
        proc.returncode = returncode
        proc.stdout = stdout
        proc.stderr = stderr
        return proc

    def test_parses_urls_from_numbered_output(self):
        stdout = (
            "1. Example Title | key info here | https://example.com/page\n"
            "2. Other | more info | https://other.com/x\n"
        )
        with mock.patch("harvest.subprocess.run", return_value=self._fake_proc(stdout=stdout)):
            result, reason = harvest._search_agy_cli({}, "sqlite wal", 5)
        self.assertIsNone(reason)
        urls = [r["url"] for r in result]
        self.assertIn("https://example.com/page", urls)
        self.assertIn("https://other.com/x", urls)

    def test_search_failed_sentinel_treated_as_failure(self):
        with mock.patch("harvest.subprocess.run", return_value=self._fake_proc(stdout="SEARCH_FAILED\n")):
            result, reason = harvest._search_agy_cli({}, "q", 5)
        self.assertIsNone(result)
        self.assertIn("SEARCH_FAILED", reason)

    def test_timeout_degrades_with_reason(self):
        with mock.patch("harvest.subprocess.run", side_effect=subprocess.TimeoutExpired(cmd="agy", timeout=5)):
            result, reason = harvest._search_agy_cli({}, "q", 5)
        self.assertIsNone(result)
        self.assertIn("timed out", reason)

    def test_nonzero_exit_degrades_with_reason(self):
        with mock.patch("harvest.subprocess.run", return_value=self._fake_proc(returncode=1, stderr="boom")):
            result, reason = harvest._search_agy_cli({}, "q", 5)
        self.assertIsNone(result)
        self.assertIn("exited with code 1", reason)

    def test_uses_configured_model_and_devnull_stdin(self):
        with mock.patch("harvest.subprocess.run", return_value=self._fake_proc(stdout="SEARCH_FAILED")) as m:
            harvest._search_agy_cli({"model": "custom-model"}, "q", 5)
        args, kwargs = m.call_args
        self.assertEqual(args[0][:3], ["agy", "--model", "custom-model"])
        self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)


class TestSearchBackendMissingKeySkips(unittest.TestCase):
    def test_tavily_missing_key_returns_none_not_raise(self):
        result, reason = harvest._search_tavily({"api_key_env": "NONEXISTENT_TAVILY_KEY_VAR"}, "q", 5)
        self.assertIsNone(result)
        self.assertIn("not set", reason)

    def test_gateway_gemini_missing_key_returns_none_not_raise(self):
        cfg = base_config()
        cfg["gateway"]["api_key_env"] = "NONEXISTENT_GATEWAY_KEY_VAR"
        result, reason = harvest._search_gateway_gemini({"model": "g"}, "q", 5, cfg)
        self.assertIsNone(result)
        self.assertIn("not set", reason)

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
# gateway chat/completions retry (shared by panel loop and judge)
# ---------------------------------------------------------------------------

def _http_error(code):
    import io
    return harvest.urllib.error.HTTPError(url="http://gw/chat/completions", code=code, msg="err",
                                           hdrs=None, fp=io.BytesIO(b""))


class TestGatewayRetry(unittest.TestCase):
    def test_503_then_503_then_200_recovers(self):
        ok_response = {"choices": [{"message": {"role": "assistant", "content": "hi"}}]}
        with mock.patch("harvest._http_json_post", side_effect=[_http_error(503), _http_error(503), ok_response]) as m, \
             mock.patch("harvest.time.sleep") as sleep_mock:
            result = harvest._http_json_post_with_retry("http://gw/chat/completions", {}, {}, 5)
        self.assertEqual(result, ok_response)
        self.assertEqual(m.call_count, 3)
        sleep_mock.assert_has_calls([mock.call(5), mock.call(15)])

    def test_403_persistent_failure_retries_once_then_gives_up(self):
        with mock.patch("harvest._http_json_post", side_effect=[_http_error(403), _http_error(403)]) as m, \
             mock.patch("harvest.time.sleep") as sleep_mock:
            with self.assertRaises(RuntimeError) as ctx:
                harvest._http_json_post_with_retry("http://gw/chat/completions", {}, {}, 5)
        self.assertEqual(m.call_count, 2)  # 1 retry -> 2 attempts total
        sleep_mock.assert_called_once_with(5)
        self.assertIn("HTTP 403 after 2 attempts", str(ctx.exception))

    def test_429_backs_off_and_recovers(self):
        ok_response = {"choices": [{"message": {"role": "assistant", "content": "hi"}}]}
        with mock.patch("harvest._http_json_post", side_effect=[_http_error(429), ok_response]) as m, \
             mock.patch("harvest.time.sleep") as sleep_mock:
            result = harvest._http_json_post_with_retry("http://gw/chat/completions", {}, {}, 5)
        self.assertEqual(result, ok_response)
        self.assertEqual(m.call_count, 2)
        sleep_mock.assert_called_once_with(5)  # first backoff in the transient schedule

    def test_5xx_exhausted_after_three_attempts_raises_with_status_and_count(self):
        with mock.patch("harvest._http_json_post", side_effect=[_http_error(503), _http_error(503), _http_error(503)]) as m, \
             mock.patch("harvest.time.sleep"):
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

        with mock.patch("harvest._http_json_post", side_effect=[_http_error(503), {"choices": [{"message": {"content": "ok"}}]}]), \
             mock.patch("harvest.time.sleep", side_effect=fake_sleep):
            harvest._http_json_post_with_retry("http://gw/chat/completions", {}, {}, 5)
        self.assertEqual(calls, [5])

    def test_worker_records_http_status_and_attempt_count_in_reason(self):
        class FlakyClient:
            def complete(self, messages, tools):
                url = "http://gw/chat/completions"
                return harvest._http_json_post_with_retry(url, {}, {}, 5)

        with mock.patch("harvest._http_json_post", side_effect=[_http_error(503), _http_error(503), _http_error(503)]), \
             mock.patch("harvest.time.sleep"):
            result = harvest.run_worker("m1", "model-a", FlakyClient(), base_config(), [], [], "goal", [], None)
        self.assertEqual(result.status, "FAILED")
        self.assertIn("HTTP 503 after 3 attempts", result.reason)

    def test_gateway_client_complete_uses_retry_wrapper(self):
        client = harvest.GatewayClient("http://gw", "key", "model-x", 5)
        ok_response = {"choices": [{"message": {"content": "hi"}}]}
        with mock.patch("harvest._http_json_post_with_retry", return_value=ok_response) as m:
            result = client.complete(messages=[{"role": "user", "content": "x"}], tools=None)
        self.assertEqual(result, ok_response)
        m.assert_called_once()

    def test_socket_timeout_retries_then_recovers(self):
        # A network-layer timeout (no HTTP status at all) must be retried
        # under the same transient backoff schedule as a 5xx, not raised
        # straight through on the first failure.
        ok_response = {"choices": [{"message": {"role": "assistant", "content": "hi"}}]}
        with mock.patch("harvest._http_json_post", side_effect=[socket.timeout("timed out"), ok_response]) as m, \
             mock.patch("harvest.time.sleep") as sleep_mock:
            result = harvest._http_json_post_with_retry("http://gw/chat/completions", {}, {}, 5)
        self.assertEqual(result, ok_response)
        self.assertEqual(m.call_count, 2)
        sleep_mock.assert_called_once_with(5)  # first backoff in the transient schedule

    def test_socket_timeout_exhausted_raises_runtime_error(self):
        with mock.patch("harvest._http_json_post",
                         side_effect=[socket.timeout("t1"), socket.timeout("t2"), socket.timeout("t3")]) as m, \
             mock.patch("harvest.time.sleep"):
            with self.assertRaises(RuntimeError) as ctx:
                harvest._http_json_post_with_retry("http://gw/chat/completions", {}, {}, 5)
        self.assertEqual(m.call_count, 3)
        self.assertIn("after 3 attempts", str(ctx.exception))

    def test_urlerror_without_status_also_retried(self):
        # urllib.error.URLError (e.g. connection refused / DNS failure) has
        # no .code at all -- must be classified transient, same as timeout.
        ok_response = {"choices": [{"message": {"role": "assistant", "content": "hi"}}]}
        with mock.patch("harvest._http_json_post",
                         side_effect=[harvest.urllib.error.URLError("connection refused"), ok_response]) as m, \
             mock.patch("harvest.time.sleep") as sleep_mock:
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
        with mock.patch("harvest.urllib.request.urlopen", side_effect=OSError("network down")):
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


# ---------------------------------------------------------------------------
# SSRF guard scope narrowing: only urllib-ua's direct, model-steered
# connection is a real SSRF surface. Backends with a fixed, config-defined
# destination host (search backends incl. gateway-gemini; tavily-extract;
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
        backends = [({"type": "gateway-gemini", "model": "g"}, harvest.RateLimiter(0))]
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
        backends = [({"type": "gateway-gemini", "model": "g"}, harvest.RateLimiter(0))]
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

    def test_agy_cli_uses_list_args_and_devnull_stdin(self):
        source = Path(harvest.__file__).read_text(encoding="utf-8")
        self.assertIn('["agy", "--model"', source)

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
                {"claim": "c", "excerpt": "this text was never fetched", "url": "https://a.com/x"}])),
            assistant_final(findings_block([
                {"claim": "c", "excerpt": "still made up text", "url": "https://a.com/x"}])),
        ])
        result = self._run(client)
        self.assertEqual(result.status, "OK")
        self.assertEqual(result.findings["claims"], [])
        self.assertEqual(result.findings["invalid_claim_count"], 1)
        self.assertEqual(len(result.rejected_claims), 1)
        self.assertEqual(result.rejected_claims[0]["reject_reason"], "excerpt_not_substring")
        self.assertEqual(result.rejected_claims[0]["excerpt"], "still made up text")

    def test_citation_retry_recovers_on_second_attempt(self):
        client = ScriptedClient([
            assistant_tool_call("c1", "fetch", {"url": "https://a.com/x"}),
            assistant_final(findings_block([
                {"claim": "c", "excerpt": "made up", "url": "https://a.com/x"}])),
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
        # Forced synthesis is the last chance, not another retry loop -- if
        # it still comes back invalid/empty, the worker fails with a reason
        # distinct from the old step_limit_exceeded so callers can tell
        # "never even tried to synthesize" apart from "tried and failed".
        cfg = base_config()
        cfg["limits"]["max_steps_per_model"] = 2
        client = ScriptedClient([
            assistant_tool_call("c1", "fetch", {"url": "https://a.com/1"}),
            assistant_tool_call("c2", "fetch", {"url": "https://a.com/2"}),
            assistant_final("not valid json"),
        ])
        with mock.patch("harvest.call_fetch_backend", return_value="text"):
            result = harvest.run_worker("m1", "model-a", client, cfg, [], self.fetch_backends, "goal", [], None)
        self.assertEqual(client.calls, 3)
        self.assertEqual(result.status, "FAILED")
        self.assertEqual(result.reason, "step_limit_no_synthesis")

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
        class ExplodingClient:
            def complete(self, messages, tools):
                raise RuntimeError("network exploded")
        result = harvest.run_worker("m1", "model-a", ExplodingClient(), self.config, [], self.fetch_backends, "goal", [], None)
        self.assertEqual(result.status, "FAILED")
        self.assertIn("exception", result.reason)

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
        # 10 valid claims (real fetched text) + 3 invalid (never-fetched
        # excerpts) in the same findings JSON, on the very first turn --
        # citation_retry_used is still False so this triggers the one nudge,
        # and the model's retry response repeats the same 3 invalid claims
        # unchanged. The worker must not FAIL: finalize_findings() strips
        # the 3 invalid claims per-claim and ships the 10 valid ones, status
        # OK, invalid_claim_count == 3.
        fact = "Rayleigh scattering explains the blue sky."
        valid_claims = [{"claim": f"valid claim {i}", "excerpt": fact, "url": "https://a.com/x"}
                        for i in range(10)]
        invalid_claims = [{"claim": f"invalid claim {i}", "excerpt": f"never fetched text {i}",
                            "url": "https://a.com/x"} for i in range(3)]
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
        self.assertTrue(all(rc["reject_reason"] == "excerpt_not_substring" for rc in result.rejected_claims))


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

    def test_strong_consensus_3_of_3(self):
        judge = {"clusters": [{"summary": "s", "source_claim_ids": ["m1-1", "m2-1", "m3-1"], "relation": "agree"}],
                 "coverage_gaps": [], "unique_insights": [], "blind_spots": []}
        merged = harvest.merge_findings(self.worker_findings, judge)
        self.assertEqual(merged["clusters"][0]["consensus"], "strong")

    def test_strong_consensus_2_of_3(self):
        judge = {"clusters": [{"summary": "s", "source_claim_ids": ["m1-1", "m2-1"], "relation": "agree"}],
                 "coverage_gaps": [], "unique_insights": [], "blind_spots": []}
        merged = harvest.merge_findings(self.worker_findings, judge)
        self.assertEqual(merged["clusters"][0]["consensus"], "strong")

    def test_minority_1_of_3(self):
        judge = {"clusters": [{"summary": "s", "source_claim_ids": ["m1-1"], "relation": "agree"}],
                 "coverage_gaps": [], "unique_insights": [], "blind_spots": []}
        merged = harvest.merge_findings(self.worker_findings, judge)
        self.assertEqual(merged["clusters"][0]["consensus"], "minority")

    def test_disputed_relation(self):
        judge = {"clusters": [{"summary": "s", "source_claim_ids": ["m1-1", "m2-1"], "relation": "contradict"}],
                 "coverage_gaps": [], "unique_insights": [], "blind_spots": []}
        merged = harvest.merge_findings(self.worker_findings, judge)
        self.assertEqual(merged["clusters"][0]["consensus"], "disputed")
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

    def test_consensus_stats_counts(self):
        merged = {"clusters": [{"consensus": "strong"}, {"consensus": "strong"}, {"consensus": "minority"}]}
        stats = harvest.compute_consensus_stats(merged)
        self.assertEqual(stats, {"strong": 2, "minority": 1, "disputed": 0})

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

    def test_degraded_still_passes(self):
        self._write_verify(verdict="DEGRADED")
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

    def tearDown(self):
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
        self.assertEqual(data["consensus_stats"]["strong"], 1)

        merged_file = self.raw_dir / harvest.MERGED_FINDINGS_FILE
        self.assertTrue(merged_file.exists())
        merged = json.loads(merged_file.read_text(encoding="utf-8"))
        self.assertEqual(len(merged["clusters"]), 1)
        self.assertEqual(merged["clusters"][0]["consensus"], "strong")

        self.assertTrue((self.raw_dir / "fetch-report.md").exists())
        for alias in ("m1", "m2", "m3"):
            self.assertTrue((self.raw_dir / "harvest" / alias / "findings.json").exists())
            self.assertTrue((self.raw_dir / "harvest" / alias / f"journal_{alias}.jsonl").exists())
            rejected_file = self.raw_dir / "harvest" / alias / "rejected_claims.json"
            self.assertTrue(rejected_file.exists())
            self.assertEqual(json.loads(rejected_file.read_text(encoding="utf-8")), [])

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

    def tearDown(self):
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
            harvest.write_fetch_report(raw_dir, [r1], [r1], {"strong": 0, "minority": 0, "disputed": 0}, 0, 0.0, [])
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
                    {"claim": "c1", "url": "u1", "excerpt": "e1", "reject_reason": "excerpt_not_substring", "matched_url_normalized": "u1"},
                    {"claim": "c2", "url": "u2", "excerpt": "e2", "reject_reason": "url_not_in_journal", "matched_url_normalized": None},
                ])
            r2 = harvest.WorkerResult(
                "m2", "model-b", "OK", {"claims": [], "keywords_used": {"zh": [], "en": []}}, [],
                rejected_claims=[
                    {"claim": "c3", "url": "u3", "excerpt": "e3", "reject_reason": "excerpt_not_substring", "matched_url_normalized": "u3"},
                ])
            harvest.write_fetch_report(raw_dir, [r1, r2], [r1, r2], {"strong": 0, "minority": 0, "disputed": 0}, 3, 1.0, [])
            report = (raw_dir / "fetch-report.md").read_text(encoding="utf-8")
            self.assertIn("按模型分布: {'m1': 2, 'm2': 1}", report)
            self.assertIn("'excerpt_not_substring': 2", report)
            self.assertIn("'url_not_in_journal': 1", report)
        finally:
            tmpdir.cleanup()

    def test_write_fetch_report_quorum_status_uses_configured_threshold_not_hardcoded_two(self):
        tmpdir = tempfile.TemporaryDirectory()
        try:
            raw_dir = Path(tmpdir.name)
            r1 = harvest.WorkerResult("m1", "model-a", "OK", {"claims": [], "keywords_used": {"zh": [], "en": []}}, [])
            # 1 alive model with default quorum_required=2 -> "not met".
            harvest.write_fetch_report(raw_dir, [r1], [r1], {"strong": 0, "minority": 0, "disputed": 0}, 0, 0.0, [])
            self.assertIn("法定人数状态: not met",
                           (raw_dir / "fetch-report.md").read_text(encoding="utf-8"))

            # Same 1 alive model, but limits.quorum=1 -> must report "met",
            # not the hardcoded-2 "not met".
            harvest.write_fetch_report(raw_dir, [r1], [r1], {"strong": 0, "minority": 0, "disputed": 0}, 0, 0.0, [],
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
            harvest.write_fetch_report(raw_dir, [r1], [r1], {"strong": 0, "minority": 0, "disputed": 0}, 0, 0.0, [])
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
            harvest.write_fetch_report(raw_dir, [r1], [r1], {"strong": 0, "minority": 0, "disputed": 0}, 0, 0.0, [],
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
            harvest.write_fetch_report(raw_dir, [r1], [r1], {"strong": 0, "minority": 0, "disputed": 0}, 0, 0.0, [],
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


class argparse_ns:
    def __init__(self, **kwargs):
        self.__dict__.update(kwargs)


if __name__ == "__main__":
    unittest.main()
