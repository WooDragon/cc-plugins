import importlib.util
import sys
from pathlib import Path

# recall-gate.py has a hyphen in its filename, so it can't be imported via
# plain `import` — load it by file path instead. _doc_gate_common must be on
# sys.path first since recall-gate.py imports it by bare module name.
_TOOLS_DIR = Path(__file__).resolve().parent.parent / "tools"
sys.path.insert(0, str(_TOOLS_DIR))
_spec = importlib.util.spec_from_file_location("recall_gate", _TOOLS_DIR / "recall-gate.py")
recall_gate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(recall_gate)
build_corpus_and_graph = recall_gate.build_corpus_and_graph


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
