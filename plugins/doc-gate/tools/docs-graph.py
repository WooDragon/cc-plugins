#!/usr/bin/env python3
"""
docs-graph.py — 文档链接图谱查询工具

功能：
- 扫描 Markdown 仓库所有 Markdown 文件的标准内联链接 [text](path.md)
- 支持断链检测、反向引用、正向引用、孤儿文档、枢纽文档、2跳邻域、JSON 导出
- 每次调用现场全量扫描，无持久状态、无外部依赖

设计约束：
- 零依赖：仅 Python 标准库
- 无状态：不落盘、不缓存
- Exit code：0=正常 / 1=有断链(仅check) / 2=参数或工具错误

版本：1.0.0
"""

import sys
import json
import argparse
from pathlib import Path
from collections import defaultdict, deque

from _doc_gate_common import (
    EXCLUDED_DIRS, ORPHAN_WHITELIST,
    detect_root, should_skip_link, resolve_link, extract_links_from_content,
)


def is_excluded(path: Path, root: Path) -> bool:
    """检查路径是否在排除目录内"""
    try:
        relative = path.relative_to(root)
    except ValueError:
        return False
    return any(part in EXCLUDED_DIRS for part in relative.parts)


def extract_links(filepath: Path):
    """从文件读取内容并提取链接（薄包装：读文件 + 委托 extract_links_from_content）。

    errors='replace' 与 recall-gate 的 'ignore' 不同——坏字节行为差异刻意留在
    各自调用点，不下沉到 common。
    返回 [(line_no, link_text, link_target), ...]，line_no 从 1 开始。
    """
    try:
        content = filepath.read_text(encoding='utf-8', errors='replace')
    except OSError:
        return []
    return extract_links_from_content(content)


def scan_all_files(root: Path):
    """扫描所有 .md 文件，返回 set[Path]"""
    files = set()
    for p in root.rglob('*.md'):
        if not is_excluded(p, root):
            files.add(p.resolve())
    return files


def build_graph(root: Path):
    """
    构建文档图。
    返回：
      - all_files: set[Path]，图中所有节点
      - outgoing: dict[Path, list[(line_no, target_str, resolved_Path|None)]]
        每条出链：(行号, 原始目标字符串, 解析后路径或None)
      - forward: dict[Path, set[Path]]，正向邻接（只含图内节点）
      - backward: dict[Path, set[Path]]，反向邻接（只含图内节点）
    """
    all_files = scan_all_files(root)

    outgoing = defaultdict(list)   # 所有出链（含断链）
    forward = defaultdict(set)     # 图内正向链接
    backward = defaultdict(set)    # 图内反向链接

    for src in all_files:
        links = extract_links(src)
        for lineno, text, target in links:
            if should_skip_link(target):
                continue
            resolved = resolve_link(src, target, root)
            outgoing[src].append((lineno, target, resolved))

            if resolved is not None and resolved in all_files:
                forward[src].add(resolved)
                backward[resolved].add(src)

    return all_files, outgoing, forward, backward


def cmd_check(args, root: Path):
    """检测断链。有断链 exit 1，无断链 exit 0。"""
    all_files, outgoing, _, _ = build_graph(root)

    broken = []
    for src in sorted(all_files):
        for lineno, target, resolved in outgoing[src]:
            # 断链：resolved 为 None（解析失败）或目标文件不存在
            if resolved is None or not resolved.exists():
                rel_src = src.relative_to(root)
                broken.append((rel_src, lineno, target))

    if args.json:
        output = [
            {"source": str(src), "line": lineno, "target": target}
            for src, lineno, target in broken
        ]
        print(json.dumps(output, ensure_ascii=False, indent=2))
    else:
        for src, lineno, target in broken:
            print(f"{src}:{lineno} → {target}")

    sys.exit(1 if broken else 0)


def _resolve_file_arg(file_arg: str, root: Path, all_files: set) -> Path:
    """
    将用户传入的 <file> 参数解析为图中节点路径。
    接受相对于 root 的路径。
    文件不在图中则 exit 2。
    """
    candidate = (root / file_arg).resolve()
    if candidate not in all_files:
        print(f"error: '{file_arg}' 不在文档图中（未找到或已被排除）", file=sys.stderr)
        sys.exit(2)
    return candidate


def cmd_backlinks(args, root: Path):
    """显示谁引用了 <file>"""
    all_files, _, _, backward = build_graph(root)
    target = _resolve_file_arg(args.file, root, all_files)

    refs = sorted(backward.get(target, set()))
    rel_refs = [str(p.relative_to(root)) for p in refs]

    if args.json:
        print(json.dumps(rel_refs, ensure_ascii=False, indent=2))
    else:
        for r in rel_refs:
            print(r)
    sys.exit(0)


def cmd_links(args, root: Path):
    """显示 <file> 引用了谁"""
    all_files, _, forward, _ = build_graph(root)
    src = _resolve_file_arg(args.file, root, all_files)

    targets = sorted(forward.get(src, set()))
    rel_targets = [str(p.relative_to(root)) for p in targets]

    if args.json:
        print(json.dumps(rel_targets, ensure_ascii=False, indent=2))
    else:
        for t in rel_targets:
            print(t)
    sys.exit(0)


def cmd_orphans(args, root: Path):
    """显示零入链文档（白名单排除）"""
    all_files, _, _, backward = build_graph(root)

    orphans = []
    for f in sorted(all_files):
        # 白名单文件名
        if f.name in ORPHAN_WHITELIST:
            continue
        rel = f.relative_to(root)
        # 零入链
        if not backward.get(f):
            orphans.append(str(rel))

    if args.json:
        print(json.dumps(orphans, ensure_ascii=False, indent=2))
    else:
        for o in orphans:
            print(o)
    sys.exit(0)


def cmd_hubs(args, root: Path):
    """显示入链 top N 文档"""
    all_files, _, _, backward = build_graph(root)

    n = args.n
    counts = [(len(backward.get(f, set())), f) for f in all_files]
    counts.sort(key=lambda x: (-x[0], str(x[1])))
    top = counts[:n]

    if args.json:
        output = [
            {"file": str(f.relative_to(root)), "inlinks": cnt}
            for cnt, f in top
        ]
        print(json.dumps(output, ensure_ascii=False, indent=2))
    else:
        for cnt, f in top:
            print(f"{f.relative_to(root)}\t{cnt}")
    sys.exit(0)


def cmd_related(args, root: Path):
    """显示 2 跳内邻域（BFS，双向）"""
    all_files, _, forward, backward = build_graph(root)
    src = _resolve_file_arg(args.file, root, all_files)

    # BFS，最多 2 跳，双向
    visited = {src}
    queue = deque([(src, 0)])
    related = []

    while queue:
        node, depth = queue.popleft()
        if depth >= 2:
            continue
        neighbors = forward.get(node, set()) | backward.get(node, set())
        for nb in neighbors:
            if nb not in visited:
                visited.add(nb)
                related.append(nb)
                queue.append((nb, depth + 1))

    related_sorted = sorted(related)
    rel_related = [str(p.relative_to(root)) for p in related_sorted]

    if args.json:
        print(json.dumps(rel_related, ensure_ascii=False, indent=2))
    else:
        for r in rel_related:
            print(r)
    sys.exit(0)


def cmd_export(args, root: Path):
    """导出 node_link 格式 JSON"""
    all_files, _, forward, _ = build_graph(root)

    # 构建节点列表（id 为相对路径字符串）
    file_to_id = {f: str(f.relative_to(root)) for f in all_files}

    nodes = [{"id": file_to_id[f]} for f in sorted(all_files)]

    links = []
    for src in sorted(all_files):
        for tgt in sorted(forward.get(src, set())):
            links.append({
                "source": file_to_id[src],
                "target": file_to_id[tgt],
            })

    graph = {"nodes": nodes, "links": links}
    output = json.dumps(graph, ensure_ascii=False, indent=2)

    if args.out:
        out_path = Path(args.out)
        out_path.write_text(output, encoding='utf-8')
        print(f"已写入 {out_path}", file=sys.stderr)
    else:
        print(output)

    sys.exit(0)


def main():
    # 推导 repo 根目录
    default_root = Path(detect_root(str(Path.cwd())))

    parser = argparse.ArgumentParser(
        prog='docs-graph.py',
        description='文档链接图谱查询工具',
    )
    parser.add_argument(
        '--root', type=str, default=None,
        help=f'repo 根目录（默认：当前工作目录）'
    )
    parser.add_argument(
        '--json', action='store_true',
        help='JSON 输出（默认人类可读文本）'
    )

    subparsers = parser.add_subparsers(dest='command')

    # check
    subparsers.add_parser('check', help='断链检测')

    # backlinks
    p_backlinks = subparsers.add_parser('backlinks', help='谁引用了 <file>')
    p_backlinks.add_argument('file', help='相对于 root 的路径')

    # links
    p_links = subparsers.add_parser('links', help='<file> 引用了谁')
    p_links.add_argument('file', help='相对于 root 的路径')

    # orphans
    subparsers.add_parser('orphans', help='零入链文档')

    # hubs
    p_hubs = subparsers.add_parser('hubs', help='入链 top N')
    p_hubs.add_argument('-n', type=int, default=10, help='显示数量（默认 10）')

    # related
    p_related = subparsers.add_parser('related', help='2 跳内邻域')
    p_related.add_argument('file', help='相对于 root 的路径')

    # export
    p_export = subparsers.add_parser('export', help='导出 node_link JSON')
    p_export.add_argument('--out', type=str, default=None, help='输出文件（默认 stdout）')

    args = parser.parse_args()

    if args.command is None:
        parser.print_help()
        sys.exit(2)

    # 确定 root
    if args.root:
        root = Path(args.root).resolve()
        if not root.is_dir():
            print(f"error: --root 目录不存在：{root}", file=sys.stderr)
            sys.exit(2)
    else:
        root = default_root
        if not root.is_dir():
            print(f"error: 推导的 root 目录不存在：{root}", file=sys.stderr)
            sys.exit(2)

    dispatch = {
        'check': cmd_check,
        'backlinks': cmd_backlinks,
        'links': cmd_links,
        'orphans': cmd_orphans,
        'hubs': cmd_hubs,
        'related': cmd_related,
        'export': cmd_export,
    }

    func = dispatch.get(args.command)
    if func is None:
        print(f"error: 未知子命令 '{args.command}'", file=sys.stderr)
        sys.exit(2)

    try:
        func(args, root)
    except SystemExit:
        raise
    except Exception as e:
        print(f"error: 工具内部错误：{e}", file=sys.stderr)
        sys.exit(2)


if __name__ == '__main__':
    main()
