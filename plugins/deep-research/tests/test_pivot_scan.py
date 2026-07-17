"""BDD coverage for pivot_scan.py -- the decision-pivot 作废集契约的确定性
扫描工具 (cc-plugins#126, 设计权威 research#48). Two contracts covered:

  1. --check-signoff: a pivot file is not "signed off" unless it has a
     non-empty "## 废止短语清单" section AND the signed_off section's
     "废止短语清单已列全" checkbox is ticked.
  2. --scan: the worklist it produces must be limited to deliverables/** +
     root CLAUDE.md/README.md, exclude intake/requirements/** and
     pipeline/**, and be byte-identical across repeated runs.
"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import pivot_scan  # noqa: E402

_SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "pivot_scan.py"


def _pivot(abrogation_section: str, signoff_checkbox: str) -> str:
    """Build a minimal pivot.md body with the given 废止短语清单 section body
    and signed_off checkbox line, mirroring decision-pivot.md.tmpl shape."""
    return f"""# 判据锚点变更 1 — 测试用例

## 变更动因（2026-07-17 用户决策原文要点）

1. 测试动因

## goal（判据正面）

- 测试判据

## non_goals（判据反面）

- **废止**测试项

## 废止短语清单

{abrogation_section}

## 研究类型

non-selection

## signed_off

- **对齐状态**：[x] 用户已确认
- **确认日期**：2026-07-17
{signoff_checkbox}
- **效力**：测试
"""


def _pivot_without_abrogation_section(signoff_checkbox: str) -> str:
    """Same shape as _pivot() but with the "## 废止短语清单" heading itself
    entirely absent (not just empty) -- covers the "section missing" branch
    distinct from "section present but empty"."""
    return f"""# 判据锚点变更 1 — 测试用例

## 变更动因（2026-07-17 用户决策原文要点）

1. 测试动因

## goal（判据正面）

- 测试判据

## non_goals（判据反面）

- **废止**测试项

## 研究类型

non-selection

## signed_off

- **对齐状态**：[x] 用户已确认
- **确认日期**：2026-07-17
{signoff_checkbox}
- **效力**：测试
"""


class TestCheckSignoff(unittest.TestCase):
    def test_missing_abrogation_section_fails(self):
        text = _pivot_without_abrogation_section(
            "- [x] 废止短语清单已列全（缺项则本 pivot 未生效）"
        )
        failures = pivot_scan.check_signoff(text)
        self.assertTrue(any("缺少 `## 废止短语清单` 段" in f for f in failures))

    def test_empty_abrogation_list_fails(self):
        text = _pivot("", "- [x] 废止短语清单已列全（缺项则本 pivot 未生效）")
        failures = pivot_scan.check_signoff(text)
        self.assertTrue(any("没有任何非空 bullet 短语" in f for f in failures))

    def test_populated_list_but_checkbox_unchecked_fails(self):
        text = _pivot(
            "- 需拆分多 gateway 落地\n- 待 Lead 裁决",
            "- [ ] 废止短语清单已列全（缺项则本 pivot 未生效）",
        )
        failures = pivot_scan.check_signoff(text)
        self.assertTrue(any("未打勾" in f for f in failures))

    def test_missing_checkbox_line_entirely_fails(self):
        text = _pivot("- 需拆分多 gateway 落地", "")
        failures = pivot_scan.check_signoff(text)
        self.assertTrue(any("缺少「废止短语清单已列全」勾选项" in f for f in failures))

    def test_fully_compliant_pivot_passes(self):
        text = _pivot(
            "- 需拆分多 gateway 落地\n- 待 Lead 裁决",
            "- [x] 废止短语清单已列全（缺项则本 pivot 未生效）",
        )
        self.assertEqual(pivot_scan.check_signoff(text), [])

    def test_uppercase_x_also_counts_as_checked(self):
        text = _pivot(
            "- 需拆分多 gateway 落地",
            "- [X] 废止短语清单已列全（缺项则本 pivot 未生效）",
        )
        self.assertEqual(pivot_scan.check_signoff(text), [])


class TestParseAbrogatedPhrases(unittest.TestCase):
    def test_html_comment_lines_are_not_treated_as_bullets(self):
        text = """## 废止短语清单

<!--
示例（仅供格式参考，非真实短语，填写时删除本示例块）：
  - 需拆分多 gateway 落地
-->

- 真实短语一
- 真实短语二

## signed_off
"""
        self.assertEqual(
            pivot_scan.parse_abrogated_phrases(text),
            ["真实短语一", "真实短语二"],
        )

    def test_section_absent_returns_none(self):
        self.assertIsNone(pivot_scan.parse_abrogated_phrases("# no sections here"))

    def test_heading_with_suffix_variant_is_still_matched(self):
        """`## 废止短语清单（附注）` must parse identically to the bare
        heading -- check-signoff and scan share `_match_abrogation_heading`,
        so a suffixed heading can't make one pass while the other fails."""
        text = """## 废止短语清单（附注）

- 真实短语一

## signed_off
"""
        self.assertEqual(
            pivot_scan.parse_abrogated_phrases(text), ["真实短语一"]
        )


class TestHeadingVariantConsistency(unittest.TestCase):
    """check-signoff and scan must reach the same conclusion for a pivot
    file whose 「废止短语清单」heading carries an allowed suffix -- they
    both go through `_match_abrogation_heading` via `parse_abrogated_phrases`,
    so there is exactly one matcher to keep in sync."""

    def _pivot_with_suffixed_heading(self) -> str:
        return """# 判据锚点变更 1 — 测试用例

## 变更动因（2026-07-17 用户决策原文要点）

1. 测试动因

## goal（判据正面）

- 测试判据

## non_goals（判据反面）

- **废止**测试项

## 废止短语清单（附注）

- 需拆分多 gateway 落地
- 待 Lead 裁决

## 研究类型

non-selection

## signed_off

- **对齐状态**：[x] 用户已确认
- **确认日期**：2026-07-17
- [x] 废止短语清单已列全（缺项则本 pivot 未生效）
- **效力**：测试
"""

    def test_check_signoff_and_scan_agree_on_suffixed_heading(self):
        text = self._pivot_with_suffixed_heading()

        self.assertEqual(pivot_scan.check_signoff(text), [])

        tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(tmpdir.cleanup)
        root = Path(tmpdir.name)
        (root / "CLAUDE.md").write_text("仍需拆分多 gateway 落地\n", encoding="utf-8")

        hits = pivot_scan.scan_worklist(text, root)
        self.assertIn(
            ("CLAUDE.md", 1, "需拆分多 gateway 落地", "仍需拆分多 gateway 落地"),
            hits,
        )


class TestCheckSignoffCli(unittest.TestCase):
    """Subprocess-level coverage of the --check-signoff exit code contract,
    matching how a real Stage 6 gate invocation would call this script."""

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)

    def _write_pivot(self, text: str) -> str:
        path = Path(self.tmpdir.name) / "decision-pivot-1.md"
        path.write_text(text, encoding="utf-8")
        return str(path)

    def test_exit_1_when_abrogation_section_missing(self):
        text = _pivot_without_abrogation_section(
            "- [x] 废止短语清单已列全（缺项则本 pivot 未生效）"
        )
        pivot_path = self._write_pivot(text)
        result = subprocess.run(
            [sys.executable, str(_SCRIPT), "--check-signoff", pivot_path],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("废止短语清单", result.stderr)

    def test_exit_1_when_checkbox_unticked(self):
        text = _pivot(
            "- 需拆分多 gateway 落地",
            "- [ ] 废止短语清单已列全（缺项则本 pivot 未生效）",
        )
        pivot_path = self._write_pivot(text)
        result = subprocess.run(
            [sys.executable, str(_SCRIPT), "--check-signoff", pivot_path],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 1)

    def test_exit_0_when_fully_compliant(self):
        text = _pivot(
            "- 需拆分多 gateway 落地\n- 待 Lead 裁决",
            "- [x] 废止短语清单已列全（缺项则本 pivot 未生效）",
        )
        pivot_path = self._write_pivot(text)
        result = subprocess.run(
            [sys.executable, str(_SCRIPT), "--check-signoff", pivot_path],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")


class TestScanWorklist(unittest.TestCase):
    """Builds a fixture project with abrogated-phrase hits scattered across
    deliverables/, CLAUDE.md, intake/requirements/, and pipeline/ -- then
    asserts the worklist only surfaces the in-scope hits, with exact
    file:line precision and stable sort order."""

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.root = Path(self.tmpdir.name)

        self.pivot_text = _pivot(
            "- 需拆分多 gateway 落地\n- 待 Lead 裁决",
            "- [x] 废止短语清单已列全（缺项则本 pivot 未生效）",
        )

        # In-scope hit #1: deliverables/final/x.md
        final_dir = self.root / "deliverables" / "final"
        final_dir.mkdir(parents=True)
        (final_dir / "x.md").write_text(
            "第一行无关\n仍需拆分多 gateway 落地才行\n第三行无关\n",
            encoding="utf-8",
        )

        # In-scope hit #2: root CLAUDE.md
        (self.root / "CLAUDE.md").write_text(
            "开放项待 Lead 裁决\n次要行\n",
            encoding="utf-8",
        )

        # Out-of-scope: intake/requirements/y.md (explicitly excluded)
        intake_dir = self.root / "intake" / "requirements"
        intake_dir.mkdir(parents=True)
        (intake_dir / "y.md").write_text(
            "历史锚点：需拆分多 gateway 落地\n", encoding="utf-8"
        )

        # Out-of-scope: pipeline/z.md (explicitly excluded, machine intermediate)
        pipeline_dir = self.root / "pipeline"
        pipeline_dir.mkdir(parents=True)
        (pipeline_dir / "z.md").write_text(
            "原始数据：待 Lead 裁决\n", encoding="utf-8"
        )

    def test_worklist_contains_deliverables_hit_with_exact_file_and_line(self):
        hits = pivot_scan.scan_worklist(self.pivot_text, self.root)
        self.assertIn(
            ("deliverables/final/x.md", 2, "需拆分多 gateway 落地", "仍需拆分多 gateway 落地才行"),
            hits,
        )

    def test_worklist_contains_root_claude_md_hit(self):
        hits = pivot_scan.scan_worklist(self.pivot_text, self.root)
        self.assertIn(
            ("CLAUDE.md", 1, "待 Lead 裁决", "开放项待 Lead 裁决"),
            hits,
        )

    def test_worklist_excludes_intake_requirements_hits(self):
        hits = pivot_scan.scan_worklist(self.pivot_text, self.root)
        paths = {h[0] for h in hits}
        self.assertFalse(any(p.startswith("intake/") for p in paths))

    def test_worklist_excludes_pipeline_hits(self):
        hits = pivot_scan.scan_worklist(self.pivot_text, self.root)
        paths = {h[0] for h in hits}
        self.assertFalse(any(p.startswith("pipeline/") for p in paths))

    def test_worklist_sorted_by_path_then_line_then_phrase(self):
        hits = pivot_scan.scan_worklist(self.pivot_text, self.root)
        sort_keys = [(h[0], h[1], h[2]) for h in hits]
        self.assertEqual(sort_keys, sorted(sort_keys))

    def test_scan_twice_produces_byte_identical_output(self):
        out1 = pivot_scan._format_worklist(
            pivot_scan.scan_worklist(self.pivot_text, self.root)
        )
        out2 = pivot_scan._format_worklist(
            pivot_scan.scan_worklist(self.pivot_text, self.root)
        )
        self.assertEqual(out1, out2)

    def test_cli_scan_twice_produces_byte_identical_stdout(self):
        pivot_path = self.root / "decision-pivot-1.md"
        pivot_path.write_text(self.pivot_text, encoding="utf-8")
        cmd = [
            sys.executable,
            str(_SCRIPT),
            "--scan",
            str(pivot_path),
            "--root",
            str(self.root),
        ]
        result1 = subprocess.run(cmd, capture_output=True, text=True)
        result2 = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(result1.returncode, 0)
        self.assertEqual(result1.stdout, result2.stdout)
        self.assertIn("deliverables/final/x.md:2", result1.stdout)
        self.assertIn("CLAUDE.md:1", result1.stdout)
        self.assertNotIn("intake/", result1.stdout)
        self.assertNotIn("pipeline/", result1.stdout)

    def test_worklist_row_has_four_tab_separated_fields_with_empty_classification(self):
        pivot_path = self.root / "decision-pivot-1.md"
        pivot_path.write_text(self.pivot_text, encoding="utf-8")
        cmd = [
            sys.executable,
            str(_SCRIPT),
            "--scan",
            str(pivot_path),
            "--root",
            str(self.root),
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        first_line = result.stdout.splitlines()[0]
        fields = first_line.split("\t")
        self.assertEqual(len(fields), 4)
        self.assertEqual(fields[3], "")  # 分类留空交人工填

    def test_scan_cli_exits_1_when_abrogation_list_empty(self):
        empty_pivot = _pivot("", "- [x] 废止短语清单已列全（缺项则本 pivot 未生效）")
        pivot_path = self.root / "empty-pivot.md"
        pivot_path.write_text(empty_pivot, encoding="utf-8")
        result = subprocess.run(
            [
                sys.executable,
                str(_SCRIPT),
                "--scan",
                str(pivot_path),
                "--root",
                str(self.root),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 1)

    def test_deliverables_missing_does_not_crash_scan(self):
        # A brand-new pivot may be scanned before deliverables/ exists at all.
        bare_root = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(bare_root, ignore_errors=True))
        (bare_root / "CLAUDE.md").write_text("待 Lead 裁决\n", encoding="utf-8")
        hits = pivot_scan.scan_worklist(self.pivot_text, bare_root)
        self.assertEqual(
            [h for h in hits if h[0] == "CLAUDE.md"],
            [("CLAUDE.md", 1, "待 Lead 裁决", "待 Lead 裁决")],
        )


class TestScanFailLoudMessages(unittest.TestCase):
    """scan_worklist must fail loud with a message that distinguishes the
    two dirty states -- "section missing" is not the same failure as
    "section present but empty", and the latter must never be conflated
    with a clean scan (an empty worklist reads as "nothing to fix")."""

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.root = Path(self.tmpdir.name)

    def test_missing_section_message_says_missing(self):
        text = _pivot_without_abrogation_section(
            "- [x] 废止短语清单已列全（缺项则本 pivot 未生效）"
        )
        with self.assertRaises(pivot_scan.PivotScanError) as ctx:
            pivot_scan.scan_worklist(text, self.root)
        self.assertIn("缺少 `## 废止短语清单` 段", str(ctx.exception))

    def test_empty_section_message_says_empty_and_refuses_silent_worklist(self):
        text = _pivot("", "- [x] 废止短语清单已列全（缺项则本 pivot 未生效）")
        with self.assertRaises(pivot_scan.PivotScanError) as ctx:
            pivot_scan.scan_worklist(text, self.root)
        self.assertIn("废止短语段存在但为空", str(ctx.exception))
        self.assertIn("拒绝产出空工单", str(ctx.exception))


class TestScanExcludesRenderedHtml(unittest.TestCase):
    """render.py output (report.html) is a deterministic function of
    report.md (cc-plugins#125/#130) -- scan must never touch it, hand-editing
    html would be silently overwritten by the next render and produce
    duplicate/uncommittable worklist entries."""

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.root = Path(self.tmpdir.name)
        self.pivot_text = _pivot(
            "- 需拆分多 gateway 落地",
            "- [x] 废止短语清单已列全（缺项则本 pivot 未生效）",
        )
        final_dir = self.root / "deliverables" / "final"
        final_dir.mkdir(parents=True)
        (final_dir / "report.md").write_text(
            "仍需拆分多 gateway 落地\n", encoding="utf-8"
        )
        (final_dir / "report.html").write_text(
            "<p>仍需拆分多 gateway 落地</p>\n", encoding="utf-8"
        )

    def test_html_hit_is_not_reported(self):
        hits = pivot_scan.scan_worklist(self.pivot_text, self.root)
        paths = {h[0] for h in hits}
        self.assertIn("deliverables/final/report.md", paths)
        self.assertNotIn("deliverables/final/report.html", paths)
        self.assertFalse(any(p.endswith(".html") for p in paths))


class TestFormatWorklistEscaping(unittest.TestCase):
    """A hit line that itself contains a literal tab (e.g. a markdown table
    row) must not be allowed to inject an extra TSV column and desync the
    4-field row contract that Stage 6 core-out relies on."""

    def test_literal_tab_in_line_content_is_escaped(self):
        hits = [("deliverables/final/x.md", 3, "需拆分多 gateway 落地", "| a\t仍需拆分多 gateway 落地 |")]
        output = pivot_scan._format_worklist(hits)
        fields = output.split("\t")
        # Escaped tab must not create a 5th field -- exactly 4 tab-delimited
        # columns (3 real tabs) survive.
        self.assertEqual(output.count("\t"), 3)
        self.assertIn("\\t", output)
        self.assertNotIn("| a\t仍", output)

    def test_literal_newline_in_line_content_is_escaped(self):
        hits = [("CLAUDE.md", 1, "待 Lead 裁决", "开放项待 Lead 裁决\n仍未决")]
        output = pivot_scan._format_worklist(hits)
        # A stray literal newline would split one worklist row into two --
        # the escaped output must remain a single line for this hit.
        self.assertEqual(len(output.splitlines()), 1)
        self.assertIn("\\n", output)


if __name__ == "__main__":
    unittest.main()
