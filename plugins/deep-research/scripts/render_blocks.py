#!/usr/bin/env python3
"""render_blocks.py -- block-level and ds: directive renderers for render.py.

Split out of render.py (module-size nudge) -- see render_common.py's
docstring for the split rationale. This module owns every function that
turns one already-tokenized block/heading node into an HTML string:
baseline default renderers (plain paragraph/blockquote/table/list/code),
the five ds: list-directive renderers (card-grid, pain-list, verdict-bar,
phase-timeline, data-grid), the arch-diagram code-block wrapper, the
callout tone styling shared by blockquote/paragraph, and the two
heading-scoped renderers (`###` credibility/decision-record badges, `##`
appendix wrapping).

render.py itself owns tokenizing raw markdown into nodes and assembling
the document; this module never touches raw markdown text, only the
already-classified (kind, lines, directive) tuples the tokenizer produced.
"""

import html
import re

from render_common import RenderError, join_lines_prose, raw_items, split_leading_bold, _OL_ITEM_RE
from render_inline import inline_convert
from _sanitize import sanitize_text

# ============================================================================
# Baseline (no-directive) block renderers + ds:callout
# ============================================================================

_CALLOUT_TONE_STYLE = {
    "amber": ' style="border-left-color: var(--signal-amber); background: var(--signal-amber-dim);"',
    "red": ' style="border-left-color: var(--signal-red); background: var(--signal-red-dim);"',
    "green": ' style="border-left-color: var(--signal-green); background: var(--signal-green-dim);"',
}


def _callout_style(params: dict) -> str:
    tone = params.get("tone")
    if tone is None:
        return ""
    if tone not in _CALLOUT_TONE_STYLE:
        raise RenderError(f"ds:callout unknown tone={tone!r} (expected amber/red/green)")
    return _CALLOUT_TONE_STYLE[tone]


def render_paragraph(lines, directive) -> str:
    inner = f"<p>{inline_convert(join_lines_prose(lines))}</p>"
    if directive is None:
        return inner
    name, params = directive
    if name != "callout":
        raise RenderError(f"ds:{name} cannot be applied to a paragraph block")
    return f'<div class="callout"{_callout_style(params)}>{inner}</div>'


def render_blockquote(lines, directive) -> str:
    stripped = [re.sub(r"^>\s?", "", l) for l in lines]
    paragraphs, buf = [], []
    for s in stripped:
        if s.strip() == "":
            if buf:
                paragraphs.append(buf)
                buf = []
        else:
            buf.append(s)
    if buf:
        paragraphs.append(buf)
    if not paragraphs:
        raise RenderError("blockquote block produced zero paragraphs")
    body = "".join(f"<p>{inline_convert(join_lines_prose(p))}</p>" for p in paragraphs)
    style = ""
    if directive is not None:
        name, params = directive
        if name != "callout":
            raise RenderError(f"ds:{name} cannot be applied to a blockquote block")
        style = _callout_style(params)
    return f'<div class="callout"{style}>{body}</div>'


_TABLE_DELIM_RE = re.compile(r"^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$")


def render_table(lines, directive) -> str:
    if directive is not None:
        raise RenderError(f"ds:{directive[0]} cannot be applied to a table block")
    rows = []
    for l in lines:
        l = l.strip()
        if _TABLE_DELIM_RE.match(l):
            continue
        rows.append([c.strip() for c in l.strip("|").split("|")])
    if not rows:
        raise RenderError("table block produced zero rows")
    header, *body = rows
    thead = "<tr>" + "".join(f"<th>{inline_convert(c)}</th>" for c in header) + "</tr>"
    tbody = "".join(
        "<tr>" + "".join(f"<td>{inline_convert(c)}</td>" for c in row) + "</tr>" for row in body
    )
    return f'<div class="table-wrap"><table><thead>{thead}</thead><tbody>{tbody}</tbody></table></div>'


def render_pre(lines, directive) -> str:
    escaped = html.escape(sanitize_text("\n".join(lines)), quote=True)
    if directive is None:
        return f"<pre><code>{escaped}</code></pre>"
    name, _params = directive
    if name != "arch-diagram":
        raise RenderError(f"ds:{name} cannot be applied to a fenced code block")
    return f'<div class="arch-diagram"><pre>{escaped}</pre></div>'


# ============================================================================
# ds: list-directive renderers
# ============================================================================


def render_card_grid(items, _params) -> str:
    cards = []
    for it in items:
        bold, rest = split_leading_bold(it)
        title = bold if bold is not None else it
        body = f"<p>{inline_convert(rest)}</p>" if (bold is not None and rest) else ""
        cards.append(f'<div class="card"><div class="card-title">{inline_convert(title)}</div>{body}</div>')
    return '<div class="card-grid">' + "".join(cards) + "</div>"


def render_pain_list(items, _params) -> str:
    rows = []
    for it in items:
        bold, rest = split_leading_bold(it)
        name = bold if bold is not None else it
        desc = rest if bold is not None else ""
        rows.append(
            '<div class="pain-item">'
            f'<span class="pain-name">{inline_convert(name)}</span>'
            f'<span class="pain-desc">{inline_convert(desc)}</span>'
            "</div>"
        )
    return '<div class="pain-list">' + "".join(rows) + "</div>"


_TONE_SUFFIX_RE = re.compile(r"\s*\((green|amber)\)\s*$")


def render_verdict_bar(items, _params) -> str:
    if not (2 <= len(items) <= 3):
        raise RenderError(f"ds:verdict-bar requires 2-3 items, got {len(items)}")
    cells = []
    for it in items:
        bold, rest = split_leading_bold(it)
        if bold is None:
            raise RenderError(f"ds:verdict-bar item missing a leading **label**: {it!r}")
        tone = ""
        m = _TONE_SUFFIX_RE.search(rest)
        if m:
            tone = " " + m.group(1)
            rest = _TONE_SUFFIX_RE.sub("", rest)
        cells.append(
            '<div class="verdict-cell">'
            f'<span class="verdict-label">{inline_convert(bold)}</span>'
            f'<span class="verdict-value{tone}">{inline_convert(rest)}</span>'
            "</div>"
        )
    return '<div class="verdict-bar">' + "".join(cells) + "</div>"


_OPTIONAL_PREFIX_RE = re.compile(r"^\[optional\]\s*")


def render_phase_timeline(items, _params) -> str:
    if not items:
        raise RenderError("ds:phase-timeline has no items")
    phases = []
    last_idx = len(items) - 1
    for idx, it in enumerate(items):
        optional = bool(_OPTIONAL_PREFIX_RE.match(it))
        it2 = _OPTIONAL_PREFIX_RE.sub("", it)
        bold, rest = split_leading_bold(it2)
        if bold is None:
            raise RenderError(f"ds:phase-timeline item missing a leading **Phase name**: {it!r}")
        dot_cls = "phase-dot optional" if optional else "phase-dot"
        name_cls = "phase-name optional-label" if optional else "phase-name"
        line_html = "" if idx == last_idx else '<div class="phase-line"></div>'
        phases.append(
            '<div class="phase"><div class="phase-rail">'
            f'<div class="{dot_cls}"></div>{line_html}</div>'
            '<div class="phase-content">'
            f'<div class="{name_cls}">{inline_convert(bold)}</div>'
            f'<div class="phase-desc">{inline_convert(rest)}</div>'
            "</div></div>"
        )
    return '<div class="phase-timeline">' + "".join(phases) + "</div>"


_DATA_ITEM_RE = re.compile(
    r"^\*\*(.+?)\*\*\s*\|\s*(.*?)\s*\|\s*(ready|partial|missing)\s*:\s*(.*)$", re.DOTALL
)
_DATA_STATUS_GLYPH = {"ready": "●", "partial": "◐", "missing": "○"}


def render_data_grid(items, _params) -> str:
    if not items:
        raise RenderError("ds:data-grid has no items")
    cells = []
    for it in items:
        m = _DATA_ITEM_RE.match(it)
        if not m:
            raise RenderError(
                "ds:data-grid item must match '**Name** | source | status: desc' "
                f"with status in ready/partial/missing: {it!r}"
            )
        name, source, status, desc = m.groups()
        cells.append(
            '<div class="data-cell">'
            f'<div class="data-name">{inline_convert(name)}</div>'
            f'<div class="data-source">{inline_convert(source)}</div>'
            f'<div class="data-status {status}">{_DATA_STATUS_GLYPH[status]} {inline_convert(desc)}</div>'
            "</div>"
        )
    return '<div class="data-grid">' + "".join(cells) + "</div>"


_LIST_DIRECTIVE_RENDERERS = {
    "card-grid": render_card_grid,
    "pain-list": render_pain_list,
    "verdict-bar": render_verdict_bar,
    "phase-timeline": render_phase_timeline,
    "data-grid": render_data_grid,
}


def render_list(lines, kind, directive) -> str:
    items = raw_items(lines, kind)
    if not items:
        raise RenderError("list block produced zero items")
    if directive is None:
        body = "".join(f"<li>{inline_convert(it)}</li>" for it in items)
        if kind == "ol":
            first_num = _OL_ITEM_RE.match(lines[0].strip()).group(1)
            return f'<ol start="{first_num}">{body}</ol>'
        return f"<ul>{body}</ul>"
    name, params = directive
    fn = _LIST_DIRECTIVE_RENDERERS.get(name)
    if fn is None:
        raise RenderError(f"ds:{name} cannot be applied to a list block")
    return fn(items, params)


def render_element(node) -> str:
    if node[0] != "block":
        raise RenderError(f"unexpected node in section body: {node!r}")
    _, kind, lines, directive = node
    if kind == "p":
        return render_paragraph(lines, directive)
    if kind == "blockquote":
        return render_blockquote(lines, directive)
    if kind == "table":
        return render_table(lines, directive)
    if kind in ("ul", "ol"):
        return render_list(lines, kind, directive)
    if kind == "pre":
        return render_pre(lines, directive)
    raise RenderError(f"unsupported block kind: {kind}")  # pragma: no cover -- defensive


# ============================================================================
# Heading-scoped renderers: h3 badges/decision-record, h2 appendix
# ============================================================================

_CREDIBILITY_LABELS = {"5": "最高可信度", "4": "高可信度", "3": "中可信度", "2": "低可信度"}
_CREDIBILITY_TONE = {"5": "green", "4": "green", "3": "amber", "2": "red"}

_DECISION_RECORD_BADGE = (
    '<div class="decision-record-badge">内部设计输入 · DECISION RECORD（非外部采集事实）</div>'
)
_APPENDIX_BADGE = (
    '<div style="margin-bottom:1.5rem;"><span class="tag tag-amber">'
    "已归档 · 已放弃路线，仅留档不充当现行判据</span></div>"
)


def render_h3(text, directive) -> str:
    tag_html = ""
    if directive is not None:
        name, params = directive
        if name != "badge":
            raise RenderError(f"ds:{name} cannot be applied to a '###' heading (only ds:badge is)")
        btype = params.get("type")
        if btype == "credibility":
            level = params.get("level")
            if level not in _CREDIBILITY_LABELS:
                raise RenderError(
                    f"ds:badge type=credibility requires level in 2-5, got {level!r}"
                )
            tone = _CREDIBILITY_TONE[level]
            tag_html = f' <span class="tag tag-{tone}">{html.escape(_CREDIBILITY_LABELS[level], quote=True)}</span>'
        elif btype == "decision-record":
            pass  # scope-wrapping is handled by render_section_body, not here
        else:
            raise RenderError(
                f"ds:badge unknown type={btype!r} (expected credibility or decision-record)"
            )
    return f"<h3>{inline_convert(text)}{tag_html}</h3>"


def render_section_body(elements) -> str:
    out = []
    i, n = 0, len(elements)
    while i < n:
        node = elements[i]
        if node[0] == "h3":
            _, text, directive = node
            if directive is not None and directive[0] == "badge" and directive[1].get("type") == "decision-record":
                j = i + 1
                while j < n and elements[j][0] != "h3":
                    j += 1
                inner = [f"<h3>{inline_convert(text)}</h3>"] + [render_element(e) for e in elements[i + 1:j]]
                out.append(f'<div class="decision-record">{_DECISION_RECORD_BADGE}' + "".join(inner) + "</div>")
                i = j
                continue
            out.append(render_h3(text, directive))
            i += 1
        else:
            out.append(render_element(node))
            i += 1
    return "".join(out)


def render_section(heading_text, directive, elements) -> str:
    body = render_section_body(elements)
    badge = ""
    wrap_open = wrap_close = ""
    if directive is not None:
        name, _params = directive
        if name != "appendix":
            raise RenderError(f"ds:{name} cannot be applied to a '##' heading (only ds:appendix is)")
        badge = _APPENDIX_BADGE
        wrap_open, wrap_close = '<div class="archived-appendix">', "</div>"
    return (
        f'{wrap_open}<section class="section"><h2>{inline_convert(heading_text)}</h2>'
        f"{badge}{body}</section>{wrap_close}"
    )
