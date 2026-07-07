"""Unit tests for hooks/read_guard.py — 主 session 绝对规则门禁。

覆盖契约①（adr-main-session-cost-fix.md）的判定边界：agent_id 空/非空区分主/子、
Read/Bash 命中受管路径、白名单放行、fail-open 硬约束、Bash 读取模式解析。

fail-open 是硬约束：宁可漏检不可误伤（never break userspace）——测试特别覆盖
grep 检索/ls/find/非研究项目等必须放行的场景。
"""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "hooks"))
import read_guard  # noqa: E402


class _ProjectFixture(unittest.TestCase):
    """建一个含 pipeline/ 的假研究项目，pipeline 下放一个大文件、一个白名单文件。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.proj = Path(self.tmp.name).resolve() / "proj"
        (self.proj / "pipeline" / "verification").mkdir(parents=True)
        (self.proj / "deliverables" / "final").mkdir(parents=True)
        self.big = self.proj / "pipeline" / "verification" / "big-report.md"
        self.big.write_text("x" * 20000)  # > 8KB 阈值
        self.receipt = self.proj / "deliverables" / "final" / "g1-receipt.md"
        self.receipt.write_text("tiny receipt")
        self.verdict = self.proj / "pipeline" / "verification" / "G1-verdict.md"
        self.verdict.write_text("y" * 20000)  # 大文件但白名单命名

    def tearDown(self):
        self.tmp.cleanup()

    def _block(self, agent_id, tool_name, tool_input):
        return read_guard._should_block(
            agent_id, tool_name, tool_input, str(self.proj)
        )[0]


class TestAgentIdGate(_ProjectFixture):
    def test_subagent_reads_pipeline_passes(self):
        # agent_id 非空 = subagent，任何读取放行
        self.assertFalse(
            self._block("abc123", "Read", {"file_path": str(self.big)})
        )

    def test_main_session_reads_big_pipeline_file_blocked(self):
        self.assertTrue(
            self._block("", "Read", {"file_path": str(self.big)})
        )

    def test_none_agent_id_treated_as_main_session_blocked(self):
        # copilot review: agent_id 缺失(None)不能 fail-open——主 session 的事件本就
        # 携带空/缺失 agent_id，对 None 放行会让主 session 永远绕过门禁。None 必须
        # 与主 session 同路径处理：研究项目内 + 受管大文件 → 拦。
        self.assertTrue(
            self._block(None, "Read", {"file_path": str(self.big)})
        )

    def test_none_agent_id_non_research_project_passes_via_path_layer(self):
        # 真正的 fail-open 在路径层：None agent_id 但非研究项目 → 放行。
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "random.md"
            f.write_text("x" * 20000)
            self.assertFalse(
                read_guard._should_block(None, "Read", {"file_path": str(f)}, d)[0]
            )

    def test_main_session_reads_big_deliverables_file_blocked(self):
        big_deliv = self.proj / "deliverables" / "final" / "report.md"
        big_deliv.write_text("z" * 20000)
        self.assertTrue(
            self._block("", "Read", {"file_path": str(big_deliv)})
        )


class TestWhitelist(_ProjectFixture):
    def test_receipt_file_passes(self):
        self.assertFalse(
            self._block("", "Read", {"file_path": str(self.receipt)})
        )

    def test_verdict_named_file_passes_even_if_large(self):
        # *-verdict.md 白名单命名，即便 > 8KB 也放行
        self.assertFalse(
            self._block("", "Read", {"file_path": str(self.verdict)})
        )

    def test_small_file_under_threshold_passes(self):
        small = self.proj / "pipeline" / "small.md"
        small.write_text("small")
        self.assertFalse(
            self._block("", "Read", {"file_path": str(small)})
        )


class TestFailOpen(_ProjectFixture):
    def test_non_research_project_passes(self):
        # cwd 下无 pipeline/ → 非研究项目 → fail-open
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "random.md"
            f.write_text("x" * 20000)
            self.assertFalse(
                read_guard._should_block(
                    "", "Read", {"file_path": str(f)}, d
                )[0]
            )

    def test_read_without_file_path_passes(self):
        self.assertFalse(self._block("", "Read", {}))

    def test_bash_without_command_passes(self):
        self.assertFalse(self._block("", "Bash", {}))

    def test_unknown_tool_passes(self):
        self.assertFalse(
            self._block("", "Grep", {"pattern": "foo"})
        )


class TestBashReadDetection(_ProjectFixture):
    def test_cat_big_pipeline_file_blocked(self):
        self.assertTrue(
            self._block("", "Bash", {"command": f"cat {self.big}"})
        )

    def test_head_tail_sed_awk_blocked(self):
        for cmd in ("head", "tail", "sed -n 1,5p", "awk '{print}'"):
            self.assertTrue(
                self._block("", "Bash", {"command": f"{cmd} {self.big}"}),
                msg=f"{cmd} should block",
            )

    def test_grep_with_pattern_passes(self):
        # grep 带真实 pattern = 检索，不是读大文件 → 放行
        self.assertFalse(
            self._block("", "Bash", {"command": f"grep foobar {self.big}"})
        )

    def test_grep_empty_pattern_full_read_blocked(self):
        # grep "" file = 全量读 → 拦
        self.assertTrue(
            self._block("", "Bash", {"command": f'grep "" {self.big}'})
        )

    def test_ls_and_find_pass(self):
        self.assertFalse(
            self._block("", "Bash", {"command": f"ls -la {self.proj}/pipeline"})
        )
        self.assertFalse(
            self._block("", "Bash", {"command": f"find {self.proj} -name '*.md'"})
        )

    def test_echo_process_substitution_read_blocked(self):
        self.assertTrue(
            self._block("", "Bash", {"command": f'echo "$(< {self.big})"'})
        )

    def test_cat_whitelist_receipt_passes(self):
        self.assertFalse(
            self._block("", "Bash", {"command": f"cat {self.receipt}"})
        )

    def test_cat_file_outside_project_passes(self):
        # cat 一个不在受管目录的文件 → 放行
        outside = self.proj / "notes.md"
        outside.write_text("x" * 20000)
        self.assertFalse(
            self._block("", "Bash", {"command": f"cat {outside}"})
        )

    def test_subagent_cat_passes(self):
        self.assertFalse(
            self._block("sub1", "Bash", {"command": f"cat {self.big}"})
        )


if __name__ == "__main__":
    unittest.main()
