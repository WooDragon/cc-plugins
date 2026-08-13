# Grok 后端：本地评审 GitHub PR

本地 grok CLI 同步评审已开的 PR，评审结果直接打印到终端——不发 PR 评论、不触碰远程状态。本地即时深度评审，默认 `high` 档；日常想省 token 可调低 effort 档控成本。

**要求**：`grok` CLI 已装并登录（未登录会在调用时提示 `grok login`）。

## 快速用法

```bash
# 首轮：全量评审，建 session
scripts/grok-review.sh <PR> [--repo owner/name] [--model M] [--effort E]

# 复核轮：续接同一 session，只发复核指令 + 本轮增量 diff
scripts/grok-review.sh <PR> --followup "<复核指令>" [--since <ref>] [--session <UUID>] \
                            [--repo owner/name] [--model M] [--effort E]
```

不带 `--repo` 时自动用当前仓库。首轮与复核轮是两条独立路径，机制见下方"多轮 session 复用"。

## 派发 A 模板（子任务 prompt）

主线把「取评审」派给子任务时复制本块，替换 `<PR>` 与复核指令文本，其余原样。`${CLAUDE_PLUGIN_ROOT}` 在 subagent 正文里不展开，故模板自带路径解析命令。

```text
用 grok 评审 PR <PR>，取回评审结果。

执行步骤：
1. 解析脚本路径：
   REVIEW=$(find ~/.claude/plugins -path '*/pr-review/skills/pr-review/scripts/grok-review.sh' 2>/dev/null | head -1)
2. 在当前工作区（即被评审 PR 所在的仓库 checkout）前台执行：
   "$REVIEW" <PR>
   复核轮改用： "$REVIEW" <PR> --followup "<复核指令文本>"

约束：
- 前台同步执行：禁止 run_in_background / Monitor / nohup 等任何后台化手段，脚本未退出不得返回。脚本只把评审正文打到 stdout、不落盘，提前返回即丢失本轮产物，只能重跑。需要分段时是拿到完整输出后分段整理，不是分段回传进度。
- 范围围栏：只跑脚本、只整理其输出。不改代码、不 commit、不 push、不动 PR 状态。
- 输出即产物：最终返回消息本身就是下列摘要，不写完成说明或元总结。

返回格式，每条 finding 一行：
  [严重度] 文件:行 — 问题一句话 — grok 给出的依据或建议一句话
严重度取 Critical / Major / Minor。grok 判定无问题时回传 LGTM 及其原话理由。
脚本非零退出时，回传退出码与 stderr 末段原文，不自行重试、不改用其他评审方式。
```

## 参数语义

| 参数 | 说明 | 默认 |
|---|---|---|
| `<PR>` | PR 编号（必填，纯数字） | — |
| `--repo owner/name` | 目标仓库，跨仓库评审时指定 | 当前 `gh` 仓库 |
| `--model M` | grok 模型 | `grok-4.6`（可用环境变量 `GROK_MODEL` 覆盖） |
| `--effort E` | 推理强度。支持的值严格为 `none/minimal/low/medium/high`；不支持 `xhigh`。 | `high`（可用环境变量 `GROK_EFFORT` 覆盖）。日常想省 token 可 `--effort low/medium` 或 `GROK_EFFORT=low`。旧持久 state 中的 `EFFORT=xhigh` 会在复核前一次性迁移为 `high`。 |
| `--followup "<文本>"` | 进入复核轮：`-r` 续接同一 session，只发 followup 文本 + 本轮增量 diff（不重发首轮全量） | 不传即为首轮 |
| `--since <ref>` | 仅复核轮生效：增量 diff 改用 `git diff <ref>` 计算基准（会先 `rev-parse --verify` 校验 ref） | 默认 `git diff <状态文件 BASE_SHA>`（首轮 HEAD）＋ untracked；`BASE_SHA` 从未记录时用 `git diff HEAD`，记录存在却不可达则 **Fail Fast**（不静默降级） |
| `--session <UUID>` | 显式覆盖本轮使用的 SID，优先级高于状态文件 | 读状态文件里的 `SID` |
| `--allow-divergent-base` | 仅首轮：本地 HEAD 与 PR `headRefOid` 不一致时默认 Fail Fast，此 flag 放行（降级为警告、照常建 session） | 默认不放行（Fail Fast） |

## 工作原理（首轮）

1. `gh pr view` 拉 PR 标题 / 描述，`gh pr diff` 拉远程 diff（都带 `--repo` 透传，不依赖本地 checkout）。
2. 安全约束（角色 + 不可信声明）经 `--rules` 走 grok 系统提示；PR 元信息与 diff 用**每次随机生成的 delimiter** 包裹后写入 prompt-file。
3. `SID=$(uuidgen)`（或兜底方案，见下），`grok --prompt-file <tmp> -m <model> --effort <effort> --sandbox read-only --output-format plain -s "$SID"` 产出评审，打印到终端。
4. **grok 成功返回后**才把 SID / BASE_SHA / MODEL / EFFORT / CWD 写入 session 状态文件（首轮失败不落盘，避免留下误导性 SID，见「session 状态文件」）。临时文件全程用 `trap ... EXIT` 清理。

## 多轮 session 复用

对同一个 PR 做多轮对抗式复评（Claude 研判 grok 意见 → 改代码 → 再评审 → 循环到 LGTM）时，若每轮都重新拉全量 diff 整包发送，token 与延迟随轮数线性放大，且模型每轮"从零重读"看不到上一轮提了什么、这轮改了什么。本脚本用 grok CLI 原生的会话续接能力解决：

- **首轮**：`SID=$(uuidgen)` 生成一个会话 ID，`grok ... -s "$SID"` 建会话并发送全量 PR diff；SID 落盘到 session 状态文件（见下）。首轮全量 diff 从此留在 grok 服务端会话历史里，天然吃到其 prompt cache。
- **复核轮**：`--followup "<复核指令>"` 触发；脚本按 PR 号读回上一轮的 SID，`grok ... -r "$SID"` 续接同一会话，prompt-file 只含 followup 文本 + **本地增量 diff**——不重发首轮那份远程全量 PR diff。grok 凭会话记忆知道自己上一轮说了什么，只需要看本地改了什么。
  - **增量语义要看清**：默认增量是 `git diff <BASE_SHA>`（BASE_SHA=首轮 HEAD），即**累积自首轮起的全部本地 delta**，不是严格的"仅相对上一轮"。好处是改完 commit 也不会漏；代价是多轮 followup 时早先几轮的改动会重复出现在增量里（grok 侧有会话记忆，多为冗余强化而非新信息）。想要严格的"仅本轮"增量、或自定义基线，复核轮传 `--since <上一轮的 tag/sha>`。相对首轮那份远程全量 PR diff，本地增量始终小得多，省 token 目标成立。
  - 首轮工作区若非干净，BASE_SHA 之后的未提交改动会被计入复核增量（脚本首轮会 stderr 警告）；需要干净语义就先 commit/stash，或复核轮用 `--since`。

典型两轮命令：

```bash
# 第 1 轮：全量评审
scripts/grok-review.sh 123

# ...Claude 研判 grok 意见，改代码，git add...

# 第 2 轮：复核，只发复核指令 + 本轮增量 diff
scripts/grok-review.sh 123 --followup "已按你的意见修复 file.go:42 的空指针解引用，请复核"
```

第 2 轮的 `--repo` 解析方式与首轮一致（传参则用传参值，否则取当前 `gh` 仓库），据此算出与首轮相同的状态文件路径才能读到 SID——若两轮所在目录/`--repo` 解析出不同仓库，会算出不同的状态文件路径而读不到 SID，触发 Fail Fast。`--model`/`--effort` 复核轮**默认沿用首轮值**（从状态文件读回，保证同一 session 各轮推理强度一致，详见下文「session 状态文件」）；显式传 `--model`/`--effort` 时以命令行为准。

### 增量 diff 语义

- 默认基准优先用**首轮记录的 `BASE_SHA`**（首轮时的 HEAD）：复核轮跑 `git diff <BASE_SHA>`，因此**即使 Claude 把修复 commit 了**，增量 diff 仍能涵盖这些已提交的改动——消除"改完 commit 再 followup 却增量为空、模型只能靠记忆猜"的陷阱。
- **`BASE_SHA` 不可达 → Fail Fast，绝不静默降级**：`BASE_SHA` 记录存在、但对象不在当前 clone（rebase / GC / 换库）时，脚本**报错退出**而非降级 `git diff HEAD`。原因：干净树下降级会得到**空增量**，正是 `BASE_SHA` 想消灭的"假收敛"陷阱换个入口（grok 复评空 diff 极易误发 LGTM），且静默无感。此时请用 `--since <ref>` 显式指定本轮基线，或在正确 clone 重开首轮。只有 `BASE_SHA` **从未记录**（旧版 session / `--session` 覆盖无 state）时才用 `git diff HEAD` 兜底——那是无锚点下的诚实尽力，且空增量会明确 stderr 提示。
- **`BASE_SHA` 可达但非 HEAD 祖先 → 也 Fail Fast**："对象存在" ≠ "基线语义仍成立"。`git diff <BASE_SHA>` 作"自首轮起累积 delta"只在 HEAD 由 BASE_SHA 派生时成立。评审途中 `git rebase` / `commit --amend` / **同仓切到别的分支** / `reset --hard` 后，旧 tip 常仍可达（reflog/别的 ref → `cat-file -e` 成功），但已非当前 HEAD 祖先——此时 `git diff` 会吐出整段 rewrite / 换分支的巨 delta，污染复评。工作区身份钉只比 toplevel **路径字符串**、管不住同仓换分支，故这里额外用 `git merge-base --is-ancestor <BASE_SHA> HEAD` 校验，非祖先即报错退出（提示用 `--since` 或在正确分支重开首轮）。
- 显式传 `--since <ref>` 时改用 `git diff <ref>`，覆盖需要自定义基线的场景（优先级高于 `BASE_SHA`）。`--since`/`--session` 仅在复核轮（配合 `--followup`）有效，首轮误用会直接报错而非静默忽略。**注意 `--since` 是基线安全网的完整旁路**：它只校验 ref 存在（`rev-parse --verify`），不做 `BASE_SHA` 路径那样的"祖先校验"——传错 ref（如指向无关分支）会得到巨 delta 且不 Fail Fast。**错误的 `--since` = 主动关闭基线安全网**，请确认 ref 确是本轮想要的基线。
- 未跟踪的新文件不在 `git diff` 范围内，脚本额外用 `git ls-files --others --exclude-standard -z` 找出这些文件，逐个 `git diff --no-index -- /dev/null <file>` 生成标准 diff 格式补进去（`--` 防以 `-` 开头的文件名被当 option；真错误的 stderr 不静默丢弃）——对抗轮里 Claude 新建的修复文件不会被静默丢弃。
- 复核轮的 `--cwd` 与增量 diff **动态同源**：都取当前 `git rev-parse --show-toplevel`，保证 grok 读到的文件树和脚本发送的增量 diff 是同一份工作区（不在合法 git 仓库时降级用状态文件里记录的历史 CWD，或省略 `--cwd`）。这个判定比首轮宽松（首轮要求本地 checkout 精确匹配 PR 的 owner/name），因此也覆盖 Fork 贡献者的工作流。
- **工作区身份钉死（Fail Fast）**：复核轮若状态文件记录了首轮 `CWD` 且与当前 toplevel **不一致**，直接报错退出——防"`cd` 到无关仓库 + `--repo` 指对 PR"时读对 SID 却 diff 错代码、产出幻觉式复评。`CWD` 与"是否给 grok 传 `--cwd`"**解耦**：只要首轮在 git 仓就记录，因此 fork/worktree（owner 启发式未命中、不传 `--cwd`）场景**同样受身份钉保护**——复核轮必须回到首轮**那个 toplevel 路径**里跑（同一 worktree 内部自洽即可；跨 worktree/clone 换了 toplevel 路径就要重开首轮，不是"支持在任意 worktree 续接"）。
- **无工作区锚点的 session 也 Fail Fast**：若首轮在**非 git 目录**（仅靠 `--repo` 拉远程 diff）建立，状态文件 `CWD` 为空、身份钉整段短路——此时复核轮若身处任意 git 仓库，其 `git diff` 会被当作"本轮修复"塞进仍有记忆的 session（身份钉的反目标）。故 `CWD` 为空时复核轮默认**报错退出**，逼你在该 PR 的正确 clone 内重开首轮以钉死工作区；显式 `--session <UUID>`（手动持 SID、知情放行）则仅告警放行。
- **首轮基线对齐（默认 Fail Fast）**：首轮审的是远程 `gh pr diff`，而复核基线 `BASE_SHA`＝首轮时的**本地 HEAD**。若本地未 checkout 该 PR 分支（本地 HEAD ≠ PR `headRefOid`），复核增量会膨胀成"整条分支相对本地 HEAD"的大 delta 并污染全部复评轮——脚本首轮**默认 Fail Fast**（能确知 diverge 时；取不到 PR head 则不阻断）。**请先 `gh pr checkout <PR>` 再跑首轮**；确知要以本地 HEAD 为基线，加 `--allow-divergent-base` 放行（降级为警告）。
- 算 diff 前，脚本会在 stderr 打印安全网信息（repo 路径、当前分支、增量 diff 字节数），方便当场核对"这份 diff 是不是本轮该发的那份"，及时发现切错分支、目录不对等问题。
- untracked 收集是 **best-effort**：`--no-index` 有差异时 exit=1 属正常（`|| true` 吞掉），但权限/路径等真错误的 stderr 保留可见（不 `2>/dev/null` 静默），避免新建的修复文件被无声丢掉。
- **空增量默认放行，但靠 RULES 堵"无 diff 假 LGTM"**：工作区干净且无 `--since` 时增量为空，脚本仅发 followup 文本（不硬失败）——因为"你说的第二点我不改，理由是……"这类**纯讨论/辩护**是一等用例，默认 Fail Fast 会误伤它（Never break userspace）。但"零改动 + 强硬 followup（如'已全部修复请 LGTM'）"在自动化循环里可能骗出假 LGTM，故在 `RULES_FOLLOWUP` 里加了**验证纪律**：无 INCREMENTAL DIFF 段时，模型**不得**仅凭 followup 自然语言关闭 Critical/Major——纯讨论就当讨论回应，声称修复却没带 diff 必须标"无法验证"并要求补 diff。这比 CLI flag 更硬（自动化作者能绕过 flag，绕不过喂给模型的系统规则）。**空增量 ≠ 修复已验证**。

### 为何用 `-s` 预指定 UUID，而非从 `--output-format json` 解析 sessionId

grok 的 `--output-format json` 输出**不是合法 JSON**——`thought` 字段里含未转义的裸换行，`jq -r '.sessionId'` 解析会直接崩掉。因此脚本不走"首轮 json 输出 → jq 抽 sessionId"这条路，改为**首轮自己生成 UUID 并用 `-s <UUID>` 指定**：首轮输出仍可用 `plain` 格式直出到终端，无需解析、少一个易碎环节。已用真实 grok 0.2.93 验证：显式 UUID 可以跨独立进程、跨 cwd 续接成立。

> **最低 grok 版本**：session 复用依赖 grok CLI 的 `-s`/`-r`（已在 **0.2.93** 实证）。更旧的 CLI 不识别 `-s` 会导致首轮直接失败——如遇首轮报未知参数，请升级 grok CLI。

### Fail Fast：复核轮无法续接时不降级

脚本的一条总原则：**基线不可信就拒绝，绝不产出误导性增量**。复核轮遇到以下情况**报错退出**，不静默降级、不新建空白 session 拼凑请求：

- **无 session 状态文件 / SID 为空**（比如从未跑过首轮、或状态文件已被 GC）：报错提示先跑一次首轮。
- **grok 返回会话失效**（stderr 命中 `Failed to restore session` / `session get failed` 等失效文案，如 `session get failed: 404 Not Found`）：报错提示 session 已不可恢复，需重开首轮。
- **`BASE_SHA` 记录存在但对象不可达**（rebase/GC/换 clone）：拒绝降级 `git diff HEAD`（干净树会得到空增量 → 假收敛），提示用 `--since` 或重开首轮。
- **`BASE_SHA` 可达但非当前 HEAD 祖先**（rebase/amend/同仓切分支/reset）：`git diff` 会产生错基线巨 delta，`merge-base --is-ancestor` 校验失败即报错退出。
- **无工作区锚点的 session 在 git 仓复核**（首轮建于非 git 目录、`CWD` 为空）：默认拒绝用当前仓库 diff 续接，提示在正确 clone 重开首轮（`--session` 知情放行则仅告警）。若当前**也不在** git 仓库（双非 git），无代码可 diff，退化为纯 followup 文本放行——远程-only 两轮纯讨论是有意支持的，不误导。

首轮侧对应的 Fail Fast：**本地 HEAD 与 PR `headRefOid` 不一致**时默认报错退出（防 session 锚在错误基线），`--allow-divergent-base` 放行。

不降级的原因：followup 文本常常预设"grok 记得前几轮的 finding"（比如"你说的第二点我不改，理由是……"），如果偷偷新建一个没有记忆的新 session、或喂进空/错的增量去接这个 followup，模型会因为看不到真实改动而产生幻觉式回应，比直接报错更危险。

网络/服务类错误（如 429/503）按 grok 原样透传退出，不与"会话失效"混淆、不重试。

### session 状态文件

- 路径：`${XDG_STATE_HOME:-$HOME/.local/state}/pr-review/<owner>__<name>__<PR>.session`，按仓库 + PR 号确定性关联，跨 Claude 上下文/session compact 仍可靠恢复。
- 权限：目录 `chmod 700`（用户私有），防同机其他用户预埋 symlink 攻击。
- 内容：简单 KV——`SID` / `MODEL` / `EFFORT` / `CWD`（首轮工作区 toplevel；**只要在 git 仓就记录**，与是否给 grok 传 `--cwd` 解耦，供复核轮"工作区身份钉"比对）/ `BASE_SHA`（首轮 HEAD，作复核默认基线；只要在 git 仓就记录）/ `CREATED`（epoch 秒）。
- 生命周期：首轮**在 grok 成功返回后**才写入/覆盖同 PR 的旧文件——首轮失败不会留下误导性 SID/BASE_SHA（"不覆盖进行中会话"**仅对 grok 失败路径成立**）。成功路径**会**覆写同 PR 既有 state：因此无参重跑首轮（漏写 `--followup`）会用新 SID 覆盖活跃 session、丢掉旧会话记忆并再烧一轮全量 diff token——脚本在**调 grok 前**就大字警告"覆写已存在的活跃 session（旧 SID→新 SID）……若本意是复核请改用 --followup"，误触可当场 Ctrl-C 止损；不默认 Fail Fast，因为重跑首轮求全新 session 是合法常见操作。复核轮只读 SID/BASE_SHA，但**成功后会 `touch` 状态文件刷新 mtime**，防止活跃 session 被 GC 误清。不建 TTL 有效性判断（靠 Fail Fast 兜底失效场景）。每次首轮写入前顺手做 30 天 GC（`find ... -name '*.session' -mtime +30 -delete`），防止状态文件无限累积。

- 复核轮默认**沿用首轮的 model/effort**（从状态文件 `MODEL`/`EFFORT` 读回，保证同一 session 各轮推理强度一致）；命令行显式给出 `--model` / `--effort` 时以命令行为准（优先级：命令行 flag > 状态文件 > 默认/环境变量）。支持的 effort 值严格为 `none/minimal/low/medium/high`，默认 `high`，不支持 `xhigh`。旧持久 state 中唯一允许出现的 `EFFORT=xhigh` 会在复核前一次性迁移为 `high`；新的命令行或环境输入 `xhigh` 会被拒绝。**显式覆盖仅本轮生效、不写回 state**——下一轮不带 flag 会回到首轮记录值（非 sticky）；state 里 `MODEL` 读回时也过 `check_model` 校验（防损坏值注入 `-m`）。

## 设计说明

- **为何用 `--prompt-file` 而非 `-p`**：macOS 命令行参数总长度上限 `ARG_MAX` 约 256KB，大 diff 直接拼进 `-p` 参数会报 `Argument list too long`。写临时文件绕过这个限制，diff 多大都能传。
- **`--sandbox read-only`**：保证 grok 评审过程只读、不会误改本地文件。
- **`--cwd` 仅当本地 checkout 就是目标仓库时才传**：脚本会比对 `git rev-parse --show-toplevel` 对应的 `gh repo view` owner/name 与目标 PR 的 owner/name 是否一致，一致才传 `--cwd`。跨仓库评审（本地不在该仓库目录）时省略 `--cwd`，防止 grok 拿本地无关的文件树产生幻觉上下文。此为启发式判断（按 gh repo owner/name 匹配），fork + repo set-default 指 upstream 等场景可能不精确。
- **空 diff 直接跳过**：无 `@@` 文本 hunk（纯二进制/rename/mode 改动）时，脚本打印提示后退出，不调用 grok，省一次无意义的模型调用。
- **超大 diff 仅警告不拦截**：diff 字节数超过阈值（脚本内 `DIFF_WARN_BYTES=200000`）时打印警告到 stderr，但仍然继续评审——上下文窗口是否溢出交给 grok CLI 自身处理。
- **prompt 注入防护**：`--rules` 把安全约束放系统侧，比塞在用户 prompt 正文里更硬——PR 数据即使包含“忽略上文指令”之类文本也不会覆盖系统规则；每次运行随机生成的 delimiter 包裹 PR 元信息与 diff（首轮/复核轮共用同一套包裹逻辑），防止 PR body/diff 或 followup 增量 diff 里伪造相同的闭合标记逃逸出不可信数据边界。
- **复核轮状态文件读取用前缀删除法，不 `source`**：状态文件 KV 用 `sed -n 's/^KEY=//p'` 逐字段提取，只剥 `^KEY=` 前缀、保留值内可能出现的 `=`（如路径含 `=` 时不会被截断）；严禁 `source`/`.` 加载状态文件——即便目录已 `chmod 700`，`source` 等于执行文件内容，是不必要的注入面。

## 安全说明

`--cwd` 命中（本地 checkout 就是目标仓库）时，grok 可以**读**工作区文件——`--sandbox read-only` 只防写不防读。这意味着未跟踪的 `.env`、密钥等文件即使没提交、没出现在 diff 里，也可能被 grok 读入上下文并上送模型 API。在包含敏感凭据的仓库里跨仓库评审、或对该仓库执行评审时需留意此风险。此外，PR 的 title/body/diff 全量进 prompt 并上送模型 API，若 diff 中含密钥/token，等同于主动泄露给模型侧。

**复核轮同样适用此风险**：复核轮的 `--cwd` 只是判定条件从"精确匹配 PR owner/name"放宽为"当前处于任一合法 git 仓库"，`--sandbox read-only` 只防写不防读的性质不变——上面这段风险说明对复核轮原样成立，不再重复展开。

**复核轮 untracked 是"确定性上送"，比 `--cwd` 的"可能被读"更强**：复核轮会把工作区**未跟踪文件整文件序列化进 INCREMENTAL DIFF** 并上送模型 API——这不是"grok 可能读到"，而是**必定进 prompt**。因此未进 `.gitignore` 的 `.env` / 密钥 / 本地配置一旦存在于工作区，就会被送到模型侧。脚本对**疑似敏感文件名默认跳过**（覆盖清单见本段下方），跳过时 stderr 大字告警并提示"确需评审请改名到非敏感模式、或用不含密钥的独立 clone——**切勿 git add 密钥，tracked 会原样上送 API**"。这是**按文件名的启发式（大小写不敏感）**、非万能——覆盖 `.env`/`.env.*`/`*.env`/`.envrc`、`*.pem`/`*.key`/`*.crt`/`*.p12`/`*.pfx`/`*.pkcs12`/`*.keystore`/`*.jks`/`*.ppk`、`id_rsa`/`id_dsa`/`id_ecdsa`/`id_ed25519`、`credentials`/`*credentials*`、`secrets`/`secrets.*`/`*secrets*`/`*.secret`/`serviceaccount*.json`、`.netrc`/`.pgpass`/`.htpasswd`（`*.example`/`*.sample`/`*.template`/`*.dist` 例外放行），但奇怪命名里的密钥仍会漏网，敏感仓库评审前请自行确认工作区没有明文凭据。**untracked 体积另有硬闸**（tracked 不受限）：单个 untracked 文件超 `UNTRACKED_FILE_MAX_BYTES`（默认 256KB）跳过、untracked 累计超 `UNTRACKED_TOTAL_MAX_BYTES`（默认 1MB）停止收集，都 loud 告警——挡住"误漏 `.gitignore` 的 node_modules/大二进制 撑爆 prompt"这一上线最易踩的事故。总增量体积仍仅 `DIFF_WARN_BYTES` 警告不硬拦（见 issue #99）。

**tracked（已 `git add`/已提交）的敏感文件：只告警、不过滤**。跳过策略只作用于 **untracked**（工具自动 `ls-files` 收集、用户没主动选它们，故默认剔除）；一旦你 `git add .env`，它就是**你显式纳入本轮评审的内容**，会走 `git diff` 原样进增量并上送 API——脚本对此**大字告警**（"本轮 tracked 增量含疑似敏感文件……"）但**不静默删改你的 diff**（那会隐藏评审材料、且改动核心 diff 路径风险高）。换言之：**这个跳过机制不是密钥防火墙**，是对"工具自动扫入"这一条入口的纵深防御。真正的边界是：**别把明文凭据放进你要评审的 diff 范围**——tracked 内容一律按你的显式选择上送。

## 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| 提示未登录 / 认证失败 | 执行 `grok login` |
| 模型不可用 / 报错 unknown model | `grok models` 查当前账号可用模型列表，用 `--model` 或 `GROK_MODEL` 换一个 |
| 评审内容看起来被截断或遗漏大段 diff | 超大 diff 可能超出 grok 上下文窗口，参考脚本的超大 diff 警告；可考虑拆分 PR 或缩小 diff 范围后重试 |
| `无法确定当前仓库` | 未在 git 仓库目录内执行，或 `gh repo view` 失败；显式传 `--repo owner/name` |
| `PR #<n> 无活跃 session。请先跑一次首轮：grok-review.sh <n>` | 首次调用就带了 `--followup`，或状态文件已被 30 天 GC 清理、或本轮 `--repo`/所在目录解析出的仓库与首轮不同（算出了不同状态文件路径）；先跑一次不带 `--followup` 的首轮，或检查两轮 `--repo` 是否一致 |
| `PR #<n> 的 session 已失效/丢失，上下文不可恢复——请重开首轮评审` | grok 返回会话失效（如 `session get failed: 404`），session 已不可恢复；重新跑首轮开始新一轮评审 |
| `跳过超大 untracked 文件` / `untracked 累计已超 ... 停止收集` | 工作区有未 `.gitignore` 的大文件/大目录（node_modules、构建产物）；先补 `.gitignore` 再重跑，避免增量体积失控 |
| `BASE_SHA=... 记录存在但对象在当前 clone 不可达` | 首轮记录的基线被 rebase/GC 掉、或换了 clone；用 `--since <ref>` 显式指定本轮基线，或在正确 clone 重开首轮 |
| `session 无工作区锚点（首轮在非 git 目录建立）` | 首轮只靠 `--repo` 拉远程 diff、没有本地工作区锚点；在该 PR 的正确 clone 内重开首轮，或 `--session <UUID>` 知情放行 |
| `本地 HEAD ... 与 PR #<n> head ... 不一致` | 首轮所在本地 HEAD 不是 PR 分支；先 `gh pr checkout <n>` 再跑首轮，或加 `--allow-divergent-base` 以本地 HEAD 为基线 |
