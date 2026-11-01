import importlib.util
import os
import sys
from pathlib import Path

# recall-gate.py has a hyphen in its filename, so it can't be imported via
# plain `import` — load it by file path instead. _doc_gate_common must be on
# sys.path first since recall-gate.py imports it by bare module name.
_TOOLS_DIR = Path(__file__).resolve().parent.parent / "tools"
sys.path.insert(0, str(_TOOLS_DIR))
import _doc_gate_common as _common
_spec = importlib.util.spec_from_file_location("recall_gate", _TOOLS_DIR / "recall-gate.py")
recall_gate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(recall_gate)
build_corpus_and_graph = recall_gate.build_corpus_and_graph

_spec_graph = importlib.util.spec_from_file_location("docs_graph", _TOOLS_DIR / "docs-graph.py")
docs_graph = importlib.util.module_from_spec(_spec_graph)
_spec_graph.loader.exec_module(docs_graph)


def _write(path: Path, title: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"# {title}\n\n这是正文一句话。\n", encoding="utf-8")


def test_pipeline_excluded_deliverables_and_docs_included(tmp_path):
    _write(tmp_path / "pipeline" / "verification" / "a.md", "pipeline intermediate")
    _write(tmp_path / "deliverables" / "final" / "report.md", "final report")
    _write(tmp_path / "docs" / "guide.md", "guide")

    corpus, all_files, _forward, _backward, _dangling = build_corpus_and_graph(str(tmp_path))

    corpus_paths = {doc["path"] for doc in corpus}

    pipeline_rel = "pipeline/verification/a.md"
    deliverables_rel = "deliverables/final/report.md"
    docs_rel = "docs/guide.md"

    assert pipeline_rel not in all_files
    assert pipeline_rel not in corpus_paths

    assert deliverables_rel in all_files
    assert deliverables_rel in corpus_paths

    assert docs_rel in all_files
    assert docs_rel in corpus_paths


def test_intake_excluded(tmp_path):
    _write(tmp_path / "intake" / "requirements" / "research-goal.md", "G0 goal")
    _write(tmp_path / "intake" / "background" / "context.md", "background")
    _write(tmp_path / "deliverables" / "final" / "report.md", "final report")

    corpus, all_files, _forward, _backward, _dangling = build_corpus_and_graph(str(tmp_path))

    corpus_paths = {doc["path"] for doc in corpus}

    intake_goal = "intake/requirements/research-goal.md"
    intake_bg = "intake/background/context.md"
    deliverables_rel = "deliverables/final/report.md"

    assert intake_goal not in all_files
    assert intake_goal not in corpus_paths
    assert intake_bg not in all_files
    assert intake_bg not in corpus_paths

    assert deliverables_rel in all_files
    assert deliverables_rel in corpus_paths


# ---------------------------------------------------------------------------
# F1 (#289): every graph key is a repo-relative POSIX string, because the
# keys are looked up with paths that come from `git status --porcelain`,
# which always uses forward slashes. A platform-separator key (docs\a.md on
# Windows) can never match, so every nested file looked like an orphan and
# every inbound link to it looked dangling.
# ---------------------------------------------------------------------------

def test_nested_graph_keys_use_posix_separators_and_match_link_edges(tmp_path):
    (tmp_path / "docs" / "deep").mkdir(parents=True)
    (tmp_path / "docs" / "deep" / "target.md").write_text("# Target\n\nx\n", encoding="utf-8")
    (tmp_path / "docs" / "index.md").write_text(
        "# Index\n\n[t](deep/target.md)\n", encoding="utf-8"
    )

    _corpus, all_files, forward, backward, dangling = build_corpus_and_graph(str(tmp_path))

    # The key spelling a git-status-driven caller will use.
    assert "docs/deep/target.md" in all_files
    assert "docs/index.md" in all_files
    # No key carries a platform separator.
    assert not any("\\" in p for p in all_files)
    # The inlink from the sibling in a subdirectory is a real edge, not a
    # dangling one — this is exactly the pair that regressed on Windows.
    assert forward["docs/index.md"] == {"docs/deep/target.md"}
    assert backward["docs/deep/target.md"] == {"docs/index.md"}
    assert dangling == {}


# ---------------------------------------------------------------------------
# F2 (#290): a link to a real file inside an EXCLUDED_DIRS directory exists
# but is never indexed, so corpus membership must not be the existence
# oracle — otherwise every such link is reported broken/dangling.
# ---------------------------------------------------------------------------

def test_link_to_existing_file_in_excluded_dir_is_not_dangling(tmp_path):
    (tmp_path / ".claude" / "skills" / "x").mkdir(parents=True)
    (tmp_path / ".claude" / "skills" / "x" / "SKILL.md").write_text("# Skill\n\nx\n", encoding="utf-8")
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "guide.md").write_text(
        "# Guide\n\n[skill](../.claude/skills/x/SKILL.md)\n[gone](../.claude/skills/x/gone.md)\n",
        encoding="utf-8",
    )

    _corpus, all_files, forward, backward, dangling = build_corpus_and_graph(str(tmp_path))

    # Excluded from indexing, by design.
    assert "docs/guide.md" in all_files
    assert ".claude/skills/x/SKILL.md" not in all_files
    # The existing target is not an edge (not a node) and not dangling.
    assert forward["docs/guide.md"] == set()
    # A genuinely missing target under the same excluded directory still is.
    assert dangling == {".claude/skills/x/gone.md": {"docs/guide.md"}}


def test_link_to_existing_file_in_excluded_dir_is_not_broken_outlink(tmp_path):
    (tmp_path / ".claude" / "skills" / "x").mkdir(parents=True)
    (tmp_path / ".claude" / "skills" / "x" / "SKILL.md").write_text("# Skill\n\nx\n", encoding="utf-8")
    (tmp_path / "docs").mkdir()
    content = "# Guide\n\n[skill](../.claude/skills/x/SKILL.md)\n"
    (tmp_path / "docs" / "guide.md").write_text(content, encoding="utf-8")

    _corpus, all_files, _forward, _backward, _dangling = build_corpus_and_graph(str(tmp_path))

    broken = recall_gate.check_broken_outlinks(content, "docs/guide.md", str(tmp_path), all_files)
    assert broken == []


def test_broken_outlink_still_reports_genuinely_missing_markdown(tmp_path):
    (tmp_path / "docs").mkdir()
    content = "# Guide\n\n[gone](missing.md)\n"
    (tmp_path / "docs" / "guide.md").write_text(content, encoding="utf-8")

    _corpus, all_files, _forward, _backward, dangling = build_corpus_and_graph(str(tmp_path))

    broken = recall_gate.check_broken_outlinks(content, "docs/guide.md", str(tmp_path), all_files)
    assert broken == [{"target": "missing.md", "line": 3}]
    assert dangling == {"docs/missing.md": {"docs/guide.md"}}


# ---------------------------------------------------------------------------
# F3 (#290 review): existence must be case-EXACT. On macOS's default
# case-insensitive APFS a link spelled `Guide.md` resolves against an on-disk
# `guide.md`, so a bare `Path.exists()` exonerates a link that is broken on
# Linux and on CI. The baseline (pure `all_files` membership) reported it;
# the F2 fix (`resolved.exists()`) regressed it on macOS only. These tests
# pin the helper's behaviour, then pin that both call sites consult it.
# ---------------------------------------------------------------------------

def test_exists_with_exact_case_true_for_matching_spelling(tmp_path):
    (tmp_path / "guide.md").write_text("# Guide\n", encoding="utf-8")

    assert _common.exists_with_exact_case(tmp_path / "guide.md") is True


def test_exists_with_exact_case_false_for_wrong_leaf_case(tmp_path):
    (tmp_path / "guide.md").write_text("# Guide\n", encoding="utf-8")

    # Judged by the spelling we were given, not by a case-insensitive lookup.
    assert _common.exists_with_exact_case(tmp_path / "Guide.md") is False


def test_exists_with_exact_case_false_for_wrong_directory_case(tmp_path):
    (tmp_path / "Docs").mkdir()
    (tmp_path / "Docs" / "inner.md").write_text("# Inner\n", encoding="utf-8")

    assert _common.exists_with_exact_case(tmp_path / "Docs" / "inner.md") is True
    assert _common.exists_with_exact_case(tmp_path / "docs" / "inner.md") is False


def test_exists_with_exact_case_false_for_absent_path(tmp_path):
    assert _common.exists_with_exact_case(tmp_path / "nope.md") is False


def test_exists_with_exact_case_false_when_fs_lies_about_case(tmp_path, monkeypatch):
    """Simulate macOS APFS: `exists()` folds case, `os.listdir` does not.

    On a case-sensitive filesystem (Linux) the plain wrong-case assertions
    above are vacuously true — even a bare `path.exists()` returns False — so
    they cannot tell the exact-case helper apart from the bug it replaced.
    Forcing `exists()` to accept any spelling makes the two implementations
    diverge here on EVERY platform: the helper must still return False,
    because the directory listing only reports the real spelling.
    """
    (tmp_path / "guide.md").write_text("# Guide\n", encoding="utf-8")
    real_exists = Path.exists

    def case_insensitive_exists(self):
        if real_exists(self):
            return True
        try:
            names = {name.lower() for name in os.listdir(self.parent)}
        except OSError:
            return False
        return self.name.lower() in names

    monkeypatch.setattr(Path, "exists", case_insensitive_exists)

    assert _common.exists_with_exact_case(tmp_path / "Guide.md") is False


def test_dangling_branch_consults_exact_case_helper(tmp_path, monkeypatch):
    """build_corpus_and_graph's dangling branch must use the helper.

    Platform-neutral: spies on the helper reference recall-gate imported, so
    a regression back to `resolved.exists()` leaves the call list empty on
    Linux and Windows alike.
    """
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "index.md").write_text(
        "# Index\n\n[gone](missing.md)\n", encoding="utf-8"
    )
    calls = []
    real_helper = recall_gate.exists_with_exact_case

    def spy(path):
        calls.append(path)
        return real_helper(path)

    monkeypatch.setattr(recall_gate, "exists_with_exact_case", spy)

    _corpus, _all_files, _forward, _backward, dangling = build_corpus_and_graph(str(tmp_path))

    assert calls, "dangling branch must consult the exact-case existence helper"
    assert dangling == {"docs/missing.md": {"docs/index.md"}}


def test_broken_outlink_branch_consults_exact_case_helper(tmp_path, monkeypatch):
    """check_broken_outlinks' .md branch must use the helper (same reasoning)."""
    (tmp_path / "docs").mkdir()
    content = "# Index\n\n[gone](missing.md)\n"
    (tmp_path / "docs" / "index.md").write_text(content, encoding="utf-8")
    _corpus, all_files, _forward, _backward, _dangling = build_corpus_and_graph(str(tmp_path))
    calls = []
    real_helper = recall_gate.exists_with_exact_case

    def spy(path):
        calls.append(path)
        return real_helper(path)

    monkeypatch.setattr(recall_gate, "exists_with_exact_case", spy)

    broken = recall_gate.check_broken_outlinks(content, "docs/index.md", str(tmp_path), all_files)

    assert calls, "broken-outlink .md branch must consult the exact-case existence helper"
    assert broken == [{"target": "missing.md", "line": 3}]


# ---------------------------------------------------------------------------
# #220: docs-graph's own rglob scan must match .md case-insensitively, the
# same way recall-gate's corpus walk does. A case-sensitive filesystem
# otherwise drops X.MD from this CLI's graph entirely.
# ---------------------------------------------------------------------------

def test_docs_graph_scan_finds_uppercase_md_extension(tmp_path):
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "upper.MD").write_text("# Upper\n\nx\n", encoding="utf-8")
    (tmp_path / "docs" / "lower.md").write_text("# Lower\n\nx\n", encoding="utf-8")

    found = docs_graph.scan_all_files(tmp_path)

    names = {p.name for p in found}
    assert names == {"upper.MD", "lower.md"}


