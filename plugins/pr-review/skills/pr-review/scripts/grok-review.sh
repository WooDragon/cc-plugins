#!/usr/bin/env bash
#
# grok-review.sh — 用本地 grok CLI 评审 GitHub PR，评审结果打印到终端。
#
# 用法:
#   首轮:   grok-review.sh <PR> [--repo owner/name] [--model M] [--effort E] [--allow-divergent-base]
#   复核轮: grok-review.sh <PR> --followup "<复核指令>" [--since <ref>] [--session <UUID>] \
#                            [--repo owner/name] [--model M] [--effort E]
#   --allow-divergent-base: 首轮本地 HEAD 与 PR head 不一致时默认 Fail Fast，此 flag 放行（降级为警告）。
#
# 设计依据（见 references/grok-review.md）:
#   - 首轮 grok -s <UUID> 建会话、发全量 PR diff；SID 落盘到 session 状态文件。
#   - 复核轮 grok -r <UUID> 续接同一会话，只发 followup 文本 + 本轮增量 diff（不重发首轮全量）。
#   - session 状态文件：${XDG_STATE_HOME:-$HOME/.local/state}/pr-review/<owner>__<name>__<PR>.session
#   - 用 --prompt-file 传 prompt+diff，规避 macOS ARG_MAX（大 diff 塞命令行会崩）。
#   - --sandbox read-only：grok 只读、不改文件。
#   - --cwd 首轮仅当本地在目标 PR 对应仓库时传入（owner/name 精确匹配）；复核轮动态取当前
#     git toplevel（与增量 diff 同源），不在合法 git 仓库时降级用 state 里的历史 CWD。
#   - 无 @@ 文本 hunk（纯二进制/rename/mode 改动）直接跳过，不调 grok（仅首轮适用）。
#   - 复核轮无法续接 session 时 Fail Fast 报错退出，不降级为新建 session
#     （followup 常预设 grok 记得前几轮 finding，发给无记忆新会话必然幻觉）。
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/pr-review-common.sh"

MODEL="${GROK_MODEL:-grok-4.6}"
EFFORT="${GROK_EFFORT:-high}"
ENV_EFFORT="${GROK_EFFORT:-}"
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
# grok session 失效的 stderr 判定正则（宽松，防 grok 版本漂移；已用真实 grok 0.2.93 验证过确切文案：
# "Error: Failed to restore session from remote: fetching session record: session get failed: 404 Not Found"）
SESSION_INVALID_RE='[Ff]ailed to restore session|session get failed'

# effort 合法值校验（首轮入口 + 复核轮 state 读回后各调一次，单一事实源）
check_effort() {
  case "$1" in
    none|minimal|low|medium|high) ;;
    *) die "非法 effort: $1（合法: none/minimal/low/medium/high）" ;;
  esac
}

# 老版 xhigh 只允许从持久 state 迁移；新的 CLI/环境输入一律拒绝。
is_legacy_xhigh() {
  [[ "$1" == "xhigh" ]]
}

# 全局产物路径，统一交给 EXIT trap 清理（函数用全局变量暴露路径，不用 $(...) 捕获，
# 防止函数内诊断/警告文本糊进路径变量）。所有中间临时文件都挂这里，确保任何 die 路径都不漏。
PROMPT_FILE=""
ERR_LOG=""
DIFF_FILE=""
INCR_DIFF_FILE=""
trap 'rm -f "${PROMPT_FILE:-}" "${ERR_LOG:-}" "${DIFF_FILE:-}" "${INCR_DIFF_FILE:-}"' EXIT

command -v grok >/dev/null 2>&1 || die "未找到 grok CLI（安装并 grok login）"
command -v gh   >/dev/null 2>&1 || die "未找到 gh CLI"
# jq 仅首轮解析 PR 元信息用，检查下沉到 build_full_prompt——复核轮纯 followup 不强制该依赖

# 将旧 state 的 EFFORT=xhigh 原子迁到 high，同时逐行保留 SID 和其余字段。
migrate_legacy_effort() {
  local sw_tmp line
  [[ -f "$STATE_FILE" ]] || return 0
  sw_tmp=$(mktemp "$STATE_DIR/.tmp.XXXXXX") || die "mktemp 失败"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == EFFORT=xhigh ]]; then
      printf 'EFFORT=high\n'
    else
      printf '%s\n' "$line"
    fi
  done < "$STATE_FILE" > "$sw_tmp"
  chmod 600 "$sw_tmp"
  mv -f "$sw_tmp" "$STATE_FILE"
  echo "警告: 已将旧 session 的 EFFORT=xhigh 迁移为 high。" >&2
}

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

[[ -n "$PR" ]] || die "用法: grok-review.sh <PR> [--repo owner/name] [--model M] [--effort E] [--followup TEXT] [--since REF] [--session UUID]"
[[ "$PR" =~ ^[0-9]+$ ]] || die "PR 必须是数字，收到: $PR"

FOLLOWUP_MODE=0
[[ -n "$FOLLOWUP" ]] && FOLLOWUP_MODE=1

# EFFORT 校验：首轮或显式 --effort 立即校验；复核轮非显式时推迟到 state 读回后校验最终生效值，
# 避免 shell 环境里一个过期的 GROK_EFFORT 挡住合法的 state 回放
if (( ! FOLLOWUP_MODE )) || (( EFFORT_EXPLICIT )); then
  check_effort "$EFFORT"
fi
# 环境变量也是新输入；xhigh 即使复核轮会优先读 state 也必须在调用 grok 前拒绝。
# 其他旧环境脏值仍不可挡住合法 state 回放，维持既有兼容行为。
if (( FOLLOWUP_MODE )) && (( ! EFFORT_EXPLICIT )) && is_legacy_xhigh "$ENV_EFFORT"; then
  die "非法 effort: xhigh（合法: none/minimal/low/medium/high）"
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

STATE_FILE="$STATE_DIR/${OWNER}__${NAME}__${PR}.session"

# 随机 delimiter：防止 diff/描述里的文本伪造出跟固定 delimiter 相同的边界（首轮/复核轮共用）
DELIM="UNTRUSTED_$(openssl rand -hex 8 2>/dev/null || printf '%s' "$$_${RANDOM}_${RANDOM}")"

# 系统侧规则文案（走 --rules，与用户数据分离，非 prompt 正文）：组装 RULES/RULES_FOLLOWUP/RULES_SECURITY
# 三个全局变量（依赖上面刚生成的 $DELIM，定义见 lib/pr-review-common.sh）。
build_rules

if (( FOLLOWUP_MODE )); then
  # ---------- 复核轮：-r 续接，Fail Fast ----------
  if [[ -n "$SESSION_OVERRIDE" ]]; then
    SID="$SESSION_OVERRIDE"
  else
    SID=$(state_get SID)
  fi
  [[ -n "$SID" ]] || die "PR #${PR} 无活跃 session。请先跑一次首轮：grok-review.sh ${PR}"
  # SID 形态白名单（纵深防御：state 损坏/被改、或 --session 传入脏值时，避免脏 SID 交给 grok -r 产生难读失败）
  [[ "$SID" =~ ^[A-Za-z0-9_-]+$ ]] || die "非法 SID（疑似 state 损坏或 --session 传入脏值）: $SID"

  # 沿用首轮 model/effort（命令行显式 flag 优先；否则读回 state 保持同 session 各轮一致；读回值先校验再采用）
  if (( ! MODEL_EXPLICIT )); then
    _s=$(state_get MODEL); [[ -n "$_s" ]] && { check_model "$_s"; MODEL="$_s"; }
  fi
  _s=$(state_get EFFORT)
  if is_legacy_xhigh "$_s"; then
    # 旧 state 是唯一允许出现 xhigh 的来源：保留其余 state 字段并在调用 grok 前完成迁移。
    migrate_legacy_effort
    _s=high
  fi
  if (( ! EFFORT_EXPLICIT )) && [[ -n "$_s" ]]; then
    check_effort "$_s"
    EFFORT="$_s"
  fi
  # 校验最终生效的 MODEL/EFFORT（覆盖 state 无值却 env GROK_MODEL/GROK_EFFORT 非法的情形）
  check_model "$MODEL"
  check_effort "$EFFORT"

  build_incremental_prompt

  ERR_LOG=$(mktemp "${TMPDIR:-/tmp}/grok-review-err.XXXXXX") || die "mktemp 失败"
  echo ">> grok 复核 PR #$PR ($OWNER/$NAME) — session=$SID model=$MODEL effort=$EFFORT" >&2

  # stderr 直接重定向到文件（不用 2> >(tee ...) 进程替换）：评审正文走 stdout 仍直接流式，
  # 只有 grok 的 stderr 进度延后到结束才刷——换来消除 rc/tee 竞态、不依赖 /dev/fd（受限 shell/沙箱也稳）。
  set +e
  grok --rules "$RULES_FOLLOWUP" --prompt-file "$PROMPT_FILE" -m "$MODEL" --effort "$EFFORT" \
    --sandbox read-only --output-format plain -r "$SID" \
    ${CWD_FLAG[@]+"${CWD_FLAG[@]}"} \
    2>"$ERR_LOG"
  rc=$?
  set -e
  cat "$ERR_LOG" >&2   # 把 grok 的 stderr 透传出来（ERR_LOG 已完整写完，无竞态）

  if (( rc != 0 )); then
    if grep -qE "$SESSION_INVALID_RE" "$ERR_LOG"; then
      die "PR #${PR} 的 session 已失效/丢失，上下文不可恢复——请重开首轮评审（grok-review.sh ${PR}）。"
    else
      exit "$rc"
    fi
  fi
  # 复核成功 → 刷新 mtime，防活跃 session 被 30 天 GC 误清；仅当 state 文件已存在，
  # 避免 --session 显式覆盖且无 state 文件时 touch 造出 0 字节空文件污染 state 目录
  if [[ -f "$STATE_FILE" ]]; then touch "$STATE_FILE" 2>/dev/null || true; fi
else
  # ---------- 首轮：-s 建会话，发全量 diff ----------
  SID=$(gen_uuid)
  [[ -n "$SID" ]] || die "生成 SID 失败"

  # BASE_SHA 与 --cwd 解耦：只要当前在 git 仓库就记首轮 HEAD 作复核默认基线（涵盖 fork/worktree
  # 等 owner/name 启发式未命中但确实在正确代码上的场景，避免"commit 后 followup 丢修复"）。
  # CWD/--cwd 仍按 owner/name 精确匹配——grok 自读整棵文件树不可控，严格匹配防幻觉。
  CWD_FLAG=()
  CWD_TO_STORE=""
  BASE_SHA_TO_STORE=""
  TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -n "$TOPLEVEL" ]]; then
    # 身份钉：只要在 git 仓就记录首轮工作区（与 owner/name 匹配解耦），复核轮据此比对——
    # 否则 fork/worktree（owner 启发式未命中）场景身份钉短路，又会重开"对错误代码续 session"的洞。
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
      # 取不到 PR head（网络抖动/旧 gh/字段空）：无法比对基线是否对齐。此处 fail-open（不阻断首轮），
      # 但必须告警——否则错基线仍可能静默落盘，主护栏被无声跳过。
      echo "警告: 无法获取 PR #${PR} head（网络/旧 gh？），跳过基线对齐校验——请自行确认已 gh pr checkout ${PR}，否则复核增量可能相对错误基线。" >&2
    elif [[ -n "$BASE_SHA_TO_STORE" && "$PR_HEAD" != "$BASE_SHA_TO_STORE" ]]; then
      if (( ALLOW_DIVERGENT_BASE )); then
        echo "警告: 本地 HEAD ($BASE_SHA_TO_STORE) 与 PR #$PR head ($PR_HEAD) 不一致（--allow-divergent-base 已放行）——复核增量将相对本地 HEAD、可能含整条 PR 分支 delta。" >&2
      else
        die "本地 HEAD ($BASE_SHA_TO_STORE) 与 PR #$PR head ($PR_HEAD) 不一致：session 会锚在错误基线，后续复核增量将是「整条 PR 分支相对本地 HEAD」的大 delta 并污染全部复评轮。请先 gh pr checkout $PR 再跑首轮；确知要以本地 HEAD 为基线则加 --allow-divergent-base。"
      fi
    fi
    # --cwd 传给 grok 仍按 owner/name 精确匹配（grok 自读整棵文件树不可控，严格匹配防幻觉）；
    # 身份钉用的 CWD_TO_STORE 已在上面无条件记录，两职解耦。
    read -r L_OWNER L_NAME < <(gh repo view --json owner,name -q '"\(.owner.login) \(.name)"' 2>/dev/null) || true
    if [[ "${L_OWNER:-}" == "$OWNER" && "${L_NAME:-}" == "$NAME" ]]; then
      CWD_FLAG=(--cwd "$TOPLEVEL")
    fi
  fi

  build_full_prompt   # 无文本 hunk（纯二进制/rename）会在此 exit 0，不再往下走——故覆写警告放其后，避免对不会写 state 的场景误吼

  # 无参重跑首轮会用新 SID 覆写已存在的活跃 session（旧会话记忆丢失 + 再烧一轮全量 diff token）——
  # 在多轮工作流里这是"漏写 --followup"的高成本脚枪。故 grok 调用前大字警告（build_full_prompt 已确认有内容要发、
  # 确会写 state），误触可 Ctrl-C 止损；不默认 Fail Fast：重跑求全新 session 是合法操作，警告足以区分误触与有意重开。
  if [[ -f "$STATE_FILE" ]]; then
    _old_sid=$(state_get SID)
    [[ -n "$_old_sid" ]] && echo "警告: 覆写已存在的活跃 session（旧 SID=${_old_sid} → 新 SID=${SID}），旧会话记忆将丢失。若本意是复核，请改用: grok-review.sh ${PR} --followup \"<复核指令>\"" >&2
  fi

  echo ">> grok 评审 PR #$PR ($OWNER/$NAME) — session=$SID model=$MODEL effort=$EFFORT" >&2

  # 先调 grok，成功（set -e 未中断）后再落盘 state：首轮失败不留误导性 SID/BASE_SHA。
  # 注意：成功路径**会**无条件覆写同 PR 的既有 state（若存在活跃 session，上面已大字警告）——
  # "不覆盖进行中会话"仅对 grok 失败路径成立（失败不落盘）。
  grok --rules "$RULES" --prompt-file "$PROMPT_FILE" -m "$MODEL" --effort "$EFFORT" \
    --sandbox read-only --output-format plain -s "$SID" \
    ${CWD_FLAG[@]+"${CWD_FLAG[@]}"}

  state_write "$SID" "$CWD_TO_STORE" "$BASE_SHA_TO_STORE"
  echo ">> 复核轮请用: grok-review.sh $PR --followup \"<复核指令>\"" >&2
fi
