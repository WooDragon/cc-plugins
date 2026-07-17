#!/usr/bin/env python3
"""pivot_scan.py -- decision-pivot 作废集契约的确定性扫描工具（stdlib-only）。

背景：decision-pivot-*.md 是"判据锚点变更"工件——旧判据被新判据废止后，若
不显式枚举旧判据在交付物里的"现行口吻"关键短语，dirty set 无法机械计算，
只能靠人肉评审逐轮撞见（cc-plugins#126，设计权威 research#48）。本脚本把
"废止短语清单"变成可确定性核销的锚：机器扫描交付物找到全部命中，落盘为
工单 TSV，人工只做二分类（历史留档合法 / 现行口吻必改）并回填该 TSV，
Stage 6 从抽样撞见变对盘上工单文件的逐行核销。

两个子命令：

  --check-signoff <pivot.md>
      校验 pivot 文件是否满足"废止短语清单已列全"的 sign-off 前提：
        1. `## 废止短语清单` 段存在，且至少含 1 条非空 bullet，且这些
           bullet 中至少 1 条不是模板占位符（`<...>` 尖括号占位，或含
           "待填写"/"TODO"/"TBD" 字样——这些是模板原文，不是用户真实
           填写的短语，计入会让半成品 pivot 假装"已列全"）
        2. `## signed_off` 段的两个 checkbox 均已勾选：
             ①「用户已确认决策变更/对齐状态」
             ②「废止短语清单已列全」
           两者都必须是锚定到 bullet 行首的合法任务列表语法
           `- [x] <marker 文本紧随>`——出现在备注行、HTML 注释、或
           `[[x]]` 之类畸形标记里的同名文本不算数（见 `_checkbox_pattern`）。
      全部满足 exit 0；否则 exit 1，stderr 逐条列出缺失项。
      这一步不扫描交付物，只校验 pivot 文件自身的结构完整性——"未过
      check-signoff" 即代表本 pivot 未生效，Stage 6 不认。

  --scan <pivot.md> --root <project_dir> [--out <worklist.tsv>]
      解析 pivot 文件的「废止短语清单」（占位符 bullet 已被过滤，不参与
      扫描），对扫描范围做全量确定性 grep，逐命中输出工单：既打印到
      stdout，也落盘到 TSV 文件（Stage 6 核销以盘上文件为准，可审计可
      复跑）。

      默认落盘路径：`<--root>/pipeline/verification/pivot-worklist-
      <pivot 文件名 stem>.tsv`（复用 reviewer 审阅报告的既有落盘目录
      `pipeline/verification/`）。`--out` 可覆写为任意路径。

      工单 schema（4 列 TSV，无表头，一行一命中）：
        1. 文件相对路径:行号
        2. 命中短语
        3. 该行内容（已转义）
        4. 分类（初始留空，人工回填，取值二选一：
           `历史留档合法` / `现行口吻必改`）

      分类留空是有意设计：机器只产出确定性命中集，"历史留档合法" vs
      "现行口吻必改" 是语义判断，本脚本不越界代劳。Stage 6 审阅据此
      TSV 逐行核销——每行分类列非空，且判为「现行口吻必改」的行对应
      位置已实际修订。

      第 2、3 列若含字面 tab/换行会被转义为 `\t`/`\n`（防 md 表格行、
      或含 tab 的用户短语撑破 TSV 列对齐，见 `_escape_tsv_field`）；
      第 1、4 列不含这类字符。

      **扫描范围**（issue #48 方案原文 + plan 低成本扩张）：
        - `deliverables/**` 下的 `.md` 文件（全部子目录，含 draft/final
          等，递归；只扫散文档，不扫其他后缀）
        - 项目根目录下的 `CLAUDE.md`、`README.md`（仅根目录，非递归）
        - 符号链接一律跳过（防越界扫描到项目外内容）

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
      随机——同一输入跑任意次字节级一致（stdout 与落盘文件皆然）。

      **落盘覆盖保护**：目标 TSV 若已存在且第 4 列（分类）至少一行非空
      ——说明人工已对该工单做过回填——默认拒绝静默覆盖，stderr 报错并
      exit 1，不写盘；加 `--force` 显式覆盖。本工具通篇的立场是消灭静默
      丢失（空工单 fail-loud、越界文件不扫），落盘覆盖同理：机器重扫产出
      的新工单不能无声吞掉人工已完成的分类判断，二者是同一条纪律的两面。

退出码：--check-signoff 不满足 / --scan 找不到可扫描的短语清单 / --scan
落盘目标已含人工回填分类且未加 --force / 参数错误均 exit 1，stderr 给出
可读原因；正常路径 exit 0。
"""
import argparse
import re
import sys
from pathlib import Path

_H2_RE = re.compile(r"^##\s+(.*\S)\s*$")
_ABROGATION_HEADING = "废止短语清单"
_SIGNOFF_HEADING = "signed_off"
_BULLET_RE = re.compile(r"^-\s+(.*\S)\s*$")

# signed_off 段必须双双打勾的两个 checkbox。marker 文本须紧随
# `- [x]`/`- [ ]` 之后（见 `_checkbox_pattern`）——不是"行内任意位置
# 出现该子串即算命中"，防备注行/HTML 注释/`[[x]]` 畸形标记误判通过。
_ALIGNMENT_CHECKLIST_MARKER = "用户已确认决策变更/对齐状态"
_SIGNOFF_CHECKLIST_MARKER = "废止短语清单已列全"
_SIGNOFF_CHECKBOXES = (
    (_ALIGNMENT_CHECKLIST_MARKER, "用户已确认决策变更/对齐状态"),
    (_SIGNOFF_CHECKLIST_MARKER, "废止短语清单已列全"),
)

# 模板占位符特征：整条短语被尖括号包裹，或含未替换的占位字样。命中任一
# 即不算"用户真实填写的废止短语"。
_PLACEHOLDER_SUBSTRINGS = ("待填写", "TODO", "TBD")

_SCAN_ROOT_FILES = ("CLAUDE.md", "README.md")
_SCAN_DELIVERABLES_DIR = "deliverables"
_WORKLIST_SUBDIR = ("pipeline", "verification")


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
    本函数（经由 `_find_abrogation_section`），不允许各自实现一份匹配
    逻辑再悄悄跑偏。匹配规则收紧为**精确匹配，或精确匹配 + 全角括号后缀**
    （如 `废止短语清单（附注）`）——`startswith` 式前缀匹配过宽，会让
    `## 废止短语清单已被废止说明` 这类语义完全不同的标题误命中；
    heading_text 已经过 `_H2_RE` 捕获，天然去除了 `##` 前缀与行首尾空白。
    """
    return heading_text == _ABROGATION_HEADING or heading_text.startswith(
        _ABROGATION_HEADING + "（"
    )


def _strip_html_comment_lines(lines):
    """过滤掉 HTML 注释块 `<!-- ... -->` 内的整行（含首尾标记行本身）。

    「废止短语清单」段的模板示例块用 HTML 注释包裹，注释内可能出现顶格
    `- 短语` 形态的示例文本（纯讲解用途，非用户真实填写）——不做注释态
    追踪的话，这类顶格 bullet 会被 `_BULLET_RE` 误收为真实短语。

    逐行状态机：遇到含 `<!--` 且同行不含 `-->` 的行即进入注释态，直到
    遇到含 `-->` 的行退出（该行本身也被丢弃）；同行内既含开又含闭标记的
    行整行丢弃，不拆解行内注释前后的内容——pivot 文件是人工撰写的结构化
    文档，不会出现这种同行混排，没必要为此增加解析复杂度。
    """
    out = []
    in_comment = False
    for line in lines:
        if in_comment:
            if "-->" in line:
                in_comment = False
            continue
        if "<!--" in line:
            if "-->" not in line:
                in_comment = True
            continue
        out.append(line)
    return out


def _is_placeholder_phrase(phrase: str) -> bool:
    """判断某条「废止短语清单」bullet 是否为未替换的模板占位符。

    两种占位符特征：
      - 整条短语被尖括号包裹（如 `<此处填……>`）
      - 含 "待填写"/"TODO"/"TBD" 字样（模板默认 bullet 即此形态）
    命中任一即视为占位符，不计为有效废止短语——否则用户复制模板后不改
    动默认 bullet 也能让 check-signoff 通过，"未列全不算生效"这条铁律
    对半成品路径就形同虚设。
    """
    if len(phrase) >= 2 and phrase.startswith("<") and phrase.endswith(">"):
        return True
    return any(marker in phrase for marker in _PLACEHOLDER_SUBSTRINGS)


def _extract_bullets(body):
    """从某 `## ` 段的 body 行中提取全部非空 bullet 短语（含占位符）。

    先剥离 HTML 注释块，再逐行以 `_BULLET_RE` 识别 `- ` 开头的行；段内
    非 bullet 的说明文字一律忽略。返回值可能含占位符短语，调用方按需
    过滤（`parse_abrogated_phrases` 过滤，`check_signoff` 需要区分"段
    全空" vs "段仅含占位符"两种不同的失败原因，因此各自处理一次）。
    """
    phrases = []
    for line in _strip_html_comment_lines(body):
        m = _BULLET_RE.match(line)
        if m:
            phrase = m.group(1).strip()
            if phrase:
                phrases.append(phrase)
    return phrases


def _find_abrogation_section(text):
    """定位「废止短语清单」段，返回 (段是否存在, 段内全部 bullet[含占位符])。"""
    for heading, body in _split_sections(text):
        if _match_abrogation_heading(heading):
            return True, _extract_bullets(body)
    return False, []


def parse_abrogated_phrases(text):
    """提取「废止短语清单」段下的**有效**（非占位符）bullet 短语列表。

    返回 None 表示该段整体缺失（区别于"段存在但无有效短语"，后者返回
    []——可能是真空，也可能全部是未替换的模板占位符，两种情况对 scan
    而言等价：都没有可扫描的真实短语）。
    """
    present, raw_phrases = _find_abrogation_section(text)
    if not present:
        return None
    return [p for p in raw_phrases if not _is_placeholder_phrase(p)]


def _checkbox_pattern(marker: str):
    """构造锚定到 bullet 行首的 checkbox 正则：`- [x] <marker>`。

    要求：整行以可选前导空白 + `-` + 可选空白开头，紧跟字面 `[` + 单个
    " "/"x"/"X" 字符 + 字面 `]`，再紧跟 marker 文本（允许中间有空白）。
    这把"行内任意位置出现 marker 子串"收紧为"marker 是这个任务列表
    checkbox 的紧邻标签"——备注行提到 marker 文本、HTML 注释里出现同名
    字样、或 `[[x]]` 之类畸形标记，都不满足这个锚定形状，不会被当作
    合法勾选处理。
    """
    return re.compile(r"^\s*-\s*\[([ xX])\]\s*" + re.escape(marker))


def _find_checkbox_match(body_lines, marker):
    pattern = _checkbox_pattern(marker)
    for line in body_lines:
        m = pattern.match(line)
        if m:
            return m
    return None


def check_signoff(text):
    """校验 pivot 文本是否满足「废止短语清单已列全」的 sign-off 前提。

    返回失败原因列表（人类可读，中文）；全部满足时返回空列表。
    """
    failures = []

    present, raw_phrases = _find_abrogation_section(text)
    if not present:
        failures.append("缺少 `## 废止短语清单` 段")
    elif len(raw_phrases) == 0:
        failures.append("`## 废止短语清单` 段存在，但没有任何非空 bullet 短语")
    else:
        valid_phrases = [p for p in raw_phrases if not _is_placeholder_phrase(p)]
        if len(valid_phrases) == 0:
            failures.append(
                "`## 废止短语清单` 段仅含未替换的模板占位符"
                "（如「待填写」/「TODO」/「TBD」或 `<...>` 尖括号占位），"
                "未列入任何有效短语"
            )

    signoff_body = None
    for heading, body in _split_sections(text):
        if heading == _SIGNOFF_HEADING:
            signoff_body = body
            break

    if signoff_body is None:
        failures.append("缺少 `## signed_off` 段")
    else:
        for marker, label in _SIGNOFF_CHECKBOXES:
            m = _find_checkbox_match(signoff_body, marker)
            if m is None:
                failures.append(f"`## signed_off` 段缺少「{label}」勾选项")
            elif m.group(1) not in ("x", "X"):
                failures.append(f"「{label}」勾选项未打勾（仍是 [ ]）")

    return failures


def _scan_scope_files(root: Path):
    """枚举扫描范围内的全部文件（见模块 docstring「扫描范围」）。

    返回按相对路径（posix 分隔符）排序的绝对路径列表，保证下游遍历顺序
    确定。deliverables/ 不存在时静默跳过（新建 pivot 可能尚未产出交付物）。
    符号链接一律跳过，防止扫描越界到项目外内容。
    """
    files = []

    deliverables = root / _SCAN_DELIVERABLES_DIR
    if deliverables.is_dir():
        for p in deliverables.rglob("*.md"):
            if p.is_file() and not p.is_symlink():
                files.append(p)

    for name in _SCAN_ROOT_FILES:
        p = root / name
        if p.is_file() and not p.is_symlink():
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
            "废止短语段存在但为空（或仅含未替换的模板占位符），拒绝产出"
            "空工单（空结果会被误读为传播干净）"
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

    交付物原文（如 md 表格行）、用户填写的废止短语，都可能含字面 tab，
    未转义会撑破下游按 `\\t` 切分的列对齐——工单是给人工核销读的，列
    错位比字面 `\\t`/`\\n` 更难发现、更容易误判分类。两处用到本函数的
    字段（命中短语、该行内容）都可能来自自由文本，故都要转义。
    """
    return text.replace("\t", "\\t").replace("\n", "\\n")


def _format_worklist(hits):
    return "\n".join(
        f"{rel}:{lineno}\t{_escape_tsv_field(phrase)}\t{_escape_tsv_field(line)}\t"
        for rel, lineno, phrase, line in hits
    )


def _default_worklist_path(root: Path, pivot_path: Path) -> Path:
    """--scan 未显式给 --out 时的默认落盘路径。

    `pipeline/verification/` 是 reviewer 审阅报告的既有落盘目录（见
    research-reviewer.md「产物落盘」），复用而非另开新目录——同一份
    pivot 的历次扫描以文件名 stem 区分，重跑覆盖同一份工单（工单本身
    是可复跑的确定性产物，不需要像审阅报告那样按时间戳追加历史）。
    """
    return root.joinpath(*_WORKLIST_SUBDIR, f"pivot-worklist-{pivot_path.stem}.tsv")


def _existing_worklist_has_classifications(path: Path) -> bool:
    """判断磁盘上已存在的工单 TSV 是否含有任一非空分类（第 4 列）。

    落盘前的覆盖保护 check：目标 TSV 若已经历过人工回填分类，--scan 重扫
    默认不得静默覆盖那些回填——这与本模块"空工单 fail-loud"是同一条纪律
    的两面（见模块 docstring「落盘覆盖保护」）。文件不存在、或存在但内容
    为空、或全部分类列均为空（尚未被人工回填过），均视为可安全覆盖，
    返回 False。
    """
    try:
        content = path.read_text(encoding="utf-8")
    except OSError:
        return False
    for line in content.splitlines():
        if not line:
            continue
        fields = line.split("\t")
        if len(fields) >= 4 and fields[3].strip():
            return True
    return False


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
        help="解析废止短语清单并对 --root 全量确定性 grep，工单输出到 stdout 并落盘",
    )
    parser.add_argument(
        "--root",
        metavar="PROJECT_DIR",
        help="--scan 的扫描根目录（研究项目根，含 deliverables/、CLAUDE.md）",
    )
    parser.add_argument(
        "--out",
        metavar="WORKLIST_TSV",
        help=(
            "覆盖 --scan 工单的默认落盘路径"
            "（默认 <root>/pipeline/verification/pivot-worklist-<pivot文件名stem>.tsv）"
        ),
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="--scan 显式覆盖已含人工回填分类的目标工单（默认拒绝静默覆盖，见模块 docstring）",
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

            out_path = (
                Path(args.out)
                if args.out
                else _default_worklist_path(root, Path(args.scan))
            )
            if not args.force and _existing_worklist_has_classifications(out_path):
                print(
                    f"错误: 目标工单已含人工回填分类，拒绝静默覆盖"
                    f"（用 --force 覆盖或 --out 另存）: {out_path}",
                    file=sys.stderr,
                )
                return 1
            out_path.parent.mkdir(parents=True, exist_ok=True)
            out_path.write_text(output + ("\n" if output else ""), encoding="utf-8")
            print(f"工单已落盘: {out_path}", file=sys.stderr)

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
