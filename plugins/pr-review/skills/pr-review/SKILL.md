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

## 执行分工（主线只研判裁决）

本 skill 的机械性工作默认交给子任务（subagent）处理，主线只做逐条研判「这条 finding 站不站得住」+ 决定改哪。

派发分两类，各自的约束无条件成立——派发时按「派的是哪类活」整组取用，不在规则内部做二选一判断。

### 派发 A —— 取评审

跑 `pr-review.sh`（grok/claude 自动路由的统一入口），回传结构化 finding 摘要（每条 `文件:行` + 问题 + 严重度 + 依据）。写进子任务 prompt 的三条约束：

1. **输出即产物**——最终返回消息本身就是摘要，不写完成说明或元总结；
2. **范围围栏**——只跑脚本、只整理其输出，不改代码、不 commit、不 push、不动 PR 状态；
3. **前台同步执行**——禁止 `run_in_background`、Monitor、`nohup` 等后台化手段，`pr-review.sh` 未退出不得返回。

第 3 条与「尽早吐中间进展」的通行做法**相反**，原因在脚本形态：`pr-review.sh` 路由到的 grok-review.sh/claude-review.sh 都只把评审正文流式打到 stdout、不落盘（state file 只存 SID/MODEL/EFFORT/CWD/BASE_SHA），子任务提前返回即丢失本轮产物，只能重跑。需要分段时是「拿到完整输出后分段整理」，不是分段回传进度。

可复制的完整 prompt 模板（含脚本路径解析）见 `references/grok-review.md`「派发 A 模板」——填 PR 号与 followup 文本即可；模板已简化为只需认识 `pr-review.sh` 这一个命令。

### 派发 B —— 定位素材

通读全量/增量 diff、按 finding 逐条读码定位，回传定位结论（finding → `文件:行` + 依据）。写进子任务 prompt 的三条约束：

1. **输出即产物**——最终返回消息本身就是定位结论，不写完成说明或元总结；
2. **范围围栏**——只读码定位，不改代码；
3. **渐进产出**——大 diff 分段读、尽早吐中间进展，防 watchdog stall。

派发 B 是调研、自身持续产出文本，第 3 条在此按常规成立。

### 主线

两类子任务都不把原始 dump 灌进主线上下文。主线侧另有一条**定稿纪律**：据以改码的结论只采信子任务的完整定稿返回，不采信中间片段——这条约束派发端自己，不写进子任务 prompt。

session 状态本就落盘（state file），复核轮的派发 A 用同一 session 续接，主线不必吃全量 diff。

例外（不必卸载）：PR 极小、单文件、diff 一屏内可尽收——主线直接研判更省往返。

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

**cwd 必须是被评审 PR 所在的仓库工作区**——底层脚本按 `git rev-parse --show-toplevel` 钉死 session 身份、按 cwd 取增量 diff，不是"不依赖 cwd"。结果直接打印到终端，不发 PR 评论。

**强制指定后端**：设 `PR_REVIEW_BACKEND=grok` 或 `PR_REVIEW_BACKEND=claude` 后再调 `pr-review.sh`，或直接调用对应的 `grok-review.sh`/`claude-review.sh`。两个后端 CLI 参数形态完全一致（`<PR> [--repo] [--model] [--effort] [--followup] [--since] [--session] [--allow-divergent-base]`），仅 `--effort` 合法集合不同：grok 严格为 `none/minimal/low/medium/high`（默认 `high`，`GROK_EFFORT` 覆盖），claude 严格为 `low/medium/high/xhigh/max`（默认 `medium`，`CLAUDE_REVIEW_EFFORT` 覆盖，`CLAUDE_REVIEW_MODEL` 覆盖 model，默认 `claude-opus-5`）。grok 复核轮读到旧持久 state 的 `EFFORT=xhigh` 时会在调用前一次性迁移为 `high`（claude 无此历史包袱）。参数细节、工作原理、故障排查见 `references/grok-review.md`（grok）/ `references/claude-review.md`（claude）。

**派发给子任务时的路径发现**：`${CLAUDE_PLUGIN_ROOT}` 在 subagent 正文里不展开。解析命令已内置于 `references/grok-review.md`「派发 A 模板」，复制该模板即可——子任务只需认识 `pr-review.sh` 这一个命令，不用先跑 `resolve-backend.sh` 再自行选脚本。

**对抗式多轮复评**：首轮 `pr-review.sh <PR>` 全量评审建 session；之后每轮 Claude 研判评审意见、改代码，再用 `pr-review.sh <PR> --followup "<复核指令>"` 续接同一 session、只发复核指令 + 本轮增量 diff（不重发首轮全量），循环到 LGTM。三轮示例：

```bash
REVIEW="${CLAUDE_PLUGIN_ROOT}/skills/pr-review/scripts/pr-review.sh"

gh pr checkout 123                                                  # 必须：先切到 PR 分支再跑首轮（本地 HEAD≠PR head 时首轮默认 Fail Fast，除非 --allow-divergent-base）
"$REVIEW" 123                                                       # 第 1 轮：全量评审
# Claude 研判 finding，改代码（在同一仓库/分支上）——修复请 git commit 新 commit，勿 git amend 首轮 tip
# （amend 会让首轮 BASE_SHA 不再是 HEAD 祖先 → 复核轮 Fail Fast，须重开首轮或 --since）
"$REVIEW" 123 --followup "已修复 XX，请复核"                          # 第 2 轮：续 session 复核
# Claude 继续研判/改代码
"$REVIEW" 123 --followup "已修复 YY，是否 LGTM"                       # 第 3 轮：直到 LGTM
```

**复核轮须在首轮同一工作区 toplevel 路径里跑**（脚本按 `git rev-parse --show-toplevel` 路径钉死身份、Fail Fast 拒绝在无关仓库续 session）——同一 worktree 内部自洽即可，**换到别的 worktree/clone 路径要重开首轮**（不是"可跨 worktree 续接"）。会话续接机制、增量 diff 语义、工作区身份钉死、Fail Fast 语义、敏感文件处理见 `references/grok-review.md`；claude 后端特有的隔离旗标、会话失效判定、state 文件后缀见 `references/claude-review.md`。

## 可选路径：copilot

需要 GitHub 原生 bot 在 PR 上留下评审记录时，读 `references/copilot-review.md`——覆盖首次触发、重新触发（re-request）与状态查询三条路径，机制不同不可混用。
