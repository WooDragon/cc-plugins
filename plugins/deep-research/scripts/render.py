#!/usr/bin/env python3
"""render.py -- deterministic report.md -> report.html renderer.

Contract: report.html = f(report.md), zero new facts. This script replaces
the old model: research-publisher agent inventing a fresh HTML generator
every run. render.py is stdlib-only and has zero timestamps / zero
randomness -- rendering the same report.md twice (or a thousand times)
produces byte-identical output. This is what makes the Stage 7 delivery
gate ("re-render + git diff --exit-code report.html") work at all: a
probabilistic renderer can never pass that gate honestly, a deterministic
one always does when nothing changed.

Implementation is split across four files, mirroring this repo's existing
harvest.py + harvest_fetch.py/harvest_search.py/harvest_journal.py
precedent (one script's concern per file, imported via `sys.path.insert` +
bare `import`, not a package):
  - render_common.py  -- RenderError, physical-line-join rule, list-item
                          splitting, leading-**bold** splitting
  - render_inline.py  -- inline span conversion (bold/code/links), the
                          href-purity logic
  - render_blocks.py  -- block-level renderers + the 10 ds: directives'
                          HTML output
  - render.py (this file) -- tokenizing raw markdown into nodes, document
                          assembly, hero fields, template loading, CLI

------------------------------------------------------------------------
Supported markdown subset (anything outside this subset is a fail-loud
error, never a silent best-effort guess)
------------------------------------------------------------------------

Document shape:
  - Exactly one `# Title` heading, and it must be the document's first
    piece of content (blank lines / ds: comments may precede it).
  - Everything between the title and the first `##` section is the
    "intro" region: blockquotes render as .callout, plain paragraphs are
    also the (only) source for the default hero sub-headline.
  - At least one `##` section is required. `###` subsections are only
    valid inside a `##` section (one before the first `##` is an error).
  - Heading depth stops at h3. `####` or deeper is unsupported (fail-loud).

Block constructs:
  - Paragraphs: consecutive non-blank plain lines. Physical line joins use
    one rule, applied identically everywhere: a CJK-ideograph boundary on
    both sides concatenates directly (CJK prose isn't inter-word spaced);
    every other boundary -- ASCII-alnum, a bold-lead run-on, sentence-final
    punctuation -- gets a space (see render_common.py's `_join_pairwise`).
  - A line starting with "→" is always its own standalone one-line
    paragraph (citation / reasoning-chain / uncertainty annotation
    convention used throughout deep-research reports) -- it never merges
    with the paragraph or list before or after it.
  - A bare `---` line (not in frontmatter position) is a horizontal-rule
    marker: explicitly recognized and deliberately ignored -- it never
    starts a block or leaks into a paragraph seam.
  - Blockquotes: consecutive `>`-prefixed lines, split into paragraphs on
    bare `>` separator lines. Render as `.callout` by default.
  - Unordered lists: `- item` (only the dash marker; `*`/`+` are not part
    of the supported subset). Ordered lists: `1. item`. Flat lists only --
    a marker line indented deeper than the list it would continue (a
    nested/sub-list) is outside the supported subset and fails loud rather
    than being silently flattened or split.
  - List items may wrap across multiple physical lines: any non-blank line
    that doesn't itself start a new block (heading/table/blockquote/fence/
    `→`/a new list marker) is treated as a continuation of the previous
    item, joined with the same physical-line-join rule as paragraphs.
  - GFM tables: every row (including the delimiter row) starts with `|`.
  - Fenced code blocks (``` ... ```): content preserved verbatim as plain
    text (HTML-escaped, not linkified, not syntax highlighted).
  - `**bold**`, `` `code` ``, `[text](url)`, and bare `https?://` URLs are
    the only supported inline spans (see render_inline.py for href purity
    and href scheme safety). GFM's `[text](url "title")` title attribute
    is not supported and fails loud.

------------------------------------------------------------------------
`<!-- ds:name key=value ... -->` visual annotation vocabulary
------------------------------------------------------------------------

A ds: comment must be a single complete line and applies to the next block
it precedes (no nesting -- a second ds: comment before the first one's
block has been consumed is an error). `ds:hero` is the one exception: it
is a document-level declaration, not attached to any block, and may appear
anywhere. Every other HTML comment (one that does not start with
`<!-- ds:`) is treated as an ordinary, invisible comment.

  ds:card-grid          -- on a list: each item becomes a `.card` (leading
                          `**Bold**` becomes the card title, the rest the
                          body paragraph; no bold => whole item is the title)
  ds:pain-list          -- on a list: same split, rendered as `.pain-item`
                          name/desc pairs
  ds:verdict-bar         -- on a list of 2-3 items, each `**Label**: value`,
                          optional trailing `(green)` / `(amber)` tone marker
  ds:phase-timeline      -- on a list, each `**Phase N · name**: description`;
                          a leading `[optional] ` marker renders that phase
                          as the dashed/optional style
  ds:data-grid           -- on a list, each item
                          `**Name** | source | status: description` with
                          status in {ready, partial, missing}
  ds:arch-diagram        -- on a fenced code block: wraps it in `.arch-diagram`
  ds:callout tone=...     -- on a blockquote or paragraph: renders/re-styles
                          it as `.callout`; optional tone in
                          {green, amber, red}
  ds:badge type=...       -- on a `###` heading:
                          type=credibility level=N (N in 2..5) appends an
                          inline `.tag` credibility badge to the heading;
                          type=decision-record wraps that heading and every
                          block up to the next `###`/section end in a
                          `.decision-record` box
  ds:appendix             -- on a `##` heading: wraps the whole section in
                          `.archived-appendix` (grayed-out/archived styling)
  ds:hero eyebrow=".." sub=".." meta="a;b;c" theme=midnight|daylight
                        -- document-level hero field overrides. Quoted
                          values may contain spaces/CJK; `meta` is a
                          `;`-separated list of spans. Unset fields fall
                          back to deterministic defaults derived from the
                          document itself (title, first intro paragraph) --
                          never fabricated.

Any `ds:` name outside this vocabulary, or one attached to a block kind it
doesn't support, is a fail-loud error.

------------------------------------------------------------------------
Anti-injection
------------------------------------------------------------------------

Every text node this script emits is HTML-escaped, and the entire final
HTML document is passed through `_sanitize.sanitize_text()` (zero-width /
bidi-control character stripping + quote-spoofing normalization) before
being written to disk.

------------------------------------------------------------------------
CLI
------------------------------------------------------------------------

    python3 render.py <path/to/report.md> [-o <output.html>]

Default output path is `report.html` next to the input file. Exit 0 on
success, exit 1 with a descriptive message on stderr for any unsupported
construct or malformed ds: annotation.
"""

import argparse
import html
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from render_common import RenderError, join_lines_prose  # noqa: E402
from render_blocks import render_element, render_section  # noqa: E402
from render_inline import inline_convert  # noqa: E402
from _sanitize import sanitize_text  # noqa: E402

# ============================================================================
# ds: directive comment parsing
# ============================================================================

_KNOWN_DIRECTIVES = frozenset(
    {
        "card-grid",
        "pain-list",
        "verdict-bar",
        "phase-timeline",
        "data-grid",
        "arch-diagram",
        "callout",
        "badge",
        "appendix",
        "hero",
    }
)

_HERO_PARAMS = frozenset({"eyebrow", "sub", "meta", "theme"})

_DS_PREFIX_RE = re.compile(r"^<!--\s*ds:")
_DS_COMMENT_RE = re.compile(
    r'^<!--\s*ds:([A-Za-z0-9_-]+)'
    r'((?:\s+[A-Za-z_][A-Za-z0-9_]*=(?:"(?:[^"\\]|\\.)*"|\S+))*)'
    r"\s*-->$"
)
_DS_PARAM_RE = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)=("(?:[^"\\]|\\.)*"|\S+)')


def parse_ds_comment(line: str):
    """Parse a single-line `<!-- ds:name key=value ... -->` comment.
    Returns (name, params_dict) or None if the line isn't a ds: comment
    shape at all (caller decides malformed-vs-not-a-ds-comment)."""
    m = _DS_COMMENT_RE.match(line)
    if not m:
        return None
    name = m.group(1)
    params = {}
    for pm in _DS_PARAM_RE.finditer(m.group(2)):
        key, val = pm.group(1), pm.group(2)
        if val.startswith('"'):
            val = val[1:-1].replace('\\"', '"')
        params[key] = val
    return name, params


# ============================================================================
# Block-level classification
# ============================================================================

_H_RE = re.compile(r"^(#{1,6})\s+(.*)$")
_UL_ITEM_RE = re.compile(r"^-\s+(.*)$")
_OL_ITEM_RE = re.compile(r"^(\d+)\.\s+(.*)$")
_FENCE_RE = re.compile(r"^```")


def classify_heading(s: str):
    m = _H_RE.match(s)
    if not m:
        return None
    level = len(m.group(1))
    text = m.group(2).strip()
    if level >= 4:
        raise RenderError(
            f"unsupported heading level h{level} (supported subset is h1/h2/h3 only): {s!r}"
        )
    return ("h1" if level == 1 else "h2" if level == 2 else "h3", text)


def classify_block_kind(s: str) -> str:
    if s.startswith("|"):
        return "table"
    if s.startswith(">"):
        return "blockquote"
    if _UL_ITEM_RE.match(s):
        return "ul"
    if _OL_ITEM_RE.match(s):
        return "ol"
    return "p"


# ============================================================================
# Tokenizer: raw markdown lines -> flat node stream
# ============================================================================
#
# Node shapes:
#   ("h1" | "h2" | "h3", text, directive_or_None)
#   ("block", kind, lines, directive_or_None)   kind in {p, blockquote,
#                                                table, ul, ol, pre}
# directive is (name, params_dict) or None.


def _record_hero(hero_overrides: dict, params: dict):
    for k in params:
        if k not in _HERO_PARAMS:
            raise RenderError(
                f"ds:hero unknown param {k!r} (expected one of {sorted(_HERO_PARAMS)})"
            )
    hero_overrides.update(params)


def tokenize(lines):
    nodes = []
    hero_overrides = {}
    pending_directive = None
    cur = None
    in_fence = False
    fence_lines = []
    fence_directive = None

    def flush():
        nonlocal cur
        if cur is not None:
            nodes.append(("block", cur["kind"], cur["lines"], cur["directive"]))
            cur = None

    def open_block(kind, first_line):
        nonlocal cur, pending_directive
        cur = {"kind": kind, "lines": [first_line], "directive": pending_directive}
        pending_directive = None

    for line_no, raw in enumerate(lines, start=1):
        stripped = raw.rstrip("\r")

        if in_fence:
            if _FENCE_RE.match(stripped.strip()):
                nodes.append(("block", "pre", fence_lines, fence_directive))
                in_fence = False
                fence_lines = []
                fence_directive = None
            else:
                fence_lines.append(stripped)
            continue

        s = stripped.strip()

        # Nested list detection: a marker line that is itself indented
        # deeper than the list it would continue is a nested/sub list --
        # outside the supported subset (flat lists only). Without this
        # check it silently mis-parses: a same-marker nested item gets
        # flattened into a sibling top-level item, a different-marker one
        # (e.g. "1." nested under "-") silently splits into two adjacent
        # lists. Both are worse than fail-loud. A non-indented marker line
        # is a legitimate next flat item, not nested -- indentation is the
        # only signal that distinguishes the two.
        if (
            cur is not None
            and cur["kind"] in ("ul", "ol")
            and stripped != stripped.lstrip()
            and classify_block_kind(s) in ("ul", "ol")
        ):
            raise RenderError(
                f"line {line_no}: nested list item {s!r} is not in the "
                "supported subset (flat lists only) -- flatten it to a "
                "single-level list or use a ds: component instead"
            )

        if s.startswith("<!--"):
            if _DS_PREFIX_RE.match(s):
                ds = parse_ds_comment(s)
                if ds is None:
                    raise RenderError(
                        "malformed ds: directive comment (expected a single-line "
                        f"'<!-- ds:name key=value ... -->'): {stripped!r}"
                    )
                name, params = ds
                if name not in _KNOWN_DIRECTIVES:
                    raise RenderError(
                        f"unknown ds: directive 'ds:{name}' (known: {sorted(_KNOWN_DIRECTIVES)})"
                    )
                if name == "hero":
                    if pending_directive is not None:
                        raise RenderError(
                            f"ds:hero cannot appear while ds:{pending_directive[0]} "
                            "is still awaiting its block"
                        )
                    _record_hero(hero_overrides, params)
                else:
                    if pending_directive is not None:
                        raise RenderError(
                            f"ds:{pending_directive[0]} has no attached block "
                            f"before ds:{name} appeared"
                        )
                    pending_directive = (name, params)
            # else: ordinary HTML comment, not a ds: directive -- invisible.
            continue

        if not s:
            flush()
            continue

        if _FENCE_RE.match(s):
            flush()
            in_fence = True
            fence_lines = []
            fence_directive = pending_directive
            pending_directive = None
            continue

        if s == "---":
            # Horizontal-rule marker line -- explicitly recognized and
            # deliberately ignored (never a block, never left to fall into
            # a paragraph seam by accident).
            flush()
            continue

        heading = classify_heading(s)
        if heading:
            flush()
            h_kind, h_text = heading
            directive, pending_directive = pending_directive, None
            nodes.append((h_kind, h_text, directive))
            continue

        if s.startswith("→"):
            flush()
            directive, pending_directive = pending_directive, None
            nodes.append(("block", "p", [stripped], directive))
            continue

        kind = classify_block_kind(s)
        if cur is not None and cur["kind"] in ("ul", "ol") and kind == "p":
            cur["lines"].append(stripped)
            continue
        if cur is not None and cur["kind"] == kind:
            cur["lines"].append(stripped)
            continue
        flush()
        open_block(kind, stripped)

    flush()
    if in_fence:
        raise RenderError("unterminated fenced code block (missing closing ```)")
    if pending_directive is not None:
        raise RenderError(
            f"ds:{pending_directive[0]} directive has no following block "
            "(end of document reached)"
        )
    return nodes, hero_overrides


# ============================================================================
# Document assembly
# ============================================================================


def parse_document(md_text: str):
    nodes, hero_overrides = tokenize(md_text.split("\n"))
    if not nodes or nodes[0][0] != "h1":
        raise RenderError("document must start with a single '# Title' H1 heading")
    _, title, h1_directive = nodes[0]
    if h1_directive is not None:
        raise RenderError("a ds: directive cannot attach to the '#' title heading")

    rest = nodes[1:]
    if any(node[0] == "h1" for node in rest):
        raise RenderError("multiple '#' H1 headings are not supported (exactly one expected)")

    first_h2_idx = next((i for i, node in enumerate(rest) if node[0] == "h2"), None)
    if first_h2_idx is None:
        raise RenderError("document has no '##' sections")

    intro_nodes = rest[:first_h2_idx]
    section_nodes = rest[first_h2_idx:]
    for node in intro_nodes:
        if node[0] == "h3":
            raise RenderError("a '###' heading appeared before the first '##' section")

    sections = []
    cur_heading, cur_elements = None, None
    for node in section_nodes:
        if node[0] == "h2":
            if cur_heading is not None:
                sections.append((cur_heading, cur_elements))
            cur_heading, cur_elements = node, []
        else:
            cur_elements.append(node)
    if cur_heading is not None:
        sections.append((cur_heading, cur_elements))

    return title, intro_nodes, sections, hero_overrides


def build_hero(title, intro_nodes, hero_overrides) -> dict:
    default_sub = ""
    for node in intro_nodes:
        if node[1] == "p":
            default_sub = join_lines_prose(node[2])
            break

    theme = hero_overrides.get("theme", "midnight")
    if theme not in ("midnight", "daylight"):
        raise RenderError(f"ds:hero theme must be 'midnight' or 'daylight', got {theme!r}")

    eyebrow = hero_overrides.get("eyebrow", "")
    sub = hero_overrides.get("sub", default_sub)
    meta_raw = hero_overrides.get("meta", "")
    meta_html = "".join(
        f"<span>{inline_convert(m.strip())}</span>" for m in meta_raw.split(";") if m.strip()
    )
    return {
        "theme": theme,
        "title_text": title,
        "eyebrow": inline_convert(eyebrow),
        "h1": inline_convert(title),
        "sub": inline_convert(sub),
        "meta": meta_html,
    }


def render_document(md_text: str):
    title, intro_nodes, sections, hero_overrides = parse_document(md_text)
    parts = [render_element(node) for node in intro_nodes]
    for h2_node, elements in sections:
        _, heading_text, directive = h2_node
        parts.append(render_section(heading_text, directive, elements))
    content_html = "\n".join(p for p in parts if p)
    hero = build_hero(title, intro_nodes, hero_overrides)
    return hero, content_html


# ============================================================================
# Template loading + top-level render + CLI
# ============================================================================

_TEMPLATE_COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)


def load_template() -> str:
    """Self-contained template resolution: relative to this script's own
    location, never CLAUDE_PLUGIN_ROOT (subagent shells don't expand it)."""
    tmpl_path = Path(__file__).resolve().parent.parent / "skills" / "deep-research" / "assets" / "report-shell.html.tmpl"
    text = tmpl_path.read_text(encoding="utf-8")
    # Strip the template's own usage-example HTML comments (component
    # vocabulary demos between hero and {{CONTENT}}) -- they document the
    # template for humans, they must never leak into a rendered report.
    return _TEMPLATE_COMMENT_RE.sub("", text)


def render_report(md_text: str, tmpl_text: str) -> str:
    hero, content_html = render_document(md_text)
    out = tmpl_text
    out = out.replace("{{THEME}}", hero["theme"])
    out = out.replace("{{TITLE}}", html.escape(hero["title_text"], quote=True))
    out = out.replace("{{HERO_EYEBROW}}", hero["eyebrow"])
    out = out.replace("{{HERO_H1}}", hero["h1"])
    out = out.replace("{{HERO_SUB}}", hero["sub"])
    out = out.replace("{{HERO_META}}", hero["meta"])
    out = out.replace("{{CONTENT}}", content_html)
    return sanitize_text(out)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="render.py", description=__doc__.splitlines()[0])
    parser.add_argument("report_md", help="path to report.md")
    parser.add_argument("-o", "--output", help="output path (default: report.html next to report_md)")
    args = parser.parse_args(argv)

    md_path = Path(args.report_md).resolve()
    if not md_path.is_file():
        print(f"error: {md_path} is not a file", file=sys.stderr)
        return 1
    out_path = Path(args.output).resolve() if args.output else md_path.parent / "report.html"

    try:
        tmpl_text = load_template()
        html_out = render_report(md_path.read_text(encoding="utf-8"), tmpl_text)
    except (RenderError, OSError) as e:
        # OSError covers a missing/unreadable template or report.md (e.g. a
        # stale/relocated plugin cache) -- without it, that case surfaces as
        # an unhandled traceback instead of the same clean CLI error path.
        print(f"error: {e}", file=sys.stderr)
        return 1

    out_path.write_text(html_out, encoding="utf-8")
    print(f"wrote {out_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
