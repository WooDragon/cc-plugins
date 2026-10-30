---
name: code-search
description: |
  代码搜索与符号导航（code search/navigation）：定义消歧用 ctags，AST 结构匹配用 ast-grep，调用点／引用及文本搜索用 grep。用于找定义、找 caller、追调用链、定位依赖影响面和陌生代码库相关代码，以及复杂精确导航的 LSP/SCIP 升级。已知文件和准确名称可直接局部文本定位，具体工具选择按正文决策表执行。
---

# 代码搜索

按已知信息与检索意图选择工具，先缩小范围，再读取必要源码。

## §1 决策表（意图 → 工具）

| 意图 | 工具 | 定位方式 |
|------|------|----------|
| 已知文件和准确名称，只需定位 | **grep** | 在该文件搜索，再局部 Read；不要求先建索引 |
| 定义消歧：区分类别、同名符号或跨行声明 | **ctags** | 索引候选文件/范围 → `readtags` 查 → 文件 + 定位 + kind |
| 反复跨文件导航 | **ctags** | 建立并复用任务内 tags |
| 找符合 AST（抽象语法树）结构的代码，如 import、调用形态、JSX 节点、try/catch | **ast-grep** | `ast-grep run -p '<pattern>' --lang <lang> <path>` |
| 找 caller 调用点、引用候选或纯文本 | **grep** | 用名称和路径缩小候选范围，再核对源码 |

文本命中是定位线索，不等于语法结构或完整调用图。需要结构匹配时应使用 ast-grep；需要定义消歧时应使用 ctags。

## §2 ctags —— 符号定义索引

要求 **Universal Ctags**，而非旧的 exuberant-ctags。先索引明确的候选文件或目录；反复导航时可复用任务内 tags，不要求每个任务先建全仓索引。

以下占位符应替换为实际文件、tags 路径和符号名。生成与查询应使用同一个 tags 路径：

```bash
# example: tags-build
ctags --links=no --langmap=TypeScript:+.tsx -f '<tags>' '<file.tsx>'
# example: tags-query
readtags -t '<tags>' -en '<symbol>'
```

查询返回符号、文件路径、定位模式与 kind（定义类别）。用 Read 核对当前源码；tags 只是派生的定位线索。索引的过滤范围和时效会影响结果，源码改变后应按需重建。

- `.tsx` 应显式加入 TypeScript 的 langmap，以免工具的默认映射遗漏文件。
- 同名符号应结合路径、kind 与源码消歧。不同语言的 kind 含义可能不同。
- 若 TypeScript 局部变量造成噪音，可用 `--kinds-TypeScript=f,c,i,m` 只收函数、类、接口和方法；被过滤的类别不会出现在结果中。
- 扩大索引范围前，应排除不相关的依赖和构建产物（如 node_modules、dist、target、vendor）。`git ls-files` 默认列出 tracked 文件：可能遗漏未跟踪的新源码，也可能包含已跟踪生成物，并不天然排除依赖和构建产物。

## §3 ast-grep —— AST 结构匹配

TypeScript 用 `typescript`，TSX 用 `tsx`，JS/JSX 用 `javascript`。示例统一使用 `ast-grep run`；命令别名为 `sg`。pattern 应是目标语言中合法的语法片段，元变量 `$VAR` 表示单节点，`$$$` 表示多节点序列。

```bash
# example: tsx-node
ast-grep run -p '<Panel $$$ />' --lang tsx '<file.tsx>'
# TypeScript 调用与类结构
ast-grep run -p 'await fetch($$$)' --lang typescript '<path>'
ast-grep run -p 'class $X extends $BASE { $$$ }' --lang typescript '<path>'
# JavaScript / JSX 的 try/catch
ast-grep run -p 'try { $$$ } catch ($E) { $$$ }' --lang javascript '<path>'
# Go 错误检查
ast-grep run -p 'if $ERR != nil { $$$ }' --lang go '<path>'
```

JSX 示例匹配真实节点，而非注释或字符串中的同形文本。其他语言值包括 `python`、`rust`、`bash`。批量规则扫描用 `ast-grep scan -r rule.yml <path>`。结构化改写用 `--rewrite '<new>'`；`-U` / `--update-all` 才写回文件，默认仅打印 diff。

## §4 grep —— 文本定位与调用点候选

已知文件和准确名称时，可直接用 Claude Code 原生 Grep 工具局部定位，再用 Read 核对，不以没有 tags 为前提。用 `glob` 限路径、`type` 限语言、`-A/-B/-C` 获取必要上下文。

caller、引用、字符串、配置值与日志可按文本搜索。文本结果不能证明类型、多态或动态调用关系。

## §5 结果边界与升级

- 按问题返回路径、定位信息或必要正文，不强制固定阶段或输出格式。
- 结果过多应先缩范围。局部、过滤或截断结果不能当作完整清单；截断时应说明结果不完整。
- 空结果不证明源码不存在。名称不确定时，应利用已知信息改用前缀或范围内文本查询，不应连续猜名称。
- AST 本应命中却为空时，应检查搜索范围、语言和 pattern，再改变查询。
- 需要精确类型推断、多态调用关系或系统性影响分析时，应升级到 LSP/SCIP（语言服务 / 静态代码索引），如 gopls、rust-analyzer；文本和 tags 不提供这些语义保证。

## §6 上下文与环境

精确、单次即可完成的查询可直接执行。陌生大库、多轮探索或结果量不可预测时，若环境支持子任务隔离，应派子 agent 检索，只回收结论与必要定位，不向主上下文灌入大量匹配。

禁 `cd`，应使用工具的路径参数；读文件用 Read，不用 `cat` / `head` / `tail`。

## §7 安装

本插件只提供方法，不分发二进制。macOS 可通过 `brew install universal-ctags ast-grep` 安装工具；Debian/Ubuntu 可通过 apt 安装 universal-ctags，ast-grep 可通过 `cargo install ast-grep` 或发行包安装。
