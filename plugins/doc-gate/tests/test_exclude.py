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

    corpus, all_files, _forward, _backward = build_corpus_and_graph(str(tmp_path))

    corpus_paths = {doc["path"] for doc in corpus}

    pipeline_rel = str(Path("pipeline") / "verification" / "a.md")
    deliverables_rel = str(Path("deliverables") / "final" / "report.md")
    docs_rel = str(Path("docs") / "guide.md")

    assert pipeline_rel not in all_files
    assert pipeline_rel not in corpus_paths

    assert deliverables_rel in all_files
    assert deliverables_rel in corpus_paths

    assert docs_rel in all_files
    assert docs_rel in corpus_paths
