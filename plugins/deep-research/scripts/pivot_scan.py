#!/usr/bin/env python3
"""pivot_scan.py -- decision-pivot 作废集契约的确定性扫描工具（stdlib-only）。

背景：decision-pivot-*.md 是"判据锚点变更"工件——旧判据被新判据废止后，若
不显式枚举旧判据在交付物里的"现行口吻"关键短语，dirty set 无法机械计算，
只能靠人肉评审逐轮撞见（cc-plugins#126，设计权威 research#48）。本脚本把
"废止短语清单"变成可确定性核销的锚：机器扫描交付物找到全部命中，人工只做
二分类（历史留档合法 / 现行口吻必改），Stage 6 从抽样撞见变逐项核销。

两个子命令：

  --check-signoff <pivot.md>
      校验 pivot 文件是否满足"废止短语清单已列全"的 sign-off 前提：
        1. `## 废止短语清单` 段存在，且至少含 1 条非空 bullet
        2. `## signed_off` 段的"废止短语清单已列全"勾选项为 [x]
      两项皆满足 exit 0；否则 exit 1，stderr 逐条列出缺失项。
      这一步不扫描交付物，只校验 pivot 文件自身的结构完整性——"未过
      check-signoff" 即代表本 pivot 未生效，Stage 6 不认。

  --scan <pivot.md> --root <project_dir>
      解析 pivot 文件的「废止短语清单」，对扫描范围做全量确定性 grep，逐
      命中输出工单到 stdout。scan 不依赖 --check-signoff 是否通过——两者
      是独立步骤，只要废止短语清单非空就能跑（signoff 状态不影响扫描
      结果本身）。

      每命中一行 TSV（4 列，末列留空交人工填）：
        文件相对路径:行号\t命中短语\t该行内容\t

      分类留空是有意设计：机器只产出确定性命中集，"历史留档合法" vs
      "现行口吻必改" 是语义判断，本脚本不越界代劳。

      「该行内容」列若含字面 tab/换行会被转义为 `\t`/`\n`（防 md 表格行
      撑破 TSV 列对齐，见 `_escape_tsv_field`），其余三列不含这类字符。

      **扫描范围**（issue #48 方案原文 + plan 低成本扩张）：
        - `deliverables/**` 下的 `.md` 文件（全部子目录，含 draft/final
          等，递归；只扫散文档，不扫其他后缀）
        - 项目根目录下的 `CLAUDE.md`、`README.md`（仅根目录，非递归）

      **显式不扫描**（各有既定理由，不是遗漏）：
        - `intake/requirements/**`（research-goal.md / supplement-*.md /
          既往 decision-pivot-*.md 等）：这些文件里的旧判据原句是有意
          保留的历史锚点，走既有"顶部横幅标注 + 冲突以最新 pivot 为准"
          惯例，不是需要核销的现行口吻污染；扫描它们只会产生噪声工单。
        - `pipeline/**`：机器中间产物（原始/脱敏/结构化/综合数据），不
          是面向读者的现行结论口吻，同样不在核销范围。
        - `deliverables/**` 下的非 `.md` 文件，尤其是 `report.html`：
          render.py 的确定性渲染产物（f(report.md)，cc-plugins#125/#130），
          手改它是错的——改 `.md` 后重渲即自动同步，html 不是独立的"现行
          口吻"来源，纳入扫描只会制造无法核销的重复工单。

      输出确定性：命中按 (文件相对路径, 行号, 短语) 排序，零时间戳/零
      随机——同一输入跑任意次字节级一致。

退出码：--check-signoff 不满足 / --scan 找不到可扫描的短语清单 / 参数错误
均 exit 1，stderr 给出可读原因；正常路径 exit 0。
"""
import argparse
import re
import sys
from pathlib import Path

_H2_RE = re.compile(r"^##\s+(.*\S)\s*$")
_ABROGATION_HEADING = "废止短语清单"
_SIGNOFF_HEADING = "signed_off"
_BULLET_RE = re.compile(r"^-\s+(.*\S)\s*$")
_SIGNOFF_CHECKLIST_MARKER = "废止短语清单已列全"
_CHECKBOX_RE = re.compile(r"\[([ xX])\]")

_SCAN_ROOT_FILES = ("CLAUDE.md", "README.md")
_SCAN_DELIVERABLES_DIR = "deliverables"


class PivotScanError(Exception):
    """业务性失败（非 Python 异常噪声）：调用方统一以 exit 1 + stderr 处理。"""


def _split_sections(text):
    """按顶层 `## ` 标题切分文本，返回 [(heading_text, body_lines), ...]。

    heading_text 是标题去掉前导 `## ` 与首尾空白后的纯文本（如
    "废止短语清单"、"signed_off"），body_lines 是该标题到下一个 `## `
    标题（或文件末尾）之间的原始行列表（不含标题行本身）。
    """
    sections = []
    heading = None
    body = []
    for line in text.splitlines():
        m = _H2_RE.match(line)
        if m:
            if heading is not None:
                sections.append((heading, body))
            heading = m.group(1)
            body = []
        elif heading is not None:
            body.append(line)
    if heading is not None:
        sections.append((heading, body))
    return sections


def _match_abrogation_heading(heading_text: str) -> bool:
    """判断某 `## ` 标题文本是否为「废止短语清单」标题。

    check-signoff 与 scan 必须对同一份 pivot 文件得出同一结论——两者共用
    本函数（经由 `parse_abrogated_phrases`），不允许各自实现一份匹配逻辑
    再悄悄跑偏。匹配规则：以 `_ABROGATION_HEADING` 开头即算命中，允许附加
    后缀（如 `废止短语清单（附注）`）；heading_text 已经过 `_H2_RE` 捕获，
    天然去除了 `##` 前缀与行首尾空白。
    """
    return heading_text.startswith(_ABROGATION_HEADING)


def parse_abrogated_phrases(text):
    """提取「废止短语清单」段下的 bullet 短语列表。

    返回 None 表示该段整体缺失（区别于"段存在但清单为空"，后者返回 []）。
    只识别以 `- ` 开头的行；段内的 HTML 注释/说明文字/占位符文本一律忽略
    （它们不以 `- ` 开头）。
    """
    for heading, body in _split_sections(text):
        if _match_abrogation_heading(heading):
            phrases = []
            for line in body:
                m = _BULLET_RE.match(line)
                if m:
                    phrase = m.group(1).strip()
                    if phrase:
                        phrases.append(phrase)
            return phrases
    return None


def check_signoff(text):
    """校验 pivot 文本是否满足「废止短语清单已列全」的 sign-off 前提。

    返回失败原因列表（人类可读，中文）；全部满足时返回空列表。
    """
    failures = []

    phrases = parse_abrogated_phrases(text)
    if phrases is None:
        failures.append("缺少 `## 废止短语清单` 段")
    elif len(phrases) == 0:
        failures.append("`## 废止短语清单` 段存在，但没有任何非空 bullet 短语")

    signoff_body = None
    for heading, body in _split_sections(text):
        if heading == _SIGNOFF_HEADING:
            signoff_body = body
            break

    if signoff_body is None:
        failures.append("缺少 `## signed_off` 段")
    else:
        marker_line = None
        for line in signoff_body:
            if _SIGNOFF_CHECKLIST_MARKER in line:
                marker_line = line
                break
        if marker_line is None:
            failures.append(
                f"`## signed_off` 段缺少「{_SIGNOFF_CHECKLIST_MARKER}」勾选项"
            )
        else:
            m = _CHECKBOX_RE.search(marker_line)
            if not m or m.group(1) not in ("x", "X"):
                failures.append(
                    f"「{_SIGNOFF_CHECKLIST_MARKER}」勾选项未打勾（仍是 [ ]）"
                )

    return failures


def _scan_scope_files(root: Path):
    """枚举扫描范围内的全部文件（见模块 docstring「扫描范围」）。

    返回按相对路径（posix 分隔符）排序的绝对路径列表，保证下游遍历顺序
    确定。deliverables/ 不存在时静默跳过（新建 pivot 可能尚未产出交付物）。
    """
    files = []

    deliverables = root / _SCAN_DELIVERABLES_DIR
    if deliverables.is_dir():
        for p in deliverables.rglob("*.md"):
            if p.is_file():
                files.append(p)

    for name in _SCAN_ROOT_FILES:
        p = root / name
        if p.is_file():
            files.append(p)

    return sorted(files, key=lambda p: p.relative_to(root).as_posix())


def scan_worklist(pivot_text: str, root: Path):
    """对 root 的扫描范围做全量确定性 grep，返回排序后的命中列表。

    每个命中是 (相对路径, 行号[1-based], 命中短语, 该行原文) 四元组。
    非 UTF-8 文本文件（如二进制附件）静默跳过，不算扫描失败。
    """
    phrases = parse_abrogated_phrases(pivot_text)
    if phrases is None:
        raise PivotScanError(
            "缺少 `## 废止短语清单` 段，无法扫描；先用 --check-signoff 确认"
            " pivot 文件已列全废止短语"
        )
    if len(phrases) == 0:
        raise PivotScanError(
            "废止短语段存在但为空，拒绝产出空工单（空结果会被误读为传播干净）"
        )

    hits = []
    for path in _scan_scope_files(root):
        try:
            content = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        rel = path.relative_to(root).as_posix()
        for lineno, line in enumerate(content.splitlines(), start=1):
            for phrase in phrases:
                if phrase in line:
                    hits.append((rel, lineno, phrase, line))

    hits.sort(key=lambda h: (h[0], h[1], h[2]))
    return hits


def _escape_tsv_field(text: str) -> str:
    """转义字段内的 tab/换行，防止破坏 4 列 TSV 结构。

    交付物原文（如 md 表格行）可能含字面 tab，未转义会撑破下游按 `\\t`
    切分的列对齐——工单是给人工核销读的，列错位比字面 `\\t`/`\\n` 更难
    发现、更容易误判分类。
    """
    return text.replace("\t", "\\t").replace("\n", "\\n")


def _format_worklist(hits):
    return "\n".join(
        f"{rel}:{lineno}\t{phrase}\t{_escape_tsv_field(line)}\t"
        for rel, lineno, phrase, line in hits
    )


def _read_pivot(path_str: str) -> str:
    path = Path(path_str)
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise PivotScanError(f"无法读取 pivot 文件 {path_str}: {exc}") from exc


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="pivot_scan.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--check-signoff",
        metavar="PIVOT_MD",
        help="校验 pivot 文件的废止短语清单 sign-off 前提，exit 0/1",
    )
    parser.add_argument(
        "--scan",
        metavar="PIVOT_MD",
        help="解析废止短语清单并对 --root 全量确定性 grep，工单输出到 stdout",
    )
    parser.add_argument(
        "--root",
        metavar="PROJECT_DIR",
        help="--scan 的扫描根目录（研究项目根，含 deliverables/、CLAUDE.md）",
    )
    args = parser.parse_args(argv)

    if args.check_signoff and args.scan:
        print("错误: --check-signoff 与 --scan 互斥，一次只能用一个", file=sys.stderr)
        return 1

    try:
        if args.check_signoff:
            text = _read_pivot(args.check_signoff)
            failures = check_signoff(text)
            if failures:
                print(f"NOT SIGNED OFF: {args.check_signoff}", file=sys.stderr)
                for reason in failures:
                    print(f"  - {reason}", file=sys.stderr)
                return 1
            return 0

        if args.scan:
            if not args.root:
                print("错误: --scan 必须同时提供 --root <project_dir>", file=sys.stderr)
                return 1
            text = _read_pivot(args.scan)
            root = Path(args.root)
            if not root.is_dir():
                print(f"错误: --root 不是目录: {args.root}", file=sys.stderr)
                return 1
            hits = scan_worklist(text, root)
            output = _format_worklist(hits)
            if output:
                print(output)
            return 0

        parser.print_help(sys.stderr)
        return 1
    except PivotScanError as exc:
        print(f"错误: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
