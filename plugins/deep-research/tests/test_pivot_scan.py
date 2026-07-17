"""BDD coverage for pivot_scan.py -- the decision-pivot 作废集契约的确定性
扫描工具 (cc-plugins#126, 设计权威 research#48). Two contracts covered:

  1. --check-signoff: a pivot file is not "signed off" unless it has a
     non-empty "## 废止短语清单" section (with at least one non-placeholder
     bullet) AND the signed_off section's two checkboxes are both ticked:
     "用户已确认决策变更/对齐状态" and "废止短语清单已列全" -- both anchored
     to a bullet line's checkbox syntax, not just substring presence anywhere
     in the file.
  2. --scan: the worklist it produces must be limited to deliverables/** +
     root CLAUDE.md/README.md, exclude intake/requirements/**, pipeline/**
     and symlinks, be byte-identical across repeated runs, and land on disk
     as a 4-column TSV under pipeline/verification/ (or --out override).
"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import pivot_scan  # noqa: E402

_SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "pivot_scan.py"

_DEFAULT_ALIGNMENT_LINE = "- [x] 用户已确认决策变更/对齐状态（原文要点见「变更动因」）"


def _pivot(
    abrogation_section: str,
    signoff_checkbox: str,
    alignment_checkbox: str = _DEFAULT_ALIGNMENT_LINE,
) -> str:
    """Build a minimal pivot.md body with the given 废止短语清单 section body
    and signed_off checkbox lines, mirroring decision-pivot.md.tmpl shape."""
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

{alignment_checkbox}
- **确认日期**：2026-07-17
{signoff_checkbox}
- **效力**：测试
"""


def _pivot_without_abrogation_section(
    signoff_checkbox: str, alignment_checkbox: str = _DEFAULT_ALIGNMENT_LINE
) -> str:
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

{alignment_checkbox}
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


class TestCheckSignoffPlaceholderRejection(unittest.TestCase):
    """A pivot copied from the template but never edited must not pass
    check-signoff just because its placeholder bullets happen to be
    non-empty strings -- placeholder text is not a user-supplied phrase."""

    def test_bracketed_placeholder_only_list_fails(self):
        text = _pivot(
            "- [待填写：短语 1]\n- [待填写：短语 2]",
            "- [x] 废止短语清单已列全（缺项则本 pivot 未生效）",
        )
        failures = pivot_scan.check_signoff(text)
        self.assertTrue(any("仅含未替换的模板占位符" in f for f in failures))

    def test_angle_bracket_placeholder_only_list_fails(self):
        text = _pivot(
            '- <此处填旧判据在交付物中的现行口吻短语，如"需拆分多 gateway 落地">',
            "- [x] 废止短语清单已列全（缺项则本 pivot 未生效）",
        )
        failures = pivot_scan.check_signoff(text)
        self.assertTrue(any("仅含未替换的模板占位符" in f for f in failures))

    def test_todo_tbd_placeholder_only_list_fails(self):
        text = _pivot(
            "- TODO\n- TBD 待补充",
            "- [x] 废止短语清单已列全（缺项则本 pivot 未生效）",
        )
        failures = pivot_scan.check_signoff(text)
        self.assertTrue(any("仅含未替换的模板占位符" in f for f in failures))

    def test_mixed_placeholder_and_real_phrase_passes_on_real_phrase_alone(self):
        """One real phrase alongside leftover placeholder bullets is enough
        to pass -- placeholders are filtered, not treated as poison for the
        whole section."""
        text = _pivot(
            "- [待填写：短语 1]\n- 需拆分多 gateway 落地",
            "- [x] 废止短语清单已列全（缺项则本 pivot 未生效）",
        )
        self.assertEqual(pivot_scan.check_signoff(text), [])
        self.assertEqual(
            pivot_scan.parse_abrogated_phrases(text), ["需拆分多 gateway 落地"]
        )


class TestCheckSignoffDualCheckbox(unittest.TestCase):
    """Both signed_off checkboxes must be ticked -- ticking only one is not
    sufficient sign-off."""

    def test_alignment_checkbox_unchecked_fails_even_if_abrogation_checked(self):
        text = _pivot(
            "- 需拆分多 gateway 落地",
            "- [x] 废止短语清单已列全（缺项则本 pivot 未生效）",
            alignment_checkbox="- [ ] 用户已确认决策变更/对齐状态（原文要点见「变更动因」）",
        )
        failures = pivot_scan.check_signoff(text)
        self.assertTrue(
            any("用户已确认决策变更/对齐状态" in f and "未打勾" in f for f in failures)
        )

    def test_abrogation_checkbox_unchecked_fails_even_if_alignment_checked(self):
        text = _pivot(
            "- 需拆分多 gateway 落地",
            "- [ ] 废止短语清单已列全（缺项则本 pivot 未生效）",
            alignment_checkbox="- [x] 用户已确认决策变更/对齐状态（原文要点见「变更动因」）",
        )
        failures = pivot_scan.check_signoff(text)
        self.assertTrue(any("废止短语清单已列全" in f and "未打勾" in f for f in failures))

    def test_alignment_checkbox_line_entirely_missing_fails(self):
        text = _pivot(
            "- 需拆分多 gateway 落地",
            "- [x] 废止短语清单已列全（缺项则本 pivot 未生效）",
            alignment_checkbox="- **对齐状态**：用户已确认（无 checkbox 语法）",
        )
        failures = pivot_scan.check_signoff(text)
        self.assertTrue(
            any(
                "缺少「用户已确认决策变更/对齐状态」勾选项" in f
                for f in failures
            )
        )

    def test_both_checked_passes(self):
        text = _pivot(
            "- 需拆分多 gateway 落地",
            "- [x] 废止短语清单已列全（缺项则本 pivot 未生效）",
            alignment_checkbox="- [x] 用户已确认决策变更/对齐状态（原文要点见「变更动因」）",
        )
        self.assertEqual(pivot_scan.check_signoff(text), [])


class TestCheckboxAnchoring(unittest.TestCase):
    """The checkbox marker must be anchored to the bullet's own checkbox
    syntax -- a note line or malformed bracket sequence that merely contains
    the marker substring must not be mistaken for a real, ticked checkbox."""

    def test_marker_text_in_prose_note_does_not_count_as_checked(self):
        text = _pivot(
            "- 需拆分多 gateway 落地",
            (
                "- 备注：废止短语清单已列全的判定标准见上文\n"
                "- [ ] 废止短语清单已列全（缺项则本 pivot 未生效）"
            ),
        )
        failures = pivot_scan.check_signoff(text)
        self.assertTrue(any("未打勾" in f for f in failures))

    def test_malformed_double_bracket_checkbox_does_not_count_as_checked(self):
        text = _pivot(
            "- 需拆分多 gateway 落地",
            "- [[x]] 废止短语清单已列全（缺项则本 pivot 未生效）",
        )
        failures = pivot_scan.check_signoff(text)
        self.assertTrue(
            any("缺少「废止短语清单已列全」勾选项" in f for f in failures)
        )

    def test_marker_inside_html_comment_does_not_count_as_checked(self):
        text = _pivot(
            "- 需拆分多 gateway 落地",
            (
                "<!-- - [x] 废止短语清单已列全（示例注释，非真实勾选） -->\n"
                "- [ ] 废止短语清单已列全（缺项则本 pivot 未生效）"
            ),
        )
        failures = pivot_scan.check_signoff(text)
        self.assertTrue(any("未打勾" in f for f in failures))


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

    def test_column_zero_bullet_inside_html_comment_is_not_collected(self):
        """A bullet at column 0 (no leading indent) inside an HTML comment
        block would slip past a naive `_BULLET_RE` check -- must still be
        excluded because it's commentary, not a real user-filled phrase."""
        text = """## 废止短语清单

<!--
- 顶格短语示例（应被忽略）
-->

- 真实短语一

## signed_off
"""
        self.assertEqual(
            pivot_scan.parse_abrogated_phrases(text), ["真实短语一"]
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

    def test_unrelated_heading_sharing_prefix_is_not_matched(self):
        """`startswith` used to be too loose: a heading like `废止短语清单
        已被废止说明` shares the literal prefix but means something entirely
        different (a note *about* a past abrogation list, not the list
        itself) -- it must not be treated as the 废止短语清单 section."""
        text = """## 废止短语清单已被废止说明

- 不应被当成废止短语

## signed_off
"""
        self.assertIsNone(pivot_scan.parse_abrogated_phrases(text))

    def test_placeholder_bullets_are_filtered_out(self):
        text = """## 废止短语清单

- [待填写：短语 1]
- 真实短语
- <占位符尖括号示例>
- TODO

## signed_off
"""
        self.assertEqual(pivot_scan.parse_abrogated_phrases(text), ["真实短语"])


class TestHeadingVariantConsistency(unittest.TestCase):
    """check-signoff and scan must reach the same conclusion for a pivot
    file whose 「废止短语清单」heading carries an allowed suffix -- they
    both go through `_match_abrogation_heading` via `parse_abrogated_phrases`,
    so there is exactly one matcher to keep in sync."""

    def _pivot_with_suffixed_heading(self) -> str:
        return f"""# 判据锚点变更 1 — 测试用例

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

{_DEFAULT_ALIGNMENT_LINE}
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

    def test_exit_1_when_only_placeholder_phrases_present(self):
        text = _pivot(
            "- [待填写：短语 1]",
            "- [x] 废止短语清单已列全（缺项则本 pivot 未生效）",
        )
        pivot_path = self._write_pivot(text)
        result = subprocess.run(
            [sys.executable, str(_SCRIPT), "--check-signoff", pivot_path],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("占位符", result.stderr)

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


class TestScanWorklistDiskOutput(unittest.TestCase):
    """--scan must land the worklist on disk (Stage 6 core-out target),
    default path pipeline/verification/pivot-worklist-<stem>.tsv, with
    --out able to override it. Content on disk must match stdout exactly."""

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
        (final_dir / "x.md").write_text(
            "仍需拆分多 gateway 落地\n", encoding="utf-8"
        )

    def test_default_worklist_path_created_with_matching_content(self):
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
        self.assertEqual(result.returncode, 0)

        expected_path = (
            self.root / "pipeline" / "verification" / "pivot-worklist-decision-pivot-1.tsv"
        )
        self.assertTrue(expected_path.is_file())
        on_disk = expected_path.read_text(encoding="utf-8")
        self.assertEqual(on_disk.rstrip("\n"), result.stdout.rstrip("\n"))
        self.assertIn(str(expected_path), result.stderr)

    def test_out_flag_overrides_default_path(self):
        pivot_path = self.root / "decision-pivot-1.md"
        pivot_path.write_text(self.pivot_text, encoding="utf-8")
        custom_out = self.root / "custom-dir" / "worklist.tsv"
        cmd = [
            sys.executable,
            str(_SCRIPT),
            "--scan",
            str(pivot_path),
            "--root",
            str(self.root),
            "--out",
            str(custom_out),
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertTrue(custom_out.is_file())

        default_path = (
            self.root / "pipeline" / "verification" / "pivot-worklist-decision-pivot-1.tsv"
        )
        self.assertFalse(default_path.exists())

    def test_worklist_file_has_four_column_schema(self):
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
        subprocess.run(cmd, capture_output=True, text=True, check=True)

        worklist_path = (
            self.root / "pipeline" / "verification" / "pivot-worklist-decision-pivot-1.tsv"
        )
        lines = worklist_path.read_text(encoding="utf-8").splitlines()
        self.assertTrue(lines)
        for line in lines:
            fields = line.split("\t")
            self.assertEqual(len(fields), 4)
            file_line, phrase, content, classification = fields
            self.assertIn(":", file_line)
            self.assertEqual(classification, "")


class TestScanOverwriteProtection(unittest.TestCase):
    """--scan must not silently clobber a worklist TSV that already carries
    human-filled classifications in column 4 -- rescanning after a pivot
    file gets a new phrase, or after deliverables/ content shifts, must not
    erase completed 人工核销 work. --force opts back into overwriting."""

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
        (final_dir / "x.md").write_text(
            "仍需拆分多 gateway 落地\n", encoding="utf-8"
        )
        self.pivot_path = self.root / "decision-pivot-1.md"
        self.pivot_path.write_text(self.pivot_text, encoding="utf-8")
        self.worklist_path = (
            self.root / "pipeline" / "verification" / "pivot-worklist-decision-pivot-1.tsv"
        )

    def _cmd(self, extra_args=None):
        cmd = [
            sys.executable,
            str(_SCRIPT),
            "--scan",
            str(self.pivot_path),
            "--root",
            str(self.root),
        ]
        return cmd + (extra_args or [])

    def test_rescan_refuses_to_overwrite_worklist_with_filled_classification(self):
        self.worklist_path.parent.mkdir(parents=True, exist_ok=True)
        pre_existing = "deliverables/final/x.md:1\t需拆分多 gateway 落地\t仍需拆分多 gateway 落地\t历史留档合法\n"
        self.worklist_path.write_text(pre_existing, encoding="utf-8")

        result = subprocess.run(self._cmd(), capture_output=True, text=True)

        self.assertEqual(result.returncode, 1)
        self.assertIn("拒绝静默覆盖", result.stderr)
        self.assertIn("--force", result.stderr)
        self.assertEqual(
            self.worklist_path.read_text(encoding="utf-8"), pre_existing
        )

    def test_force_flag_overwrites_worklist_with_filled_classification(self):
        self.worklist_path.parent.mkdir(parents=True, exist_ok=True)
        pre_existing = "deliverables/final/x.md:1\t需拆分多 gateway 落地\t仍需拆分多 gateway 落地\t历史留档合法\n"
        self.worklist_path.write_text(pre_existing, encoding="utf-8")

        result = subprocess.run(self._cmd(["--force"]), capture_output=True, text=True)

        self.assertEqual(result.returncode, 0)
        on_disk = self.worklist_path.read_text(encoding="utf-8")
        self.assertNotEqual(on_disk, pre_existing)
        self.assertIn("deliverables/final/x.md:1", on_disk)

    def test_rescan_overwrites_worklist_with_all_empty_classifications(self):
        self.worklist_path.parent.mkdir(parents=True, exist_ok=True)
        unclassified = "deliverables/final/x.md:1\t需拆分多 gateway 落地\t仍需拆分多 gateway 落地\t\n"
        self.worklist_path.write_text(unclassified, encoding="utf-8")

        result = subprocess.run(self._cmd(), capture_output=True, text=True)

        self.assertEqual(result.returncode, 0)
        self.assertEqual(
            self.worklist_path.read_text(encoding="utf-8").rstrip("\n"),
            result.stdout.rstrip("\n"),
        )

    def test_scan_to_nonexistent_worklist_path_needs_no_force(self):
        self.assertFalse(self.worklist_path.exists())
        result = subprocess.run(self._cmd(), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertTrue(self.worklist_path.is_file())


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

    def test_placeholder_only_section_refuses_silent_worklist(self):
        text = _pivot("- [待填写：短语 1]", "- [x] 废止短语清单已列全（缺项则本 pivot 未生效）")
        with self.assertRaises(pivot_scan.PivotScanError) as ctx:
            pivot_scan.scan_worklist(text, self.root)
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


class TestScanExcludesSymlinks(unittest.TestCase):
    """A symlink inside deliverables/ pointing outside the project must not
    be followed by rglob -- scan is scoped to the project, not wherever a
    symlink happens to point."""

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.root = Path(self.tmpdir.name)
        self.pivot_text = _pivot(
            "- 需拆分多 gateway 落地",
            "- [x] 废止短语清单已列全（缺项则本 pivot 未生效）",
        )

    def test_symlinked_md_file_in_deliverables_is_not_scanned(self):
        final_dir = self.root / "deliverables" / "final"
        final_dir.mkdir(parents=True)

        outside_dir = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(outside_dir, ignore_errors=True))
        outside_file = outside_dir / "outside.md"
        outside_file.write_text("仍需拆分多 gateway 落地\n", encoding="utf-8")

        symlink_path = final_dir / "linked.md"
        symlink_path.symlink_to(outside_file)

        hits = pivot_scan.scan_worklist(self.pivot_text, self.root)
        paths = {h[0] for h in hits}
        self.assertNotIn("deliverables/final/linked.md", paths)

    def test_symlinked_root_claude_md_is_not_scanned(self):
        outside_dir = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(outside_dir, ignore_errors=True))
        outside_file = outside_dir / "outside-claude.md"
        outside_file.write_text("需拆分多 gateway 落地\n", encoding="utf-8")

        (self.root / "CLAUDE.md").symlink_to(outside_file)

        hits = pivot_scan.scan_worklist(self.pivot_text, self.root)
        paths = {h[0] for h in hits}
        self.assertNotIn("CLAUDE.md", paths)


class TestFormatWorklistEscaping(unittest.TestCase):
    """A hit line that itself contains a literal tab (e.g. a markdown table
    row) must not be allowed to inject an extra TSV column and desync the
    4-field row contract that Stage 6 core-out relies on. The phrase column
    is user-supplied free text too and needs the same protection."""

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

    def test_literal_tab_in_phrase_column_is_escaped(self):
        hits = [("CLAUDE.md", 1, "短语\t含tab", "行内容不含tab")]
        output = pivot_scan._format_worklist(hits)
        fields = output.split("\t")
        self.assertEqual(len(fields), 4)
        self.assertEqual(output.count("\t"), 3)
        self.assertIn("短语\\t含tab", fields[1])


if __name__ == "__main__":
    unittest.main()
