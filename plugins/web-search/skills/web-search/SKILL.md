---
name: web-search
description: |
  需要从互联网获取或核实信息、读取网页内容、查询最新版本/价格/官方文档或 X/Twitter 社区反馈时使用。派发联网检索任务前加载；执行搜索的子 agent 也应加载。仅分析本地代码、日志或离线夹具，不因出现搜索工具名而触发。实际搜索仍通过 subagent 隔离，主上下文不直接执行搜索。
---

# 联网搜索

## 搜索隔离原则（红线）

**主上下文禁止直接执行搜索**。所有搜索操作必须通过 Task/Agent subagent 隔离；subagent 内部可直接调用搜索工具。违反此原则会导致主上下文上下文消耗不可控。

隔离同样适用于本 skill 的入口脚本：由被派发的 subagent 执行，不由主线执行。

---

## 选档：先分清要哪一类搜索

| 需求 | 走哪档 |
|---|---|
| 一般联网检索：最新信息、文档、版本、价格、技术现状 | 下方**四级降级链** |
| X/Twitter 社区讨论、社区口碑、产品在 X 上的真实反馈 | **社区调研档**（独立章节，仅 grok，无 fallback） |
| 两者都要 | 拆成两个 subagent 分别执行，不要在一个 Task 里混跑 |

四级链里的 agy / 内置 WebSearch / DDG **都做不了 X 社区检索**，社区需求误走四级链只会拿到博客与新闻稿。反向亦然：社区调研档只返 x.com，拿它查版本号是浪费。

---

## 入口脚本

所有可执行逻辑都在脚本里，正文不再内嵌命令片段：

- `skills/web-search/scripts/probe.sh` — 能力探测，输出 KEY=VALUE 矩阵
- `skills/web-search/scripts/search.sh` — 统一搜索入口，封装降级链

```bash
SEARCH="${CLAUDE_PLUGIN_ROOT}/skills/web-search/scripts/search.sh"
[ -x "$SEARCH" ] || { echo "web-search 脚本路径解析失败" >&2; exit 1; }
"$SEARCH" "<query>"
```

社区调研档加 `--community`。路径用 `${CLAUDE_PLUGIN_ROOT}`，不要 `find`：本文件经 skill 加载时该变量已展开成绝对路径，被当**文件**读取时它是字面量，故配方带 `[ -x ]` 先验——解析不出来就当场停。

### 退出码契约

| 码 | 含义 | 调用方动作 |
|---|---|---|
| `0` | 拿到结果，结果在 stdout | 直接使用 |
| `1` | 全链失败（各级都不可用或都失败） | 按无结果处理，不要盲目重试 |
| `3` | 需调用方执行内置 WebSearch | 自行跑 WebSearch 工具；失败时带 `WEB_SEARCH_BUILTIN_UNAVAILABLE=1` 重入脚本，续跑 DDG 兜底 |

`3` 是 handoff 不是失败：内置 WebSearch 是 Claude Code 的宿主工具，bash 脚本调不到，只能交给调用方。**漏掉重入**会让第 4 级 DDG 永远不可达。

---

## 通用 web 搜索：四级降级链

降级路径：**agy → grok → 内置 WebSearch → DuckDuckGo html**。每级失败（退出码非零 ∨ 输出为空 ∨ 输出含 `SEARCH_FAILED`）才进入下一级。内容农场屏蔽名单（见下方独立章节）适用于所有级别，不在每级重复。

**探测不到的级别整级跳过**：脚本先跑探测器拿能力矩阵，未安装的 CLI 直接打印 `[skip] <级名>: <原因>` 到 stderr 并进入下一级，**不调用、不重试**。这是为了避免为空转烧时间——缺失的二进制不存在"失败重试"的语义。各级具体差异见下方「探测语义」。

**外层 Task timeout 按预期走到哪级设**（各级实测耗时之和，别用单级的数字掐全链）：只跑 agy ≥120s；预期可能降级到 grok ≥400s（agy 3 次重试 + grok 一轮）；要留全链兜底 ≥600s。设太短会在 agy 重试中途被外层掐死，表现为"假失败"。

### 第 1 级 · agy（主力）

`--model "Gemini 3.8 Flash (Low)" -p <prompt>`，单次超时 130s。

**重试策略**：同一查询最多调用 3 次（1 次初试 + 2 次重试），退避间隔 3s / 6s（避让 429 限流）。3 次全部失败才降级 grok。

**失败判定**：退出码非零 ∨ 输出为空 ∨ 输出含 `SEARCH_FAILED` ∨ 超时。

**陷阱警告**：agy 429 重试失败时，退出码**可能仍为 0**，必须同时检查输出内容，不能只看退出码。

**URL 不可默认信任**：实测出现过真实结果与伪造 URL 混杂在同一批返回里的情况（域名与路径结构都「看起来合理」，实际 404），处理要求见「结果处理规范」第 5 条。

### 第 2 级 · grok（agy 全部失败后降级）

`--effort low --output-format plain --tools web_search,open_page --no-subagents --no-memory --max-turns 8`，超时 200s。规则写在 `--system-prompt-override` 里。

**关键约束（每条都是实测结论，删改有代价）：**

- **`--effort` 合法值只有 `high|medium|low` 三档**，本级用 `low`。传 `none`/`minimal`/`xhigh` 会被 grok CLI 报错拒绝。
- **规则必须放 `--system-prompt-override`，不能放 `--rules`**：放 `--rules` 时 `SEARCH_FAILED` 指令不被遵守。代价是覆盖 grok 默认 system prompt 与 `--rules`，本场景不需要 grok 自带的多步搜索策略，属有意取舍。
- **system-prompt 里那句 "NO shell / Never attempt" 是功能性约束，不是客套话**：删掉它 grok 会去调本机 agy，把已耗尽的 agy 配额再烧一轮并拖到超时。`--tools` / `--disallowed-tools` / `--sandbox` 三者都拦不住这件事，system-prompt 声明是唯一有效手段。
- **`--no-subagents` + `--max-turns 8` 是防超时的关键**：不限制时 grok 会起 subagent 多路降级并拖到超时。

**失败判定**（与 agy 同款）：退出码非零 ∨ 输出为空 ∨ 输出含 `SEARCH_FAILED`。grok 失败时退出码仍可能为 0，必须同时检查输出内容。

**格式遵守度有限**：要求单行列表，grok 有时给散文或 JSON 结构体。这是可接受的——grok 是 fallback，此时优先保住"有真实 URL 的可用结果"，不为格式加重试。

### 第 3 级 · 内置 WebSearch 工具

grok 失败后，脚本以 `exit 3` 交还调用方，由 subagent 在 tool-use 层面直接调用 Claude Code 内置的 `WebSearch` 工具。

**失败判定**：工具报错 ∨ 返回 0 条结果 ∨ 按内容农场名单过滤后剩 0 条 → 带 `WEB_SEARCH_BUILTIN_UNAVAILABLE=1` 重入脚本，降级到第 4 级。

### 第 4 级 · DuckDuckGo html 端点（最末级兜底）

curl 以 `--data-urlencode` 拼查询，解析 `result__a` / `result__snippet`，从 `uddg=` 参数取真实 URL（不跟随跳转）。

**请求头必须成套，UA 主因：**

- **UA 必须用桌面 Linux Chrome**：`Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36`。**不能用 macOS UA**——实测 macOS UA 被 DDG 确定性拒绝，返回 403，与本机 IP 无关。隔离实验：只换 Linux UA、不加 Accept 头仍然是 200（3 次 2 成）；保留 macOS UA、只加 Accept 头返回 202 CAPTCHA。故 UA 是主因。
- **`Accept` 与 `Accept-Language` 是配套加固**：`Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8`、`Accept-Language: en-US,en;q=0.9`。与 Linux UA 同组使用。
- **`Referer: https://duckduckgo.com/` 必需**：无此头返回 202 + CAPTCHA（"Select all squares containing a duck"）。
- **端点固定为 `https://html.duckduckgo.com/html/`**：去掉 `html.` 前缀会返回 302；`lite/` 端点虽返回 200 但 class 名不同、无 `result__a`，不可用；POST 表单返回 403。

**失败检测按序三步**（顺序不可改成无条件并列）：① HTTP 非 200（含连接超时的 000）→ 进入重试判定；② 有 `result__a` 匹配则视为成功；③ 无 `result__a` 时才查 `anomaly` 区分是 CAPTCHA 还是真无结果。`anomaly` **不可无条件 grep**——实测 200 正常结果页 `anomaly` 出现 0 次，202 CAPTCHA 页出现 47 次，但正常页仍可能偶然命中该词，无条件 grep 会误伤。另：解析后产出 0 行同样判失败。

**重试策略区分瞬态与确定性拒绝：**

| 状态 | 含义 | 处理 |
|---|---|---|
| `202` | CAPTCHA，DDG 的常态间歇限流 | 重试 1 次（退避 3s），仍失败才判本级失败 |
| `000` | 无响应（连接失败或客户端超时） | 同上，重试 1 次 |
| `403` | 确定性拒绝（请求指纹被封） | **不重试**，直接判本级失败 |
| `200` | 正常响应 | 按三步检测，无结果行即判失败（服务端已应答，重问没有新信息） |

实测同一套正确参数连打 4 次：2 次 200、1 次 202、1 次 200。这是 DDG 的常态限流，不是本级的缺陷，故 202 值得一次重试；而 403 不会因为重问变成 200。

**其他约束：**

- **脆性提示**：`result__a` / `result__snippet` 是 DuckDuckGo 的非官方 HTML class 名，DDG 改版即失效。若解析失效应直接删除本级而非修补。
- **本机 `ddgr` / `ddgs` / `duckduckgo_search` 均未安装，不要为此安装任何包**——纯 curl + urldecode 即可。
- DDG 这级返回的结果**不经内容农场过滤**（curl + 正则不具备判定能力），调用方须按下方屏蔽名单自行丢弃命中项。

---

## 社区调研档（仅 grok，无 fallback）

**适用场景**：需要检索 X（Twitter）社区的真实讨论帖、产品在 X 上的口碑、技术社区对某话题的近期反应。agy、内置 WebSearch、DuckDuckGo 均无法做 X 社区检索，本档**仅 grok 可用，无降级**。

入口：`"$SEARCH" "<query>" --community`。

**实验性**：本档样本量有限，已知失败模式均已定位。grok 缺失时脚本直接报不可用并 `exit 1`；grok 检索失败时同样 `exit 1`，属优雅失败，调用方据此明确知道无结果。

**关键约束（每条都是实测结论，删改有代价）：**

- **工具集必须给全**（3 个 X 检索工具 + `web_search` + `open_page`，共 5 个；grok 另有 `x_user_search` 是按用户查档不是按话题检索，本档不需要）。**收窄工具集反而更差**——只给单个 X 工具时 grok 会绕开它去调本机 agy 并耗尽 max-turns。
- **质量边界（重要）**：返回的 x.com URL 经实测真实可核对，**但帖子要点可能是从搜索片段归纳的二手信息，不等于读过原帖**。因为本机 grok 订阅疑似无 X 原生检索数据权限，本档实际走 `web_search` 检索 site:x.com，拿不到原帖正文。因此：**URL 可直接引用；要点若要作为结论依据，须先用 WebFetch 抓原帖核实**。
- 社区调研同样受搜索隔离原则约束，必须通过 subagent 隔离执行。

---

## 页面抓取：WebFetch

获取特定 URL 的完整页面内容时使用 WebFetch 工具，不要用搜索引擎。

---

## 内容农场屏蔽名单

以下来源的搜索结果**必须**全部屏蔽，不得引用（四级降级链共用，不在每级重复）：

- CSDN
- 百度云
- 腾讯云
- 华为云
- 阿里云
- 火山引擎
- 稀土掘金

这些内容农场充斥过时信息、广告堆砌内容、复制粘贴垃圾，引用它们是在用噪音污染答案。

---

## 结果处理规范

1. **每条结果格式**：标题 | 关键信息（1-2句）| 完整来源 URL（必须含完整路径）
2. **去重**：同一来源只保留最相关一条
3. **不做总结**：返回搜索结果列表，由调用方决定如何使用
4. **优先级**：官方文档 > 知名技术博客 > Stack Overflow > 其他
5. **第 1 级 agy 的 URL 必须二次核实**：实测 agy 会在真实结果里穿插并不存在的 URL（域名与路径都"看起来合理"但 404）。凡将被引用为结论依据的条目，引用前逐条 WebFetch 验证可访问且内容匹配；核实不通过的直接剔除，**不得以"看起来是官方域名"为由放行**。确实无法逐条核实时，须在产出里显式标注「未核实」，不得默认当作可信来源。agy 自报的 `GROUNDED_COUNT` 只是行为约束手段，**不构成核实证据**，不可据以跳过 WebFetch。
6. **数量不是质量**：宁可返回 2 条已核实的，也不要返回 8 条未核实的。上游 prompt 已要求 agy 宁少勿凑数，下游不得反过来因"结果太少"而放宽核实标准。

---

## 深度调研拆分原则

多路并行调研时，按**信息源不重叠**拆分子问题，每个子 Task 负责正交的信息域，最后主上下文汇总。禁止多个 Task 查询同一来源。

---

## 探测语义

`probe.sh` 直接执行时打印能力矩阵，被 source 时只定义函数、不输出。退出码恒 `0`——它是探测器不是判定器。输出的键：

| 键 | 含义 |
|---|---|
| `PLATFORM` | `macos` / `linux` / `windows` / `unknown` |
| `AGY_BIN` | agy 可执行路径，缺失为空 |
| `GROK_BIN` | grok 可执行路径，缺失为空 |
| `TIMEOUT_BIN` | POSIX 风格 timeout 路径，缺失为空 |
| `PYTHON_BIN` | 可用的 Python 3 解释器路径，缺失为空 |
| `CURL_BIN` | curl 路径，缺失为空 |
| `CURL_DATA_URLENCODE` | `1` / `0` |
| `DDG_READY` | `1` 仅在 curl + python3 + `--data-urlencode` 三者齐备时 |

**为什么探测，而不是直接调用后按失败处理**：本机实测 agy / grok 均未安装，若按"失败重试"处理会对不存在的二进制跑满 3 次 × 130s 超时，白烧 6.5 分钟才降级。探测不到即整级跳过，把等待时间降为零。

**各平台的判别细节**（都踩过）：

- **timeout 同名不同义**：Windows 的 `timeout.exe` 是"等待按键"命令，参数当秒数，与 POSIX `timeout` 毫无关系。Git Bash 下若 PATH 解析到系统版会挂住。故必须用 `--version` 输出含 `coreutils` 来判别，仅凭 `command -v` 命中不算数。macOS 上 coreutils 装名为 `gtimeout`，作为第二候选。
- **Python 坏桩**：Windows 的 `WindowsApps\python.exe` 是应用商店重定向桩，`command -v` 能找到、执行无输出、退出码还可能是 `0`（本机实测为 49）。只判退出码会把桩当可用，故必须实跑 `--version` 并校验输出以 `Python 3` 开头。
- **二进制存在性**：`command -v` 之后再用 `-x` 二次确认，避免 PATH 中不可执行条目被误认。
- **curl 老版本**：`--help all` 是新版才有的 flag，老版 curl 会拒绝；此时退到 `curl --help` 再查 `--data-urlencode`。
- **没有 timeout 时的行为**：`TIMEOUT_BIN` 为空表示调用方直接执行、不做超时保护，**不是**"无法搜索"。

### 平台能力矩阵

| 级别 | macOS | Linux | Windows (Git Bash) |
|---|---|---|---|
| agy | 装则可用 | 装则可用 | 装则可用 |
| grok | 装则可用 | 装则可用 | 装则可用 |
| 内置 WebSearch | 可用 | 可用 | 可用 |
| DuckDuckGo | 需 curl + python3 | 需 curl + python3 | 需 Git Bash 自带 curl + 真正的 python3（非 WindowsApps 桩） |

社区调研档在无 grok 的平台上**直接报不可用**，不落到四级链——四级链里没有一级能做 X 检索，降级只会拿到错误类型的结果。

测试相关：脚本的所有 agy / grok / curl 调用都经由可覆盖函数（`invoke_agy` / `invoke_grok` / `invoke_grok_community` / `CURL_CMD`），测试用假命令替换即可，不需要真的安装任何 CLI。
