# docs-graph.py 使用指南

## 概述

零依赖单文件 Python CLI，扫描 Markdown 仓库的标准内联链接 `[text](path)`，提供断链检测、反向引用、邻域查询等 7 个子命令。每次调用全量扫描，无持久状态，无外部依赖。

## 安装

随 doc-gate 插件分发，工具位于 `tools/docs-graph.py`，无需单独安装。也可直接运行：

```
python3 tools/docs-graph.py --help
```

## 子命令参考

### `check` — 断链检测

扫描仓库所有 Markdown 文件，报告无法解析或目标不存在的链接。exit 1 表示有断链，exit 0 表示无断链。

```
python3 docs-graph.py --root /path/to/repo check
python3 docs-graph.py check
```

输出格式：`<source>:<line> → <target>`

### `backlinks <file>` — 谁引用了它

列出图中所有引用了指定文件的文档。

```
python3 docs-graph.py backlinks CLAUDE.md
python3 docs-graph.py --root /path/to/repo backlinks docs/architecture.md
```

`<file>` 为相对于 `--root` 的路径。

### `links <file>` — 它引用了谁

列出指定文件引用的所有图内文档。

```
python3 docs-graph.py links README.md
```

### `orphans` — 零入链文档

列出没有任何文档引用它的文档。白名单自动排除 `CLAUDE.md`、`README.md`、`MEMORY.md` 以及 `archive/` 目录下的文件。

```
python3 docs-graph.py orphans
python3 docs-graph.py --json orphans
```

### `hubs [-n N]` — 入链最多的 top N 文档

按入链数量降序列出文档，默认显示前 10 个。

```
python3 docs-graph.py hubs
python3 docs-graph.py hubs -n 5
```

### `related <file>` — 2 跳内双向邻域

通过 BFS 找出与指定文件在 2 跳内（双向链接）相连的所有文档。

```
python3 docs-graph.py related docs/architecture.md
```

### `export [--out f.json]` — 导出链接图

以 node_link 格式导出完整链接图。默认输出到 stdout，`--out` 指定文件路径。

```
python3 docs-graph.py export
python3 docs-graph.py export --out graph.json
```

## 通用选项

| 选项 | 说明 |
|------|------|
| `--root <dir>` | 仓库根目录（默认：当前工作目录） |
| `--json` | 以 JSON 格式输出（默认人类可读文本） |

## Exit Code 契约

| Code | 含义 |
|------|------|
| `0` | 正常 |
| `1` | 有断链（仅 `check` 子命令） |
| `2` | 参数错误、文件不在图中、或工具内部错误 |

## 排除规则

以下目录的文件不纳入扫描和图构建：

- `.git/`
- `.agents/`
- `node_modules/`
- `.venv/`
- `research/`
- `docs-graph-tests/`

## 典型工作流

**重命名前查影响面：**

```
python3 docs-graph.py backlinks old-name.md
```

找出所有引用方，逐一修改引用后再重命名文件。

**归档前查入链：**

```
python3 docs-graph.py backlinks target.md
```

确认入链为零或已完成迁移后再归档。

**提交被门禁阻断：**

修复 `check` 报出的断链，或在确认断链为误报时使用 `--skip-link-check` 逃生口（由门禁 hook 提供）。

## Obsidian 兼容

仓库根目录可直接作为 Obsidian vault 打开。Obsidian v1.1+ 原生渲染标准 Markdown 相对链接，零配置，与本工具无依赖关系。

## 设计约束

- **零外部依赖**：仅使用 Python 标准库（`re`、`json`、`argparse`、`pathlib` 等）
- **无状态**：每次调用全量扫描，不落盘，不缓存
- **接口稳定**：CLI 子命令是公开契约，行为变更需版本标注
- **只处理标准内联链接**：`[text](path)` 格式；不处理 wiki 链接、引用式链接、图片链接
