#!/usr/bin/env python3
"""render_common.py -- shared primitives for render.py's module split.

Split out of render.py (which grew past this repo's single-file size
nudge) the same way harvest.py factors into harvest_fetch.py /
harvest_search.py / harvest_journal.py: one script's concern per file,
still stdlib-only, still imported by simple `sys.path.insert` + bare
`import` (matching the harvest_* precedent, not a package).

Holds: the RenderError exception (raised across every render_*.py module),
the ASCII-alnum physical-line-join rule shared by paragraph and list-item
text, list marker regexes, list-item splitting (raw_items / raw wrapped
continuation folding), and the leading-**bold** item splitter used by every
ds: list-directive renderer (card-grid/pain-list/verdict-bar/
phase-timeline).
"""

import re


class RenderError(Exception):
    """Raised for any construct outside the supported markdown subset, or
    any malformed / unknown / misapplied ds: directive. Always fail-loud:
    render.py never silently drops or best-effort-guesses content."""


_UL_ITEM_RE = re.compile(r"^-\s+(.*)$")
_OL_ITEM_RE = re.compile(r"^(\d+)\.\s+(.*)$")


def _is_ascii_alnum(ch: str) -> bool:
    return ch.isascii() and ch.isalnum()


def _join_pairwise(a: str, b: str) -> str:
    """The one physical-line-join rule used everywhere a wrapped line
    needs to be reattached to the text before it: ASCII-alnum boundary on
    both sides gets a space (so wrapped English/identifier text doesn't
    fuse into one word), anything else (in particular CJK prose, which
    doesn't use inter-word spaces) is concatenated directly."""
    if a and b and _is_ascii_alnum(a[-1]) and _is_ascii_alnum(b[0]):
        return a + " " + b
    return a + b


def join_lines_prose(lines) -> str:
    text = ""
    for line in lines:
        text = _join_pairwise(text, line.strip())
    return text


def raw_items(lines, kind: str):
    """Split a ul/ol block's raw lines into item strings, folding
    unmarked continuation lines (wrapped list items) into the item they
    continue -- see render.py module docstring "List items may wrap...".
    """
    marker_re = _OL_ITEM_RE if kind == "ol" else _UL_ITEM_RE
    items = []
    cur = None
    for l in lines:
        s = l.strip()
        m = marker_re.match(s)
        if m:
            if cur is not None:
                items.append(cur)
            cur = m.group(2) if kind == "ol" else m.group(1)
        else:
            cur = _join_pairwise(cur, s) if cur is not None else s
    if cur is not None:
        items.append(cur)
    return items


_LEAD_BOLD_RE = re.compile(r"^\*\*(.+?)\*\*(.*)$", re.DOTALL)


def split_leading_bold(raw_item: str):
    """Split a list item's raw text into (bold_lead_or_None, rest). Used
    by every ds: list-directive renderer (card-grid/pain-list/
    verdict-bar/phase-timeline) that needs a title/label plus a body."""
    m = _LEAD_BOLD_RE.match(raw_item)
    if not m:
        return None, raw_item
    rest = re.sub(r"^[：:]\s*", "", m.group(2)).strip()
    return m.group(1), rest
