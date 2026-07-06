#!/usr/bin/env python3
"""verify_report_html.py -- deterministic mechanical gate for research-publisher.

Contract under test: report.html = f(report.md), zero new facts. This script
cannot verify "zero new facts" (that's semantic, left to Lead's visual review)
but it CAN mechanically verify the structural half of the contract:

1. Link conservation: every URL in report.md's prose (both [text](url) and
   bare http(s):// forms; fenced code blocks and inline code spans excluded)
   must survive into report.html's href/src attributes (after HTML-unescaping,
   since markdown "&" in a URL renders as "&amp;" in HTML). Scoped to report.md
   only -- references.md is a separate deliverable the publisher does not
   render into report.html, so its URLs are NOT in the must-conserve set.
2. Section conservation: every ## / ### heading in report.md must have its
   text appear somewhere in report.html's rendered text.
3. Self-containment: no external <link>/<script>/<img> resource loads, no
   external @import -- report.html must open offline as a single file.
   (Content-level <a href="http..."> reference links are legitimate and NOT
   flagged -- those are the report's citations, not resource loads.)
4. Zero-JS house style (bonus): no <script> tag at all, external or not.

Stdlib only. Three-state exit code, mirroring harvest.py's cmd_check /
gate_check.py convention:

    0 = PASS   (all checks satisfied)
    1 = FAIL   (structural loss or self-containment violation; details printed)
    2 = N/A    (report.html does not exist yet -- nothing to verify)

CLI:
    python3 verify_report_html.py <path>

<path> is either a deliverables/final/ directory (report.md, references.md,
report.html resolved by convention inside it) or a direct path to report.html
(report.md / references.md resolved as siblings in the same directory).
"""

import argparse
import html
import re
import sys
from pathlib import Path

_VERDICT_EXIT_CODES = {"PASS": 0, "FAIL": 1, "N_A": 2}

# Markdown link URL: `[text](url)` -- captured group is the URL, terminated
# at the first unescaped ')' or whitespace (URLs containing literal ')' are
# a rare edge case we intentionally don't chase -- correctness on the common
# case matters more than exhaustive coverage here).
_MD_LINK_URL_RE = re.compile(r"\[[^\]]*\]\((https?://[^\s)]+)\)")

# Bare http(s) URL not immediately preceded by "](" (i.e. not the URL portion
# of a markdown link we already captured above via _MD_LINK_URL_RE).
_BARE_URL_RE = re.compile(r"(?<!\]\()https?://[^\s)>\]]+")

# Fenced code blocks, stripped before header/link scanning so that '#' inside
# code (shell comments, etc.) never masquerades as a markdown heading.
_CODE_FENCE_RE = re.compile(r"```.*?```", re.DOTALL)

# Inline code span (single backtick pair). Stripped ONLY on the URL-extraction
# path (not headings): a URL inside `...` renders as <code> plain text with no
# href, so it must not be counted as a must-conserve link.
_INLINE_CODE_RE = re.compile(r"`[^`]*`")

# ## or ### heading, but not #### or deeper (negative lookahead on the 4th #).
_HEADING_RE = re.compile(r"^(#{2,3})(?!#)\s+(.+?)\s*$", re.MULTILINE)

# href="..." or src="..." attribute value, single or double quoted.
_HTML_ATTR_RE = re.compile(r"""(?:href|src)\s*=\s*["']([^"']+)["']""", re.IGNORECASE)

_TAG_RE = re.compile(r"<[^>]+>")
_WHITESPACE_RE = re.compile(r"\s+")
_MD_LINK_TEXT_RE = re.compile(r"\[([^\]]*)\]\([^)]*\)")

# Match-normalization: keep only alphanumerics and CJK, drop everything else
# (punctuation, separators, whitespace, markdown emphasis markers). Applied
# identically to both md heading text and HTML text before the containment
# check, so display-layer typographic rewrites don't cause false positives:
#   - "primary_job" -> "primaryjob" on BOTH sides (underscore dropped) so an
#     identifier heading matches whether or not it kept the underscore;
#   - " — " (em dash) and " · " (middle dot) both vanish, so a separator
#     swap during rendering ("层 1 — X" -> "层 1 · X") still matches.
# CJK range 㐀-鿿 covers CJK Unified Ideographs + Extension A, which
# spans the Han characters that appear in these reports.
_MATCH_STRIP_RE = re.compile(r"[^0-9a-z㐀-鿿]+")


def _normalize_for_match(text: str) -> str:
    """Reduce text to a comparison key: lowercase, alphanumerics + CJK only.

    Shared by md-side (needle) and HTML-side (haystack) so the section
    containment check compares semantic content, not exact byte sequences.
    This does NOT weaken real-loss detection: an entirely dropped section's
    substantive characters still won't appear anywhere in the normalized
    HTML, so it still fails to match. It only tolerates lossless typographic
    rewrites of a heading that IS present (separator/punctuation changes,
    identifier underscores kept-or-dropped).
    """
    return _MATCH_STRIP_RE.sub("", text.lower())


def _strip_trailing_punct(url: str) -> str:
    """Strip trailing sentence punctuation markdown authors commonly leave
    stuck to a bare URL (e.g. "see https://x.com/a." at end of a sentence)."""
    return url.rstrip(".,;:)]}>'\"")


def _normalize_url(url: str) -> str:
    url = _strip_trailing_punct(url.strip())
    if url.endswith("/") and url.count("/") > 2:
        url = url[:-1]
    return url


def extract_md_urls(text: str) -> set:
    """Extract all URLs referenced from markdown text: link-form and bare.

    Both fenced code blocks (```...```) AND inline code spans (`...`) are
    stripped first: a URL inside code -- an example curl command, a repo URL
    in a config snippet, an API endpoint written as `https://api.example/v1`
    -- is not a citation. Per report-html-guide.md the publisher renders code
    as arch-diagram/<pre> or <code> plain text and MUST NOT linkify its
    contents, so such URLs never get an href/src in the HTML. Counting them
    as "must-be-conserved links" would false-positive a correctly rendered
    report into an unsatisfiable FAIL (a deadlock trap the publisher cannot
    fix). Only prose-level links must survive.

    NOTE: this code-span stripping is intentionally confined to the URL
    path. extract_md_headings does NOT strip inline code, because a heading
    like `## 关于 primary_job` needs its identifier text preserved for the
    _normalize_for_match comparison (see the underscore/em-dash fix).
    """
    body = _INLINE_CODE_RE.sub(" ", strip_code_fences(text))
    urls = set()
    for m in _MD_LINK_URL_RE.finditer(body):
        urls.add(_normalize_url(m.group(1)))
    for m in _BARE_URL_RE.finditer(body):
        urls.add(_normalize_url(_strip_trailing_punct(m.group(0))))
    return urls


def extract_html_urls(html_text: str) -> set:
    """Extract href/src attribute values from HTML, unescaped and normalized.

    html.unescape() is the crux fix: markdown "&" in a URL renders as
    "&amp;" in HTML attributes, so comparing raw attribute strings against
    markdown URLs would false-positive on every ampersand-bearing URL.
    """
    urls = set()
    for m in _HTML_ATTR_RE.finditer(html_text):
        urls.add(_normalize_url(html.unescape(m.group(1))))
    return urls


def strip_code_fences(md_text: str) -> str:
    return _CODE_FENCE_RE.sub("", md_text)


def extract_md_headings(md_text: str) -> list:
    """Extract ## / ### heading texts from markdown, code fences excluded.

    Heading text keeps its raw characters (only markdown link syntax is
    collapsed to its label); all punctuation/emphasis/separator normalization
    is deferred to _normalize_for_match at comparison time, applied identically
    to both sides. In particular underscores are preserved here so identifier
    headings like "primary_job" are not mangled before the shared normalizer
    runs.
    """
    body = strip_code_fences(md_text)
    headings = []
    for m in _HEADING_RE.finditer(body):
        text = m.group(2)
        text = _MD_LINK_TEXT_RE.sub(lambda lm: lm.group(1), text)
        text = _WHITESPACE_RE.sub(" ", text).strip()
        if text:
            headings.append(text)
    return headings


def html_to_text(html_text: str) -> str:
    """Strip tags to plain text for substring containment checks.

    Not a full HTML parser -- deliberately simple, matching this project's
    stdlib-only, mechanically-verifiable-by-inspection style (see
    gate_check.py / harvest.py precedent). Good enough for "is this heading
    text present somewhere in the rendered page."
    """
    # Drop <style>/<script> blocks wholesale -- their content is CSS/JS, not
    # rendered prose, and could otherwise spuriously contain heading-like text.
    no_style = re.sub(r"<style[^>]*>.*?</style>", " ", html_text, flags=re.DOTALL | re.IGNORECASE)
    no_script = re.sub(r"<script[^>]*>.*?</script>", " ", no_style, flags=re.DOTALL | re.IGNORECASE)
    no_comments = re.sub(r"<!--.*?-->", " ", no_script, flags=re.DOTALL)
    text = _TAG_RE.sub(" ", no_comments)
    text = html.unescape(text)
    return _WHITESPACE_RE.sub(" ", text).strip()


_EXTERNAL_RESOURCE_RE = re.compile(
    r"""<(link|script|img)\b[^>]*\b(?:href|src)\s*=\s*["'](https?://[^"']+)["'][^>]*>""",
    re.IGNORECASE,
)
_IMPORT_URL_RE = re.compile(r"@import\s+(?:url\()?[\"']?(https?://[^\"')\s]+)", re.IGNORECASE)
_SCRIPT_TAG_RE = re.compile(r"<script\b", re.IGNORECASE)


def find_external_resources(html_text: str) -> list:
    """Return violations: external <link>/<script>/<img> resource loads or
    @import url(http...). Content-level <a href="http..."> reference links
    are NOT flagged here -- those are legitimate citations, not resource
    fetches; see the caller for the <a> exclusion rationale.
    """
    violations = []
    for m in _EXTERNAL_RESOURCE_RE.finditer(html_text):
        tag, url = m.group(1).lower(), m.group(2)
        violations.append(f'<{tag}> loads external resource: {url}')
    for m in _IMPORT_URL_RE.finditer(html_text):
        violations.append(f"@import loads external resource: {m.group(1)}")
    return violations


def find_script_tags(html_text: str) -> list:
    """House style is zero-JS. Any <script> tag at all is a violation,
    regardless of whether its src is external or inline."""
    return [m.group(0) for m in _SCRIPT_TAG_RE.finditer(html_text)]


def resolve_paths(path_arg: str):
    """Resolve (report_md, references_md_or_None, report_html) from either
    a deliverables/final/ directory or a direct report.html path.

    Returns None for report_html specifically when it does not exist yet --
    callers use that to signal the N/A verdict (nothing to verify yet).
    """
    p = Path(path_arg).resolve()
    if p.is_dir():
        directory = p
        report_html = directory / "report.html"
    else:
        directory = p.parent
        report_html = p

    report_md = directory / "report.md"
    references_md = directory / "references.md"

    return (
        report_md if report_md.exists() else None,
        references_md if references_md.exists() else None,
        report_html if report_html.exists() else None,
    )


def check_report_html(path_arg: str):
    """Returns (verdict, reason, details). verdict is exactly one of
    "PASS" / "FAIL" / "N_A". details is a list of human-readable strings
    (empty on PASS/N_A, itemized violations on FAIL).
    """
    # references.md is intentionally NOT unpacked/used here: the HTML is
    # strictly f(report.md), and references.md is an independent deliverable
    # (the full >=20-link bibliography) that the publisher does not render.
    # Requiring its links to survive into the HTML would be an unsatisfiable
    # FAIL. Link conservation is scoped to report.md's own links only.
    report_md_path, _references_md_path, report_html_path = resolve_paths(path_arg)

    if report_html_path is None:
        return "N_A", "report.html does not exist yet -- nothing to verify", []

    if report_md_path is None:
        return "N_A", "report.md not found alongside report.html -- cannot verify against a primary source", []

    md_text = report_md_path.read_text(encoding="utf-8")
    html_text = report_html_path.read_text(encoding="utf-8")

    details = []

    # 1. Link conservation (scoped to report.md only -- see note above)
    md_urls = extract_md_urls(md_text)
    html_urls = extract_html_urls(html_text)
    missing_urls = sorted(md_urls - html_urls)
    for url in missing_urls:
        details.append(f"missing link: {url} (present in report.md, absent from report.html)")

    # 2. Section conservation (compare on normalized keys so lossless
    #    display-layer typography -- separator swaps, punctuation -- doesn't
    #    false-positive; see _normalize_for_match).
    md_headings = extract_md_headings(md_text)
    html_match_key = _normalize_for_match(html_to_text(html_text))
    missing_headings = [
        h for h in md_headings if _normalize_for_match(h) not in html_match_key
    ]
    for h in missing_headings:
        details.append(f'missing section: "{h}" (## / ### heading in report.md, absent from report.html)')

    # 3. Self-containment
    for violation in find_external_resources(html_text):
        details.append(f"external resource: {violation}")

    # 4. Zero-JS house style
    for script_tag in find_script_tags(html_text):
        details.append(f"script tag present (house style is zero-JS): {script_tag}")

    if details:
        reason = (
            f"{len(missing_urls)} missing link(s), {len(missing_headings)} missing section(s), "
            f"{len(details) - len(missing_urls) - len(missing_headings)} self-containment/JS violation(s)"
        )
        return "FAIL", reason, details

    reason = f"{len(md_urls)} link(s) conserved, {len(md_headings)} section(s) conserved, self-contained OK"
    return "PASS", reason, []


def main():
    parser = argparse.ArgumentParser(prog="verify_report_html.py")
    parser.add_argument(
        "path",
        help="deliverables/final/ directory, or a direct path to report.html",
    )
    args = parser.parse_args()

    verdict, reason, details = check_report_html(args.path)
    print(f"{verdict}: {reason}")
    for line in details:
        print(f"  - {line}")
    sys.exit(_VERDICT_EXIT_CODES[verdict])


if __name__ == "__main__":
    main()
