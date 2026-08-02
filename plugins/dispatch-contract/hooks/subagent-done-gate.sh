#!/usr/bin/env bash
# SubagentStop hook: enforce that a subagent's final message ends with a
# standalone %%DONE%% marker line when its dispatch prompt required one, so a
# handoff report can't be silently truncated, replaced by a "done" summary,
# or diverted into a file instead of the final message.
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
# finalized inline report; the subagent's last non-empty final-message line
# must then equal the MARK exactly (not just contain it — a trailing marker
# after unfinished prose would otherwise still pass).
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
L1=$(head -n 1 -- "$TP" 2>/dev/null)
case "$L1" in
  *fork-context-ref*) PROMPT_SRC=$(head -n 2 -- "$TP" 2>/dev/null) ;;
  *)                  PROMPT_SRC=$L1 ;;
esac
grep -qF "$MARK" <<< "$PROMPT_SRC" || exit 0

# 最终消息「末个非空行」须与 MARK 相等（不是包含），仅容忍前后空白与 CR。
# 容忍空白是因为尾随空格/CRLF 是高频且零歧义的；不容忍 markdown 修饰
# （**MARK**、`MARK`、- MARK 等仍拦），每放宽一分就多开一分带内信令的口子。
LAST_LINE=$(printf '%s' "$LAST" | grep -v '^[[:space:]]*$' | tail -1)
[[ "$LAST_LINE" =~ ^[[:space:]]*"$MARK"[[:space:]]*$ ]] && exit 0

printf '[subagent-done-gate] 最终消息末尾未检测到独立成行的 %s，说明报告没写完。请把完整报告直接输出在最终消息里（不要写进文件，也不要只写完成说明），并在末尾单独一行输出 %s——该行只能有这个标记本身，不要加粗、不要代码块或反引号、不要列表符号或标题符号、后面不要跟标点或其他文字。某一节做不到就保留该节并写明原因，不要留空。\n' "$MARK" "$MARK" >&2
printf '[subagent-done-gate] 逃生舱：export ALLOW_UNMARKED_FINAL=1\n' >&2
exit 2
