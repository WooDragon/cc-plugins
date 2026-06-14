---
name: code-search
description: |
  代码搜索与符号导航——按「症状」选对工具（ctags / ast-grep / grep），别一上来就 grep。当需要：
  - 找某符号的定义 / 跳转到定义（"X 在哪定义"、"这个函数/类/方法在哪"、"find definition"、"jump to definition"）→ ctags
  - 找符合某 AST 结构形状的代码（import 语句、特定调用形态、React 组件定义、所有 try/catch）→ ast-grep
  - 找谁调用了 X / caller 调用点 / 纯文本·字符串出现处（"who calls X"、"find references/callers"、"全局搜 X"）→ grep
  - 追调用链 / 依赖影响面分析、理解陌生代码库前定位相关代码
  - 大库精确调用图 grep/ctags 扛不住时的升级路径（LSP/SCIP）
  时调用此 Skill，按决策表选工具、抄命令模板，避免用 grep 找定义（漏重载/跨行签名/注释噪音）、避免用正则凑 AST 结构。
  Triggers: 代码搜索, 搜代码, 找定义, 符号定位, 跳转到定义, 找 caller, 谁调用, 调用链, AST 结构匹配, 全局搜索, ctags, ast-grep, grep, find definition, find references, who calls, jump to definition, code navigation.
---

# 代码搜索

代码检索执行层：找代码先按**症状**选工具，三件套分工明确——别一上来就 `grep`。

## §1 决策表（症状 → 工具）

| 症状 | 工具 | 命令骨架 |
|------|------|---------|
| 找某符号**定义** / 跳转到定义 | **ctags** | 建索引 → `readtags` 查 → 文件 + 定位 + kind |
| 找符合某 **AST 结构形状**的代码（import、特定调用形态、组件定义、所有 try/catch） | **ast-grep** | `ast-grep run -p '<pattern>' --lang <lang>` |
| 找**谁调用了 X** / caller 调用点 / 纯文本·字符串 | **grep** | Grep 工具（ripgrep 内核）；调用链 1-2 跳够 |

一句话记忆：**定义找 ctags，结构找 ast-grep，调用与文本找 grep。**

## §2 反模式纠偏

最常见的错误 = 该用 ctags/ast-grep 时一上来就 grep。

- ❌ **用 grep 找函数/类定义** → 漏重载、漏跨行签名、被注释和字符串里的同名淹没。→ 用 **ctags**。
- ❌ **用正则凑 AST 结构匹配**（如"所有 `await fetch(...)`"）→ 正则表达不准语法树形状，转义地狱还漏。→ 用 **ast-grep**。
- ✅ **grep 的正确边界**：caller 调用点验证、纯文本/字符串搜索、ast-grep 表达不了的跨语义场景、以及**没有 tags 索引时找定义的降级兜底**（带噪音，临时用）。

## §3 ctags —— 符号定义索引（主力）

找定义的正解。两步索引模型：建一次索引，之后 O(1) 查表，跨语言统一。实测 5 语言（TS/Py/Go/Rust/Shell）定义定位零偏差。

```bash
# 第一步 建索引（task 内首次建一次，后续复用）——必须排除依赖/构建产物
git ls-files | ctags --links=no -L - --langmap=TypeScript:+.tsx   # git 项目优先：只索引版本控制内文件，天然避开 node_modules/dist/.gitignore
ctags -R --exclude=node_modules --exclude=dist --exclude=.git --langmap=TypeScript:+.tsx .   # 非 git 项目兜底

# 第二步 查定义（替代 grep 找定义）
readtags -t tags -en "functionName"
# 输出：functionName <TAB> path/to/file.py <TAB> /^def functionName(...):$/;" <TAB> kind:f <TAB> typeref:...
# → 拿到文件路径 + 定位模式 + kind，再用 Read 精读
```

特性：tags 是纯文本派生物，**零依赖、可 100% 重建**（删了 `ctags -R` 再来一遍，11.5k 文件 repo 约 9s）；过期直接重建，不像 LSP 要常驻进程。

**五个必知坑**：
1. **`.tsx` 默认盲区** → 不加 `--langmap=TypeScript:+.tsx` 时 React 组件 0 收录。
2. **Rust trait 被标 `kind:interface`**（语义偏移）→ 查询时结合 `language:` 字段区分。
3. **TS 局部 const 噪音**（实测 openclaw tags 达 67MB）→ 建索引加 `--kinds-TypeScript=f,c,i,m` 只收函数/类/接口/方法。
4. **Shell heredoc 的 `EOF` 被当符号** → 下游按 kind 过滤。
5. **未排除依赖/构建产物**（node_modules / dist / target / vendor）→ tags 爆炸 + 第三方同名符号淹没精度。用上面的 `git ls-files | ctags -L -`（git 项目）或 `--exclude`（非 git）。

## §4 ast-grep —— AST 结构模式匹配

找"符合某语法形状的代码"，不是找符号定义（那归 ctags）。按语法树匹配，不受格式/换行/注释干扰。

```bash
# 一次性搜索：-p 模式，--lang 语言；元变量 $VAR=单节点，$$$=多节点序列
ast-grep run -p 'await fetch($$$)' --lang typescript          # 所有 await fetch 调用
ast-grep run -p 'class $X extends $BASE { $$$ }' --lang typescript  # 所有继承某类的 class
ast-grep run -p 'import { $$$ } from "react"' --lang typescript  # tsx/jsx 文件也用 --lang typescript
ast-grep run -p 'try { $$$ } catch ($E) { $$$ }' --lang typescript  # 所有 try/catch（TS/JS）
ast-grep run -p 'if $ERR != nil { $$$ }' --lang go            # Go 错误检查惯用结构（Go 无 try/catch）

# 规则文件批量扫描
ast-grep scan -r rule.yml <path>

# 结构化改写：-U / --update-all 才写回文件（默认仅打印 diff）
ast-grep run -p '<old>' --rewrite '<new>' -U --lang go
```

语言值：`js` / `typescript`（tsx/jsx 也用此值）/ `python` / `go` / `rust` / `bash`。命令名 `ast-grep`（别名 `sg`），子命令是 `run`——旧式裸 `sg -p` 不对。pattern 必须是**合法的完整语法片段**（如 `class` 要带 `{ $$$ }` 类体），否则 ast-grep 报 ERROR node、匹配为空。

## §5 grep —— 调用点与文本

LLM 本就熟练，不补用法，只守边界：
- **caller 调用点验证**：找"谁调用了 X"用符号名 grep；实测调用链 **1-2 跳完全够**。
- **纯文本 / 字符串字面量 / 配置值 / 日志**。
- 用 Claude Code 原生 **Grep 工具**（ripgrep 内核），`-A/-B/-C` 看上下文、`type` 过滤语言、`glob` 限路径。先缩范围再搜，别全库裸扫。

## §6 升级信号

grep/ctags 扛不住时——**巨型库 grep 超时** / **需 3+ 跳才能理清波及面** / **接口多态需精确类型推断**（caller 含接口/泛型，文本匹配漏报）/ **要系统主动推断影响面**——正解是 **LSP/SCIP 系**（确定性静态分析）：

- `gopls`（Go）、`rust-analyzer`（Rust，支持 SCIP 输出）、`CodeGraphContext` 的 SCIP fallback（多语言）。

**不是 graphify / codegraph**：启发式 name-match，实测 Rust caller 漏报 ~85%、Go 接口方法漏报 100%、codegraph 还有 Shell 全缺口。

## §7 上下文经济

搜索结果会吃上下文：
- **精确、单次即得**（已知符号名、明确路径）→ 直接搜。
- **结果不可预测 / 多轮探索 / 大范围检索**（陌生大库摸索、"找出所有用到 X 的地方再分析"）→ 若环境支持子任务隔离（如 Claude Code 的 Task / subagent），派子 agent 执行，**只回收结论**，别把成百上千行匹配灌进主上下文。

禁 `cd`（用工具的路径参数）；读文件用 Read，不用 `cat` / `head` / `tail`。

## §8 安装

成熟系统工具，不分发二进制：
```bash
# macOS
brew install universal-ctags ast-grep
# Debian/Ubuntu：universal-ctags 走 apt；ast-grep 走 cargo install ast-grep（或下载 GitHub release）
```
要求 **Universal Ctags**（非老的 exuberant-ctags，参数差异大）。
