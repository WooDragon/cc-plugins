import json
import subprocess
import io
import sys
from pathlib import Path

# _doc_gate_common.py is imported by bare module name throughout this suite;
# tools/ must be on sys.path before importing it.
_TOOLS_DIR = Path(__file__).resolve().parent.parent / "tools"
sys.path.insert(0, str(_TOOLS_DIR))
import _doc_gate_common as _common


def test_ensure_utf8_stdout_does_not_crash_on_stringio(monkeypatch):
    monkeypatch.setattr(sys, "stdout", io.StringIO())
    _common.ensure_utf8_stdout()


def test_ensure_utf8_stdout_does_not_crash_on_none(monkeypatch):
    monkeypatch.setattr(sys, "stdout", None)
    _common.ensure_utf8_stdout()


def test_ensure_utf8_stdout_reconfigures_text_wrapper_to_utf8(monkeypatch):
    buffer = io.BytesIO()
    stream = io.TextIOWrapper(buffer, encoding="gbk", errors="strict")
    monkeypatch.setattr(sys, "stdout", stream)

    _common.ensure_utf8_stdout()

    assert stream.encoding == "utf-8"
    # A character outside GBK must now encode instead of raising.
    stream.write("\U0001F600")
    stream.flush()
    assert buffer.getvalue() == "\U0001F600".encode("utf-8")


def test_ensure_utf8_stdout_leaves_utf8_surrogateescape_untouched(monkeypatch):
    buffer = io.BytesIO()
    stream = io.TextIOWrapper(buffer, encoding="utf-8", errors="surrogateescape")
    monkeypatch.setattr(sys, "stdout", stream)

    _common.ensure_utf8_stdout()

    assert stream.encoding == "utf-8"
    assert stream.errors == "surrogateescape"
    stream.write("\udcff")
    stream.flush()
    assert buffer.getvalue() == b"\xff"


def test_ensure_utf8_stdout_recognises_utf8_encoding_aliases(monkeypatch):
    buffer = io.BytesIO()
    stream = io.TextIOWrapper(buffer, encoding="UTF8", errors="strict")
    monkeypatch.setattr(sys, "stdout", stream)

    _common.ensure_utf8_stdout()

    assert stream.encoding == "UTF8"
    assert stream.errors == "strict"


def test_docs_graph_json_output_is_utf8_on_native_filenames(tmp_path):
    names = ["emoji-\U0001F600.md", "中文文档.md"]
    for name in names:
        (tmp_path / name).write_text("# x\n", encoding="utf-8")

    completed = subprocess.run(
        [sys.executable, str(_TOOLS_DIR / "docs-graph.py"), "--root", str(tmp_path), "--json", "orphans"],
        capture_output=True,
        check=False,
    )

    assert completed.returncode == 0, completed.stderr
    assert sorted(json.loads(completed.stdout.decode("utf-8"))) == sorted(names)


def test_docs_graph_text_output_is_utf8_on_native_filenames(tmp_path):
    (tmp_path / "中文文档.md").write_text("# 中文\n\n[gone](GONE.md)\n", encoding="utf-8")

    completed = subprocess.run(
        [sys.executable, str(_TOOLS_DIR / "docs-graph.py"), "--root", str(tmp_path), "check"],
        capture_output=True,
        check=False,
    )

    assert completed.returncode == 1, completed.stderr
    assert "→" in completed.stdout.decode("utf-8")
