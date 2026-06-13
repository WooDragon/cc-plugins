"""recall-gate.py — BM25 lexical recall + link graph gate for doc-gate plugin."""

import re
import os
import sys
import math
import json
import argparse
import urllib.parse
from pathlib import Path
from collections import Counter


EXCLUDED_DIRS = {'.git', '.agents', 'node_modules', '.venv', 'research', 'docs-graph-tests'}
ORPHAN_WHITELIST = {'CLAUDE.md', 'README.md', 'MEMORY.md'}

_EN_TOKEN_RE = re.compile(r'[a-zA-Z][a-zA-Z0-9_.-]{1,}')
_ZH_RUN_RE = re.compile(r'[一-鿿]+')
_CODE_FENCE_RE = re.compile(r'^```')
_LINK_PATTERN = re.compile(r'(?<!\!)\[([^\]]*)\]\(([^)]+)\)')


# ---------------------------------------------------------------------------
# Tokenization + text utils
# ---------------------------------------------------------------------------

def tokenize(text: str) -> list:
    tokens = []
    en_spans = []
    for m in _EN_TOKEN_RE.finditer(text):
        tokens.append(m.group().lower())
        en_spans.append((m.start(), m.end()))
    cleaned = list(text)
    for start, end in en_spans:
        for i in range(start, end):
            cleaned[i] = ' '
    cleaned_text = ''.join(cleaned)
    for run_m in _ZH_RUN_RE.finditer(cleaned_text):
        run = run_m.group()
        for i in range(len(run) - 1):
            tokens.append(run[i:i+2])
    return tokens


def _strip_fences(content: str) -> str:
    lines = []
    in_fence = False
    for line in content.splitlines():
        if _CODE_FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if not in_fence:
            lines.append(line)
    return '\n'.join(lines)


def _extract_title(content: str) -> str:
    for line in content.splitlines():
        stripped = line.strip()
        if stripped.startswith('# '):
            return stripped[2:].strip()
    return ''


# ---------------------------------------------------------------------------
# Link graph functions (ported from docs-graph.py)
# ---------------------------------------------------------------------------

def extract_links_from_content(content: str) -> list:
    """Extract links from content string. Returns [(lineno, text, target), ...]"""
    results = []
    in_code_block = False
    for lineno, line in enumerate(content.splitlines(), start=1):
        if _CODE_FENCE_RE.match(line.strip()):
            in_code_block = not in_code_block
            continue
        if in_code_block:
            continue
        for text, target in _LINK_PATTERN.findall(line):
            results.append((lineno, text, target))
    return results


def should_skip_link(target: str) -> bool:
    return target.startswith(('http://', 'https://', 'mailto:', '#', 'file://', '/'))


def resolve_link(source_file: Path, target: str, root: Path):
    target = target.split('#')[0]
    if not target:
        return None
    target = urllib.parse.unquote(target)
    try:
        resolved = (source_file.parent / target).resolve()
    except (ValueError, OSError):
        return None
    try:
        resolved.relative_to(root.resolve())
    except ValueError:
        return None
    return resolved


# ---------------------------------------------------------------------------
# BM25 engine
# ---------------------------------------------------------------------------

def build_idf(corpus_tokens: list) -> dict:
    N = len(corpus_tokens)
    df: dict = {}
    for doc_tokens in corpus_tokens:
        for term in set(doc_tokens):
            df[term] = df.get(term, 0) + 1
    idf = {}
    for term, freq in df.items():
        idf[term] = math.log((N - freq + 0.5) / (freq + 0.5) + 1)
    return idf


def bm25_score(query_tokens: list, doc_tokens: list, doc_len: int, avg_dl: float,
               idf: dict, k1: float = 1.2, b: float = 0.75) -> float:
    tf_map = Counter(doc_tokens)
    score = 0.0
    denom_base = 1.0 - b + b * (doc_len / avg_dl) if avg_dl > 0 else 1.0
    for term in query_tokens:
        if term not in idf:
            continue
        tf = tf_map.get(term, 0)
        numerator = tf * (k1 + 1)
        denominator = tf + k1 * denom_base
        score += idf[term] * (numerator / denominator if denominator > 0 else 0.0)
    return score


def batch_bm25(query_tokens: list, corpus: list, idf: dict, avg_dl: float) -> list:
    results = []
    for idx, doc in enumerate(corpus):
        score = bm25_score(query_tokens, doc['tokens'], doc['token_count'], avg_dl, idf)
        results.append((idx, score))
    results.sort(key=lambda x: x[1], reverse=True)
    return results


def filename_jaccard(query_filename: str, doc_filename: str) -> float:
    def _segments(fname: str) -> set:
        base = re.sub(r'\.md$', '', fname, flags=re.IGNORECASE)
        parts = re.split(r'[-_.]', base)
        return {p.lower() for p in parts if p}

    q_set = _segments(os.path.basename(query_filename))
    d_set = _segments(os.path.basename(doc_filename))
    union = q_set | d_set
    if not union:
        return 0.0
    return len(q_set & d_set) / len(union)


def rank_candidates(query_text: str, query_filename: str, corpus: list,
                    content_idf: dict, title_idf: dict,
                    avg_dl: float, avg_title_dl: float,
                    threshold: float = 0.0, top_n: int = 10) -> list:
    query_tokens = tokenize(query_text)
    query_fname_base = os.path.basename(query_filename)

    content_scores = batch_bm25(query_tokens, corpus, content_idf, avg_dl)
    max_content = max((s for _, s in content_scores), default=0.0)

    title_raw = []
    for doc in corpus:
        ts = bm25_score(query_tokens, doc['title_tokens'],
                        len(doc['title_tokens']), avg_title_dl, title_idf)
        title_raw.append(ts)
    max_title = max(title_raw, default=0.0)

    ranked = []
    for idx, c_score in content_scores:
        doc = corpus[idx]
        doc_basename = os.path.basename(doc['path'])
        if doc_basename in ORPHAN_WHITELIST:
            continue
        if os.path.normpath(doc['path']) == os.path.normpath(query_filename):
            continue

        bm25_norm = (c_score / max_content) if max_content > 0 else 0.0
        title_norm = (title_raw[idx] / max_title) if max_title > 0 else 0.0
        jac = filename_jaccard(query_fname_base, doc['path'])
        if query_fname_base:
            combined = 0.65 * bm25_norm + 0.25 * jac + 0.10 * title_norm
        else:
            combined = 0.75 * bm25_norm + 0.25 * title_norm

        if combined >= threshold:
            ranked.append({
                'path': doc['path'],
                'score': round(combined, 4),
                'title': doc['title'],
            })

    ranked.sort(key=lambda x: x['score'], reverse=True)
    return ranked[:top_n]


def build_indexes(corpus: list) -> tuple:
    content_idf = build_idf([doc['tokens'] for doc in corpus])
    title_idf = build_idf([doc['title_tokens'] for doc in corpus])
    total_len = sum(doc['token_count'] for doc in corpus)
    avg_dl = total_len / len(corpus) if corpus else 1.0
    total_title_len = sum(len(doc['title_tokens']) for doc in corpus)
    avg_title_dl = total_title_len / len(corpus) if corpus else 1.0
    return content_idf, title_idf, avg_dl, avg_title_dl


# ---------------------------------------------------------------------------
# Single-pass scanner: BM25 corpus + link adjacency
# ---------------------------------------------------------------------------

def build_corpus_and_graph(root: str) -> tuple:
    """Single os.walk pass building BM25 corpus, forward/backward adjacency, and all_files set."""
    root_path = Path(root).resolve()
    corpus = []
    # all_files: set of relative path strings
    all_files: set = set()
    # adjacency keyed by relative path string
    forward: dict = {}   # rel_path -> set of rel target strings
    backward: dict = {}  # rel_path -> set of rel source strings

    # First pass: collect content and tokens
    file_contents: dict = {}  # rel_path -> content
    for dirpath, dirnames, filenames in os.walk(str(root_path)):
        dirnames[:] = [d for d in dirnames if d not in EXCLUDED_DIRS]
        for fname in filenames:
            if not fname.endswith('.md'):
                continue
            fpath = Path(dirpath) / fname
            try:
                content = fpath.read_text(encoding='utf-8', errors='ignore')
            except OSError:
                continue
            rel_path = os.path.relpath(str(fpath), str(root_path))
            all_files.add(rel_path)
            file_contents[rel_path] = content

            title = _extract_title(content)
            body_for_tokens = _strip_fences(content)
            tokens = tokenize(body_for_tokens)
            title_tokens = tokenize(title) if title else []
            corpus.append({
                'path': rel_path,
                'title': title,
                'tokens': tokens,
                'title_tokens': title_tokens,
                'token_count': len(tokens),
            })
            forward[rel_path] = set()
            backward.setdefault(rel_path, set())

    # Second pass: build link adjacency
    for rel_path, content in file_contents.items():
        src_path = root_path / rel_path
        links = extract_links_from_content(content)
        for _lineno, _text, target in links:
            if should_skip_link(target):
                continue
            resolved = resolve_link(src_path, target, root_path)
            if resolved is None:
                continue
            try:
                rel_target = os.path.relpath(str(resolved), str(root_path))
            except ValueError:
                continue
            if rel_target in all_files:
                forward[rel_path].add(rel_target)
                backward.setdefault(rel_target, set()).add(rel_path)

    return corpus, all_files, forward, backward


# ---------------------------------------------------------------------------
# Gate-specific checks
# ---------------------------------------------------------------------------

def check_orphan(target_file: str, backward: dict, orphan_whitelist: set) -> bool:
    basename = os.path.basename(target_file)
    if basename in orphan_whitelist:
        return False
    inlinks = backward.get(target_file, set())
    return len(inlinks) == 0


def check_broken_outlinks(content: str, target_file: str, root: str, all_files: set) -> list:
    """Return list of {target, line} dicts for broken outlinks in content."""
    root_path = Path(root).resolve()
    src_path = root_path / target_file
    broken = []
    links = extract_links_from_content(content)
    for lineno, _text, target in links:
        if should_skip_link(target):
            continue
        resolved = resolve_link(src_path, target, root_path)
        if resolved is None:
            broken.append({'target': target, 'line': lineno})
            continue
        try:
            rel_target = os.path.relpath(str(resolved), str(root_path))
        except ValueError:
            broken.append({'target': target, 'line': lineno})
            continue
        # For .md targets check against corpus all_files set
        if rel_target.lower().endswith('.md'):
            if rel_target not in all_files:
                broken.append({'target': target, 'line': lineno})
        else:
            # Non-.md: fall back to filesystem existence check
            if not resolved.exists():
                broken.append({'target': target, 'line': lineno})
    return broken


# ---------------------------------------------------------------------------
# Gate entry point
# ---------------------------------------------------------------------------

def cmd_gate(args):
    content = sys.stdin.read()
    root = str(Path(args.root).resolve())

    if args.target_file:
        target_file = os.path.relpath(args.target_file, root) if os.path.isabs(args.target_file) else args.target_file
    else:
        target_file = ''

    corpus, all_files, _forward, backward = build_corpus_and_graph(root)

    recall_results = []
    has_recall = False
    if corpus and content.strip():
        content_idf, title_idf, avg_dl, avg_title_dl = build_indexes(corpus)
        candidates = rank_candidates(
            content, target_file, corpus,
            content_idf, title_idf, avg_dl, avg_title_dl,
            threshold=args.threshold,
            top_n=args.top_n,
        )
        recall_results = [{'path': r['path'], 'score': r['score'], 'title': r['title']}
                          for r in candidates]
        has_recall = len(recall_results) > 0

    orphan = False
    if target_file:
        orphan = check_orphan(target_file, backward, ORPHAN_WHITELIST)

    broken_outlinks = []
    if target_file and content.strip():
        broken_outlinks = check_broken_outlinks(content, target_file, root, all_files)

    has_findings = has_recall or orphan or bool(broken_outlinks)

    output = {
        'has_findings': has_findings,
        'recall': recall_results,
        'orphan': orphan,
        'broken_outlinks': broken_outlinks,
    }
    print(json.dumps(output, ensure_ascii=False))


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description='recall-gate: BM25 recall + link graph gate.')
    parser.add_argument('--root', required=True, help='Repo root directory')
    parser.add_argument('--target-file', default='', help='File being edited (relative to root)')
    parser.add_argument('--threshold', type=float, default=0.30, help='Min combined score (default: 0.30)')
    parser.add_argument('--top-n', type=int, default=5, help='Max recall results (default: 5)')
    parser.add_argument('--json', action='store_true', help='(ignored, output is always JSON in gate mode)')

    subparsers = parser.add_subparsers(dest='subcommand', required=True)
    subparsers.add_parser('gate', help='Read content from stdin, output gate JSON')

    args = parser.parse_args()

    if args.subcommand == 'gate':
        cmd_gate(args)
        sys.exit(0)


if __name__ == '__main__':
    main()
