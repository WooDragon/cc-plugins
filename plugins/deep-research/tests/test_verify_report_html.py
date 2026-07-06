"""BDD coverage for verify_report_html.py -- the mechanical gate that checks
report.html = f(report.md) structurally (link conservation, section
conservation, self-containment). See scripts/verify_report_html.py module
docstring for the full contract; this file exercises it via subprocess, the
same way a real research-publisher self-check invocation would run it, so a
regression in the CLI wiring (argparse, exit codes, stdout format) is caught
too -- not just the underlying functions.
"""
import subprocess
import sys
from pathlib import Path

import pytest

_SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "verify_report_html.py"

_SAMPLE_MD = """# Sample Report

## Overview

Some intro text with a link to [Example Source](https://example.com/a?b=1).

## Findings

Findings text.

### Sub-finding detail

More detail here.
"""

_SAMPLE_HTML_GOOD = """<!DOCTYPE html>
<html lang="zh-CN" data-theme="midnight">
<head><meta charset="UTF-8"><title>Sample Report</title>
<style>body { color: #000; }</style>
</head>
<body>
<div class="page">
  <header class="hero"><h1>Sample Report</h1></header>
  <section class="section">
    <h2>Overview</h2>
    <p>Some intro text with a link to <a href="https://example.com/a?b=1">Example Source</a>.</p>
  </section>
  <section class="section">
    <h2>Findings</h2>
    <p>Findings text.</p>
    <h3>Sub-finding detail</h3>
    <p>More detail here.</p>
  </section>
</div>
</body>
</html>
"""


def run_verify(path_arg):
    result = subprocess.run(
        [sys.executable, str(_SCRIPT), str(path_arg)],
        capture_output=True,
        text=True,
    )
    return result.returncode, result.stdout, result.stderr


def _write(dir_path: Path, name: str, content: str) -> Path:
    p = dir_path / name
    p.write_text(content, encoding="utf-8")
    return p


class TestCleanHtmlPasses:
    """A correctly rendered report.html (all links present, all sections
    present, no external resources) must PASS with exit code 0."""

    def test_clean_html_exits_zero(self, tmp_path):
        _write(tmp_path, "report.md", _SAMPLE_MD)
        _write(tmp_path, "report.html", _SAMPLE_HTML_GOOD)

        code, stdout, _ = run_verify(tmp_path)

        assert code == 0
        assert "PASS" in stdout

    def test_clean_html_via_direct_report_html_path(self, tmp_path):
        _write(tmp_path, "report.md", _SAMPLE_MD)
        html_path = _write(tmp_path, "report.html", _SAMPLE_HTML_GOOD)

        code, stdout, _ = run_verify(html_path)

        assert code == 0
        assert "PASS" in stdout


class TestMissingLinkFails:
    """If report.html drops one of report.md's URLs, that's a structural
    loss of a citation -- must FAIL with exit code 1 and name the URL."""

    def test_dropped_url_fails_and_is_named(self, tmp_path):
        _write(tmp_path, "report.md", _SAMPLE_MD)
        html_without_link = _SAMPLE_HTML_GOOD.replace(
            '<a href="https://example.com/a?b=1">Example Source</a>',
            "Example Source",
        )
        _write(tmp_path, "report.html", html_without_link)

        code, stdout, _ = run_verify(tmp_path)

        assert code == 1
        assert "FAIL" in stdout
        assert "example.com/a?b=1" in stdout


class TestMissingSectionFails:
    """If report.html drops one of report.md's ## headings, that's a
    structural loss of a whole section -- must FAIL with exit code 1."""

    def test_dropped_heading_fails(self, tmp_path):
        _write(tmp_path, "report.md", _SAMPLE_MD)
        html_without_section = _SAMPLE_HTML_GOOD.replace(
            "<h3>Sub-finding detail</h3>\n    <p>More detail here.</p>\n  ",
            "",
        )
        _write(tmp_path, "report.html", html_without_section)

        code, stdout, _ = run_verify(tmp_path)

        assert code == 1
        assert "FAIL" in stdout
        assert "Sub-finding detail" in stdout


class TestExternalResourceFails:
    """Self-containment is a hard rule: no <script src="http...">, no
    <link href="http...">. Must FAIL with exit code 1. A content-level
    <a href="http..."> citation link must NOT trigger this (that's
    covered by TestCleanHtmlPasses, which already has such a link)."""

    def test_external_script_src_fails(self, tmp_path):
        _write(tmp_path, "report.md", _SAMPLE_MD)
        html_with_external_script = _SAMPLE_HTML_GOOD.replace(
            "</head>",
            '<script src="https://cdn.example.com/lib.js"></script></head>',
        )
        _write(tmp_path, "report.html", html_with_external_script)

        code, stdout, _ = run_verify(tmp_path)

        assert code == 1
        assert "FAIL" in stdout

    def test_external_link_href_fails(self, tmp_path):
        _write(tmp_path, "report.md", _SAMPLE_MD)
        html_with_external_link = _SAMPLE_HTML_GOOD.replace(
            "</head>",
            '<link rel="stylesheet" href="https://cdn.example.com/style.css"></head>',
        )
        _write(tmp_path, "report.html", html_with_external_link)

        code, stdout, _ = run_verify(tmp_path)

        assert code == 1
        assert "FAIL" in stdout


class TestAmpersandEscapingDoesNotFalsePositive:
    """The crux regression case: markdown URLs containing '&' render as
    '&amp;' in HTML attributes. Without html.unescape() before comparison,
    every such URL would false-positive as "missing". Must PASS."""

    def test_ampersand_url_escaped_in_html_still_passes(self, tmp_path):
        md = """# Report

## Section One

See [data source](https://x.com/a?b=1&c=2) for details.
"""
        html_content = """<!DOCTYPE html>
<html><head><title>Report</title><style></style></head>
<body>
<section class="section">
<h2>Section One</h2>
<p>See <a href="https://x.com/a?b=1&amp;c=2">data source</a> for details.</p>
</section>
</body></html>
"""
        _write(tmp_path, "report.md", md)
        _write(tmp_path, "report.html", html_content)

        code, stdout, _ = run_verify(tmp_path)

        assert code == 0
        assert "PASS" in stdout


class TestHeadingNormalizationNoFalsePositive:
    """Dogfooding regression: section conservation must compare semantic
    content, not exact bytes. Two lossless display-layer rewrites of a
    heading that IS present must still PASS -- underscore identifiers and
    separator swaps both bit real reports."""

    def test_underscore_identifier_heading_passes(self, tmp_path):
        # Bug 1: heading contains a code identifier ("primary_job"); the
        # underscore is a literal part of the token, not markdown emphasis.
        # HTML keeps the underscore -> must match, not be flagged missing.
        md = """# Report

## 关于 primary_job 与 non_goals 的分析

Body text.
"""
        html_content = """<!DOCTYPE html>
<html><head><title>Report</title><style></style></head>
<body>
<section class="section">
<h2>关于 primary_job 与 non_goals 的分析</h2>
<p>Body text.</p>
</section>
</body></html>
"""
        _write(tmp_path, "report.md", md)
        _write(tmp_path, "report.html", html_content)

        code, stdout, _ = run_verify(tmp_path)

        assert code == 0, stdout
        assert "PASS" in stdout

    def test_em_dash_rendered_as_middle_dot_passes(self, tmp_path):
        # Bug 2: md heading uses em dash " — "; publisher typesets it as
        # " · " (middle dot) in HTML. Heading body is intact -> must match.
        md = """# Report

### 层 1 — 纯 markdown skill（轻量方案）

Body text.
"""
        html_content = """<!DOCTYPE html>
<html><head><title>Report</title><style></style></head>
<body>
<section class="section">
<h3>层 1 · 纯 markdown skill（轻量方案）</h3>
<p>Body text.</p>
</section>
</body></html>
"""
        _write(tmp_path, "report.md", md)
        _write(tmp_path, "report.html", html_content)

        code, stdout, _ = run_verify(tmp_path)

        assert code == 0, stdout
        assert "PASS" in stdout

    def test_genuinely_dropped_section_still_fails(self, tmp_path):
        # Guardrail: normalization must NOT weaken real-loss detection. A
        # section whose substantive text is entirely absent from the HTML
        # must still FAIL even under the relaxed normalized comparison.
        md = """# Report

## 存在的章节

Present.

## 被整段删除的章节标题

Dropped.
"""
        html_content = """<!DOCTYPE html>
<html><head><title>Report</title><style></style></head>
<body>
<section class="section">
<h2>存在的章节</h2>
<p>Present.</p>
</section>
</body></html>
"""
        _write(tmp_path, "report.md", md)
        _write(tmp_path, "report.html", html_content)

        code, stdout, _ = run_verify(tmp_path)

        assert code == 1
        assert "FAIL" in stdout
        assert "被整段删除的章节标题" in stdout


class TestCodeFenceUrlsAreNotMustConserveLinks:
    """Copilot review regression: a URL inside a fenced code block (example
    curl command, repo URL in a config snippet) is not a citation. The
    publisher renders code blocks as <pre> plain text and MUST NOT linkify
    them, so such URLs have no href/src in the HTML. Counting them as
    must-conserve links would false-positive a correctly rendered report
    into an unsatisfiable FAIL. Only prose-level links must survive."""

    def test_code_block_url_not_required_prose_link_is(self, tmp_path):
        md = """# Report

## Setup

Install per the [official guide](https://example.com/docs), then run:

```bash
curl https://example.com/api/v1/install | sh
```

Done.
"""
        # HTML keeps the prose link as <a href>, but the code-block URL is
        # rendered as <pre> plain text -- deliberately NOT an <a href>.
        html_content = """<!DOCTYPE html>
<html><head><title>Report</title><style></style></head>
<body>
<section class="section">
<h2>Setup</h2>
<p>Install per the <a href="https://example.com/docs">official guide</a>, then run:</p>
<div class="arch-diagram"><pre>curl https://example.com/api/v1/install | sh</pre></div>
<p>Done.</p>
</section>
</body></html>
"""
        _write(tmp_path, "report.md", md)
        _write(tmp_path, "report.html", html_content)

        code, stdout, _ = run_verify(tmp_path)

        assert code == 0, stdout
        assert "PASS" in stdout

    def test_prose_link_still_required_even_with_code_block_present(self, tmp_path):
        # Guardrail: stripping code fences must not weaken detection of a
        # genuinely dropped prose link. Same md, but HTML omits the prose
        # link's <a href> -> must still FAIL and name the missing URL.
        md = """# Report

## Setup

Install per the [official guide](https://example.com/docs), then run:

```bash
curl https://example.com/api/v1/install | sh
```

Done.
"""
        html_content = """<!DOCTYPE html>
<html><head><title>Report</title><style></style></head>
<body>
<section class="section">
<h2>Setup</h2>
<p>Install per the official guide, then run:</p>
<div class="arch-diagram"><pre>curl https://example.com/api/v1/install | sh</pre></div>
<p>Done.</p>
</section>
</body></html>
"""
        _write(tmp_path, "report.md", md)
        _write(tmp_path, "report.html", html_content)

        code, stdout, _ = run_verify(tmp_path)

        assert code == 1
        assert "example.com/docs" in stdout


class TestInlineCodeSpanUrlsAreNotMustConserveLinks:
    """Copilot review round 3: same deadlock as fenced blocks, but for inline
    code spans (`...`). A URL written as `https://api.example/v1` renders to
    <code> plain text with no href, so it must not be a must-conserve link."""

    def test_inline_code_url_not_required_prose_link_is(self, tmp_path):
        md = """# Report

## API

Call the [public docs](https://example.com/docs) endpoint at `https://api.example.com/v1` directly.
"""
        # Prose link kept as <a href>; the inline-code URL rendered as <code>
        # plain text (no href) -- must not be flagged missing.
        html_content = """<!DOCTYPE html>
<html><head><title>Report</title><style></style></head>
<body>
<section class="section">
<h2>API</h2>
<p>Call the <a href="https://example.com/docs">public docs</a> endpoint at <code>https://api.example.com/v1</code> directly.</p>
</section>
</body></html>
"""
        _write(tmp_path, "report.md", md)
        _write(tmp_path, "report.html", html_content)

        code, stdout, _ = run_verify(tmp_path)

        assert code == 0, stdout
        assert "PASS" in stdout

    def test_prose_link_still_required_with_inline_code_url_present(self, tmp_path):
        # Guardrail: stripping inline code must not weaken detection of a
        # genuinely dropped prose link.
        md = """# Report

## API

Call the [public docs](https://example.com/docs) endpoint at `https://api.example.com/v1` directly.
"""
        html_content = """<!DOCTYPE html>
<html><head><title>Report</title><style></style></head>
<body>
<section class="section">
<h2>API</h2>
<p>Call the public docs endpoint at <code>https://api.example.com/v1</code> directly.</p>
</section>
</body></html>
"""
        _write(tmp_path, "report.md", md)
        _write(tmp_path, "report.html", html_content)

        code, stdout, _ = run_verify(tmp_path)

        assert code == 1
        assert "example.com/docs" in stdout


class TestReferencesMdNotInMustConserveSet:
    """Copilot review round 3 + user decision: link conservation is scoped to
    report.md ONLY. references.md is an independent deliverable (the full
    bibliography) the publisher does not render into the HTML, so its URLs
    must NOT be required to survive -- otherwise every report FAILs
    unsatisfiably. HTML is strictly f(report.md)."""

    def test_references_only_url_absent_from_html_still_passes(self, tmp_path):
        md = """# Report

## Overview

See [main source](https://example.com/main) for the core finding.
"""
        # references.md has an extra URL that never appears in the HTML.
        references = """# References

1. https://example.com/main
2. https://extra.example.com/only-in-references
"""
        html_content = """<!DOCTYPE html>
<html><head><title>Report</title><style></style></head>
<body>
<section class="section">
<h2>Overview</h2>
<p>See <a href="https://example.com/main">main source</a> for the core finding.</p>
</section>
</body></html>
"""
        _write(tmp_path, "report.md", md)
        _write(tmp_path, "references.md", references)
        _write(tmp_path, "report.html", html_content)

        code, stdout, _ = run_verify(tmp_path)

        assert code == 0, stdout
        assert "PASS" in stdout


class TestNoReportHtmlIsNotApplicable:
    """Before publisher has rendered anything, there's no report.html to
    check -- this is N/A (exit 2), not FAIL. Distinguishing "not done yet"
    from "done wrong" matters: N/A must never block a pipeline that simply
    hasn't reached Stage 7 Delivery yet."""

    def test_missing_report_html_exits_two(self, tmp_path):
        _write(tmp_path, "report.md", _SAMPLE_MD)

        code, stdout, _ = run_verify(tmp_path)

        assert code == 2
        assert "N_A" in stdout or "N/A" in stdout


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
