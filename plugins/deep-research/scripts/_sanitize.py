#!/usr/bin/env python3
"""_sanitize.py -- shared anti-injection text cleaner for deep-research.

Untrusted text can enter the pipeline from two directions: external search
results (harvester writing source titles/labels into fetch-report.md) and
report.md prose (render.py turning it into report.html). Both directions
funnel through this single module so the cleaning rule has exactly one
definition, not two that can drift apart.

Threats addressed (deterministic, stdlib-only, no false-positive risk on
ordinary CJK/English prose):

1. **Zero-width characters** (U+200B ZERO WIDTH SPACE .. U+200F RIGHT-TO-LEFT
   MARK, U+FEFF ZERO WIDTH NO-BREAK SPACE / BOM): invisible in every renderer,
   used to smuggle payloads past human review or to break up a keyword so
   naive string matching misses it. Stripped outright -- they carry no
   legitimate display semantics in report prose.
2. **Bidirectional control characters** (U+202A..U+202E explicit
   embedding/override, U+2066..U+2069 isolates): can reorder how surrounding
   text *displays* without changing its underlying bytes -- the classic
   "trojan source" trick (a URL or filename that reads safe but resolves
   differently). Stripped outright.
3. **Quote-spoofing lookalikes**: a curated set of Unicode code points that
   render as a quotation mark to a human but are not the real `"`/`'`
   `html.escape` knows how to neutralize. Left alone, a naive downstream
   string interpolation could be tricked into treating them as literal
   quotes; normalizing them to the plain ASCII quote they impersonate means
   they get the same escaping treatment as a real quote, and a human reading
   a "quoted attribution" can no longer be shown a mark that quietly isn't
   one. Ordinary curly quotes (U+2018/2019/201C/201D, the common CJK/English
   typographic quotes) are legitimate prose and are deliberately NOT touched.

This module does not do HTML escaping itself -- that stays the caller's job
(html.escape / render.py's own escape step) so sanitize_text() is safe to
call on plain text destined for either markdown or HTML output.

All character classes below are built from explicit \\uXXXX escapes (never
literal invisible/lookalike characters pasted into source) so the patterns
stay greppable, diffable, and immune to editor/encoding mangling.
"""

import re

# U+200B..U+200F: zero-width space/non-joiner/joiner, LTR/RTL marks.
# U+FEFF: zero-width no-break space / byte-order mark.
_ZERO_WIDTH_RE = re.compile("[​-‏﻿]")

# U+202A..U+202E: LRE/RLE/PDF/LRO/RLO explicit bidi formatting.
# U+2066..U+2069: LRI/RLI/FSI/PDI bidi isolates.
_BIDI_CONTROL_RE = re.compile("[‪-‮⁦-⁩]")

# Lookalike double-quote code points normalized to a plain ASCII `"`.
_SPOOFED_DOUBLE_QUOTES = (
    "ʺ"  # MODIFIER LETTER DOUBLE PRIME
    "ˮ"  # MODIFIER LETTER DOUBLE APOSTROPHE
    "״"  # HEBREW PUNCTUATION GERSHAYIM
    "″"  # DOUBLE PRIME
    "‶"  # REVERSED DOUBLE PRIME
    "〃"  # DITTO MARK
    "＂"  # FULLWIDTH QUOTATION MARK
)

# Lookalike single-quote/apostrophe code points normalized to a plain ASCII `'`.
_SPOOFED_SINGLE_QUOTES = (
    "ʹ"  # MODIFIER LETTER PRIME
    "ʼ"  # MODIFIER LETTER APOSTROPHE
    "′"  # PRIME
    "＇"  # FULLWIDTH APOSTROPHE
)

_QUOTE_SPOOF_RE = re.compile(
    "[" + _SPOOFED_DOUBLE_QUOTES + _SPOOFED_SINGLE_QUOTES + "]"
)
_DOUBLE_QUOTE_SET = frozenset(_SPOOFED_DOUBLE_QUOTES)


def _normalize_quote_spoofs(text: str) -> str:
    return _QUOTE_SPOOF_RE.sub(
        lambda m: '"' if m.group(0) in _DOUBLE_QUOTE_SET else "'", text
    )


def sanitize_text(text: str) -> str:
    """Strip zero-width/bidi-control characters and normalize quote-spoofing
    lookalikes. Idempotent: sanitize_text(sanitize_text(x)) == sanitize_text(x).
    """
    if not text:
        return text
    text = _ZERO_WIDTH_RE.sub("", text)
    text = _BIDI_CONTROL_RE.sub("", text)
    text = _normalize_quote_spoofs(text)
    return text


if __name__ == "__main__":
    import sys

    for line in sys.stdin:
        sys.stdout.write(sanitize_text(line))
