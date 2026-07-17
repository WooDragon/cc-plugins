"""BDD coverage for render.py -- the deterministic report.md -> report.html
renderer that replaced research-publisher agent's probabilistic, hand-rolled
rendering. See scripts/render.py module docstring for the full contract
(supported markdown subset, ds: directive vocabulary, href purity rules,
anti-injection). This file exercises the renderer at both the function level
(render_document/inline_convert/tokenize) and, for a couple of cases, via
subprocess through the CLI, the same way a real Stage 7 delivery-gate
invocation would run it.
"""

import html
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import render  # noqa: E402
from render_common import RenderError, join_lines_prose  # noqa: E402
from render_inline import inline_convert  # noqa: E402
from _sanitize import sanitize_text  # noqa: E402

_SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "render.py"
_TEMPLATE = render.load_template()


def render_html(md_text: str) -> str:
    return render.render_report(md_text, _TEMPLATE)


# A single sample document exercising every ds: directive at least once, so
# the "each directive -> its component class appears" coverage and the
# conservation checks can share one fixture.
_SAMPLE_MD = """<!-- ds:hero eyebrow="Test Eyebrow" sub="Test sub headline" meta="tag-a;tag-b" theme=daylight -->
# Sample Report

> Intro callout line, with **bold** text.

## Overview

Intro paragraph with a [link](https://example.com/a) and a bare URL \
https://example.com/b。more prose after full-width punctuation.

<!-- ds:verdict-bar -->
- **结论**：可行 (green)
- **限制**：有保留 (amber)

<!-- ds:card-grid -->
- **要点一**：说明一
- **要点二**：说明二

<!-- ds:pain-list -->
- **问题一**：描述一
- **问题二**：描述二

<!-- ds:phase-timeline -->
1. **Phase 0 · 起步**：说明
2. [optional] **Phase 1 · 可选**：说明

<!-- ds:data-grid -->
- **数据项** | 来源 | ready: 已就绪说明

<!-- ds:arch-diagram -->
```text
box -> box
```

<!-- ds:callout tone=amber -->
关键提示段落。

<!-- ds:badge type=credibility level=5 -->
### 高可信度小节

内容文本。

<!-- ds:badge type=decision-record -->
### 内部设计输入

决策记录内容第一段。

<!-- ds:appendix -->
## 附录区

已归档内容说明。
"""


# ============================================================================
# Differential conservation helpers (TestConservationDifferential) --
# deliberately independent of render.py's own tokenizer / render_inline.py's
# href-purity logic, so a real second implementation is what's being
# cross-checked against, not the same code path run twice.
# ============================================================================

# Fullwidth/CJK punctuation blocks a bare URL match should stop at (General
# Punctuation U+3000-303F, Halfwidth/Fullwidth Forms U+FF00-FFEF) -- a
# deny-list, the mirror-image approach of render_inline.py's CJK-ideograph
# allow-list, but landing on the same practical truncation point.
_NAIVE_BARE_URL_RE = re.compile(r"https?://[^\s　-〿＀-￯]+")
_NAIVE_BRACKET_LINK_RE = re.compile(r"\]\(([^)]+)\)")
_NAIVE_TRAILING_PUNCT_RE = re.compile(r"""[.,;:'")\]}>]+$""")


def _naive_headings(md_text: str, level: int):
    """Independent heading-text extractor: a plain per-line regex, not
    render.py's stateful tokenizer. `level` is 2 or 3 (## / ###); the
    negative lookahead keeps a level-2 match from also matching a
    level-3 line."""
    prefix = "#" * level
    pattern = re.compile(r"^" + re.escape(prefix) + r"(?!#)\s+(.*?)\s*$")
    out = []
    for line in md_text.split("\n"):
        m = pattern.match(line.strip())
        if m:
            out.append(m.group(1).strip())
    return out


def _naive_link_urls(md_text: str):
    """Independent link-URL extractor: naive non-balanced bracket-link
    capture plus a deny-list bare-URL regex, each independently stripped
    of trailing ASCII punctuation -- not render_inline.py's balanced-paren
    scan / CJK allow-list / paren-balance-aware trailing-punct stripper.
    Returns a set (this is a set-membership differential check, not a
    count)."""
    urls = set()
    for m in _NAIVE_BRACKET_LINK_RE.finditer(md_text):
        urls.add(_NAIVE_TRAILING_PUNCT_RE.sub("", m.group(1).strip()))
    for m in _NAIVE_BARE_URL_RE.finditer(md_text):
        urls.add(_NAIVE_TRAILING_PUNCT_RE.sub("", m.group(0)))
    return urls


_BADGE_SPAN_RE = re.compile(r'\s*<span class="tag[^"]*">.*?</span>')
_ANY_TAG_RE = re.compile(r"<[^>]+>")


def _html_heading_texts(html_out: str, tag: str):
    """Extract the visible text of every `<h{tag}>...</h{tag}>` in the
    rendered output, with the credibility-badge span (if any) removed
    first -- that span's own text is not part of the markdown heading and
    must not be compared as if it were."""
    out = []
    for m in re.finditer(rf"<{tag}[^>]*>(.*?)</{tag}>", html_out, re.DOTALL):
        inner = _BADGE_SPAN_RE.sub("", m.group(1))
        inner = _ANY_TAG_RE.sub("", inner)
        out.append(html.unescape(inner).strip())
    return out


def _html_hrefs(html_out: str):
    return {html.unescape(m) for m in re.findall(r'href="([^"]*)"', html_out)}


class TestSanitize(unittest.TestCase):
    def test_strips_zero_width_characters(self):
        self.assertEqual(sanitize_text("a​b﻿c"), "abc")

    def test_strips_bidi_control_characters(self):
        self.assertEqual(sanitize_text("a‮b⁦c⁩d"), "abcd")

    def test_normalizes_quote_spoof_double(self):
        # U+2033 DOUBLE PRIME looks like a closing double-quote but isn't one.
        self.assertEqual(sanitize_text("″quoted″"), '"quoted"')

    def test_normalizes_quote_spoof_single(self):
        # U+2032 PRIME looks like an apostrophe but isn't one.
        self.assertEqual(sanitize_text("it′s"), "it's")

    def test_ordinary_curly_quotes_untouched(self):
        # Legitimate typographic quotes are prose, not spoofing -- must survive.
        text = "“hello” and ‘hi’"
        self.assertEqual(sanitize_text(text), text)

    def test_idempotent(self):
        text = "a​b‮″quoted″"
        once = sanitize_text(text)
        twice = sanitize_text(once)
        self.assertEqual(once, twice)

    def test_empty_string(self):
        self.assertEqual(sanitize_text(""), "")


class TestHrefPurity(unittest.TestCase):
    def test_bracket_link_full_width_annotation_stays_outside_href(self):
        out = inline_convert("[text](https://a.com)（全角附注）")
        # The annotation must render as plain text AFTER the closing </a>,
        # not leak into the href attribute value itself.
        href_start = out.index('href="') + len('href="')
        href_value = out[href_start:out.index('"', href_start)]
        self.assertEqual(href_value, "https://a.com")
        self.assertTrue(out.endswith("（全角附注）"))

    def test_bare_url_truncates_at_full_width_punctuation(self):
        out = inline_convert("详见 https://a.com/path。后续文字")
        href_start = out.index('href="') + len('href="')
        href_value = out[href_start:out.index('"', href_start)]
        self.assertEqual(href_value, "https://a.com/path")

    def test_bracket_link_preserves_legitimate_cjk_path(self):
        out = inline_convert("[中文路径](https://zh.wikipedia.org/wiki/中国)")
        href_start = out.index('href="') + len('href="')
        href_value = out[href_start:out.index('"', href_start)]
        self.assertEqual(href_value, "https://zh.wikipedia.org/wiki/中国")

    def test_bare_url_with_balanced_trailing_paren_survives(self):
        out = inline_convert("见 https://en.wikipedia.org/wiki/Diff_(disambiguation) 一节")
        href_start = out.index('href="') + len('href="')
        href_value = out[href_start:out.index('"', href_start)]
        self.assertEqual(href_value, "https://en.wikipedia.org/wiki/Diff_(disambiguation)")

    def test_bare_url_with_unbalanced_ascii_paren_stripped(self):
        out = inline_convert("text (https://a.com) more")
        href_start = out.index('href="') + len('href="')
        href_value = out[href_start:out.index('"', href_start)]
        self.assertEqual(href_value, "https://a.com")

    def test_link_cannot_nest_another_link(self):
        # Label text that itself looks like a bare URL must not become a
        # second <a> inside the outer one.
        out = inline_convert("[https://inner.example](https://outer.example)")
        self.assertEqual(out.count("<a "), 1)


class TestHrefSchemeAllowlist(unittest.TestCase):
    """Non-allow-listed URL schemes downgrade to plain text (label
    survives, href discarded) instead of failing the whole render -- a
    poisoned link from harvested source material shouldn't take the
    report down, but it also must never reach an href."""

    def test_javascript_scheme_downgrades_to_plain_text(self):
        out = inline_convert("[click me](javascript:alert(1))")
        self.assertNotIn("<a ", out)
        self.assertNotIn("javascript:", out)
        self.assertEqual(out, "click me")

    def test_data_scheme_downgrades_to_plain_text(self):
        out = inline_convert('[img](data:text/html,<script>alert(1)</script>)')
        self.assertNotIn("<a ", out)
        self.assertNotIn("data:", out)

    def test_vbscript_scheme_downgrades_to_plain_text(self):
        out = inline_convert("[x](vbscript:msgbox(1))")
        self.assertNotIn("<a ", out)

    def test_file_scheme_downgrades_to_plain_text(self):
        out = inline_convert("[local](file:///etc/passwd)")
        self.assertNotIn("<a ", out)
        self.assertNotIn("file:", out)

    def test_scheme_check_is_case_insensitive(self):
        out = inline_convert("[x](JavaScript:alert(1))")
        self.assertNotIn("<a ", out)

    def test_http_https_mailto_remain_links(self):
        self.assertIn("<a ", inline_convert("[a](http://example.com)"))
        self.assertIn("<a ", inline_convert("[a](https://example.com)"))
        self.assertIn("<a ", inline_convert("[a](mailto:test@example.com)"))

    def test_relative_path_has_no_scheme_and_stays_a_link(self):
        out = inline_convert("[rel](/a/b/c)")
        self.assertIn('href="/a/b/c"', out)

    def test_anchor_link_has_no_scheme_and_stays_a_link(self):
        out = inline_convert("[jump](#section-1)")
        self.assertIn('href="#section-1"', out)

    def test_protocol_relative_url_has_no_scheme_and_stays_a_link(self):
        out = inline_convert("[cdn](//cdn.example.com/x.js)")
        self.assertIn('href="//cdn.example.com/x.js"', out)

    def test_zero_width_spliced_scheme_still_caught(self):
        # sanitize_text() strips zero-width characters *before* the scheme
        # check runs, so "java<ZWSP>script:" can't dodge the allow-list by
        # smuggling an invisible character into the scheme token.
        out = inline_convert("[x](java​script:alert(1))")
        self.assertNotIn("<a ", out)


class TestGfmLinkTitleUnsupported(unittest.TestCase):
    def test_double_quoted_title_fails_loud(self):
        with self.assertRaises(RenderError):
            inline_convert('[text](https://example.com "a title")')

    def test_single_quoted_title_fails_loud(self):
        with self.assertRaises(RenderError):
            inline_convert("[text](https://example.com 'a title')")


class TestPhysicalLineJoin(unittest.TestCase):
    """_join_pairwise's boundary rule: a space is inserted at every
    physical-line-join boundary except a CJK-ideograph <-> CJK-ideograph
    one (correct Chinese typography has no inter-word spaces)."""

    def test_bold_lead_plus_continuation_gets_a_space(self):
        self.assertEqual(join_lines_prose(["**结论**", "可行，理由如下"]), "**结论** 可行，理由如下")

    def test_sentence_final_ascii_period_plus_continuation_gets_a_space(self):
        self.assertEqual(join_lines_prose(["Done.", "Next sentence."]), "Done. Next sentence.")

    def test_sentence_final_fullwidth_period_plus_continuation_gets_a_space(self):
        self.assertEqual(join_lines_prose(["第一句话结束。", "第二句延续"]), "第一句话结束。 第二句延续")

    def test_cjk_to_cjk_boundary_gets_no_space(self):
        self.assertEqual(join_lines_prose(["纯中文", "续行也是中文"]), "纯中文续行也是中文")

    def test_ascii_alnum_boundary_still_gets_a_space(self):
        self.assertEqual(join_lines_prose(["wrapped English", "continues here"]), "wrapped English continues here")

    def test_list_item_wrap_with_bold_lead_continuation(self):
        md = "# Title\n\n## Section\n\n- **要点**\n  续行内容\n"
        out = render_html(md)
        self.assertIn("<strong>要点</strong> 续行内容", out)


class TestHorizontalRuleIgnored(unittest.TestCase):
    def test_bare_dashes_line_produces_no_output_and_no_error(self):
        md = "# Title\n\n## Section\n\nBefore.\n\n---\n\nAfter.\n"
        out = render_html(md)
        section = re.search(r"<section\b.*?</section>", out, re.DOTALL).group(0)
        # The two paragraphs must be adjacent siblings -- no <hr>, and no
        # stray "---" text node, sitting in the seam between them (the CSS
        # in the surrounding template legitimately contains "---" as a
        # comment-banner decoration, so the check is scoped to the section
        # body, not the whole document).
        self.assertIn("<p>Before.</p><p>After.</p>", section)
        self.assertNotIn("<hr", section)
        self.assertNotIn("---", section)


class TestConservation(unittest.TestCase):
    """h2/h3 counts and link set conserved 1:1 between report.md and
    report.html for the sample document."""

    @classmethod
    def setUpClass(cls):
        cls.html = render_html(_SAMPLE_MD)

    def test_h2_count_conserved(self):
        # "## Overview" + "## 附录区"
        self.assertEqual(self.html.count("<h2>"), 2)

    def test_h3_count_conserved(self):
        # "### 高可信度小节" + "### 内部设计输入"
        self.assertEqual(self.html.count("<h3"), 2)

    def test_bracket_link_present(self):
        self.assertIn('href="https://example.com/a"', self.html)

    def test_bare_url_present_and_truncated(self):
        self.assertIn('href="https://example.com/b"', self.html)

    def test_no_script_tag(self):
        self.assertNotIn("<script", self.html)

    def test_no_external_resource_refs(self):
        import re

        self.assertEqual(
            re.findall(r'<(?:link|img)\b[^>]*\bhttps?://', self.html), []
        )

    def test_theme_override_applied(self):
        self.assertIn('data-theme="daylight"', self.html)

    def test_hero_fields_present(self):
        self.assertIn("Test Eyebrow", self.html)
        self.assertIn("Test sub headline", self.html)
        self.assertIn("<span>tag-a</span>", self.html)
        self.assertIn("<span>tag-b</span>", self.html)


class TestDirectiveClasses(unittest.TestCase):
    """Each ds: directive in the sample document produces its mapped
    component class in the output."""

    @classmethod
    def setUpClass(cls):
        cls.html = render_html(_SAMPLE_MD)

    def test_verdict_bar(self):
        self.assertIn('class="verdict-bar"', self.html)
        self.assertIn('class="verdict-value green"', self.html)
        self.assertIn('class="verdict-value amber"', self.html)

    def test_card_grid(self):
        self.assertIn('class="card-grid"', self.html)
        self.assertIn('class="card"', self.html)

    def test_pain_list(self):
        self.assertIn('class="pain-list"', self.html)
        self.assertIn('class="pain-item"', self.html)

    def test_phase_timeline(self):
        self.assertIn('class="phase-timeline"', self.html)
        self.assertIn('class="phase-dot optional"', self.html)
        self.assertIn('class="phase-name optional-label"', self.html)

    def test_data_grid(self):
        self.assertIn('class="data-grid"', self.html)
        self.assertIn('class="data-status ready"', self.html)

    def test_arch_diagram(self):
        self.assertIn('class="arch-diagram"', self.html)
        self.assertIn("box -&gt; box", self.html)

    def test_callout_with_tone(self):
        self.assertIn("var(--signal-amber)", self.html)
        self.assertIn("关键提示段落", self.html)

    def test_credibility_badge(self):
        self.assertIn('class="tag tag-green"', self.html)
        self.assertIn("最高可信度", self.html)

    def test_decision_record(self):
        self.assertIn('class="decision-record"', self.html)
        self.assertIn('class="decision-record-badge"', self.html)

    def test_appendix(self):
        self.assertIn('class="archived-appendix"', self.html)
        self.assertIn("已归档 · 已放弃路线", self.html)


class TestIdempotence(unittest.TestCase):
    def test_byte_identical_across_renders(self):
        first = render_html(_SAMPLE_MD)
        second = render_html(_SAMPLE_MD)
        self.assertEqual(first, second)

    def test_no_timestamps_or_random_markers(self):
        # A cheap structural proxy: rendering the same input 5x never
        # diverges by even one byte.
        renders = {render_html(_SAMPLE_MD) for _ in range(5)}
        self.assertEqual(len(renders), 1)


class TestFailLoud(unittest.TestCase):
    def test_h4_heading_unsupported(self):
        md = "# Title\n\n## Section\n\n#### Too Deep\n\nbody\n"
        with self.assertRaises(RenderError):
            render_html(md)

    def test_missing_h1_title(self):
        md = "## Section\n\nbody\n"
        with self.assertRaises(RenderError):
            render_html(md)

    def test_no_sections_at_all(self):
        md = "# Title\n\nintro paragraph only, no ## section\n"
        with self.assertRaises(RenderError):
            render_html(md)

    def test_unknown_ds_directive(self):
        md = "# Title\n\n## Section\n\n<!-- ds:does-not-exist -->\nbody\n"
        with self.assertRaises(RenderError):
            render_html(md)

    def test_malformed_ds_comment(self):
        md = "# Title\n\n## Section\n\n<!-- ds card-grid -->\nbody\n"
        # "ds card-grid" (missing colon) is not a ds: prefix at all -> this
        # one is tolerated as an ordinary comment, not a directive. The
        # genuinely malformed case is a ds: prefix with broken param syntax.
        render_html(md)  # should not raise -- not a ds: comment at all
        bad = "# Title\n\n## Section\n\n<!-- ds:card-grid key=\"unterminated -->\nbody\n"
        with self.assertRaises(RenderError):
            render_html(bad)

    def test_directive_on_wrong_block_kind(self):
        md = "# Title\n\n## Section\n\n<!-- ds:card-grid -->\nplain paragraph, not a list\n"
        with self.assertRaises(RenderError):
            render_html(md)

    def test_dangling_directive_at_end_of_document(self):
        md = "# Title\n\n## Section\n\nbody\n\n<!-- ds:callout -->\n"
        with self.assertRaises(RenderError):
            render_html(md)

    def test_stacked_directives_without_intervening_block(self):
        md = "# Title\n\n## Section\n\n<!-- ds:callout -->\n<!-- ds:card-grid -->\n- item\n"
        with self.assertRaises(RenderError):
            render_html(md)

    def test_verdict_bar_wrong_item_count(self):
        md = "# Title\n\n## Section\n\n<!-- ds:verdict-bar -->\n- **仅一项**：值\n"
        with self.assertRaises(RenderError):
            render_html(md)

    def test_h3_before_first_h2(self):
        md = "# Title\n\n### Too Early\n\nbody\n\n## Section\n\nbody2\n"
        with self.assertRaises(RenderError):
            render_html(md)

    def test_multiple_h1_rejected(self):
        md = "# Title\n\n## Section\n\nbody\n\n# Second Title\n"
        with self.assertRaises(RenderError):
            render_html(md)

    def test_nested_unordered_list_rejected(self):
        md = "# Title\n\n## Section\n\n- item one\n  - nested sub item\n- item two\n"
        with self.assertRaises(RenderError):
            render_html(md)

    def test_nested_ordered_list_under_unordered_rejected(self):
        md = "# Title\n\n## Section\n\n- item one\n  1. nested ordered item\n- item two\n"
        with self.assertRaises(RenderError):
            render_html(md)

    def test_flat_list_with_unindented_next_item_is_not_nested(self):
        # A non-indented "-" line is a legitimate next flat item, not a
        # nested sub-list -- indentation is the only signal that
        # distinguishes the two, so this must NOT raise.
        md = "# Title\n\n## Section\n\n- item one\n- item two\n"
        render_html(md)


class TestCli(unittest.TestCase):
    def test_cli_writes_report_html_and_exits_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            md_path = Path(tmp) / "report.md"
            md_path.write_text("# Title\n\n## Section\n\nbody text.\n", encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(_SCRIPT), str(md_path)],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            out_html = Path(tmp) / "report.html"
            self.assertTrue(out_html.exists())
            self.assertIn("<h2>Section</h2>", out_html.read_text(encoding="utf-8"))

    def test_cli_fails_loud_with_nonzero_exit(self):
        with tempfile.TemporaryDirectory() as tmp:
            md_path = Path(tmp) / "report.md"
            md_path.write_text("no title at all\n", encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(_SCRIPT), str(md_path)],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("error:", result.stderr)


class TestConservationDifferential(unittest.TestCase):
    """Cross-checks render.py's rendered output against a *second,
    independently-written* extraction of headings and link URLs from the
    raw markdown (see the helpers above) -- full-set equality, not a count
    and not a spot-check. This is the differential-conservation guard
    called for in cc-plugins#125 review follow-up: it does not reimplement
    or gate on any runtime re-render/verify step (that mechanism was
    retired -- see 3c63387/#125 history), it only adds this test-side
    cross-check. Run once against the in-repo controlled fixture, once
    against a real delivered report.md (read-only; its rendered output is
    written under /private/tmp, never back into the research repo)."""

    def _assert_conserved(self, md_text, html_out):
        self.assertEqual(
            set(_naive_headings(md_text, 2)), set(_html_heading_texts(html_out, "h2"))
        )
        self.assertEqual(
            set(_naive_headings(md_text, 3)), set(_html_heading_texts(html_out, "h3"))
        )
        self.assertEqual(_naive_link_urls(md_text), _html_hrefs(html_out))

    def test_controlled_fixture(self):
        self._assert_conserved(_SAMPLE_MD, render_html(_SAMPLE_MD))

    def test_real_delivered_report(self):
        report_path = Path(
            "/Users/woodragon/Work/research/projects/"
            "企业ai网关治理-dlp与多租户落地调研/deliverables/final/report.md"
        )
        if not report_path.is_file():
            self.skipTest(f"real delivered report fixture not present: {report_path}")
        md_text = report_path.read_text(encoding="utf-8")  # read-only
        html_out = render_html(md_text)

        out_dir = Path(tempfile.mkdtemp(prefix="dr-render-conservation-", dir="/private/tmp"))
        (out_dir / "report.html").write_text(html_out, encoding="utf-8")

        self._assert_conserved(md_text, html_out)


if __name__ == "__main__":
    unittest.main()
