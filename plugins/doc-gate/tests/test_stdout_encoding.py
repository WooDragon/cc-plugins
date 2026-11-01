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
