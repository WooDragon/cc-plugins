#!/usr/bin/env python3
"""render_inline.py -- inline markdown span conversion for render.py.

Split out of render.py (module-size nudge) -- see render_common.py's
docstring for the split rationale. This module owns the one part of the
renderer with a real correctness hazard: href purity (module docstring
section "href purity" in render.py), i.e. never letting a full-width prose
annotation leak into an href, and never truncating a legitimate CJK path
out of one.

`[text](url)` links get their URL from a balanced-paren scan (the URL is
whatever the markdown syntax's own `(` `)` pair delimits, verbatim,
including any raw CJK it legitimately contains). Bare `https?://` URLs are
matched against an ALLOW-list character class -- URL-legal ASCII plus the
CJK Unified Ideographs ranges -- so full-width/CJK punctuation is simply
not a class member and a match naturally stops there, with no separate
punctuation deny-list to keep in sync.
"""

import html
import re

from _sanitize import sanitize_text

# ALLOW-list of bare-URL characters: URL-legal ASCII plus CJK Unified
# Ideographs (Basic block 一-鿿, Extension A 㐀-䶿). Full-width/CJK
# punctuation is not a member, so matching stops there by construction.
_BARE_URL_CHARS = r"A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%一-鿿㐀-䶿"
_BARE_URL_RE = re.compile(r"https?://[" + _BARE_URL_CHARS + r"]+")
_URL_TRAILING_PUNCT = ".,;:]}>'\""


def _strip_url_trailing_punct(url: str) -> str:
    """Strip common ASCII sentence-trailing punctuation off a matched bare
    URL. A trailing ')' is only stripped when it is unbalanced within the
    matched substring itself, so a URL that legitimately ends in a
    balanced parenthetical (e.g. a Wikipedia disambiguation page) survives
    intact."""
    while url:
        c = url[-1]
        if c == ")":
            if url.count("(") < url.count(")"):
                url = url[:-1]
                continue
            break
        if c in _URL_TRAILING_PUNCT:
            url = url[:-1]
            continue
        break
    return url


def _scan_balanced_url(s: str, start: int):
    """s[start] is the character right after the '(' of a markdown link.
    Scans forward tracking paren balance; returns (url, index_after_close)
    or None if no balanced close is found (or raw whitespace is hit --
    markdown link URLs don't contain literal unescaped whitespace)."""
    depth = 0
    i, n = start, len(s)
    while i < n:
        c = s[i]
        if c == "(":
            depth += 1
        elif c == ")":
            if depth == 0:
                return s[start:i], i + 1
            depth -= 1
        elif c.isspace():
            return None
        i += 1
    return None


def _render_link(label_raw: str, url_raw: str, allow_links: bool, label_is_url: bool = False) -> str:
    url = sanitize_text(url_raw)
    href = html.escape(url, quote=True)
    if label_is_url or not label_raw:
        label = href
    else:
        label = inline_convert(label_raw, allow_links=allow_links)
    return f'<a href="{href}">{label}</a>'


def inline_convert(text: str, allow_links: bool = True) -> str:
    """Single left-to-right scan converting `[text](url)` links, bare
    https?:// URLs, `` `code` `` spans and **bold** emphasis to HTML.
    Not a chain of regex substitutions -- a single pass avoids ordering
    hazards (bold containing a link, a URL adjacent to `**`, etc). Link
    labels are converted with allow_links=False so a link can never nest
    another link inside it."""
    text = sanitize_text(text)
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]

        if allow_links and c == "[":
            close = text.find("]", i + 1)
            if close != -1 and close + 1 < n and text[close + 1] == "(":
                scanned = _scan_balanced_url(text, close + 2)
                if scanned is not None:
                    url, end = scanned
                    out.append(_render_link(text[i + 1:close], url, allow_links=False))
                    i = end
                    continue

        if allow_links:
            m = _BARE_URL_RE.match(text, i)
            if m:
                url = _strip_url_trailing_punct(m.group(0))
                out.append(_render_link(url, url, allow_links=False, label_is_url=True))
                i += len(url)
                continue

        if c == "`":
            close = text.find("`", i + 1)
            if close != -1:
                out.append(f"<code>{html.escape(text[i + 1:close], quote=True)}</code>")
                i = close + 1
                continue

        if text.startswith("**", i):
            close = text.find("**", i + 2)
            if close != -1:
                out.append(f"<strong>{inline_convert(text[i + 2:close], allow_links=allow_links)}</strong>")
                i = close + 2
                continue

        out.append(html.escape(c, quote=True))
        i += 1
    return "".join(out)
