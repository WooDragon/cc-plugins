"""_doc_gate_common.py — doc-gate 排除名单 + 链接图谱原语的单一来源。

recall-gate.py 与 docs-graph.py 共享此模块，杜绝排除逻辑三处漂移。
任何新增排除目录 / 链接处理改动只改这里，import 重力井保证消费者引用同一对象。

零依赖：仅标准库 re / os / subprocess / urllib.parse / pathlib。
两个消费者以绝对路径被调用，Python 将脚本所在目录置于 sys.path[0]，
故同目录 import 不依赖 cwd，hook 热路径可靠。
"""

import re
import os
import subprocess
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


# ---------------------------------------------------------------------------
# .gitignore 可见性（按「最近祖先 git 仓库」分段判定）
# ---------------------------------------------------------------------------

# 一次调用同时取已跟踪文件与未被忽略的未跟踪文件。--exclude-standard 让
# .gitignore / .git/info/exclude / 全局 excludes 一并生效；-z 避免路径被
# 按换行切分（合法路径可以包含换行）。
_GIT_LS_FILES_ARGS = ('ls-files', '-z', '--cached', '--others', '--exclude-standard')


def _discover_git_repos(root) -> list:
    """返回 *root* 之内（含 *root* 自身）的 git 仓库根，剪枝 EXCLUDED_DIRS。

    剪枝与扫描本身同一份名单，仓库发现不会走进 node_modules / .git 等目录。
    普通仓库的 `.git` 是目录，linked worktree 的 `.git` 是文件，两者都算仓库根。
    """
    repos = []
    for dirpath, dirnames, _filenames in os.walk(os.fspath(root)):
        current = Path(dirpath)
        marker = current / '.git'
        if marker.is_dir() or marker.is_file():
            repos.append(current.resolve())
        dirnames[:] = [name for name in dirnames if name not in EXCLUDED_DIRS]
    return repos


def _repo_visible_files(repo: Path):
    """返回 *repo* 中 git 认为「存在」的绝对路径集合（已 resolve）。

    返回 None 表示无法判定（git 不存在 / 非 0 退出）。调用方必须把 None
    当作 fail-open，绝不能当作「该仓库下一个文件都不可见」。
    """
    try:
        proc = subprocess.run(
            ['git', '-C', str(repo), *_GIT_LS_FILES_ARGS],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
        )
    except OSError:
        return None
    if proc.returncode != 0:
        return None

    visible = set()
    for entry in proc.stdout.split(b'\0'):
        if not entry:
            continue
        # surrogateescape 让非 UTF-8 文件名原样往返，不丢也不炸。
        relative = entry.decode('utf-8', errors='surrogateescape')
        visible.add((repo / relative).resolve())
    return frozenset(visible)


class GitVisibility:
    """按最近祖先仓库判定的 .gitignore 可见性。

    `repos` 映射「仓库根绝对路径 → 可见绝对路径集合（或 None = 该仓库查询失败）」。
    空映射表示 root 下没有仓库根，此时过滤器整体不启用（保持历史行为）。
    """

    def __init__(self, repos: dict):
        self._repos = repos

    def __bool__(self) -> bool:
        return bool(self._repos)

    def is_visible(self, path) -> bool:
        """*path* 是否保留。不属于任何仓库 → 保留；仓库查询失败 → 保留。"""
        resolved = Path(path).resolve()
        nearest = None
        for repo_root in self._repos:
            try:
                resolved.relative_to(repo_root)
            except ValueError:
                continue
            # 嵌套子仓：最近（路径最长）的仓库根是唯一权威。
            if nearest is None or len(repo_root.parts) > len(nearest.parts):
                nearest = repo_root

        if nearest is None:
            return True
        visible = self._repos[nearest]
        if visible is None:
            return True
        return resolved in visible


def build_git_visibility(root) -> GitVisibility:
    """为 *root* 下每个仓库构建一次 .gitignore 可见性过滤器。

    三种退化全部落在保守一侧：
    - root 下找不到任何仓库根 → 过滤器不启用（测试沙箱、非 git 目录不受影响）
    - 某仓库 git 查询失败 → 该仓库范围内不启用过滤（绝不误删文档）
    - 文件不属于任何已发现仓库 → 保留

    每次调用重新构建，不落盘、不缓存（工具设计约束是无状态）。
    """
    repos = {}
    for repo_root in _discover_git_repos(root):
        repos[repo_root] = _repo_visible_files(repo_root)
    return GitVisibility(repos)


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
