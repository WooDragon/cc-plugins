"""_doc_gate_common.py — doc-gate 排除名单 + 链接图谱原语的单一来源。

recall-gate.py 与 docs-graph.py 共享此模块，杜绝排除逻辑三处漂移。
任何新增排除目录 / 链接处理改动只改这里，import 重力井保证消费者引用同一对象。

零依赖：仅标准库 re / os / urllib.parse / pathlib。
两个消费者以绝对路径被调用，Python 将脚本所在目录置于 sys.path[0]，
故同目录 import 不依赖 cwd，hook 热路径可靠。
"""

import re
import os
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
