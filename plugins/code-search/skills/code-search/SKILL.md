---
name: code-search
description: |
  代码搜索与符号导航——在代码库里找定义、找引用、追调用链、看结构、跑正则。当需要：
  - 查找函数/类/方法/变量/常量/类型/接口的定义（"X 在哪定义"、"找 X 的定义"、"where is X defined"、"jump to definition"、"跳转到定义"）
  - 追踪符号的所有引用/调用点（"谁调用了 X"、"X 在哪被用到"、"find references/usages"、"call sites"、"哪些文件用了 X"）
  - 分析调用链、依赖、import 关系（"X 的调用链"、"谁 import 了 Y"、"dependency/call graph"、"依赖分析"）
  - 跨文件搜文本/正则/字符串字面量（grep、ripgrep、正则匹配、"全局搜 X"、"search for pattern"、"搜一下哪里有"）
  - 按文件名/路径定位文件、看目录树/项目结构（"有哪些 X 文件"、"文件树"、"项目结构"、"find files"、"glob"）
  - 定位 TODO/FIXME/标记注释或特定代码模式（"所有 TODO"、"找所有 catch 块"、ast 结构模式匹配）
  - 在动手改代码、读代码、理解陌生代码库之前先定位相关代码
  时调用此 Skill，按工具决策树选对 ast-grep / ripgrep / grep / find / Glob / Read，避免盲目全库 grep、避免把大检索结果塞满主上下文。
  Triggers: 代码搜索, 搜代码, 查找代码, 找函数, 找定义, 找用法, 找引用, 符号导航, 代码导航, 调用链, 依赖分析, 全局搜索, grep, ripgrep, rg, ast-grep, sg, find files, search code, find function, find references, where defined, who calls, call graph, codebase search, locate code, navigate code.
---

# 代码搜索

在代码库里定位代码：找定义、找引用、追调用链、看结构、跑正则。核心一句话——**按搜索意图选对工具，别一上来就 `grep -r`**。

## 决策原则

搜索前先问：**我找的是「语法结构」还是「文本」？**

- **结构**（函数/类/方法/类型/import 的定义与调用）→ `ast-grep`（命令 `ast-grep`，部分环境别名 `sg`），按 AST 匹配，不受格式、换行、注释干扰。
- **文本**（字符串字面量、注释、配置值、日志、跨语言关键词）→ **Grep 工具**（Claude Code 原生，ripgrep 内核），正则匹配。
- ast-grep 表达不了的结构 → 回退 Grep / 正则。

## §1 工具决策树

| 搜索目标 | 首选 | 要点 / 示例 |
|---------|------|------------|
| 函数/类/方法/类型/接口**定义** | `ast-grep` | `ast-grep -p 'function $NAME($$$)'`、`-p 'class $NAME'`、`-p 'def $NAME'`；`-l <lang>` 指定语言 |
| 符号**引用/调用点** | Grep 工具 / `ast-grep` | 快速铺开用 Grep 搜符号名；噪音大时换 `ast-grep -p '$NAME($$$)'` 精确匹配调用形态 |
| 文本 / 正则 / 字面量 | **Grep 工具** | 原生 Grep（rg 内核）优先于裸 `rg`/`grep`；用 `-A/-B/-C` 看上下文、`type` 过滤语言、`glob` 限路径 |
| 文件名 / 路径定位 | **Glob 工具** | `**/*.ts`、`**/test_*.py`；多条件或按时间/大小回退 `find` |
| import / 依赖关系 | `ast-grep` | 匹配 import/require/use 语句结构，比正则稳 |
| 目录树 / 结构概览 | Glob / `find` | 先摸结构建坐标系，再精搜 |
| 已知文件读内容 | **Read** | 禁止 `cat`/`head`/`tail` |

## §2 按意图选策略

- **找定义**：ast-grep 结构匹配（`function/class/def/type/interface $NAME`）。比 grep 准——不会把调用点、同名字符串、注释误当定义。
- **找引用/调用点**：Grep 符号名快速铺开；若噪音大（同名变量、注释命中），换 ast-grep 调用模式 `$NAME($$$)` 收敛。
- **调用链 / 依赖**：组合——先 ast-grep 定位定义，再找所有调用点，按需逐层展开。别指望一条命令出全图。
- **结构概览**：Glob 看文件分布、`find` 看目录树，建立坐标系后再精搜。
- **文本模式**：纯文本 / 正则 / 配置值 / 日志，直接 Grep 工具，用 `type` 和路径缩范围。

## §3 组合技巧

- **先窄后宽**：先 Glob 把文件集缩到目标范围（按目录 / 扩展名），再在范围内 Grep，别全库扫。
- **先定位后读**：先 ast-grep / Grep 拿到 `file:line`，再 Read 精读——不要 Read 一堆文件靠肉眼找。
- **逐层收敛**：命中太多就加 `type`、限路径、换结构匹配收紧，而不是翻页看完。

## §4 上下文经济

搜索结果会占用上下文，按规模分流：

- **精确、单次即得**（已知符号名、明确路径）→ 直接搜。
- **结果不可预测 / 需多轮检索 / 大范围探索**（陌生代码库摸索、"找出所有用到 X 的地方再分析"）→ 若运行环境支持子任务隔离（如 Claude Code 的 Task / subagent），派子 agent 执行，**只回收结论**，别把成百上千行匹配灌进主上下文。检索取数是低推理活，适合卸载到更轻量的执行单元。

## §5 反模式

- ❌ 一上来 `grep -r pattern .` 不缩范围 → 噪音淹没信号；先 Glob 缩范围或用 ast-grep 结构搜。
- ❌ 用 `cat` / `head` / `tail` 读文件 → 用 Read。
- ❌ 能用 ast-grep 结构搜（找函数定义）却用脆弱正则硬凑 → 换行、参数、注释一变就漏。
- ❌ 大范围检索直接在主上下文跑 → 污染上下文；派 Task 隔离。
- ❌ `cd` 切目录 → 用工具的路径参数代替。
