---
name: pr-review
description: |
  对已开的 GitHub PR 做 AI 代码评审，三个后端：grok（本地 CLI 同步产出评审到终端，即时深度评审、默认 high 档可调低档控成本，适合本地自审）、claude（本地 `claude -p` 同步评审，wrapper 会话经 grok provider 路由时的默认自动切换目标，也可手动强制）、copilot（gh 触发 GitHub Copilot bot 异步评审、结果回帖 PR，成本高通常不启用、仅复杂项目收尾）。统一入口 `pr-review.sh` 在 grok/claude 间自动路由。当需要：
  - 评审某个 PR（给出 PR 编号）、快速自审改动质量
  - 本地评审 PR（默认路径，grok/claude 自动路由）
  - 用 claude 评审 PR / 强制走 claude 后端
  - 触发 / 重新触发 GitHub Copilot 评审 PR（可选路径）
  - 查询 Copilot 评审请求状态
  时调用此 Skill。
  注意边界：本 skill 针对「已开 PR 编号」的评审；本地未提交 working diff 的即时 review 走 /code-review，不由本 skill 承接。
  Triggers: pr review, review this pr, 评审 PR, 评审这个 PR, 审查 PR, grok review, grok 评审, 用 grok 评审 PR, claude review, claude 评审, 用 claude 评审 PR, copilot review, copilot 评审, 触发 copilot, request copilot reviewer, re-request review, 重新评审 PR.
---

# PR Review

对已开的 GitHub PR 做 AI 代码评审，三个后端按需选（grok/claude 由 `pr-review.sh` 自动路由，copilot 独立入口）。

## 执行分工（主线裁决，评审正文落盘）

评审正文**重定向落盘**为评审日志，主线读原文裁决。取评审不派子任务（subagent），定位素材也不派——两者都是「评审正文不落盘」逼出来的补偿动作，落盘后一并消失。

**一轮只派一次**：主线裁决 → 派修复子任务改一遍并跑一次复核 → 主线读新一轮日志再裁决。循环由主线驱动，子任务不自行收敛。

### 1. 取评审：主线自跑，后台执行，两流分文件

第 1 步 · 前台，切到 PR 分支并建日志目录：

```bash
gh pr checkout <PR>                                    # 首轮前必须切到 PR 分支
mkdir -p "$(git rev-parse --git-dir)/pr-review"
```

第 2 步 · **后台**（Bash 工具参数 `run_in_background: true`），跑评审：

```bash
REVIEW="${CLAUDE_PLUGIN_ROOT}/skills/pr-review/scripts/pr-review.sh"
[ -x "$REVIEW" ] || { echo "pr-review 脚本路径解析失败" >&2; exit 1; }
LOG="$(git rev-parse --git-dir)/pr-review"
"$REVIEW" <PR> > "$LOG/<PR>-r1.log" 2> "$LOG/<PR>-r1.err"
```

预期结果：第 2 步的 tool_result 只有一行受理回执（`Command running in background with ID: …`），评审正文进 `.log`，诊断与告警进 `.err`。评审跑完后完成通知自动送达主线，其中带 `<status>` 与 exit code。「dump 不进主线」由重定向达成。相比派一个子任务去跑，这条路径少一个实例的 system prompt 与 skill 加载开销。**漏掉重定向就是错的**——正文会直接灌进主线上下文，旧失败模式原地复活。

**评审调用应走后台，`run_in_background` 是 Bash 工具参数、不是命令的一部分**——它写在工具调用的 `run_in_background` 字段里，照抄上面的命令文本抄不到它。理由是通道容量：前台 Bash 调用的 `timeout` 上限 600000ms 是硬顶，而评审时长随 PR 体量与 `--effort` 增长、无上限，撞顶即被 SIGTERM 杀（`Exit code 143`）或被静默移入后台；后台通道无此上限。正文与诊断既已全部落盘，前台阻塞也换不回任何多余信息。

两步分开跑，是因为 shell 变量不跨 Bash 调用保留——第 2 步须自带 `REVIEW` / `LOG` 赋值，不能指望第 1 步的赋值还在。

`$(git rev-parse --git-dir)` 在 worktree 里返回该 worktree 自己的 gitdir——评审日志随工作区走，不入版本库。

**两流必须分文件，不得 `2>&1` 合并**：脚本有意把评审正文放 stdout、诊断放 stderr，而首轮的引擎调用不做 stderr 隔离，`2>&1` 会让进度与告警插进评审正文中间。脚本非零退出时读 `.err` 拿原文，不自行重试、不改用其他评审方式。

**路径用 `${CLAUDE_PLUGIN_ROOT}`，不要 `find … | head -1`**：本文件经 skill 加载时该变量已展开成绝对路径；被当**文件**读取时它是字面量（主线 shell 环境里并没有这个变量），故配方带 `[ -x "$REVIEW" ]` 先验——路径解析不出来就当场停，不往下跑。**每处 `REVIEW=` 赋值后面都紧跟这行先验**，本仓文档无例外：配方要能独立照抄，就不能靠「上一节已经写过」。`find` 有两个实测失败模式——它解析到的是 marketplace 源码副本而非已安装的 cache（cache 路径含版本段，`*/pr-review/skills/…` 匹配不到），而远程安装无本地 clone 时零命中。

**等完成通知，不要轮询**：后台评审跑完时通知会自动送达，主线**不应**用 `sleep` + `tail` 反复探日志——那每探一次烧一个 turn，且拿到的是半截正文。派完后台调用就结束本轮、交还主循环。想看中途进度时读一次后台任务的 output 文件即可，不要为此起轮询循环。

**被中断时不要重开一轮**：后台通道无超时，剩余的中断来源只有用户主动中断与 session 结束。此时残日志**不得**拿来裁决，两条路径的补救不同：

- **首轮**——SID 在 `.err` 的 `session=` 行里（脚本在调引擎**之前**就打了它），应丢弃残日志，用 `--session <SID> --followup "<继续评审的指令>"` 续接，不重发全量 diff。续接失败时脚本会明确报 session 已失效并要求重开首轮，故这条路径**宜**先试——试错成本低于无条件重发全量 diff。
- **复核轮**——session 已在 state 文件里，应丢弃残日志**只重跑这一轮 `--followup`**，不要回头重开首轮（那会覆写 SID）。

### 2. 裁决：主线 Read 评审日志（每轮都回到这一步）

主线 Read `.log` 拿**无损原文**，逐条研判「这条 finding 站不站得住」。评审正文自带 reviewer 的推理与代码依据，主线无须再从代码里把评审已经说过的话重新推导一遍——这是「定位素材」这类派发被删掉的原因。

日志过大时按 offset/limit 分段读完。**不要只 grep 严重度标签**——那把无损原文重新压回一行摘要，删掉「定位素材」派发的理由也随之消失。

主线**跨轮维护**两份清单：**采纳清单**（每条附评审原文摘录 + 落点 `文件:行`）与**驳回清单**（每条附驳回理由）。首轮建立，之后每轮用新日志**增量更新**——划掉已关闭项、接纳新项。复核规则要求评审方不重列未变化部分，故**不得只凭本轮正文重建清单**，否则上一轮采纳、本轮没被点名的项会凭空蒸发，提前判空。

**收敛判据是「本轮评审跑成了，且采纳清单为空」，不是「评审方说了 `LGTM`」**——评审引擎是对等 peer 不是权威，把它的措辞当出口就是让 peer 变回权威。

**前置必须先验**：本轮 `exit=0` 且 `.log` 是完整评审正文。复核轮的 Fail Fast（cwd 钉死、`BASE_SHA` 非祖先、session 失效）走 `die()`，原因进 `.err`、**`.log` 是空的**——拿空 `.log` 当「本轮无 finding」会把采纳清单清成空、假收敛，失败与「没问题」同形。非零退出一律读 `.err` 按 §1 的失败路径处理：不重试、不换引擎，**也不收工**。

前置成立后：采纳清单为空即收工，无论本轮评审是 `LGTM`、还是仍在复述已被驳回的 finding；采纳清单非空（未改净的旧项，或新 finding 经裁决进入）则回第 3 步再派一次。

这条判据让常见分支自然落位，不必逐种枚举：仅驳回项复述 → 采纳为空 → 收工；新 finding 全被驳回 → 采纳仍空 → 收工；采纳项没改净 → 采纳非空 → 再派。

复核走同一评审 session，**被驳回的 finding 常被原样复述**。驳回清单只给修复子任务挡不住这件事——评审 session 才是复述的源头，故工单的 `--followup` 正文应带上驳回清单（「以下维持驳回，无新证据不要重开」）。

安全阀：连续 3 轮采纳清单不见空，停下来交人裁决，不要继续派。这是拦跑飞，不是预算闸。

不要用 `diff` 两轮日志判「新增」：复核输出是 session 续写而非 finding 全量重列，`.err` 每轮还带变动的增量字节数，整文件比对与 finding 增没增无关。

### 3. 修复：一轮一派

主线把两份清单合成工单，派一个**修复子任务**。工单要素：

- **采纳清单**逐条改；**驳回清单**随附——只给采纳清单，子任务会把主线已驳回的 finding 一并改掉
- **cwd 钉死为首轮的仓库 toplevel，禁用 worktree 隔离**——脚本按 `git rev-parse --show-toplevel` 钉 session 身份，换路径直接 Fail Fast
- 改完 `git commit` 新 commit（勿 `git amend` 首轮 tip），然后跑**一次**复核：
  `<REVIEW 绝对路径> <PR> --followup "<复核指令 + 驳回清单>" > <日志目录>/<PR>-r<N>.log 2> <日志目录>/<PR>-r<N>.err`
- **该复核调用与首轮同样走后台**（`run_in_background: true`），等完成通知，不轮询——超时上限对子任务一样是硬顶，理由见 §1
- **回传 exit code 与两个日志路径，到此为止**——不判定收敛、不循环、不自行裁决

脚本路径与日志目录在工单里**应展开成字面绝对路径**：子任务不继承主线的 shell 变量，`${CLAUDE_PLUGIN_ROOT}` 在子任务 prompt 里也不展开。

档位默认 `dev`。只有当工单把每条都钉到 `文件:行:改法`、子任务纯粹转录时才降 `dev-econ`——实现评审意见通常含改法取舍，塞进经济档不合其准入判据。

### 例外

PR 极小、单文件、diff 一屏内可尽收——主线直接跑、直接改，**不必派修复子任务**。落盘不在豁免之列：两流重定向对一屏 diff 的代价也接近零，而免掉它就是把正文灌回主线，旧失败模式原地复活。

## 后端选择

| 后端 | 机制 | 何时用 | 详细用法 |
|---|---|---|---|
| grok | 本地 CLI 同步产出评审 → 终端 | 本地即时深度评审，默认 high 可调档；`pr-review.sh` 自动路由的默认目标 | `references/grok-review.md` |
| claude | 本地 `claude -p` 同步产出评审 → 终端 | wrapper 会话经 grok provider 路由时，`pr-review.sh` 自动切换到的目标；也可手动强制 | `references/claude-review.md` |
| copilot（可选） | gh 触发 GitHub Copilot bot 异步评审 → 回帖 PR | 复杂项目收尾、成本高通常不启用 | `references/copilot-review.md` |

## 默认路径：`pr-review.sh`

`pr-review.sh` 是 grok/claude 之间的自动路由统一入口——`resolve-backend.sh` 决定用哪个后端：`PR_REVIEW_BACKEND` 环境变量显式覆盖 > 自动探测当前会话是否经 wrapper 走 grok 路径（`ANTHROPIC_DEFAULT_OPUS_MODEL` 是否以 `grok/` 开头）> 默认 grok（现状不变）。

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/pr-review/scripts/pr-review.sh" <PR> [--repo owner/name]
```

**cwd 必须是被评审 PR 所在的仓库工作区**——底层脚本按 `git rev-parse --show-toplevel` 钉死 session 身份、按 cwd 取增量 diff，不是"不依赖 cwd"。结果打到 stdout（按上文重定向落盘），不发 PR 评论。

**强制指定后端**：设 `PR_REVIEW_BACKEND=grok` 或 `PR_REVIEW_BACKEND=claude` 后再调 `pr-review.sh`，或直接调用对应的 `grok-review.sh`/`claude-review.sh`。两个后端 CLI 参数形态完全一致（`<PR> [--repo] [--model] [--effort] [--followup] [--since] [--session] [--allow-divergent-base]`），仅 `--effort` 合法集合不同：grok 严格为 `none/minimal/low/medium/high`（默认 `high`，`GROK_EFFORT` 覆盖），claude 严格为 `low/medium/high/xhigh/max`（默认 `medium`，`CLAUDE_REVIEW_EFFORT` 覆盖，`CLAUDE_REVIEW_MODEL` 覆盖 model，默认 `claude-opus-5`）。grok 复核轮读到旧持久 state 的 `EFFORT=xhigh` 时会在调用前一次性迁移为 `high`（claude 无此历史包袱）。参数细节、工作原理、故障排查见 `references/grok-review.md`（grok）/ `references/claude-review.md`（claude）。

**脚本路径发现**：主线用 `${CLAUDE_PLUGIN_ROOT}/skills/pr-review/scripts/pr-review.sh`——展开时机与配套先验见「执行分工」§1。下发工单时把它**展开成字面绝对路径**写进去：子任务 prompt 里 `${CLAUDE_PLUGIN_ROOT}` 不展开，而 `find … | head -1` 有实测失败模式（见「执行分工」§1）。只需认识 `pr-review.sh` 这一个命令，不必先跑 `resolve-backend.sh` 再自行选脚本。

**对抗式多轮复评**：首轮 `pr-review.sh <PR>` 全量评审建 session；复核轮 `--followup "<复核指令>"` 续接同一 session、只发复核指令 + 本轮增量 diff（不重发首轮全量）。每轮的正文与诊断各自落盘为 `<PR>-r<N>.log` / `<PR>-r<N>.err`。**轮次由主线驱动**，分工与收敛判据见上文「执行分工」；本段只讲脚本侧的 session 机制。

前台，切分支 + 建日志目录（本地 HEAD≠PR head 时首轮默认 Fail Fast，除非 `--allow-divergent-base`）：

```bash
gh pr checkout 123
mkdir -p "$(git rev-parse --git-dir)/pr-review"
```

后台（`run_in_background: true`），第 1 轮全量评审：

```bash
REVIEW="${CLAUDE_PLUGIN_ROOT}/skills/pr-review/scripts/pr-review.sh"
[ -x "$REVIEW" ] || { echo "pr-review 脚本路径解析失败" >&2; exit 1; }
LOG="$(git rev-parse --git-dir)/pr-review"
"$REVIEW" 123 > "$LOG/123-r1.log" 2> "$LOG/123-r1.err"

# 之后每轮的 --followup 由修复子任务按 §3 执行（同样走后台，形如下行），主线只 Read 它回传的路径：
#   "$REVIEW" 123 --followup "<复核指令 + 驳回清单>" > "$LOG/123-r2.log" 2> "$LOG/123-r2.err"
# 修复请 git commit 新 commit，勿 git amend 首轮 tip
# （amend 会让首轮 BASE_SHA 不再是 HEAD 祖先 → 复核轮 Fail Fast，须重开首轮或 --since）
```

**复核轮须在首轮同一工作区 toplevel 路径里跑**（脚本按 `git rev-parse --show-toplevel` 路径钉死身份、Fail Fast 拒绝在无关仓库续 session）——同一 worktree 内部自洽即可，**换到别的 worktree/clone 路径要重开首轮**（不是"可跨 worktree 续接"）。会话续接机制、增量 diff 语义、工作区身份钉死、Fail Fast 语义、敏感文件处理见 `references/grok-review.md`；claude 后端特有的隔离旗标、会话失效判定、state 文件后缀见 `references/claude-review.md`。

## 可选路径：copilot

需要 GitHub 原生 bot 在 PR 上留下评审记录时，读 `references/copilot-review.md`——覆盖首次触发、重新触发（re-request）与状态查询三条路径，机制不同不可混用。
