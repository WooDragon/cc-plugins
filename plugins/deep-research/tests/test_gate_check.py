import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "hooks"))
import gate_check  # noqa: E402


class TestLocateProjectDir(unittest.TestCase):
    """插件化后研究项目可以在用户任意工作目录下，不再有固定的框架仓库根
    (REPO_ROOT) 做查找边界。copilot review on #25 最初修的 bug 依然适用：
    event cwd 落在项目子目录（如 pipeline/1_raw、deliverables）时要向上
    走到项目根，而不是 fail-open。区别只是上溯不再受 REPO_ROOT 约束，改
    为受 _MAX_WALKUP_LEVELS 层数上限约束。"""

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.base = Path(self.tmpdir.name).resolve()
        self.project_dir = self.base / "myproj"
        (self.project_dir / "pipeline" / "1_raw").mkdir(parents=True)

    def tearDown(self):
        self.tmpdir.cleanup()

    def test_cwd_is_project_dir_itself(self):
        event = {"cwd": str(self.project_dir)}
        self.assertEqual(gate_check._locate_project_dir(event, ""), self.project_dir)

    def test_cwd_nested_inside_pipeline_subdir_walks_up_to_project_root(self):
        nested = self.project_dir / "pipeline" / "1_raw"
        event = {"cwd": str(nested)}
        self.assertEqual(gate_check._locate_project_dir(event, ""), self.project_dir)

    def test_cwd_nested_in_sibling_deliverables_dir_walks_up_to_project_root(self):
        deliverables = self.project_dir / "deliverables"
        deliverables.mkdir(parents=True)
        event = {"cwd": str(deliverables)}
        self.assertEqual(gate_check._locate_project_dir(event, ""), self.project_dir)

    def test_walk_up_bounded_returns_none_when_pipeline_beyond_max_levels(self):
        # 把上限压到 2 层，再把 pipeline/ 放到 4 层深处——验证上溯确实有
        # 界，不会无限走到底找到项目根。
        with mock.patch.object(gate_check, "_MAX_WALKUP_LEVELS", 2):
            deep = self.project_dir / "pipeline" / "a" / "b" / "c" / "d"
            deep.mkdir(parents=True)
            event = {"cwd": str(deep)}
            self.assertIsNone(gate_check._locate_project_dir(event, ""))

    def test_missing_cwd_and_no_project_path_in_message_returns_none(self):
        self.assertIsNone(gate_check._locate_project_dir({}, "no path mentioned here"))

    def test_project_path_in_message_resolved_relative_to_cwd(self):
        # 没有固定 REPO_ROOT 可拼接了，message_text 里的 projects/xxx 相对
        # 路径改为相对 event.cwd 解析。
        nested_project = self.base / "workspace" / "projects" / "demo"
        (nested_project / "pipeline").mkdir(parents=True)
        event = {"cwd": str(self.base / "workspace")}
        message = "见 projects/demo/pipeline/verification/harvest-verify.json"
        self.assertEqual(gate_check._locate_project_dir(event, message), nested_project)

    def test_project_path_in_message_ignored_without_cwd(self):
        # 拿不到 cwd 时没有相对基准，该候选整体跳过（不臆造绝对路径）。
        self.assertIsNone(gate_check._locate_project_dir({}, "见 projects/demo/pipeline/x"))

    def test_message_path_with_dotdot_traversal_is_rejected(self):
        # copilot review on #37: message_text 不可信，含 .. 段的相对路径
        # （projects/../otherproj）不得 resolve 到 cwd 之外，否则可能核验
        # 错项目、放过错误的 GATE_VERDICT PASS。这类候选整体拒绝。
        sibling = self.base / "otherproj"
        (sibling / "pipeline").mkdir(parents=True)
        # cwd 下另建一个合法但无 pipeline 的 workspace，确保唯一能命中的
        # 只有穿越到的 sibling——若穿越未被拦，就会错误返回 sibling。
        workspace = self.base / "workspace"
        workspace.mkdir()
        event = {"cwd": str(workspace)}
        message = "见 projects/../../otherproj/pipeline/verification/x"
        self.assertIsNone(gate_check._locate_project_dir(event, message))

    def test_message_path_via_symlink_escaping_cwd_is_rejected(self):
        # copilot review on #37: 即便拦了 .. 段，若 cwd 下的 projects 是指向
        # 外部的 symlink，Path(cwd)/rel 仍会 resolve 到 cwd 之外。语义层围栏
        # （resolve 后必须仍在 cwd_resolved 下）必须拦住它。
        outside = self.base / "outside"
        (outside / "demo" / "pipeline").mkdir(parents=True)
        workspace = self.base / "ws"
        workspace.mkdir()
        # ws/projects -> ../outside （软链逃逸）
        (workspace / "projects").symlink_to(outside, target_is_directory=True)
        event = {"cwd": str(workspace)}
        message = "见 projects/demo/pipeline/verification/x"
        self.assertIsNone(gate_check._locate_project_dir(event, message))


class TestGatePassRegex(unittest.TestCase):
    """copilot review on #25: GATE_PASS_RE was not anchored to a standalone
    line, so a message that merely quotes the marker as a documentation
    example (e.g. "如 `GATE_VERDICT: G1 PASS`") could accidentally trip the
    hook. quality-gates.md specifies the marker must be its own line."""

    def test_matches_marker_on_its_own_line(self):
        self.assertIsNotNone(gate_check.GATE_PASS_RE.search("GATE_VERDICT: G1 PASS"))

    def test_matches_marker_as_last_line_of_multiline_message(self):
        text = "Sufficiency review complete.\n\nGATE_VERDICT: G1 PASS"
        self.assertIsNotNone(gate_check.GATE_PASS_RE.search(text))

    def test_does_not_match_marker_quoted_mid_sentence_as_example(self):
        text = "标记格式如 `GATE_VERDICT: G1 PASS`、`GATE_VERDICT: G3 RECYCLE`，仅供参考。"
        self.assertIsNone(gate_check.GATE_PASS_RE.search(text))

    def test_does_not_match_fail_or_recycle(self):
        self.assertIsNone(gate_check.GATE_PASS_RE.search("GATE_VERDICT: G1 FAIL"))
        self.assertIsNone(gate_check.GATE_PASS_RE.search("GATE_VERDICT: G1 RECYCLE"))

    def test_does_not_match_marker_with_trailing_content_on_same_line(self):
        # copilot review round 4 on #25: quality-gates.md defines the
        # marker as an *entire* line ("GATE_VERDICT: G<N> PASS|FAIL|RECYCLE"),
        # not just a line-start prefix -- trailing text after PASS must not
        # count as a genuine verdict declaration.
        text = "GATE_VERDICT: G1 PASS (pending final human sign-off)"
        self.assertIsNone(gate_check.GATE_PASS_RE.search(text))

    def test_matches_marker_with_trailing_whitespace_only(self):
        self.assertIsNotNone(gate_check.GATE_PASS_RE.search("GATE_VERDICT: G1 PASS   \n"))


if __name__ == "__main__":
    unittest.main()
