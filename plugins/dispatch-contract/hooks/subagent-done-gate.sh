#!/usr/bin/env bash
# SubagentStop hook: enforce that a subagent's final message ends with a
# standalone %%DONE%% marker line when its dispatch prompt required one, so a
# handoff report can't be silently truncated, replaced by a "done" summary,
# or diverted into a file *in place of* the final message (a file deliverable
# alongside a final-message report is fine and expected; see the
# subagent-dispatch skill's 定稿标记 section).
#
# Judgment source: the dispatch prompt itself, never the subagent's own words.
# The hook reads the transcript's first line. If that first line is a
# fork-context-ref record, the dispatch prompt lives on line 2 instead (a
# tool_use.input.prompt written by the dispatcher), so the hook reads two
# lines for that shape. For every other shape, the first line already is the
# dispatcher's prompt, and the hook reads only that line — it must not also
# read the subagent's own line 2, or the subagent could plant the MARK in its
# own first-turn reply and open its own gate.
# If the judged line(s) contain the MARK, the dispatcher asked for a
# finalized inline report, and two structural conditions must both hold.
# (1) The subagent's last non-empty final-message line equals the MARK
# exactly — not merely contains it, or a trailing marker after unfinished
# prose would still pass. (2) At least one other non-empty line is present:
# the MARK is a terminator, not the deliverable, so a message whose only
# non-blank line is the MARK carries a zero-byte report, and it is rejected
# on its own path with its own directive. (1) is necessary, never
# sufficient — do not "simplify" the second check away.
#
# MARK 刻意不含尖括号：harness 会中和"指令形状"文本里的 < >，尖括号 token 有被改写导致永久误拦的风险。
#
# Fail-open: parse errors, missing fields, no jq, unreadable transcript, prompt didn't require the marker.
# Temporary bypass: export ALLOW_UNMARKED_FINAL=1
set -u

MARK='%%DONE%%'

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

[[ "${ALLOW_UNMARKED_FINAL:-}" == "1" ]] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

STOP_ACTIVE=$(jq -r '.stop_hook_active // false' <<< "$INPUT" 2>/dev/null) || exit 0
[[ "$STOP_ACTIVE" == "true" ]] && exit 0   # 已续跑过一次 → 最多拦一次

# 区分「字段缺失/为 null」与「字段存在但只有空白」：前者无从判断，放行；后者是
# 实打实的空交付，必须落到末行判定并被拦。不能只看 $(...) 的结果——命令替换会剥掉
# 尾部换行，纯换行的最终消息会伪装成空串从这里溜走。
jq -e '.last_assistant_message != null' <<< "$INPUT" >/dev/null 2>&1 || exit 0
LAST=$(jq -r '.last_assistant_message' <<< "$INPUT" 2>/dev/null) || exit 0

TP=$(jq -r '.agent_transcript_path // empty' <<< "$INPUT" 2>/dev/null) || exit 0
[ -n "$TP" ] || exit 0
# ${HOME:-} 而非 $HOME：参数替换的替换文本无论模式是否匹配都会求值，
# set -u 下 HOME 未设置会让脚本以退出码 1 崩溃——违反"只有 0/2 两态"的契约。
TP="${TP/#\~/${HOME:-}}"
# -f 而非 -r：-r 只查权限位，指向无写端 FIFO 时 head 会永久阻塞，
# 让整个 SubagentStop 悬挂——比误拦更糟，误拦还有逃生舱，挂起没有出口。
[ -f "$TP" ] || exit 0

# 判定侧只看「派发方写的那一行」，不看子 agent 自己写的行——否则子 agent 在首轮
# 正文里提一句该标记就能给自己开闸（带内信令，与交付侧同一类错误）。
# 普通子 agent：首行 type:"user"，即派发 prompt 原文。
# fork 型子 agent：首行 type:"fork-context-ref" 不含 prompt，派发文本在第 2 行的
# assistant tool_use.input.prompt 里——那仍然是派发方的文本。
# 实测 191 份真实 transcript 只有这两种形态。不扫全文件——那会把「子 agent 读过
# 含该标记的文件」也误判成派发方要求过。
# fork 特征串刻意用宽松匹配：误命中只是退回旧的取两行行为（至多多拦一次、自愈），
# 漏命中却会让整类 fork 子 agent 静默失去保护，方向上不对称。
#
# 只取「派发方那两行」本身还不够：SubagentStart 注入的三/四条铁律落在
# attachment 记录里，今天恰好在这两行读取窗口之外——这是碰巧安全，不是结构
# 安全。dispatch-rules-inject.sh 现在会往铁律④里放 MARK 字面量，一旦 CC 未来
# 把 attachment 记录挪进这两行的窗口，就会让每一个 subagent 都被误判成「派发方
# 要求了标记」，那是灾难性误拦扩面。故显式滤掉 attachment 形态的记录：
# 失配（CC 内部字段改名）退化为现状（继续用未过滤的整行文本判断，不劣化）；
# 过度匹配（滤掉了本该保留的行）退化为该行的 MARK 判不出来 → fail-open 放行。
# 两个方向都安全，都不会新增误拦。
L1=$(head -n 1 -- "$TP" 2>/dev/null)
case "$L1" in
  *fork-context-ref*) PROMPT_SRC=$(head -n 2 -- "$TP" 2>/dev/null) ;;
  *)                  PROMPT_SRC=$L1 ;;
esac
PROMPT_SRC=$(grep -v '"type"[[:space:]]*:[[:space:]]*"attachment"' <<< "$PROMPT_SRC" 2>/dev/null)
grep -qF "$MARK" <<< "$PROMPT_SRC" || exit 0

# 最终消息「末个非空行」须与 MARK 相等（不是包含），仅容忍前后空白与 CR。
# 容忍空白是因为尾随空格/CRLF 是高频且零歧义的；不容忍 markdown 修饰
# （**MARK**、`MARK`、- MARK 等仍拦），每放宽一分就多开一分带内信令的口子。
NONBLANK=$(printf '%s' "$LAST" | grep -v '^[[:space:]]*$')
LAST_LINE=$(printf '%s' "$NONBLANK" | tail -1)
if [[ "$LAST_LINE" =~ ^[[:space:]]*"$MARK"[[:space:]]*$ ]]; then
  # 标记在场不等于报告在场。整条最终消息只剩标记这一行时交付物为零——门禁自称
  # 判「报告在场」，这一格正落在那句话里，此前却因为只看末行而放行。
  # 判据是「除标记外还有没有非空行」，不看内容、不查词表：要了标记就是要了交付物，
  # marker-only 恒为违约，不存在需要放行的正当形态。
  # 这一支不受下方 FLOOR 判据影响、不与之合并——合并会误伤「标记在场 + 短但合规
  # 的报告」（如「APPROVED. 无发现。」+ 标记，仅 30 字节）：这种 agent 完全照做了，
  # 不该被罚。两侧语义各自成立：标记在场 = agent 声明已完成，只否决字面为空的声明；
  # 标记缺席 = 只在无贵重产物可毁时才拦。
  [ "$(printf '%s\n' "$NONBLANK" | wc -l)" -gt 1 ] && exit 0
  printf '[subagent-done-gate] 最终消息只有 %s 这一行，报告是空的。标记只是结束信号，不是交付物——完整报告必须写在标记之前的同一条消息里。若任务同时要求落盘交付物，按派发约定写 .wip 并 promote，但不要把报告只写进文件。补齐报告后，仍在末尾单独一行输出 %s。\n' "$MARK" "$MARK" >&2
  printf '[subagent-done-gate] 逃生舱：export ALLOW_UNMARKED_FINAL=1\n' >&2
  exit 2
fi

# ============================================================
# 标记缺席分支：判据反转 (issue #183)
#
# SubagentStop 的 exit 2 语义是「阻止 subagent 停止」，必然强制它再写一条
# 消息；而 harness 取最后一条 assistant 消息作为回传产物。所以拦截本身就是
# 赌局——agent 只要补发一条短消息（哪怕只有标记本身），已写好的完整报告就被
# 顶掉、静默丢失。SubagentStop 没有改写最终消息的能力，这条路堵死。
#
# 全机 4761 份 subagent transcript、489 个「拦截前后」配对的实测：
#   被拦下那条 < 800B  → 拦后崩塌 5%，健康重写 74%
#   被拦下那条 ≥ 3000B → 拦后崩塌 40%，健康重写 25%
# 拦大消息才是灾难源。而契约本来要抓的东西——完成说明/元总结/空交付——
# 按大小分层抽样逐条核对过，本来就全是小消息（0–200B 全是「Sent.」「已完成，
# 无需响应」一类；500B 起才开始出现真实交付物）。
#
# 故只拦「小到不可能是产物」的消息：FLOOR 以下才有资格被拦，FLOOR 及以上一律
# 放行 + 用 systemMessage 告警（可见但不阻断）。这样续跑轮丢正文这个失败模式
# 在结构上就不存在了——被拦的那条本来就没有正文可丢。
#
# FLOOR=500 字节的依据即上面那段分层抽样结论。两个方向的误差都是良性的：
# 偏低 → 退化为无保护（不销毁产物）；偏高 → 拦到的仍是小报告，实测该区间
# 74% 健康重写、5% 崩塌，且有下方的回显兜底。DONE_GATE_BODY_FLOOR 是唯一旋钮。
#
# 字节数用 wc -c（确定性字节计数），不用 ${#X}——${#X} 在 UTF-8 下按字符数，
# 中文报告会把字节阈值算成字符阈值，FLOOR=500 字节的实测依据就对不上了。
FLOOR="${DONE_GATE_BODY_FLOOR:-500}"
# 非法覆盖值（非纯数字）退回默认——旋钮设错不该让门禁在数值比较上崩溃或
# 变成不可预期的 fail-closed。
[[ "$FLOOR" =~ ^[0-9]+$ ]] || FLOOR=500
BODY_BYTES=$(printf '%s' "$NONBLANK" | wc -c | tr -d '[:space:]')

if [ "$BODY_BYTES" -ge "$FLOOR" ]; then
  # 正文够大，判定为已有贵重产物——不拦，只告警。systemMessage 是这个 hook
  # stdout 目前唯一的用途，不会与别的输出冲突；jq 失败时 fail-open 放行。
  MSG="[subagent-done-gate] 最终消息末尾缺少独立成行的 ${MARK}，但正文已有 ${BODY_BYTES} 字节，判定为已有报告，不拦截——续跑会把这条产物顶掉，比漏标记更糟。请在下次派发前提醒该 agent 补标记。"
  jq -n --arg msg "$MSG" '{systemMessage:$msg}' 2>/dev/null || exit 0
  exit 0
fi

# 正文小于 FLOOR：小到不可能是贵重产物，回显成本天然有界（≤ FLOOR 字节），
# 拦截把重发从「凭记忆重写」降级为「照抄上一条」。
printf '[subagent-done-gate] 最终消息末尾未检测到独立成行的 %s，正文仅 %s 字节，判定为无报告可丢，予以拦截。不要只补标记——把完整报告与标记写在同一条新消息里，你上一条消息不会被读取。以下是被拦下的原文（重发时可直接复用）：\n---\n%s\n---\n若任务同时要求落盘交付物，按派发约定写 .wip 并 promote，但不要把报告只写进文件。并在末尾单独一行输出 %s——该行只能有这个标记本身，不要加粗、不要代码块或反引号、不要列表符号或标题符号、后面不要跟标点或其他文字。\n' "$MARK" "$BODY_BYTES" "$NONBLANK" "$MARK" >&2
printf '[subagent-done-gate] 逃生舱：export ALLOW_UNMARKED_FINAL=1\n' >&2
exit 2
