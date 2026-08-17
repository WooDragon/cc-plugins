#!/usr/bin/env bash
#
# claude-review.sh — 用本地 claude CLI（Claude Code 非交互模式 `claude -p`）评审 GitHub
# PR，评审结果打印到终端。与 grok-review.sh 是并列的同构后端，CLI 参数形态完全一致：
#
#   首轮:   claude-review.sh <PR> [--repo owner/name] [--model M] [--effort E] [--allow-divergent-base]
#   复核轮: claude-review.sh <PR> --followup "<复核指令>" [--since <ref>] [--session <UUID>] \
#                              [--repo owner/name] [--model M] [--effort E]
#   --allow-divergent-base: 首轮本地 HEAD 与 PR head 不一致时默认 Fail Fast，此 flag 放行（降级为警告）。
#
# 设计依据（见 references/claude-review.md）:
#   - 首轮 claude -p --session-id <uuid> 建会话、发全量 PR diff；复核轮 --resume <uuid> 续接。
#   - session 状态文件：${XDG_STATE_HOME:-$HOME/.local/state}/pr-review/<owner>__<name>__<PR>.claude.session
#     （后缀 .claude.session，与 grok 的 .session 互不覆盖，同一 PR 可各自独立跑一条评审 session）。
#   - 隔离旗标：--setting-sources "" --tools "" --disable-slash-commands，调用前
#     unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT——防止在当前 Claude Code 会话内部拉起 claude -p
#     子进程时递归加载 hook/plugin（复用 plugins/plan-review/scripts/lib/engines/claude.sh 已验证
#     的隔离手法）。**不加** --no-session-persistence：那会导致会话不落盘、--resume 完全失效，
#     与本脚本要的多轮对抗复评需求矛盾——这是与 plan-review 的 claude engine 的关键差异，勿抄错。
#   - --setting-sources "" 必须是空字符串，不能是 "local"：实测 --setting-sources local 仍会
#     加载 cwd 下 .claude/settings.local.json 里的 SessionStart 等 hook 并真实执行（即使
#     --tools "" 已禁用全部工具调用，hook 执行不经过工具调用路径，不受 --tools 约束）。本脚本
#     的运行前提是 cwd 通常是 `gh pr checkout <PR>` 之后的外部贡献者分支工作区——恶意 PR 可以把
#     .claude/settings.local.json track 进分支、挂一个恶意 hook，一旦本脚本在该工作区跑就等于
#     在本机执行 PR 作者的任意命令。传空字符串彻底关闭 settings 加载，消除这个面。
#   - 调用前除 unset CLAUDECODE/CLAUDE_CODE_ENTRYPOINT 外，同时 unset 一组 ANTHROPIC_*/
#     CLAUDE_AGENT_* 路由变量（API_KEY/BASE_URL/AUTH_TOKEN/DEFAULT_*_MODEL 等）：当前会话若经
#     `~/.claude/scripts/claude-wrapper.sh` 的 grok 分支启动，这些变量会注入整个进程环境、被
#     本子进程继承——不清理的话 resolve-backend.sh 判给 claude 后端，但 claude -p 子进程仍带着
#     grok 网关的 BASE_URL/API_KEY，请求根本没有脱离 grok 路径，功能名存实亡。清空后子进程只能
#     走 claude 正常的 OAuth/keychain 登录态。
#   - --tools "" 已让 claude 完全没有文件读取能力（比 grok 的 --sandbox read-only 更强——grok
#     还能靠 --cwd 读工作区文件，claude 这条路径下连"读"都不允许），故不需要传等价的
#     --cwd/sandbox 参数；全部上下文都在 prompt-file 里以文本形式喂给它。BASE_SHA/CWD 身份钉死
#     逻辑仍保留（build_full_prompt/build_incremental_prompt 共用 lib），那是为了"从哪个 git
#     仓库取 diff 文本"服务的，与 claude 进程本身能不能碰文件系统是两回事。
#   - 复核轮无法续接 session 时 Fail Fast 报错退出，不降级为新建 session（followup 常预设
#     claude 记得前几轮 finding，发给无记忆新会话必然幻觉）。
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/pr-review-common.sh"

MODEL="${CLAUDE_REVIEW_MODEL:-claude-opus-5}"
EFFORT="${CLAUDE_REVIEW_EFFORT:-medium}"
# 命令行是否显式给出 model/effort（复核轮据此决定沿用 state 还是尊重 flag；set -u 下必须先初始化）
MODEL_EXPLICIT=0
EFFORT_EXPLICIT=0
# 首轮本地 HEAD 与 PR head 不一致时默认 Fail Fast（防 session 锚在错误基线）；显式放行才降级为警告
ALLOW_DIVERGENT_BASE=0
DIFF_WARN_BYTES=200000
# untracked 体积闸（工具自动扫入的文件才受限；tracked 是用户显式纳入、不在此列）
UNTRACKED_FILE_MAX_BYTES=262144     # 单个 untracked 文件超 256KB 跳过（疑似大二进制/构建产物）
UNTRACKED_TOTAL_MAX_BYTES=1048576   # untracked 累计超 1MB 停止收集（疑似 node_modules 等未 gitignore）
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/pr-review"
# claude session 失效的 stderr 判定正则（已用真实 claude CLI 验证过确切文案：
# "No conversation found with session ID: <uuid>"）
SESSION_INVALID_RE='No conversation found'

# effort 合法值校验（首轮入口 + 复核轮 state 读回后各调一次，单一事实源）
# claude CLI 实际支持集合 low/medium/high/xhigh/max；none/minimal 是 grok 专属值，此处不合法。
check_effort() {
  case "$1" in
    low|medium|high|xhigh|max) ;;
    *) die "非法 effort: $1（合法: low/medium/high/xhigh/max）" ;;
  esac
}

# 全局产物路径，统一交给 EXIT trap 清理（函数用全局变量暴露路径，不用 $(...) 捕获，
# 防止函数内诊断/警告文本糊进路径变量）。所有中间临时文件都挂这里，确保任何 die 路径都不漏。
PROMPT_FILE=""
ERR_LOG=""
DIFF_FILE=""
INCR_DIFF_FILE=""
trap 'rm -f "${PROMPT_FILE:-}" "${ERR_LOG:-}" "${DIFF_FILE:-}" "${INCR_DIFF_FILE:-}"' EXIT

command -v claude >/dev/null 2>&1 || die "未找到 claude CLI（安装并 claude login）"
command -v gh     >/dev/null 2>&1 || die "未找到 gh CLI"
# jq 仅首轮解析 PR 元信息用，检查下沉到 build_full_prompt——复核轮纯 followup 不强制该依赖

PR=""
REPO=""
FOLLOWUP=""
SINCE=""
SESSION_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo|-R)  [[ -n "${2:-}" && "$2" != -* ]] || die "--repo 缺少值"; REPO="$2"; shift 2 ;;
    --model)    [[ -n "${2:-}" && "$2" != -* ]] || die "--model 缺少值"; MODEL="$2"; MODEL_EXPLICIT=1; shift 2 ;;
    --effort)   [[ -n "${2:-}" && "$2" != -* ]] || die "--effort 缺少值"; EFFORT="$2"; EFFORT_EXPLICIT=1; shift 2 ;;
    --followup) [[ -n "${2:-}" && "$2" != -* ]] || die "--followup 缺少值（如需 '-' 开头文案请改写措辞）"; FOLLOWUP="$2"; shift 2 ;;
    --since)    [[ -n "${2:-}" && "$2" != -* ]] || die "--since 缺少值"; SINCE="$2"; shift 2 ;;
    --session)  [[ -n "${2:-}" && "$2" != -* ]] || die "--session 缺少值"; SESSION_OVERRIDE="$2"; shift 2 ;;
    --allow-divergent-base) ALLOW_DIVERGENT_BASE=1; shift ;;
    -*) die "未知参数: $1" ;;
    *)  if [[ -z "$PR" ]]; then PR="$1"; shift; else die "多余参数: $1"; fi ;;
  esac
done

[[ -n "$PR" ]] || die "用法: claude-review.sh <PR> [--repo owner/name] [--model M] [--effort E] [--followup TEXT] [--since REF] [--session UUID]"
[[ "$PR" =~ ^[0-9]+$ ]] || die "PR 必须是数字，收到: $PR"

FOLLOWUP_MODE=0
[[ -n "$FOLLOWUP" ]] && FOLLOWUP_MODE=1

# EFFORT 校验：首轮或显式 --effort 立即校验；复核轮非显式时推迟到 state 读回后校验最终生效值，
# 避免 shell 环境里一个过期的 CLAUDE_REVIEW_EFFORT 挡住合法的 state 回放
if (( ! FOLLOWUP_MODE )) || (( EFFORT_EXPLICIT )); then
  check_effort "$EFFORT"
fi
# MODEL 同理：首轮或显式 --model 立即校验；复核轮非显式推迟到 state 读回后校验最终值
if (( ! FOLLOWUP_MODE )) || (( MODEL_EXPLICIT )); then
  check_model "$MODEL"
fi

# --since / --session 仅在复核轮有效；首轮给出属误用，直接报错而非静默忽略
if (( ! FOLLOWUP_MODE )); then
  [[ -z "$SINCE" ]] || die "--since 仅在复核轮（配合 --followup）有效"
  [[ -z "$SESSION_OVERRIDE" ]] || die "--session 仅在复核轮（配合 --followup）有效"
fi
# --allow-divergent-base 仅首轮有效；复核轮误用直接报错（与上面首轮误用对称，不静默 no-op）
if (( FOLLOWUP_MODE )) && (( ALLOW_DIVERGENT_BASE )); then
  die "--allow-divergent-base 仅在首轮有效（复核轮基线由 BASE_SHA/--since 决定）"
fi

# owner/name 解析
if [[ -n "$REPO" ]]; then
  [[ "$REPO" =~ ^[^/]+/[^/]+$ ]] || die "--repo 须为 owner/name 格式，收到: $REPO"
  OWNER="${REPO%%/*}"; NAME="${REPO##*/}"
else
  read -r OWNER NAME < <(gh repo view --json owner,name -q '"\(.owner.login) \(.name)"') \
    || die "无法确定当前仓库，请用 --repo owner/name 指定"
fi
[[ -n "$OWNER" && -n "$NAME" ]] || die "owner/name 解析失败"
# 校验 owner/name 字符集：二者会拼进 STATE_FILE 路径，禁止 '/' 等路径分隔符防目录逃逸
[[ "$OWNER" =~ ^[A-Za-z0-9._-]+$ && "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] \
  || die "owner/name 含非法字符（仅允许 字母/数字/. _ -）: $OWNER/$NAME"
REPO_FLAG=(-R "$OWNER/$NAME")

# .claude.session 后缀：与 grok 的 .session 互不覆盖，同一 PR 可各自独立跑评审 session
STATE_FILE="$STATE_DIR/${OWNER}__${NAME}__${PR}.claude.session"

# 随机 delimiter：防止 diff/描述里的文本伪造出跟固定 delimiter 相同的边界（首轮/复核轮共用）
DELIM="UNTRUSTED_$(openssl rand -hex 8 2>/dev/null || printf '%s' "$$_${RANDOM}_${RANDOM}")"

# 系统侧规则文案（走 --system-prompt，与用户数据分离，非 prompt 正文）：组装
# RULES/RULES_FOLLOWUP/RULES_SECURITY 三个全局变量（依赖上面刚生成的 $DELIM，
# 定义见 lib/pr-review-common.sh，与 grok-review.sh 共用同一份规则文案）。
build_rules

if (( FOLLOWUP_MODE )); then
  # ---------- 复核轮：--resume 续接，Fail Fast ----------
  if [[ -n "$SESSION_OVERRIDE" ]]; then
    SID="$SESSION_OVERRIDE"
  else
    SID=$(state_get SID)
  fi
  [[ -n "$SID" ]] || die "PR #${PR} 无活跃 session。请先跑一次首轮：claude-review.sh ${PR}"
  # SID 形态白名单（纵深防御：state 损坏/被改、或 --session 传入脏值时，避免脏 SID 交给 claude --resume 产生难读失败）
  [[ "$SID" =~ ^[A-Za-z0-9_-]+$ ]] || die "非法 SID（疑似 state 损坏或 --session 传入脏值）: $SID"

  # 沿用首轮 model/effort（命令行显式 flag 优先；否则读回 state 保持同 session 各轮一致；读回值先校验再采用）
  if (( ! MODEL_EXPLICIT )); then
    _s=$(state_get MODEL); [[ -n "$_s" ]] && { check_model "$_s"; MODEL="$_s"; }
  fi
  if (( ! EFFORT_EXPLICIT )); then
    _s=$(state_get EFFORT); [[ -n "$_s" ]] && { check_effort "$_s"; EFFORT="$_s"; }
  fi
  # 校验最终生效的 MODEL/EFFORT（覆盖 state 无值却 env CLAUDE_REVIEW_MODEL/CLAUDE_REVIEW_EFFORT 非法的情形）
  check_model "$MODEL"
  check_effort "$EFFORT"

  build_incremental_prompt

  ERR_LOG=$(mktemp "${TMPDIR:-/tmp}/claude-review-err.XXXXXX") || die "mktemp 失败"
  echo ">> claude 复核 PR #$PR ($OWNER/$NAME) — session=$SID model=$MODEL effort=$EFFORT" >&2

  # Strip Claude Code internal env vars to prevent recursive hook/plugin loading（复用
  # plan-review 的 claude engine 隔离手法）。同时清空 ANTHROPIC_*/CLAUDE_AGENT_* 路由变量：
  # 当前会话若经 claude-wrapper.sh 的 grok 分支启动，这些变量会注入整个进程环境、被本子进程
  # 继承——不清理的话 resolve-backend.sh 判给 claude 后端，但 claude -p 子进程仍带着 grok
  # 网关的 BASE_URL/API_KEY，请求根本没有脱离 grok 路径，功能名存实亡。清空后子进程只能走
  # claude 正常的 OAuth/keychain 登录态。stderr 直接重定向到文件（不用 2> >(tee ...) 进程替换）：
  # 评审正文走 stdout 仍直接流式，只有 claude 的 stderr 进度延后到结束才刷——换来消除 rc/tee
  # 竞态、不依赖 /dev/fd（受限 shell/沙箱也稳）。
  unset CLAUDECODE
  unset CLAUDE_CODE_ENTRYPOINT
  unset ANTHROPIC_API_KEY
  unset ANTHROPIC_BASE_URL
  unset ANTHROPIC_API_BASE_URL
  unset CLAUDE_AGENT_API_BASE_URL
  unset ANTHROPIC_AUTH_TOKEN
  unset ANTHROPIC_DEFAULT_OPUS_MODEL
  unset ANTHROPIC_DEFAULT_SONNET_MODEL
  unset ANTHROPIC_DEFAULT_HAIKU_MODEL
  unset ANTHROPIC_SMALL_FAST_MODEL
  set +e
  claude -p --model "$MODEL" --effort "$EFFORT" \
    --setting-sources "" --tools "" --disable-slash-commands \
    --system-prompt "$RULES_FOLLOWUP" \
    --resume "$SID" \
    < "$PROMPT_FILE" 2>"$ERR_LOG"
  rc=$?
  set -e
  cat "$ERR_LOG" >&2   # 把 claude 的 stderr 透传出来（ERR_LOG 已完整写完，无竞态）

  if (( rc != 0 )); then
    if grep -qE "$SESSION_INVALID_RE" "$ERR_LOG"; then
      die "PR #${PR} 的 session 已失效/丢失，上下文不可恢复——请重开首轮评审（claude-review.sh ${PR}）。"
    else
      exit "$rc"
    fi
  fi
  # 复核成功 → 刷新 mtime，防活跃 session 被 30 天 GC 误清；仅当 state 文件已存在，
  # 避免 --session 显式覆盖且无 state 文件时 touch 造出 0 字节空文件污染 state 目录
  if [[ -f "$STATE_FILE" ]]; then touch "$STATE_FILE" 2>/dev/null || true; fi
else
  # ---------- 首轮：--session-id 建会话，发全量 diff ----------
  SID=$(gen_uuid)
  [[ -n "$SID" ]] || die "生成 SID 失败"

  # BASE_SHA 与「传不传 --cwd」解耦：只要当前在 git 仓库就记首轮 HEAD 作复核默认基线（涵盖
  # fork/worktree 等 owner/name 启发式未命中但确实在正确代码上的场景，避免"commit 后 followup
  # 丢修复"）。claude 侧因 --tools "" 完全无文件访问能力，本就不传 --cwd/sandbox 类旗标——
  # CWD_TO_STORE 只服务身份钉死（决定"从哪个 git 仓库取 diff 文本"），与 claude 进程能否碰
  # 文件系统是两回事。
  CWD_TO_STORE=""
  BASE_SHA_TO_STORE=""
  TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -n "$TOPLEVEL" ]]; then
    CWD_TO_STORE="$TOPLEVEL"
    BASE_SHA_TO_STORE=$(git -C "$TOPLEVEL" rev-parse HEAD 2>/dev/null || echo "")
    # 首轮工作区非干净：复核轮 git diff BASE_SHA 会把此刻未提交改动一并算作"本轮修复"
    if [[ -n "$(git -C "$TOPLEVEL" status --porcelain 2>/dev/null)" ]]; then
      echo "警告: 首轮工作区存在未提交改动——复核轮增量将相对 BASE_SHA 累积计入这些改动（如需干净语义先 commit/stash）。" >&2
    fi
    # 首轮审的是远程 gh pr diff，基线却是本地 HEAD：若本地未 checkout 该 PR 分支，复核增量会变成
    # "整条分支相对本地 HEAD"的大 delta——省 token 目标直接反转，且 session 一旦锚在错误基线，后续每轮都中招。
    # 比对 PR headRefOid：不一致默认 Fail Fast（能确知 diverge 时才拦，取不到 head 则不阻断）；--allow-divergent-base 放行。
    PR_HEAD=$(gh pr view "$PR" "${REPO_FLAG[@]}" --json headRefOid -q '.headRefOid' 2>/dev/null || echo "")
    if [[ -z "$PR_HEAD" ]]; then
      echo "警告: 无法获取 PR #${PR} head（网络/旧 gh？），跳过基线对齐校验——请自行确认已 gh pr checkout ${PR}，否则复核增量可能相对错误基线。" >&2
    elif [[ -n "$BASE_SHA_TO_STORE" && "$PR_HEAD" != "$BASE_SHA_TO_STORE" ]]; then
      if (( ALLOW_DIVERGENT_BASE )); then
        echo "警告: 本地 HEAD ($BASE_SHA_TO_STORE) 与 PR #$PR head ($PR_HEAD) 不一致（--allow-divergent-base 已放行）——复核增量将相对本地 HEAD、可能含整条 PR 分支 delta。" >&2
      else
        die "本地 HEAD ($BASE_SHA_TO_STORE) 与 PR #$PR head ($PR_HEAD) 不一致：session 会锚在错误基线，后续复核增量将是「整条 PR 分支相对本地 HEAD」的大 delta 并污染全部复评轮。请先 gh pr checkout $PR 再跑首轮；确知要以本地 HEAD 为基线则加 --allow-divergent-base。"
      fi
    fi
  fi

  build_full_prompt   # 无文本 hunk（纯二进制/rename）会在此 exit 0，不再往下走——故覆写警告放其后，避免对不会写 state 的场景误吼

  # 无参重跑首轮会用新 SID 覆写已存在的活跃 session（旧会话记忆丢失 + 再烧一轮全量 diff token）——
  # 在多轮工作流里这是"漏写 --followup"的高成本脚枪。故 claude 调用前大字警告（build_full_prompt 已
  # 确认有内容要发、确会写 state），误触可 Ctrl-C 止损；不默认 Fail Fast：重跑求全新 session 是合法
  # 操作，警告足以区分误触与有意重开。
  if [[ -f "$STATE_FILE" ]]; then
    _old_sid=$(state_get SID)
    [[ -n "$_old_sid" ]] && echo "警告: 覆写已存在的活跃 session（旧 SID=${_old_sid} → 新 SID=${SID}），旧会话记忆将丢失。若本意是复核，请改用: claude-review.sh ${PR} --followup \"<复核指令>\"" >&2
  fi

  echo ">> claude 评审 PR #$PR ($OWNER/$NAME) — session=$SID model=$MODEL effort=$EFFORT" >&2

  # Strip Claude Code internal env vars to prevent recursive hook/plugin loading（复用
  # plan-review 的 claude engine 隔离手法）。同时清空 ANTHROPIC_*/CLAUDE_AGENT_* 路由变量：
  # 当前会话若经 claude-wrapper.sh 的 grok 分支启动，这些变量会注入整个进程环境、被本子进程
  # 继承——不清理的话 resolve-backend.sh 判给 claude 后端，但 claude -p 子进程仍带着 grok
  # 网关的 BASE_URL/API_KEY，请求根本没有脱离 grok 路径，功能名存实亡。清空后子进程只能走
  # claude 正常的 OAuth/keychain 登录态。**不加** --no-session-persistence（会导致会话不落盘、
  # --resume 无法生效，与多轮复评需求矛盾）。先调 claude，成功（set -e 未中断）后再落盘 state：
  # 首轮失败不留误导性 SID/BASE_SHA。注意：成功路径**会**无条件覆写同 PR 的既有 state（若存在
  # 活跃 session，上面已大字警告）——"不覆盖进行中会话"仅对 claude 失败路径成立。
  unset CLAUDECODE
  unset CLAUDE_CODE_ENTRYPOINT
  unset ANTHROPIC_API_KEY
  unset ANTHROPIC_BASE_URL
  unset ANTHROPIC_API_BASE_URL
  unset CLAUDE_AGENT_API_BASE_URL
  unset ANTHROPIC_AUTH_TOKEN
  unset ANTHROPIC_DEFAULT_OPUS_MODEL
  unset ANTHROPIC_DEFAULT_SONNET_MODEL
  unset ANTHROPIC_DEFAULT_HAIKU_MODEL
  unset ANTHROPIC_SMALL_FAST_MODEL
  claude -p --model "$MODEL" --effort "$EFFORT" \
    --setting-sources "" --tools "" --disable-slash-commands \
    --system-prompt "$RULES" \
    --session-id "$SID" \
    < "$PROMPT_FILE"

  state_write "$SID" "$CWD_TO_STORE" "$BASE_SHA_TO_STORE"
  echo ">> 复核轮请用: claude-review.sh $PR --followup \"<复核指令>\"" >&2
fi
