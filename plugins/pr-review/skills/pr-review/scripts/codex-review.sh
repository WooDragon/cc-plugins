#!/usr/bin/env bash
#
# codex-review.sh — 用本地 codex CLI（`codex exec`）评审 GitHub PR，评审结果打印到终端。
# 与 grok-review.sh / claude-review.sh 是并列的同构后端，CLI 参数形态完全一致：
#
#   首轮:   codex-review.sh <PR> [--repo owner/name] [--model M] [--effort E] [--allow-divergent-base]
#   复核轮: codex-review.sh <PR> --followup "<复核指令>" [--since <ref>] [--session <UUID>] \
#                              [--repo owner/name] [--model M] [--effort E]
#   --allow-divergent-base: 首轮本地 HEAD 与 PR head 不一致时默认 Fail Fast，此 flag 放行（降级为警告）。
#
# 设计依据（见 references/codex-review.md）——以下均为本机 codex-cli 0.147.0 实测结论，非臆造：
#   - session/thread id 捕获：`codex exec --json` 把事件以 JSONL 打到 stdout，首行恒为
#     {"type":"thread.started","thread_id":"<uuid>"}。提取表达式：
#     jq -r 'select(.type=="thread.started") | .thread_id' <json_log> | head -n1
#     （备选 `codex exec resume --last` 未采用：受 cwd 过滤影响、且不像本方案能拿到确定的
#     thread_id 落 state，多轮 session 定位不如显式 SID 可靠）。
#   - 复核轮续接用 `codex exec ... resume <SID> <PROMPT>`；session 失效的真实 stderr 文案
#     （SID 不存在/rollout 找不到）实测为：
#       "Error: thread/resume: thread/resume failed: no rollout found for thread id <uuid> (code -32600)"
#     故 SESSION_INVALID_RE 锚定 "no rollout found for thread"（比整段错误文案更抗版本漂移，
#     同时不会跟网络错误等其他失败误撞）。该错误只出现在 stderr，stdout 为空（未进入
#     turn.started 阶段），与 ERR_LOG 单独重定向的设计吻合。
#   - effort：codex exec 没有 --effort 旗标，走 `-c model_reasoning_effort=<v>`。合法集合
#     实测取自 API 400 响应原文："Supported values are: 'none', 'low', 'medium', 'high',
#     'xhigh', and 'max'."（传非法值如 minimal 会被 API 拒绝，报错里完整列出合法集合）。
#     none/low/medium/high/xhigh/max 六档均已逐一或抽样验证可用（high/max 实测跑通）。
#     注意此集合与 grok 后端的 none/minimal/low/medium/high 不同（grok 无 xhigh/max，
#     多一个 minimal），与 claude 后端的 low/medium/high/xhigh/max 也不同（codex 多一个 none）——
#     三后端各自独立校验，不可混用判据。
#   - **无 --system-prompt / --rules 等价旗标**（本机 --help 逐项核对，无此类选项）。
#     grok/claude 都能把系统侧规则文案走独立通道（--rules / --system-prompt）与用户数据
#     分离投递；codex exec 没有对应通道，本脚本退而求其次：把 RULES/RULES_FOLLOWUP 文案
#     直接拼进 prompt 正文最前面（wrap_prompt_with_rules），DELIM 包裹的不可信数据仍在其后、
#     边界不变，只是"系统指令"与"用户数据"现在共享同一个输入通道而非两个独立通道——这是
#     codex CLI 能力边界决定的、与 grok/claude 的真实差异，不是本脚本选择放弃隔离。
#   - **不传 --output-format**：codex exec 没有该旗标（不同于 grok 的 --output-format plain）。
#     本脚本改用 --json（拿 thread_id）+ -o "$OUT_FILE"（拿干净的最终回复文本，不含事件包装/
#     不含 codex 默认人类可读模式里夹带的完整 prompt 回显），成功后 `cat "$OUT_FILE"` 把评审
#     正文打到 stdout——语义上与 grok/claude"评审结果打印到终端"一致，但**不是逐字流式**：
#     codex 进程运行期间用户看不到中间过程，只有整个 turn 完成、-o 文件写出后才一次性吐出评审
#     正文（grok/claude 是边生成边流式打印）。这是使用 --json+-o 换取"可靠拿到 thread_id +
#     干净正文"的代价，已在 references/codex-review.md 记录为已知边界，不是本脚本疏漏。
#   - **不复用 unset_provider_routing_env**：该函数清理的是 Claude Code 生态专属变量
#     （ANTHROPIC_*/CLAUDE_AGENT_*/CLAUDE_CODE_MESSAGING_*/CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY），
#     服务的是"claude -p 子进程可能继承到 grok 网关路由变量"这一 claude 后端专属风险。
#     codex 凭证走独立的 CODEX_HOME，不识别、不消费这些变量，复用它属于无证据的 cargo-cult；
#     也不 unset CLAUDECODE/CLAUDE_CODE_ENTRYPOINT——那两个变量是 claude 二进制自身用来判断
#     "是否在 Claude Code 内部递归启动"的信号，codex 二进制不识别、不会据此加载任何 hook/plugin，
#     对 codex 子进程унset 它们没有实际效果，写了也只是误导性噪音。本机未发现 codex 存在等价的
#     路由变量泄露风险，故按任务要求不臆造新的清理函数。
#   - **-s read-only + --ignore-rules**：read-only 沙盒钉死 codex 只读、不可写文件/执行命令；
#     --ignore-rules 阻止加载被评审仓库（未受信 PR checkout）里的 execpolicy `.rules` 文件。
#     **不加 --ephemeral**：那会话不落盘、--resume 完全失效，与本脚本要的多轮对抗复评矛盾。
#   - **-C（工作目录）比照 grok 的 --cwd 做同名安全收紧，未照抄任务给出的"无条件传 -C"骨架**：
#     read-only 沙盒仍允许 codex 读取给定目录下的文件（不同于 claude 后端的 --tools ""——
#     那条路径下 claude 连"读"都不被允许，故 claude 后端从不需要传等价的 --cwd/-C）。既然
#     codex 有读文件能力，就该比照 grok 的做法：只有本地 checkout 精确匹配 --repo 的
#     owner/name 时才传 -C 指向该目录，避免"--repo 指向别的仓库、却把当前目录暴露给 codex
#     读"的错配面。复核轮同理，从 lib 的 build_incremental_prompt 产出的 CWD_FLAG（其元素是
#     grok 专属的 --cwd 数组）里只取路径部分（CWD_FLAG[1]）另组 -C，不改 lib、不复用其
#     --cwd token。
#   - **-c project_doc_max_bytes=0 + --strict-config**：codex CLI 会把被评审仓库根目录的
#     AGENTS.md 自动加载进指令层（不是普通文件内容，是「项目指令」抬升地位）——PR 作者能在
#     自己仓库里塞一份 AGENTS.md 借此劫持评审结论，且 -s read-only 只挡写入/执行，挡不住这条
#     纯读取的提示词注入面。本机 codex-cli 0.147.0 实测坐实（同一 prompt，AGENTS.md 里写
#     "internal codename is ZEBRA47"）：默认（无旗标）codex 回答 ZEBRA47（自动加载生效）；
#     加 -c project_doc_max_bytes=0 后回答 UNKNOWN（自动加载被关掉）。故两条路径都必须传
#     project_doc_max_bytes=0。同时加 --strict-config：已实测该旗标会让未知配置键报错退出
#     （`-c totally_bogus_key_xyz=1` → exit 1），而 project_doc_max_bytes 被其接受（证明键存在）；
#     加上它是为了防未来 codex 版本改名/删掉这个键时，本脚本的 -c 静默变成 no-op、安全旗标
#     形同虚设却不报错——宁可 fail loud（脚本报错退出，逼人发现并修复），不要 fail silent（自动
#     加载悄悄复活，评审在不知情中重新暴露给注入）。代价见下条已知边界。
#   - **残余边界（--strict-config 消除不了）**：评审任务本身就要求 codex 读被评审仓库的 diff
#     与文件内容，这些由 PR 作者控制，仍会进入模型上下文——区别是它们现在是普通文件内容，不再
#     享有 AGENTS.md 那种「项目指令」的抬升地位。这是评审这件事本身的固有面，不是本旗标遗漏。
#     完整已消除/取舍/残余三层记录见 references/codex-review.md「已知边界」节。
#   - 复核轮无法续接 session 时 Fail Fast 报错退出，不降级为新建 session（followup 常预设
#     codex 记得前几轮 finding，发给无记忆新会话必然幻觉）——与 grok/claude 两后端一致。
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/pr-review-common.sh"

MODEL="${CODEX_REVIEW_MODEL:-gpt-5.6-luna}"
EFFORT="${CODEX_REVIEW_EFFORT:-medium}"
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
# codex session 失效的 stderr 判定正则（已用本机 codex-cli 0.147.0 实测验证过确切文案，见文件头注释）
SESSION_INVALID_RE='no rollout found for thread'

# effort 合法值校验（首轮入口 + 复核轮 state 读回后各调一次，单一事实源）
# codex CLI 实际支持集合 none/low/medium/high/xhigh/max（实测取自 API 400 响应原文，见文件头注释）。
check_effort() {
  case "$1" in
    none|low|medium|high|xhigh|max) ;;
    *) die "非法 effort: $1（合法: none/low/medium/high/xhigh/max）" ;;
  esac
}

# 全局产物路径，统一交给 EXIT trap 清理（函数用全局变量暴露路径，不用 $(...) 捕获，
# 防止函数内诊断/警告文本糊进路径变量）。所有中间临时文件都挂这里，确保任何 die 路径都不漏。
PROMPT_FILE=""
ERR_LOG=""
DIFF_FILE=""
INCR_DIFF_FILE=""
JSON_LOG=""
OUT_FILE=""
trap 'rm -f "${PROMPT_FILE:-}" "${ERR_LOG:-}" "${DIFF_FILE:-}" "${INCR_DIFF_FILE:-}" "${JSON_LOG:-}" "${OUT_FILE:-}"' EXIT

command -v codex >/dev/null 2>&1 || die "未找到 codex CLI（安装并 codex login）"
command -v gh    >/dev/null 2>&1 || die "未找到 gh CLI"
# jq 首轮解析 PR 元信息（lib build_full_prompt）与提取 thread_id 都需要，检查下沉到
# build_full_prompt——复核轮纯 followup 不强制该依赖（复核轮自身的 thread_id 提取不涉及，
# 因为 SID 直接从 state/--session 读回，不需要再解析一次 --json 输出）。

# 把系统侧规则文案（$1）拼进 PROMPT_FILE 正文最前面：codex exec 没有 --system-prompt/--rules
# 等价旗标（见文件头注释），只能与用户数据共享同一个输入通道。DELIM 包裹的不可信数据边界不变。
wrap_prompt_with_rules() {
  local rules="$1" wrapped
  wrapped=$(mktemp "${TMPDIR:-/tmp}/codex-review-wrapped.XXXXXX") || die "mktemp 失败"
  { printf '%s\n\n' "$rules"; cat "$PROMPT_FILE"; } > "$wrapped"
  rm -f "$PROMPT_FILE"
  PROMPT_FILE="$wrapped"
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

[[ -n "$PR" ]] || die "用法: codex-review.sh <PR> [--repo owner/name] [--model M] [--effort E] [--followup TEXT] [--since REF] [--session UUID]"
[[ "$PR" =~ ^[0-9]+$ ]] || die "PR 必须是数字，收到: $PR"

FOLLOWUP_MODE=0
[[ -n "$FOLLOWUP" ]] && FOLLOWUP_MODE=1

# EFFORT 校验：首轮或显式 --effort 立即校验；复核轮非显式时推迟到 state 读回后校验最终生效值，
# 避免 shell 环境里一个过期的 CODEX_REVIEW_EFFORT 挡住合法的 state 回放
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

# .codex.session 后缀：与 grok 的 .session、claude 的 .claude.session 互不覆盖，
# 同一 PR 可各自独立跑评审 session（state_gc 的 *.session glob 已覆盖，lib 不用改）。
STATE_FILE="$STATE_DIR/${OWNER}__${NAME}__${PR}.codex.session"

# 随机 delimiter：防止 diff/描述里的文本伪造出跟固定 delimiter 相同的边界（首轮/复核轮共用）
DELIM="UNTRUSTED_$(openssl rand -hex 8 2>/dev/null || printf '%s' "$$_${RANDOM}_${RANDOM}")"

# 系统侧规则文案：组装 RULES/RULES_FOLLOWUP/RULES_SECURITY 三个全局变量（依赖上面刚生成的
# $DELIM，定义见 lib/pr-review-common.sh，与 grok/claude 共用同一份规则文案原文）。codex 没有
# 独立通道投递，稍后经 wrap_prompt_with_rules 拼进 prompt 正文（见文件头注释）。
build_rules

if (( FOLLOWUP_MODE )); then
  # ---------- 复核轮：resume 续接，Fail Fast ----------
  if [[ -n "$SESSION_OVERRIDE" ]]; then
    SID="$SESSION_OVERRIDE"
  else
    SID=$(state_get SID)
  fi
  [[ -n "$SID" ]] || die "PR #${PR} 无活跃 session。请先跑一次首轮：codex-review.sh ${PR}"
  # SID 形态白名单（纵深防御：state 损坏/被改、或 --session 传入脏值时，避免脏 SID 交给
  # codex resume 产生难读失败）
  [[ "$SID" =~ ^[A-Za-z0-9_-]+$ ]] || die "非法 SID（疑似 state 损坏或 --session 传入脏值）: $SID"

  # 沿用首轮 model/effort（命令行显式 flag 优先；否则读回 state 保持同 session 各轮一致；读回值先校验再采用）
  if (( ! MODEL_EXPLICIT )); then
    _s=$(state_get MODEL); [[ -n "$_s" ]] && { check_model "$_s"; MODEL="$_s"; }
  fi
  if (( ! EFFORT_EXPLICIT )); then
    _s=$(state_get EFFORT); [[ -n "$_s" ]] && { check_effort "$_s"; EFFORT="$_s"; }
  fi
  # 校验最终生效的 MODEL/EFFORT（覆盖 state 无值却 env CODEX_REVIEW_MODEL/CODEX_REVIEW_EFFORT 非法的情形）
  check_model "$MODEL"
  check_effort "$EFFORT"

  build_incremental_prompt
  wrap_prompt_with_rules "$RULES_FOLLOWUP"

  # 从 lib 产出的 CWD_FLAG（grok 专属 --cwd 数组）里只取路径部分，另组 codex 的 -C（不改 lib）。
  CODEX_CWD=()
  if (( ${#CWD_FLAG[@]} == 2 )); then
    CODEX_CWD=(-C "${CWD_FLAG[1]}")
  fi

  ERR_LOG=$(mktemp "${TMPDIR:-/tmp}/codex-review-err.XXXXXX") || die "mktemp 失败"
  JSON_LOG=$(mktemp "${TMPDIR:-/tmp}/codex-review-json.XXXXXX") || die "mktemp 失败"
  OUT_FILE=$(mktemp "${TMPDIR:-/tmp}/codex-review-out.XXXXXX") || die "mktemp 失败"
  echo ">> codex 复核 PR #$PR ($OWNER/$NAME) — session=$SID model=$MODEL effort=$EFFORT" >&2

  # stdout（--json 事件流）与 stderr 分别重定向到独立文件：stdout 用于诊断失败路径（本轮
  # 实际展示给用户的评审正文改从 -o "$OUT_FILE" 取，见下方 cat），stderr 用于会话失效判定
  # （SESSION_INVALID_RE 只出现在 stderr，见文件头注释实测记录）。
  set +e
  codex exec -m "$MODEL" -c model_reasoning_effort="$EFFORT" \
    -c project_doc_max_bytes=0 --strict-config \
    -s read-only "${CODEX_CWD[@]}" --ignore-rules --color never \
    --json -o "$OUT_FILE" \
    resume "$SID" - < "$PROMPT_FILE" \
    >"$JSON_LOG" 2>"$ERR_LOG"
  rc=$?
  set -e
  cat "$ERR_LOG" >&2   # 把 codex 的 stderr 透传出来（ERR_LOG 已完整写完，无竞态）

  if (( rc != 0 )); then
    if grep -qE "$SESSION_INVALID_RE" "$ERR_LOG"; then
      die "PR #${PR} 的 session 已失效/丢失，上下文不可恢复——请重开首轮评审（codex-review.sh ${PR}）。"
    else
      exit "$rc"
    fi
  fi
  cat "$OUT_FILE"   # 评审正文（-o 捕获的最终回复），打印到 stdout
  # 复核成功 → 刷新 mtime，防活跃 session 被 30 天 GC 误清；仅当 state 文件已存在，
  # 避免 --session 显式覆盖且无 state 文件时 touch 造出 0 字节空文件污染 state 目录
  if [[ -f "$STATE_FILE" ]]; then touch "$STATE_FILE" 2>/dev/null || true; fi
else
  # ---------- 首轮：建会话，发全量 diff ----------
  # BASE_SHA 与「传不传 -C」解耦：只要当前在 git 仓库就记首轮 HEAD 作复核默认基线（涵盖
  # fork/worktree 等 owner/name 启发式未命中但确实在正确代码上的场景，避免"commit 后 followup
  # 丢修复"）。
  CODEX_CWD=()
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
      echo "警告: 无法获取 PR #${PR} head（网络/旧 gh？），跳过基线对齐校验——请自行确认已 gh pr checkout ${PR}，否则复核增量可能相对错误基线。" >&2
    elif [[ -n "$BASE_SHA_TO_STORE" && "$PR_HEAD" != "$BASE_SHA_TO_STORE" ]]; then
      if (( ALLOW_DIVERGENT_BASE )); then
        echo "警告: 本地 HEAD ($BASE_SHA_TO_STORE) 与 PR #$PR head ($PR_HEAD) 不一致（--allow-divergent-base 已放行）——复核增量将相对本地 HEAD、可能含整条 PR 分支 delta。" >&2
      else
        die "本地 HEAD ($BASE_SHA_TO_STORE) 与 PR #$PR head ($PR_HEAD) 不一致：session 会锚在错误基线，后续复核增量将是「整条 PR 分支相对本地 HEAD」的大 delta 并污染全部复评轮。请先 gh pr checkout $PR 再跑首轮；确知要以本地 HEAD 为基线则加 --allow-divergent-base。"
      fi
    fi
    # -C 传给 codex 仍按 owner/name 精确匹配（read-only 沙盒下 codex 仍可读取目录内文件，
    # 比照 grok --cwd 的收紧口径，见文件头注释；claude 后端不需要这层是因为 --tools "" 下
    # 它连读都不允许）；身份钉用的 CWD_TO_STORE 已在上面无条件记录，两职解耦。
    read -r L_OWNER L_NAME < <(gh repo view --json owner,name -q '"\(.owner.login) \(.name)"' 2>/dev/null) || true
    if [[ "${L_OWNER:-}" == "$OWNER" && "${L_NAME:-}" == "$NAME" ]]; then
      CODEX_CWD=(-C "$TOPLEVEL")
    fi
  fi

  build_full_prompt   # 无文本 hunk（纯二进制/rename）会在此 exit 0，不再往下走——故覆写警告放其后，避免对不会写 state 的场景误吼
  wrap_prompt_with_rules "$RULES"

  # 无参重跑首轮会建全新 session（旧会话记忆丢失 + 再烧一轮全量 diff token）——在多轮工作流里
  # 这是"漏写 --followup"的高成本脚枪。故 codex 调用前大字警告（build_full_prompt 已确认有
  # 内容要发、确会写 state），误触可 Ctrl-C 止损；不默认 Fail Fast：重跑求全新 session 是合法
  # 操作，警告足以区分误触与有意重开。
  if [[ -f "$STATE_FILE" ]]; then
    _old_sid=$(state_get SID)
    [[ -n "$_old_sid" ]] && echo "警告: 覆写已存在的活跃 session（旧 SID=${_old_sid} → 新会话），旧会话记忆将丢失。若本意是复核，请改用: codex-review.sh ${PR} --followup \"<复核指令>\"" >&2
  fi

  echo ">> codex 评审 PR #$PR ($OWNER/$NAME) — model=$MODEL effort=$EFFORT" >&2

  ERR_LOG=$(mktemp "${TMPDIR:-/tmp}/codex-review-err.XXXXXX") || die "mktemp 失败"
  JSON_LOG=$(mktemp "${TMPDIR:-/tmp}/codex-review-json.XXXXXX") || die "mktemp 失败"
  OUT_FILE=$(mktemp "${TMPDIR:-/tmp}/codex-review-out.XXXXXX") || die "mktemp 失败"

  # 先调 codex，成功（rc=0）后再落盘 state：首轮失败不留误导性 SID/BASE_SHA。
  set +e
  codex exec -m "$MODEL" -c model_reasoning_effort="$EFFORT" \
    -c project_doc_max_bytes=0 --strict-config \
    -s read-only "${CODEX_CWD[@]}" --ignore-rules --color never \
    --json -o "$OUT_FILE" \
    - < "$PROMPT_FILE" \
    >"$JSON_LOG" 2>"$ERR_LOG"
  rc=$?
  set -e
  cat "$ERR_LOG" >&2

  if (( rc != 0 )); then
    exit "$rc"
  fi

  SID=$(jq -r 'select(.type=="thread.started") | .thread_id' "$JSON_LOG" 2>/dev/null | head -n1)
  [[ -n "$SID" ]] || die "codex --json 输出未捕获到 thread_id（疑似 codex CLI 契约变更，需重新实测 references/codex-review.md 记录的三处 CLI 形态）"

  cat "$OUT_FILE"   # 评审正文（-o 捕获的最终回复），打印到 stdout

  state_write "$SID" "$CWD_TO_STORE" "$BASE_SHA_TO_STORE"
  echo ">> 复核轮请用: codex-review.sh $PR --followup \"<复核指令>\"" >&2
fi
