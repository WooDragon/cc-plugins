import importlib.util
import sys
import time
from pathlib import Path

# doc-exit-report.py has a hyphen in its filename, so it can't be imported
# via plain `import` — load it by file path, same pattern as test_exclude.py.
# recall-gate.py (imported internally by doc-exit-report.py via its own
# spec_from_file_location) needs _doc_gate_common importable by bare module
# name, so tools/ must be on sys.path before exec_module runs.
_TOOLS_DIR = Path(__file__).resolve().parent.parent / "tools"
sys.path.insert(0, str(_TOOLS_DIR))
_spec = importlib.util.spec_from_file_location("doc_exit_report", _TOOLS_DIR / "doc-exit-report.py")
doc_exit_report = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(doc_exit_report)


def _write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


# ---------------------------------------------------------------------------
# read_dirty_paths_from_stdin — NUL-delimited parsing
# ---------------------------------------------------------------------------

class _FakeStdin:
    def __init__(self, raw: bytes):
        class _Buf:
            def read(self_inner):
                return raw
        self.buffer = _Buf()


def test_read_dirty_paths_splits_on_nul_not_newline(monkeypatch):
    raw = b"a.md\0weird\nname.md\0b.md\0"
    monkeypatch.setattr(doc_exit_report.sys, "stdin", _FakeStdin(raw))
    paths = doc_exit_report.read_dirty_paths_from_stdin()

    assert paths == ["a.md", "weird\nname.md", "b.md"]


def test_read_dirty_paths_skips_empty_segments(monkeypatch):
    raw = b"a.md\0\0\0b.md\0"
    monkeypatch.setattr(doc_exit_report.sys, "stdin", _FakeStdin(raw))
    paths = doc_exit_report.read_dirty_paths_from_stdin()

    assert paths == ["a.md", "b.md"]


# ---------------------------------------------------------------------------
# Deleted file: content checks skipped, graph checks still produced
# ---------------------------------------------------------------------------

def test_deleted_file_skips_content_checks_but_keeps_graph_checks(tmp_path):
    _write(tmp_path / "A.md", "# A\n\n[b](B.md)\n")
    _write(tmp_path / "B.md", "# B\n\ncontent\n")

    report = doc_exit_report.build_report(
        root=str(tmp_path),
        dirty_paths=["B.md"],
        threshold=0.30,
        top_n=5,
        budget_sec=25.0,
        start_time=time.monotonic(),
    )
    entry = report["files"]["B.md"]

    # B.md still exists on disk here (we never deleted it) — this covers the
    # exists=True path as a baseline. The dedicated not-exists assertion
    # follows below.
    assert entry["exists"] is True

    (tmp_path / "B.md").unlink()

    report2 = doc_exit_report.build_report(
        root=str(tmp_path),
        dirty_paths=["B.md"],
        threshold=0.30,
        top_n=5,
        budget_sec=25.0,
        start_time=time.monotonic(),
    )
    entry2 = report2["files"]["B.md"]

    assert entry2["exists"] is False
    # Content checks must be empty — nothing to read.
    assert entry2["recall"] == []
    assert entry2["broken_outlinks"] == []
    # Once B.md no longer exists it drops out of all_files, so the A->B edge
    # is no longer a backward "inlink" (that relation is for edges landing
    # on a file that still exists) — it becomes a dangling reverse-edge
    # instead. inlinks/stale_inlinks are correctly empty here; dangling_refs
    # is where "who still links this deleted file" shows up.
    assert entry2["inlinks"] == []
    assert entry2["stale_inlinks"] == []
    # A deleted file does not need an inlink to be discovered; it needs other
    # files to stop linking it. So orphan=False for nonexistent files (the
    # actionable signal is dangling_refs, not orphan).
    assert entry2["orphan"] is False
    assert entry2["dangling_refs"] == ["A.md"]


def test_deleted_file_not_referenced_orphan_false(tmp_path):
    """Deleted file with zero inlinks must have orphan=False.

    Before the fix, a deleted file would report orphan=True because inlinks_set
    is empty. Now, any nonexistent file must have orphan=False (it doesn't need
    an index link; it needs other files to stop linking it).
    """
    _write(tmp_path / "orphaned.md", "# Orphaned\n\ncontent\n")
    # Create another file so the corpus is non-empty, avoiding unrelated
    # code paths that might be affected by a fully empty graph.
    _write(tmp_path / "other.md", "# Other\n\ncontent\n")

    report = doc_exit_report.build_report(
        root=str(tmp_path),
        dirty_paths=["orphaned.md"],
        threshold=0.30,
        top_n=5,
        budget_sec=25.0,
        start_time=time.monotonic(),
    )
    entry = report["files"]["orphaned.md"]
    assert entry["exists"] is True
    assert entry["orphan"] is True  # True while it exists

    (tmp_path / "orphaned.md").unlink()

    report2 = doc_exit_report.build_report(
        root=str(tmp_path),
        dirty_paths=["orphaned.md"],
        threshold=0.30,
        top_n=5,
        budget_sec=25.0,
        start_time=time.monotonic(),
    )
    entry2 = report2["files"]["orphaned.md"]
    assert entry2["exists"] is False
    # After deletion, even though it has no inlinks, orphan must be False.
    assert entry2["orphan"] is False
    assert entry2["dangling_refs"] == []


def test_deleted_file_with_dangling_refs_orphan_false(tmp_path):
    """Deleted file with dangling_refs must have orphan=False (not True).

    This is the main regression test: before the fix, a deleted file that
    other files still link to would report both orphan=True (wrong) and
    dangling_refs non-empty (right). The orphan signal should never be True
    for a nonexistent file.
    """
    _write(tmp_path / "A.md", "# A\n\n[b](B.md)\n")
    _write(tmp_path / "B.md", "# B\n\ncontent\n")

    report = doc_exit_report.build_report(
        root=str(tmp_path),
        dirty_paths=["B.md"],
        threshold=0.30,
        top_n=5,
        budget_sec=25.0,
        start_time=time.monotonic(),
    )
    entry = report["files"]["B.md"]
    assert entry["exists"] is True

    (tmp_path / "B.md").unlink()

    report2 = doc_exit_report.build_report(
        root=str(tmp_path),
        dirty_paths=["B.md"],
        threshold=0.30,
        top_n=5,
        budget_sec=25.0,
        start_time=time.monotonic(),
    )
    entry2 = report2["files"]["B.md"]
    assert entry2["exists"] is False
    # The critical assertion: deleted files must have orphan=False, even with dangling_refs.
    assert entry2["orphan"] is False
    assert entry2["dangling_refs"] == ["A.md"]


# ---------------------------------------------------------------------------
# stale_inlinks: dirty_set filtering
# ---------------------------------------------------------------------------

def test_stale_inlinks_filters_out_dirty_set_members(tmp_path):
    _write(tmp_path / "A.md", "# A\n\n[b](B.md)\n")
    _write(tmp_path / "B.md", "# B\n\ncontent\n")

    # A is also dirty -> must NOT appear in B's stale_inlinks.
    report = doc_exit_report.build_report(
        root=str(tmp_path),
        dirty_paths=["B.md", "A.md"],
        threshold=0.30,
        top_n=5,
        budget_sec=25.0,
        start_time=time.monotonic(),
    )
    entry = report["files"]["B.md"]
    assert entry["inlinks"] == ["A.md"]
    assert entry["stale_inlinks"] == []

    # A NOT dirty -> must appear in B's stale_inlinks.
    report2 = doc_exit_report.build_report(
        root=str(tmp_path),
        dirty_paths=["B.md"],
        threshold=0.30,
        top_n=5,
        budget_sec=25.0,
        start_time=time.monotonic(),
    )
    entry2 = report2["files"]["B.md"]
    assert entry2["stale_inlinks"] == ["A.md"]


# ---------------------------------------------------------------------------
# A2: dirty_superset vs report set — an excluded-from-reporting linker that
# is nonetheless git-dirty must still count as "touched" for stale_inlinks
# self-termination (#219).
# ---------------------------------------------------------------------------

def test_dirty_superset_retires_stale_inlinks_for_excluded_linker(tmp_path):
    # SKILL.md links B.md. SKILL.md is basename-excluded from doc-exit.sh's
    # report set (see _doc_gate_exclude.sh), so the bash caller's FILTERED
    # report set never includes it — but it IS git-dirty. Without the A2
    # fix, dirty_set would be derived from the filtered report set alone,
    # so SKILL.md editing it can never retire this finding.
    _write(tmp_path / "SKILL.md", "# Skill\n\n[b](B.md)\n")
    _write(tmp_path / "B.md", "# B\n\ncontent\n")

    # Report set (what doc-exit.sh actually iterates/reports on) excludes
    # SKILL.md — only B.md is a report target here, matching real behavior.
    report = doc_exit_report.build_report(
        root=str(tmp_path),
        dirty_paths=["B.md"],
        threshold=0.30,
        top_n=5,
        budget_sec=25.0,
        start_time=time.monotonic(),
        dirty_superset=["B.md", "SKILL.md"],
    )
    entry = report["files"]["B.md"]
    assert entry["inlinks"] == ["SKILL.md"]
    # The core assertion: SKILL.md must NOT appear in stale_inlinks, because
    # the superset says it has been touched too.
    assert entry["stale_inlinks"] == []


def test_dirty_superset_omitted_falls_back_to_report_set(tmp_path):
    # Without dirty_superset, behavior must be identical to before A2 —
    # dirty_set derives from dirty_paths alone.
    _write(tmp_path / "SKILL.md", "# Skill\n\n[b](B.md)\n")
    _write(tmp_path / "B.md", "# B\n\ncontent\n")

    report = doc_exit_report.build_report(
        root=str(tmp_path),
        dirty_paths=["B.md"],
        threshold=0.30,
        top_n=5,
        budget_sec=25.0,
        start_time=time.monotonic(),
    )
    entry = report["files"]["B.md"]
    assert entry["stale_inlinks"] == ["SKILL.md"]


# ---------------------------------------------------------------------------
# A6: recall must NOT gate has_findings, even in isolation (#219). The bats
# "recall uses final full-text content" test can't isolate this: its
# "other.md" target has zero inlinks, so orphan=True already forces
# has_findings independent of recall. This fixture uses two files that link
# EACH OTHER (both indexed, neither orphan, neither stale since both are
# dirty) so recall is the only non-empty field on the target entry.
# ---------------------------------------------------------------------------

def test_recall_alone_does_not_gate_has_findings(tmp_path):
    _write(
        tmp_path / "topic.md",
        "# Topic\n\n[other](other.md)\n\n配置文件热重载与动态刷新机制说明甲配置文件热重载与动态刷新机制。\n",
    )
    _write(
        tmp_path / "other.md",
        "# Other\n\n[topic](topic.md)\n\n配置文件热重载与动态刷新机制说明乙配置文件热重载与动态刷新机制补充。\n",
    )

    report = doc_exit_report.build_report(
        root=str(tmp_path),
        dirty_paths=["other.md"],
        threshold=0.10,
        top_n=5,
        budget_sec=25.0,
        start_time=time.monotonic(),
        dirty_superset=["other.md", "topic.md"],
    )
    entry = report["files"]["other.md"]
    assert entry["orphan"] is False
    assert entry["stale_inlinks"] == []
    assert entry["broken_outlinks"] == []
    assert entry["dangling_refs"] == []
    # recall is the ONLY non-empty signal on this entry.
    assert len(entry["recall"]) > 0
    assert entry["recall"][0]["path"] == "topic.md"
    # The core assertion: recall alone must not gate has_findings.
    assert report["has_findings"] is False


# ---------------------------------------------------------------------------
# has_findings: inlinks alone must NOT count as a finding
# ---------------------------------------------------------------------------

def test_has_findings_false_when_only_inlinks_nonempty(tmp_path):
    # A 3-cycle (A->B->C->A) so every file has a non-empty, non-stale
    # inlinks set (each linker is itself dirty too) and none is an orphan —
    # isolating inlinks as the ONLY non-empty field on every entry.
    _write(tmp_path / "A.md", "# A\n\n[b](B.md)\n\n配置文件热重载说明甲。\n")
    _write(tmp_path / "B.md", "# B\n\n[c](C.md)\n\n动态刷新机制说明乙。\n")
    _write(tmp_path / "C.md", "# C\n\n[a](A.md)\n\n完全无关的占位内容丙。\n")

    report = doc_exit_report.build_report(
        root=str(tmp_path),
        dirty_paths=["A.md", "B.md", "C.md"],
        threshold=0.30,
        top_n=5,
        budget_sec=25.0,
        start_time=time.monotonic(),
    )
    for name, linker in (("A.md", "C.md"), ("B.md", "A.md"), ("C.md", "B.md")):
        entry = report["files"][name]
        assert entry["inlinks"] == [linker], name
        assert entry["stale_inlinks"] == [], name
        assert entry["orphan"] is False, name
        assert entry["recall"] == [], name
        assert entry["broken_outlinks"] == [], name
        assert entry["dangling_refs"] == [], name
    assert report["has_findings"] is False


# ---------------------------------------------------------------------------
# Budget: degraded flag + recall skipped, graph checks unaffected
# ---------------------------------------------------------------------------

def test_budget_exceeded_sets_degraded_and_skips_recall_but_keeps_graph_checks(tmp_path):
    _write(tmp_path / "A.md", "# A\n\n[b](B.md)\n")
    _write(tmp_path / "B.md", "# B\n\ncontent that would otherwise be recall-scored\n")

    # start_time far enough in the past that elapsed > budget_sec=0 is
    # already true before the first rank_candidates call.
    stale_start = time.monotonic() - 1000.0

    report = doc_exit_report.build_report(
        root=str(tmp_path),
        dirty_paths=["B.md"],
        threshold=0.0,
        top_n=5,
        budget_sec=0.0,
        start_time=stale_start,
    )

    assert report["degraded"] is True
    assert report["degraded_reason"] != ""

    entry = report["files"]["B.md"]
    # Content-based check (recall) skipped under budget pressure.
    assert entry["recall"] == []
    # Graph-only checks still produced.
    assert entry["inlinks"] == ["A.md"]
    assert entry["stale_inlinks"] == ["A.md"]
    assert entry["orphan"] is False


def test_budget_not_exceeded_runs_recall_normally(tmp_path):
    _write(tmp_path / "topic.md", "# Topic\n\n重复关键字重复关键字重复关键字用于命中查重。\n")
    _write(tmp_path / "other.md", "# Other\n\n重复关键字重复关键字重复关键字用于命中查重加一些补充。\n")

    report = doc_exit_report.build_report(
        root=str(tmp_path),
        dirty_paths=["other.md"],
        threshold=0.10,
        top_n=5,
        budget_sec=25.0,
        start_time=time.monotonic(),
    )
    entry = report["files"]["other.md"]
    assert not report["degraded"]
    paths_found = {c["path"] for c in entry["recall"]}
    assert "topic.md" in paths_found
