"""_doc_gate_common.py — doc-gate 排除名单 + 链接图谱原语的单一来源。

recall-gate.py 与 docs-graph.py 共享此模块，杜绝排除逻辑三处漂移。
任何新增排除目录 / 链接处理改动只改这里，import 重力井保证消费者引用同一对象。

零依赖：仅标准库 re / os / urllib.parse / pathlib。
两个消费者以绝对路径被调用，Python 将脚本所在目录置于 sys.path[0]，
故同目录 import 不依赖 cwd，hook 热路径可靠。
"""

import re
import os
import sys
import urllib.parse
from pathlib import Path


# 扫描时排除的目录（路径部件匹配，非子串）。
# .claude / logs 为 #23 降噪新增：工具产物、会话日志不应进文档引用图。
# pipeline 为 deep-research 机器生成中间产物，同样不应进文档引用图；
# deliverables（最终交付）刻意不在此列——它仍需可被 recall 索引。
EXCLUDED_DIRS = {'.git', '.agents', 'node_modules', '.venv', 'research',
                 'docs-graph-tests', '.claude', 'logs', 'pipeline', 'intake'}

# orphans 白名单（文件名匹配）：索引 / 入口文件天然无入链，不报孤儿。
ORPHAN_WHITELIST = {'CLAUDE.md', 'README.md', 'MEMORY.md'}

# 标准内联链接 [text](path)，排除图片 ![]()。
LINK_PATTERN = re.compile(r'(?<!\!)\[([^\]]*)\]\(([^)]+)\)')

# code fence 起止标记。
CODE_FENCE = re.compile(r'^```')


def detect_root(start_path: str, override_root: str = None) -> str:
    """从 start_path 向上找最外层 CLAUDE.md 作锚点；回退首个 .git；再回退 cwd。"""
    if override_root:
        p = Path(override_root)
        if p.is_dir():
            return str(p.resolve())

    home = Path.home()
    current = Path(start_path).resolve()
    if current.is_file():
        current = current.parent

    outermost_claude = None
    first_git = None
    depth = 0
    while current != home and current != current.parent and depth < 64:
        if (current / 'CLAUDE.md').exists():
            outermost_claude = current
        if (current / '.git').exists() and first_git is None:
            first_git = current
        current = current.parent
        depth += 1

    if outermost_claude:
        return str(outermost_claude)
    if first_git:
        return str(first_git)
    return os.getcwd()


def is_auto_memory_path(path, root=None) -> bool:
    """Return whether *path* is Claude Code auto-memory under optional *root*.

    The check is lexical: it neither resolves symlinks nor requires the target
    to exist, which keeps deleted and not-yet-created memory entries out of
    scope just like existing ones. A relative path becomes root-relative only
    when ``root`` is supplied. The sole accepted shape is a continuous
    ``.claude/projects/<non-empty project>/memory`` component sequence.
    """
    path_text = os.fspath(path)
    root_text = os.fspath(root) if root is not None else ""
    if os.path.isabs(path_text):
        candidate = path_text
    elif root_text:
        candidate = os.path.join(root_text, path_text)
    else:
        candidate = path_text

    normalized_parts = Path(os.path.normpath(candidate)).parts
    for index in range(len(normalized_parts) - 3):
        if (normalized_parts[index] == '.claude'
                and normalized_parts[index + 1] == 'projects'
                and normalized_parts[index + 2]
                and normalized_parts[index + 3] == 'memory'):
            return True
    return False


def repo_relative_key(path, root) -> str:
    """Return *path* relative to *root*, spelled with POSIX separators.

    Every key in the link graph is built here, because those keys are looked
    up with paths that come from `git status --porcelain`, which always uses
    forward slashes. A key built with the platform separator can never equal
    one of those: on Windows ``os.path.relpath`` yields ``docs\\a.md`` while
    the git side asks for ``docs/a.md``, so every file below the root looks
    like an orphan and every inbound link from it looks like a dangling
    edge. Normalising once at generation keeps both sides in one spelling
    instead of translating at each of the several lookup sites.

    Raises ValueError when *path* is not inside *root* (on Windows, also
    when the two are on different drives) — callers decide what an
    out-of-tree path means, because it differs: a resolved link that escapes
    the root is skipped, a CLI target that escapes it simply is not a node.
    """
    relative = os.path.relpath(os.fspath(path), os.fspath(root))
    if relative == os.pardir or relative.startswith(os.pardir + os.sep):
        raise ValueError(f'{os.fspath(path)!r} is outside {os.fspath(root)!r}')
    return Path(relative).as_posix()


def exists_with_exact_case(path) -> bool:
    """Return whether *path* exists on disk with exactly this spelling.

    ``Path.exists()`` alone cannot answer that on every platform. macOS's
    default APFS is case-insensitive, so a link to ``Guide.md`` resolves
    against an on-disk ``guide.md`` and looks fine locally — while the same
    link is genuinely broken on Linux and on GitHub's runners. The graph has
    to judge "does the target exist" the way the case-sensitive platforms
    will, or a dangling link passes here and breaks elsewhere.

    So: a quick ``exists()`` first (a genuinely absent path is absent under
    every spelling — nothing to compare), then a component-by-component
    comparison against the real directory entry names. The walk starts from
    an anchor prefix and descends, so a case-insensitive filesystem cannot
    hand back the wrong spelling at any single level: each level's listing is
    scanned for an exact string match before the next level is entered. A
    path that leaves the filesystem (symlink target outside the walk) simply
    fails the exact comparison and reports False — the conservative answer
    for a link checker.

    On case-sensitive filesystems (Linux) this cannot disagree with
    ``exists()``; the extra directory scans are bounded by path depth and
    only run for targets that actually exist, which is not the hot path.
    """
    target = Path(os.path.abspath(os.fspath(path)))
    if not target.exists():
        return False

    # Walk from the filesystem root so a relative input still gets a stable
    # starting point, then compare each remaining component against the real
    # directory entry names. os.path.abspath collapses '.'/'..' and makes the
    # path absolute WITHOUT normalising case — unlike Path.resolve(), which on
    # Windows rewrites every component to its on-disk spelling and would
    # destroy exactly the evidence this function exists to inspect.
    parts = target.parts
    if not parts:
        return False

    anchor = Path(parts[0])
    try:
        current = anchor
        for part in parts[1:]:
            try:
                entries = os.listdir(current)
            except OSError:
                return False
            if part not in entries:
                return False
            current = current / part
    except OSError:
        return False
    return current.exists()


def ensure_utf8_stdout() -> None:
    """Force this process's stdout to UTF-8 regardless of platform locale.

    Every tool here prints ``json.dumps(..., ensure_ascii=False)`` — the
    report is full of Chinese. On Windows the default stdout encoding is the
    ANSI code page (GBK on a zh-CN box), so those bytes reach the caller in a
    different encoding than the UTF-8 the message was written in: jq may
    still pass them through, but the hook's stderr renders mojibake and any
    UTF-8 assertion in the tests can never match. macOS/Linux already default
    to UTF-8, so reconfiguring is a no-op there; it is not a behaviour change
    for them, only a fix for Windows.
    """
    stream = getattr(sys, 'stdout', None)
    reconfigure = getattr(stream, 'reconfigure', None)
    if reconfigure is not None:
        try:
            reconfigure(encoding='utf-8', errors='replace')
        except (ValueError, OSError):
            pass


def should_skip_link(target: str) -> bool:
    """外部链接 / 纯锚点 / 绝对路径 → 跳过（不纳入图）。"""
    return target.startswith(('http://', 'https://', 'mailto:', '#', 'file://', '/'))


def resolve_link(source_file: Path, target: str, root: Path):
    """解析相对链接为 root 内绝对路径；越界 / 空 / 解析失败 → None。"""
    target = target.split('#')[0]
    if not target:
        return None
    target = urllib.parse.unquote(target)
    try:
        resolved = (source_file.parent / target).resolve()
    except (ValueError, OSError):
        return None
    try:
        resolved.relative_to(root.resolve())
    except ValueError:
        return None
    return resolved


def extract_links_from_content(content: str) -> list:
    """从内容字符串提取链接（跳过 code fence 内）。返回 [(lineno, text, target), ...]。

    纯字符串处理，不读文件——读取由调用方各自负责（recall errors='ignore'、
    docs-graph errors='replace'，坏字节行为差异刻意留在各自调用点）。
    """
    results = []
    in_code_block = False
    for lineno, line in enumerate(content.splitlines(), start=1):
        if CODE_FENCE.match(line.strip()):
            in_code_block = not in_code_block
            continue
        if in_code_block:
            continue
        for text, target in LINK_PATTERN.findall(line):
            results.append((lineno, text, target))
    return results
