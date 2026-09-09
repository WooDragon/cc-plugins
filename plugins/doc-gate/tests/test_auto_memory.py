import importlib.util
import json
import pytest
import subprocess
import sys
import time
from pathlib import Path

_TOOLS_DIR = Path(__file__).resolve().parent.parent / "tools"
sys.path.insert(0, str(_TOOLS_DIR))


def _load_module(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, _TOOLS_DIR / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


recall_gate = _load_module("recall_gate_auto_memory", "recall-gate.py")
docs_graph = _load_module("docs_graph_auto_memory", "docs-graph.py")
doc_exit_report = _load_module("doc_exit_report_auto_memory", "doc-exit-report.py")
common = _load_module("doc_gate_common_auto_memory", "_doc_gate_common.py")


def _write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


_PATH_CASES = json.loads(
    (Path(__file__).resolve().parent / "fixtures" / "auto-memory-paths.json").read_text(
        encoding="utf-8"
    )
)


def _case_value(value: str, root: Path, ordinary_root: Path) -> str:
    return value.replace("ORDINARY_ROOT", str(ordinary_root)).replace("ROOT", str(root))


def test_auto_memory_path_matrix_is_lexical_and_root_aware(tmp_path):
    root = tmp_path / ".claude"
    ordinary_root = tmp_path / "ordinary"

    for case in _PATH_CASES:
        path = _case_value(case["path"], root, ordinary_root)
        case_root = _case_value(case["root"], root, ordinary_root)
        assert common.is_auto_memory_path(path, case_root) is case["expected"], case


def test_scanners_prune_auto_memory_before_reading_content(monkeypatch, tmp_path):
    root = tmp_path / ".claude"
    memory_file = root / "projects" / "fictional" / "memory" / "secret.md"
    docs_file = root / "projects" / "fictional" / "docs" / "guide.md"
    plans_file = root / "projects" / "fictional" / "plans" / "next.md"
    _write(memory_file, "# Private\n\nprivate-memory-token\n")
    _write(docs_file, "# Guide\n\npublic-doc-token\n")
    _write(plans_file, "# Plan\n\npublic-plan-token\n")

    original_read_text = Path.read_text
    reads = []

    def tracking_read_text(path, *args, **kwargs):
        reads.append(path.resolve())
        return original_read_text(path, *args, **kwargs)

    monkeypatch.setattr(Path, "read_text", tracking_read_text)
    corpus, all_files, _forward, _backward, _dangling = recall_gate.build_corpus_and_graph(str(root))
    graph_files = docs_graph.scan_all_files(root)
    graph_nodes, _outgoing, _graph_forward, _graph_backward = docs_graph.build_graph(root)

    assert "projects/fictional/memory/secret.md" not in all_files
    assert "projects/fictional/memory/secret.md" not in {doc["path"] for doc in corpus}
    assert docs_file.resolve() in graph_files
    assert plans_file.resolve() in graph_files
    assert memory_file.resolve() not in graph_files
    assert docs_file.resolve() in graph_nodes
    assert plans_file.resolve() in graph_nodes
    assert memory_file.resolve() not in graph_nodes
    assert memory_file.resolve() not in reads


@pytest.mark.parametrize("root_kind", ["ancestor", "memory", "memory-descendant"])
def test_scanners_skip_memory_at_each_root_depth(monkeypatch, tmp_path, root_kind):
    config_root = tmp_path / ".claude"
    memory_root = config_root / "projects" / "example" / "memory"
    _write(memory_root / "topic.md", "# Private\n\nprivate-memory-token\n")
    _write(
        memory_root / "nested" / "topic.md",
        "# Nested private\n\nnested-memory-token\n",
    )
    _write(
        config_root / "projects" / "example" / "docs" / "guide.md",
        "# Guide\n\npublic-doc-token\n",
    )
    root_by_kind = {
        "ancestor": tmp_path,
        "memory": memory_root,
        "memory-descendant": memory_root / "nested",
    }
    scan_root = root_by_kind[root_kind]

    def forbidden_read_text(*args, **kwargs):
        raise AssertionError("excluded subtree content must not be read")

    monkeypatch.setattr(Path, "read_text", forbidden_read_text)

    corpus, all_files, forward, backward, dangling = recall_gate.build_corpus_and_graph(
        str(scan_root)
    )
    assert corpus == []
    assert all_files == set()
    assert forward == {}
    assert backward == {}
    assert dangling == {}

    assert docs_graph.scan_all_files(scan_root) == set()
    nodes, outgoing, graph_forward, graph_backward = docs_graph.build_graph(scan_root)
    assert nodes == set()
    assert outgoing == {}
    assert graph_forward == {}
    assert graph_backward == {}


def test_memory_links_are_out_of_scope_but_normal_missing_markdown_is_not(tmp_path):
    root = tmp_path / ".claude"
    source = root / "projects" / "fictional" / "docs" / "guide.md"
    _write(
        source,
        "# Guide\n\n"
        "[existing memory](../memory/known.md#section)\n"
        "[encoded memory](../memory/future%20note.md#section)\n"
        "[normal missing](missing.md)\n",
    )
    _write(root / "projects" / "fictional" / "memory" / "known.md", "# Private\n")

    _corpus, _files, forward, _backward, dangling = recall_gate.build_corpus_and_graph(str(root))
    source_rel = "projects/fictional/docs/guide.md"
    assert forward[source_rel] == set()
    assert dangling == {"projects/fictional/docs/missing.md": {source_rel}}

    all_files, outgoing, _forward, _backward = docs_graph.build_graph(root)
    assert source.resolve() in all_files
    assert len(outgoing[source.resolve()]) == 1
    assert outgoing[source.resolve()][0][1] == "missing.md"


def test_standalone_report_filters_auto_memory_dirty_paths(tmp_path):
    root = tmp_path / ".claude"
    memory_rel = "projects/fictional/memory/entry.md"
    _write(root / memory_rel, "# Private\n\nsecret\n")

    report = doc_exit_report.build_report(
        root=str(root),
        dirty_paths=[memory_rel],
        threshold=0.30,
        top_n=5,
        budget_sec=25.0,
        start_time=time.monotonic(),
        dirty_superset=[memory_rel],
    )

    assert report["has_findings"] is False
    assert report["files"] == {}


def test_recall_cli_memory_target_returns_empty_schema_without_reading_fixture_content(tmp_path):
    root = tmp_path / ".claude"
    target = root / "projects" / "fictional" / "memory" / "entry.md"
    _write(target, "# Private\n\nprivate-memory-token\n")

    completed = subprocess.run(
        [
            sys.executable,
            str(_TOOLS_DIR / "recall-gate.py"),
            "--root",
            str(root),
            "--target-file",
            "projects/fictional/memory/entry.md",
            "gate",
        ],
        input="private-memory-token",
        text=True,
        capture_output=True,
        check=False,
    )

    assert completed.returncode == 0, completed.stderr
    assert json.loads(completed.stdout) == {
        "has_findings": False,
        "recall": [],
        "orphan": False,
        "broken_outlinks": [],
    }


def test_docs_graph_cli_ignores_memory_links_but_reports_normal_missing_link(tmp_path):
    root = tmp_path / ".claude"
    _write(
        root / "projects" / "fictional" / "docs" / "guide.md",
        "# Guide\n\n[memory](../memory/missing.md)\n[missing](missing.md)\n",
    )

    completed = subprocess.run(
        [sys.executable, str(_TOOLS_DIR / "docs-graph.py"), "--root", str(root), "check"],
        text=True,
        capture_output=True,
        check=False,
    )

    assert completed.returncode == 1
    assert "missing.md" in completed.stdout
    assert "../memory/missing.md" not in completed.stdout


def test_empty_filtered_report_returns_before_graph_build(monkeypatch, tmp_path):
    root = tmp_path / ".claude"
    memory_rel = "projects/example/memory/entry.md"
    _write(root / memory_rel, "# Private\n\ncontent\n")

    def unexpected_graph_build(*args, **kwargs):
        raise AssertionError("memory-only report must not build a graph")

    monkeypatch.setattr(doc_exit_report.recall_gate, "build_corpus_and_graph", unexpected_graph_build)
    report = doc_exit_report.build_report(
        root=str(root),
        dirty_paths=[memory_rel],
        threshold=0.30,
        top_n=5,
        budget_sec=0.0,
        start_time=time.monotonic(),
    )

    assert report == {
        "root": str(root),
        "degraded": False,
        "degraded_reason": "",
        "has_findings": False,
        "files": {},
    }


def test_report_cli_memory_only_batch_skips_budget_degrade(tmp_path):
    root = tmp_path / ".claude"
    memory_rel = "projects/example/memory/entry.md"
    _write(root / memory_rel, "# Private\n\ncontent\n")
    for index in range(25):
        _write(root / f"projects/example/docs/public-{index}.md", f"# Public {index}\n")

    completed = subprocess.run(
        [
            sys.executable,
            str(_TOOLS_DIR / "doc-exit-report.py"),
            "--root",
            str(root),
            "--budget-sec",
            "0",
        ],
        input=memory_rel + "\0",
        text=True,
        capture_output=True,
        check=False,
    )

    assert completed.returncode == 0, completed.stderr
    assert json.loads(completed.stdout) == {
        "root": str(root),
        "degraded": False,
        "degraded_reason": "",
        "has_findings": False,
        "files": {},
    }
