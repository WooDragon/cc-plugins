#!/usr/bin/env python3
"""doc-exit-report.py — structural exit-gate finding report for doc-gate.

Single responsibility: given a final-state batch of relative .md paths, emit
a structured JSON report of cross-document findings. Does not touch git,
does not implement the hook (blocking) protocol, and does not do root
detection — the caller (doc-exit.sh) resolves root via `git rev-parse` and
passes it in.

Input paths arrive on stdin, NUL-separated (never newline-separated — a
legal POSIX path may contain a literal newline, and this tool exists
precisely to survive that intact end to end).

recall-gate.py has a hyphenated filename, so it is loaded via
importlib.util.spec_from_file_location rather than `import recall_gate`
(the pattern already used by tests/test_exclude.py). Both files live in the
same tools/ directory, which Python places at sys.path[0] when either script
is invoked by absolute path — see _doc_gate_common.py's own docstring for
why that guarantee holds regardless of the caller's cwd.
"""

import argparse
import importlib.util
import json
import os
import sys
import time
from pathlib import Path

_SELF_DIR = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("recall_gate", _SELF_DIR / "recall-gate.py")
recall_gate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(recall_gate)


def read_dirty_paths_from_stdin() -> list:
    """NUL-delimited relative paths from stdin.buffer — never split on
    newline, which would re-introduce the exact path-splitting hazard the
    NUL delimiter was chosen to avoid upstream (git status -z)."""
    raw = sys.stdin.buffer.read()
    paths = []
    for chunk in raw.split(b'\0'):
        if not chunk:
            continue
        try:
            paths.append(chunk.decode('utf-8'))
        except UnicodeDecodeError:
            continue
    return paths


def read_nul_paths_from_file(path: str) -> list:
    """NUL-delimited relative paths from a file on disk — same decoding
    discipline as read_dirty_paths_from_stdin (never split on newline)."""
    raw = Path(path).read_bytes()
    paths = []
    for chunk in raw.split(b'\0'):
        if not chunk:
            continue
        try:
            paths.append(chunk.decode('utf-8'))
        except UnicodeDecodeError:
            continue
    return paths


def _dedupe_preserve_order(paths: list) -> list:
    seen = set()
    out = []
    for p in paths:
        if p in seen:
            continue
        seen.add(p)
        out.append(p)
    return out


def build_report(root: str, dirty_paths: list, threshold: float, top_n: int,
                  budget_sec: float, start_time: float,
                  dirty_superset: list = None) -> dict:
    # dirty_paths is the report set — the files this call actually iterates
    # and emits findings for (already exclusion-filtered by the caller).
    # dirty_superset (when given) is the UNFILTERED superset of every dirty
    # .md path — used only to answer "has this file been touched at all" for
    # stale_inlinks self-termination. A file the caller excludes from
    # reporting (SKILL.md, deliverables/*, ...) can still be a genuine
    # inlink-source whose own edit should retire a stale_inlinks finding;
    # computing "touched" from the filtered set alone would make that
    # finding permanently unsatisfiable. dirty_superset=None (the default)
    # preserves the pre-A2 behavior for callers — notably existing tests —
    # that only ever had one list to begin with.
    dirty_set = set(dirty_superset) if dirty_superset is not None else set(dirty_paths)
    ordered_paths = _dedupe_preserve_order(dirty_paths)

    # The budget must cover graph construction itself, not just the BM25
    # pass that follows it — os.walk + reading every .md's content is the
    # single most expensive step in this tool, and it used to run BEFORE any
    # budget check existed at all (A7, #219). A large doc corpus could blow
    # past the hook's own 60s timeout during this call alone, and a timed-
    # out hook is killed SILENTLY by the platform (see doc-exit.sh's header
    # comment) — indistinguishable from "nothing to report". Turning that
    # into a visible, bounded-once-per-Stop-cycle block is strictly better
    # than an invisible kill, so a truncated walk produces a degraded report
    # rather than either silently completing on a partial graph (wrong
    # stale_inlinks/orphan/dangling_refs) or silently exiting clean.
    try:
        corpus, all_files, _forward, backward, dangling = recall_gate.build_corpus_and_graph(
            root, start_time=start_time, budget_sec=budget_sec,
        )
    except recall_gate.GraphBudgetExceeded as exc:
        return {
            'root': root,
            'degraded': True,
            'degraded_reason': (
                f'本次检查因超出耗时预算未能完成（已扫描 {exc.scanned_count} 个文件），'
                f'未做一致性判定。可调整 DOC_EXIT_GATE_BUDGET_SEC 提高预算，'
                f'或设置 DOC_EXIT_GATE_DISABLED=1 临时关闭本检查。'
            ),
            'has_findings': True,
            'files': {},
        }

    content_idf = title_idf = avg_dl = avg_title_dl = None
    if corpus:
        content_idf, title_idf, avg_dl, avg_title_dl = recall_gate.build_indexes(corpus)

    degraded = False
    degraded_reason = ''
    has_findings = False
    files_out = {}

    for relpath in ordered_paths:
        basename = os.path.basename(relpath)
        inlinks_set = backward.get(relpath, set())
        inlinks = sorted(inlinks_set)
        stale_inlinks = sorted(x for x in inlinks_set if x not in dirty_set)
        orphan = recall_gate.is_orphan(inlinks_set, basename, recall_gate.ORPHAN_WHITELIST)
        dangling_refs = sorted(dangling.get(relpath, set()))

        abs_path = Path(root) / relpath
        exists = abs_path.is_file()

        # A deleted file does not need an inlink to be discovered; it needs
        # other files to stop linking it. That's dangling_refs' job. Reporting
        # orphan=True for a nonexistent file produces a misleading suggestion
        # to "add an index link" to something that no longer exists.
        if not exists:
            orphan = False

        recall_results = []
        broken_outlinks = []

        if exists:
            content = None
            try:
                content = abs_path.read_text(encoding='utf-8', errors='ignore')
            except OSError:
                content = None

            if content is not None:
                # broken_outlinks is a pure graph-lookup check (reuses the
                # already-built all_files set) — cheap, so it stays on even
                # once the time budget for the expensive BM25 pass is spent.
                broken_outlinks = recall_gate.check_broken_outlinks(content, relpath, root, all_files)

                if not degraded:
                    elapsed = time.monotonic() - start_time
                    if elapsed > budget_sec:
                        degraded = True
                        degraded_reason = (
                            f'耗时预算 {budget_sec}s 已超出（已用 {elapsed:.1f}s），'
                            f'已放弃剩余文件的查重检查（recall），仅保留结构类检查'
                            f'（入链/孤儿/dangling/断链）。'
                        )
                    elif corpus:
                        candidates = recall_gate.rank_candidates(
                            content, relpath, corpus,
                            content_idf, title_idf, avg_dl, avg_title_dl,
                            threshold=threshold, top_n=top_n,
                        )
                        recall_results = [
                            {'path': c['path'], 'score': c['score'], 'title': c['title']}
                            for c in candidates
                        ]

        file_finding = {
            'exists': exists,
            'inlinks': inlinks,
            'stale_inlinks': stale_inlinks,
            'orphan': orphan,
            'recall': recall_results,
            'broken_outlinks': broken_outlinks,
            'dangling_refs': dangling_refs,
        }
        files_out[relpath] = file_finding

        # inlinks itself is NOT a finding — most files legitimately have
        # inbound links, so treating presence-of-inlinks as a finding would
        # be vacuously true almost everywhere.
        #
        # recall is deliberately excluded from has_findings: unlike the
        # other three (structural facts — stale_inlinks/dangling_refs are
        # actionable by fixing a link and self-terminate once fixed;
        # broken_outlinks likewise), recall is a heuristic BM25 similarity
        # suggestion with no action that makes it go away — the same edit
        # to an existing file cannot reduce its lexical overlap with an
        # unrelated pre-existing file. Blocking on it would be a gate no
        # edit can satisfy, and it would re-fire every subsequent Stop cycle
        # since the dirty set doesn't change before commit. recall is still
        # computed and still rendered in the report — it just doesn't gate.
        # orphan IS kept in this predicate, which is what lets recall still
        # surface for the case it's meant to catch: a newly created
        # document (which has no inlinks yet, hence orphan=True) will still
        # block and show its recall candidates for review.
        if stale_inlinks or orphan or broken_outlinks or dangling_refs:
            has_findings = True

    return {
        'root': root,
        'degraded': degraded,
        'degraded_reason': degraded_reason,
        'has_findings': has_findings,
        'files': files_out,
    }


def main():
    parser = argparse.ArgumentParser(
        description='doc-exit-report: structural exit-gate finding report for a batch of dirty .md paths.'
    )
    parser.add_argument('--root', required=True, help='Repo root (resolved absolute path, from git rev-parse)')
    parser.add_argument('--threshold', type=float, default=0.30, help='Min combined recall score (default: 0.30)')
    parser.add_argument('--top-n', type=int, default=5, help='Max recall results per file (default: 5)')
    parser.add_argument('--budget-sec', type=float, default=25.0, help='Recall time budget in seconds (default: 25)')
    parser.add_argument('--dirty-superset-file', default=None,
                         help='Path to a NUL-delimited file listing every dirty .md path '
                              'unfiltered by the exclusion list (see build_report docstring)')
    args = parser.parse_args()

    start_time = time.monotonic()
    root = str(Path(args.root).resolve())

    dirty_paths = read_dirty_paths_from_stdin()
    dirty_superset = read_nul_paths_from_file(args.dirty_superset_file) if args.dirty_superset_file else None

    report = build_report(root, dirty_paths, args.threshold, args.top_n, args.budget_sec, start_time,
                           dirty_superset=dirty_superset)
    print(json.dumps(report, ensure_ascii=False))
    sys.exit(0)


if __name__ == '__main__':
    main()
