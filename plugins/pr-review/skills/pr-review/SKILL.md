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

### 1. 取评审：主线自跑，stdout 重定向

```bash
REVIEW=$(find ~/.claude/plugins -path '*/pr-review/skills/pr-review/scripts/pr-review.sh' 2>/dev/null | head -1)
LOG="$(git rev-parse --git-dir)/pr-review"; mkdir -p "$LOG"

gh pr checkout <PR>                                        # 首轮前必须切到 PR 分支
"$REVIEW" <PR> > "$LOG/<PR>-r1.log" 2>&1; echo "exit=$?"
```

预期结果：主线上下文里只出现 `exit=0` 一行。「dump 不进主线」由重定向达成。相比派一个子任务去跑，这条路径少一个实例的 system prompt 与 skill 加载开销。前台 Bash 阻塞到脚本退出，「不得提前返回」由调用形态保证，无须写成纪律。

`$(git rev-parse --git-dir)` 在 worktree 里返回该 worktree 自己的 gitdir——评审日志随工作区走，不入版本库。

**唯一需要子任务的场景**：超大 PR 触到 Bash 前台调用的超时上限时，应派一个子任务跑同一条重定向命令；它同样只回传 `exit=` 一行——产物在评审日志里，回传什么都不影响。这是机械判据，不含取舍。

### 2. 裁决：主线 Read 评审日志

主线 Read 评审日志拿**无损原文**，逐条研判「这条 finding 站不站得住」。评审正文自带 reviewer 的推理与代码依据，主线无须再从代码里把评审已经说过的话重新推导一遍——这是「定位素材」这类派发被删掉的原因。

评审日志过大时按 offset/limit 分段读，或先 grep `Critical|Major` 收窄。两者都是 Read 的常规用法，不需要额外机制。

主线产出两份清单：**采纳清单**（每条附评审原文摘录 + 落点 `文件:行`）与**驳回清单**（每条附驳回理由）。

### 3. 修复：一次派发，一条收敛规则

主线把两份清单加下方收敛规则合成工单，派一个**修复子任务**执行。规格已钉死、不含取舍，`dev-econ` 档即可。收敛规则只有一条：

> 改完跑 `<REVIEW 绝对路径> <PR> --followup "<复核指令>" > <评审日志目录>/<PR>-r<N>.log 2>&1`。
> 复核结果只确认修复、或只出 Minor → 继续收敛，**上限 3 轮**。
> 出现**新的** Critical/Major → 停下回传，不自行裁决。

工单里的脚本路径与评审日志目录**应展开成字面绝对路径**——子任务不继承主线的 shell 变量。

「是否新增」由两轮评审日志比对得出，是可核验的事实而非判断题。修复子任务在正常路径上不做任何裁决：它执行一份已裁决的工单并确认落地，裁决权完整留在主线。

**驳回清单必须随工单下发**——只给采纳清单，修复子任务会把主线已驳回的 finding 一并改掉。

### 例外

PR 极小、单文件、diff 一屏内可尽收——主线直接跑、直接改，不必落盘也不必派发。

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

**脚本路径发现**：`${CLAUDE_PLUGIN_ROOT}` 只在本文件正文里可读，subagent prompt 与下发工单里都不展开——用 `find ~/.claude/plugins -path '*/pr-review/skills/pr-review/scripts/pr-review.sh' | head -1` 解析，或直接展开成字面绝对路径。只需认识 `pr-review.sh` 这一个命令，不必先跑 `resolve-backend.sh` 再自行选脚本。

**对抗式多轮复评**：首轮 `pr-review.sh <PR>` 全量评审建 session；之后每轮主线研判评审意见、下发修复，再用 `pr-review.sh <PR> --followup "<复核指令>"` 续接同一 session、只发复核指令 + 本轮增量 diff（不重发首轮全量），循环到 LGTM。**每轮重定向到独立日志文件**，轮次间直接比对即可判出「新增 finding」。三轮示例：

```bash
REVIEW=$(find ~/.claude/plugins -path '*/pr-review/skills/pr-review/scripts/pr-review.sh' 2>/dev/null | head -1)
LOG="$(git rev-parse --git-dir)/pr-review"; mkdir -p "$LOG"

gh pr checkout 123                                          # 必须：先切到 PR 分支再跑首轮（本地 HEAD≠PR head 时首轮默认 Fail Fast，除非 --allow-divergent-base）
"$REVIEW" 123 > "$LOG/123-r1.log" 2>&1; echo "exit=$?"      # 第 1 轮：全量评审
# 主线 Read "$LOG/123-r1.log" 逐条裁决 → 下发修复工单（修复请 git commit 新 commit，勿 git amend 首轮 tip）
# （amend 会让首轮 BASE_SHA 不再是 HEAD 祖先 → 复核轮 Fail Fast，须重开首轮或 --since）
"$REVIEW" 123 --followup "已修复 XX，请复核" > "$LOG/123-r2.log" 2>&1; echo "exit=$?"
# diff "$LOG/123-r1.log" "$LOG/123-r2.log" 判有无新增 Critical/Major；有则回主线裁决，无则继续收敛
"$REVIEW" 123 --followup "已修复 YY，是否 LGTM" > "$LOG/123-r3.log" 2>&1; echo "exit=$?"
```

**复核轮须在首轮同一工作区 toplevel 路径里跑**（脚本按 `git rev-parse --show-toplevel` 路径钉死身份、Fail Fast 拒绝在无关仓库续 session）——同一 worktree 内部自洽即可，**换到别的 worktree/clone 路径要重开首轮**（不是"可跨 worktree 续接"）。会话续接机制、增量 diff 语义、工作区身份钉死、Fail Fast 语义、敏感文件处理见 `references/grok-review.md`；claude 后端特有的隔离旗标、会话失效判定、state 文件后缀见 `references/claude-review.md`。

## 可选路径：copilot

需要 GitHub 原生 bot 在 PR 上留下评审记录时，读 `references/copilot-review.md`——覆盖首次触发、重新触发（re-request）与状态查询三条路径，机制不同不可混用。
