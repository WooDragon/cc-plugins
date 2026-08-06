#!/usr/bin/env bash
# PreToolUse hook (matcher: Agent, Task): block ad-hoc dispatch calls whose
# subagent_type/model cannot deliver what the prompt itself asks for.
#
# Two capability-need signals (EXEC, WRITE) and two read-only-declaration
# signals (RO, NEG) are extracted from the prompt text. They combine into one
# derived predicate:
#
#   NEEDS_CAP = (EXEC || WRITE) && !RO && !NEG
#
# ...meaning "this task asks for something beyond read-only, and nothing in
# the same prompt declares the task read-only after all". Three independent
# judgments fire off that signal set:
#
#   A (originally migrated verbatim from pre-dispatch-readonly-guard.sh;
#      condition WIDENED from !EXEC to !EXEC && !WRITE_A — see "A's exemption"
#      below for why the verbatim condition stopped holding; WRITE_A is a
#      NEG-scrubbed variant of WRITE, not the raw WRITE signal — see
#      WRITE_HIT_A's own comment near its computation for why the raw
#      signal is not safe to reuse here):
#        !EXEC && !WRITE_A && (RO || NEG) && TYPE in {general-purpose, claude}
#        -> read-only declaration sent to a full-privilege agent; Explore's
#           Edit/Write/NotebookEdit are physically disabled, so re-dispatch
#           there cannot exceed scope even if the declaration is wrong.
#
#      A's exemption (why !EXEC alone is no longer correct): the original
#      pre-dispatch-readonly-guard.sh had no WRITE signal, so !EXEC meant
#      "this task needs nothing beyond read-only" in that world. Once WRITE
#      was introduced, a prompt like "只读查看现有实现，然后修复 main.py" hits
#      !EXEC (true, no exec-intent phrase) AND RO (true, "只读查看") AND WRITE
#      (true, "修复 main.py") at the same time. Under the old !EXEC-only
#      condition, A fired and told the caller to re-dispatch to Explore — but
#      Explore's Edit/Write is physically disabled, so the re-dispatch cannot
#      do what the prompt asks. That is a dead end the gate manufactured,
#      not a legitimate rejection (see issue's Critical finding #1). Adding
#      !WRITE closes it: a prompt carrying write intent is no longer routed
#      toward an agent that cannot write, regardless of what RO/NEG also say
#      in the same prompt.
#
#   B (new): NEEDS_CAP && TYPE in {explore, plan}
#        -> this task needs write/exec capability, but Explore/Plan have
#           Edit/Write/NotebookEdit physically disabled and Bash limited to a
#           read-only whitelist. The dispatch would dead-end after burning a
#           full round trip. Re-dispatch to general-purpose/dev.
#
#      B's accepted miss (NOT the same gap as A's old dead end above): mixed
#      RO+WRITE prompts dispatched directly to Explore (e.g. "调研根因并修复"
#      sent straight to subagent_type=explore) still pass, because NEEDS_CAP
#      folds to 0 whenever RO_HIT is 1 (see NEEDS_CAP's own comment below).
#      This is a real under-block and it is deliberately kept — tightening
#      NEEDS_CAP to ignore RO for mixed prompts would flood genuine read-only
#      research dispatches with false positives. The reason this is safe to
#      leave as B's problem rather than promoted to a fix: it is a same-shape
#      miss that existed before this patch too (today's behavior for such
#      prompts is already "pass"), so leaving it is a no-op, not a regression.
#      It must not be confused with A's now-fixed dead end: A's problem was
#      that the gate ACTIVELY REJECTED and then pointed the caller at an
#      agent that physically cannot comply — a self-inflicted trap with no
#      good exit. B's miss is merely PASSIVE under-coverage — the dispatch
#      goes through unexamined, which is exactly today's baseline, not a
#      regression this patch introduces or a trap this patch built.
#
#   C (new): NEEDS_CAP && model contains "haiku"
#        -> this task needs write/exec capability, which in practice means
#           interpreting run/test/build output well enough to decide what to
#           do next — a judgment-forming action the haiku tier is excluded
#           from by the daily model-tiering rubric (取数活 vs 落地活). Model
#           substring match, not exact match: real values look like
#           "claude-haiku-4-5-20251001", never the bare word.
#
# B and C are independent: a dispatch can hit both at once (Explore + haiku
# asked to fix code), and both rejection messages are printed before the
# single trailing `exit 2` — a caller fixing only one would still get bounced
# by the other on re-dispatch otherwise.
#
# subagent_type default: an ABSENT field means "general-purpose" (the
# platform's own fallback), not "treat as missing" — same rule
# pre-dispatch-readonly-guard.sh already applies, kept for A's parity.
#
# Escape hatch: ALLOW_DISPATCH_CAPABILITY_MISMATCH=1 in the `env` block of
# ~/.claude/settings.json (a plain Bash `export` does not reach this hook's
# process — it is spawned by the CC main process, not by the calling shell).
# One hook, one switch: the old pre-dispatch-readonly-guard.sh switch name
# ALLOW_READONLY_DISPATCH_WRITE described judgment A only; this hook's scope
# widened to bidirectional capability matching (A + B + C), so it gets a name
# that describes the widened scope instead of carrying the old, now-partial
# name forward.
#
# [GATE-DEGRADE] vs [GATE-BYPASS]: these two stderr tags are NOT the same
# condition and must not collapse into one. [GATE-BYPASS] means a human
# deliberately opened the escape hatch — not a malfunction, and checked BEFORE
# any degrade path so an open hatch is never misreported as broken judgment
# data. [GATE-DEGRADE] means the judgment data itself could not be read
# (empty stdin, missing jq, malformed JSON, unexpected field shape) — the gate
# could not form an opinion at all. Merging the two labels would make a grep
# for real breakage indistinguishable from every session that simply has the
# hatch on, which is exactly how issue #164's silent gate death went
# unnoticed for months. This preamble is inlined rather than sourced from
# ~/.claude/hooks/lib/gate.sh because that path is a different repo — a
# cross-repo `source` would make this hook's behavior depend on a file this
# plugin does not ship and cannot pin.
#
# No tool_name filter is implemented here on purpose: this script is wired
# into hooks.json under two separate matcher entries, "Agent" and "Task".
# The framework itself gates delivery to those matchers, so a tool_name
# branch inside the script would be dead code with no reachable false path —
# writing it would misleadingly imply the check does something.
set -u

INPUT=$(cat)

# Knowing bypass is checked first: an open hatch is the reason this dispatch
# passes, not evidence the gate is broken, and it must be reported as such
# regardless of whether any judgment below would otherwise have fired.
if [[ "${ALLOW_DISPATCH_CAPABILITY_MISMATCH:-}" == "1" ]]; then
  printf '[GATE-BYPASS] dispatch-capability-guard: escape hatch ALLOW_DISPATCH_CAPABILITY_MISMATCH=1\n' >&2
  exit 0
fi

if [ -z "$INPUT" ]; then
  printf '[GATE-DEGRADE] dispatch-capability-guard: empty stdin\n' >&2
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  printf '[GATE-DEGRADE] dispatch-capability-guard: jq unavailable\n' >&2
  exit 0
fi

SUBAGENT_TYPE=$(jq -r '.tool_input.subagent_type // empty' <<< "$INPUT" 2>/dev/null) || {
  printf '[GATE-DEGRADE] dispatch-capability-guard: subagent_type extract failed\n' >&2
  exit 0
}
PROMPT=$(jq -r '.tool_input.prompt // empty' <<< "$INPUT" 2>/dev/null) || {
  printf '[GATE-DEGRADE] dispatch-capability-guard: prompt extract failed\n' >&2
  exit 0
}
MODEL=$(jq -r '.tool_input.model // empty' <<< "$INPUT" 2>/dev/null) || {
  printf '[GATE-DEGRADE] dispatch-capability-guard: model extract failed\n' >&2
  exit 0
}

[ -z "$PROMPT" ] && exit 0

# subagent_type default differs from prompt/model-style fields: absent means
# "general-purpose", not "treat as missing" (mirrors
# pre-dispatch-readonly-guard.sh's same rule, kept for judgment A's parity).
[ -z "$SUBAGENT_TYPE" ] && SUBAGENT_TYPE="general-purpose"
TYPE=$(tr '[:upper:]' '[:lower:]' <<< "$SUBAGENT_TYPE")

# Fold ASCII to lowercase so English signals match regardless of case; CJK is
# unaffected by tr. All English patterns below are written lowercase to match
# against the folded text. Same treatment as pre-dispatch-readonly-guard.sh.
PROMPT_LC=$(tr '[:upper:]' '[:lower:]' <<< "$PROMPT")
MODEL_LC=$(tr '[:upper:]' '[:lower:]' <<< "$MODEL")

# --- Signal 1: EXEC (exec intent) — the bare keyword list below
# (RE_EXEC_BARE*) is migrated verbatim from pre-dispatch-readonly-guard.sh,
# where it was used as an EXEMPTION (widening the word list only ever
# widened the set of prompts allowed to pass — harmless in that direction).
# This hook reuses it as a REJECTION signal (judgment B blocks on EXEC_HIT),
# which flips the safety direction: a bare keyword list now widens the set
# of prompts BLOCKED, and false positives there have a real cost (실측 in
# Major finding #2 — "查一下跑测试的脚本在哪" is pure research and got
# blocked). Per gate-design.md §2 (anchor syntactic shape, not bare
# keywords), EXEC_HIT now requires a bare-keyword match to sit in an
# imperative/delegation clause, not a research-frame or negated clause.
# The word list itself is unchanged from the original migration; only the
# surrounding clause is inspected before accepting the hit.
RE_EXEC_BARE_CN='前台(同步)?执行|执行脚本|运行脚本|跑脚本|跑测试|运行测试|执行测试|跑用例|跑一遍(测试|脚本|用例)|跑 ?lint|跑 ?build|跑构建|执行以下命令|执行下列命令'
RE_EXEC_BARE_EN='run (the |this |that )?scripts?|execute (the |this )?scripts?|run (the )?tests?|run (the )?test suite|run (the )?lint|run (the )?build'
RE_EXEC_BARE="${RE_EXEC_BARE_CN}|${RE_EXEC_BARE_EN}"
# Research-frame / negation words that, when they appear in the SAME CLAUSE
# preceding the bare-keyword hit (i.e. between the nearest clause boundary
# 逗号/顿号/分号/句号/comma/period and the match), demote it back to a
# non-hit: the keyword is the OBJECT of a research or negated verb, not an
# imperative to execute. Mirrors RO_ACT's existing anchor-not-bare-keyword
# treatment — same design move, applied to EXEC instead of RO.
RE_EXEC_FRAME_CN='查|找|看|分析|说明|文档|哪里|在哪|为什么|如何|怎么|不要|不用|别|无需|不需要|不必|勿|莫'
RE_EXEC_FRAME_EN='document how to|find where|explain why|show me where|do not|don.t|dont|why not|should not'

# --- Signal 2: WRITE (write intent, NEW) — anchored per gate-design.md §2:
# anchor on syntactic shape, not bare keywords. A write verb alone (裸
# 改/写) is NOT collected: 创建一份调研报告 produces a report, not code, and
# collecting the bare verb would misclassify that genuinely read-only task as
# a write task. Requiring an adjacent code-object or path-shaped token is
# what keeps the two apart — same reasoning pre-dispatch-readonly-guard.sh's
# RE_WRITE_SCOPE comment already documents for a different judgment.
WRITE_VERB='修改|修复|重构|实现|新增|添加|删除|重命名|改写|补充|编写|落地|开发|加一个|加个'
# bug|issue|error added per Minor finding #4: "fix the bug in auth" carries
# no code/file/test noun at all, only a defect noun, and was missing from
# the object list. English tokens kept as-is (not translated) because 中文
# 句子里 bug 常年以英文原词出现（"修复 auth 模块的 bug"），同一 token 双语都要收。
WRITE_OBJ='文件|代码|源码|函数|方法|测试|用例|脚本|模块|类|接口|配置|字段|bug|issue|error'
# Path-shaped token: contains a slash, or a common source/doc extension.
RE_PATH_TOKEN='[[:alnum:]_.-]*/[[:alnum:]_./-]*|[[:alnum:]_-]+\.(py|sh|ts|tsx|js|jsx|go|md|json|yaml|yml|rb|java|c|cpp|h|rs)'
RE_WRITE_CN="(${WRITE_VERB})[^。,，;；]{0,20}(${WRITE_OBJ})|(${WRITE_VERB})[^。,，;；]{0,20}(${RE_PATH_TOKEN})"
# bug|bugs|issue|issues|error|errors added per Minor finding #4: "fix the
# bug in auth" carried no file/code/test noun, only a defect noun.
RE_WRITE_EN='(implement|fix|refactor|rename|add|remove|modify|write)s? (the |a |an |this )?(file|files|code|function|functions|test|tests|script|scripts|module|modules|bug|bugs|issue|issues|error|errors)'
RE_WRITE_PATH_EN="(implement|fix|refactor|rename|add|remove|modify|write)[^.,;]{0,40}(${RE_PATH_TOKEN})"

# --- Signal 3: RO (read-only declaration) — migrated verbatim from
# pre-dispatch-readonly-guard.sh (RE_RO / RE_RO_DECL), including all inline
# comments: they record real false-positive history, not noise.
# 动作表刻意不含 任务/task：它们是名词而非调研动作，收进来会让本条要治的主题词
# 误报换皮复活（`实现只读任务队列` / `implement a read-only task queue`）。
# 「这是一个只读任务」这类句式由下面的 RE_RO_DECL 用更窄的句型锚定。
RO_ACT='查看|查阅|阅读|通读|调查|调研|分析|审查|审阅|评审|梳理|浏览|检索|排查|核查|摸底|巡查'
RO_ACT_EN='analysis|analyze|analyse|review|investigation|investigate|inspection|inspect|audit|survey|research|exploration|explore'
# 中文侧容忍 只读 与动作之间的空白与逗号（`只读 查看` / `只读，梳理`），与英文侧
# 的 [ -]? 对齐——分隔符不改变语义，漏拦却是实的。
# 方式|模式 收在中缀里以覆盖「以只读方式查看」「以只读模式梳理」——高频显式声明。
RE_RO="只读(的|地)?(方式|模式)?(下)?[[:space:]，,、:：]*(${RO_ACT})|(${RO_ACT})[[:space:]]*只读|read[ -]?only[ -]?(${RO_ACT_EN})"
# 显式任务性质声明。两种形态都要求 只读 与 任务 之间有句法承接（系动词或冒号），
# 故 `实现只读任务队列` 这类偏正短语不命中：
#   系动词式  `这是一个只读任务` / `is a read-only task`
#   标签式    `只读任务：…` / `read-only task:`
RE_RO_DECL='(是|为)(一个|一项)?只读(的)?(任务|工作|活儿)|is a read[ -]?only (task|job)'
RE_RO_DECL="${RE_RO_DECL}|只读(任务|工作)[[:space:]]*[:：]|read[ -]?only (task|job)[[:space:]]*:"
RE_RO_DECL="${RE_RO_DECL}|(任务|工作)(是|为)只读"

# --- Signal 4: NEG (absolute negation of writing) — migrated verbatim from
# pre-dispatch-readonly-guard.sh (RE_NEG / RE_NEG_EN / RE_DOUBLE_NEG /
# RE_WRITE_SCOPE / RE_SCOPE_NEG), including all inline comments.
# The distinction that resolves issue #125's main complaint: an ABSOLUTE
# object (文件/代码, optionally quantified 任何/所有) declares a read-only
# task, while a RELATIVE object (docs/ 之外的文件, 其他文件, settings.json) is
# dispatch-contract rule ② scope fencing — the very wording the contract
# requires of write tasks. Anchoring on the object is what tells them apart;
# bare 不修改 cannot.
NEG='不|不要|不得|不准|不许|勿|别|禁止|请勿|严禁|切勿'
WRITE='修改|改动|更改|变更|编辑|改写|写入|改|写'
OBJ='文件|代码|源码|源代码|源文件|仓库文件|工程文件|项目文件|内容'
RE_NEG="(${NEG})(${WRITE})(任何|所有|一切|任一)?(${OBJ})"
# 宾语前容忍限定词：`do not modify the code` 与 `any files` 同为绝对否定，
# 只认 any/all 会漏掉更常见的 the/this 形态。
RE_NEG_EN="(do not|don't|dont|never) (modify|change|edit|write|touch|alter) ?(any|all|the|this|that|these|those)? ?(file|files|code|source)"
# 双重否定是写声明而非只读声明：`不得不改代码` 内嵌 `不改代码`，子串式否定判据
# 会把它反读。这些前缀本身就把 NEG 的首字（不/非）吃进去了，故判定时用「否定命中
# 是否落在双重否定跨度内」来抵消，而非整段作废（见下方 scan 循环）。
RE_DOUBLE_NEG="(不得不|不能不|不是不|并非不|无法不|非得)(${WRITE})"
# 排他性写范围声明。豁免的正当性来自「只/仅」带的**排他语义**（我写，但只写这里）
# ——此时后文的 `不改代码` 与 `不改其他文件` 同义，宾语看着绝对、语义仍相对。
# 刻意不含裸写动词（创建|新增|追加|新建|chmod）：它们不带排他性，`创建一份调研
# 报告，不修改任何文件` 是**真只读任务**（产出物是报告不是代码），收进来等于让
# 日常措辞清空绝对否定这条防线。这类元语言写作任务本就该走 Explore 之外的通道，
# 不该靠本豁免放行。
# 左边界排除 不|非：`不只改测试` 是「不止于改测试」，语义与 `只改测试` 相反，
# 子串匹配会把它误吃成排他写范围、进而放掉后面的绝对否定。
RE_WRITE_SCOPE='(^|[^不非])(只|仅)(改|修改|动|新增|新建|创建|写|写入|编辑|碰|touch)'
# 多字否定前缀单列黑名单：`不要只改测试` 的左邻是「要」而非「不」，单靠 [^不非]
# 挡不住。不能把「要」加进排除集——那会误伤 `需要只改测试` 这类正当排他声明，
# 故按前缀词显式排除。
RE_SCOPE_NEG='(不要|不得|不准|不许|别|请勿|切勿|切莫|禁止|严禁|不可|不能|勿)(只|仅)(改|修改|动|新增|新建|创建|写|写入|编辑|碰)'
# 英文对称：`only change tests, do not modify the code` 与中文 `只改测试，不改代码`
# 同构，缺了它英文写任务照样被误拦。just 与 limit changes to 是同义高频变体。
RE_WRITE_SCOPE_EN='(only|just) (change|modify|edit|touch|write|add)|(change|modify|edit|touch|write) only|limit (changes|edits|modifications) to'

# --- Compute EXEC / WRITE -----------------------------------------------
# EXEC_HIT: bare-keyword match required, PLUS the clause containing the
# match must not carry a research-frame or negation word. Clause boundary
# is the nearest 逗号/顿号/分号/句号 (or English comma/period) to the LEFT of
# the match — this is what lets "查一下跑测试的脚本在哪，只读调研" (frame word
# 查 sits in the same clause as 跑测试) stay a non-hit while "只读调研，跑一遍
# 测试确认" (frame word 只读调研 is in the PRIOR clause, separated by a comma)
# still hits: the frame word must govern the same clause as the keyword, not
# merely appear earlier in the sentence.
EXEC_HIT=0
if [[ "$PROMPT_LC" =~ $RE_EXEC_BARE ]]; then
  EXEC_MATCH="${BASH_REMATCH[0]}"
  EXEC_PREFIX="${PROMPT_LC%%"$EXEC_MATCH"*}"
  EXEC_CLAUSE="${EXEC_PREFIX##*[,，、；;。.]}"
  if [[ "$EXEC_CLAUSE" =~ $RE_EXEC_FRAME_CN || "$EXEC_CLAUSE" =~ $RE_EXEC_FRAME_EN ]]; then
    EXEC_HIT=0
  else
    EXEC_HIT=1
  fi
fi

WRITE_HIT=0
if [[ "$PROMPT_LC" =~ $RE_WRITE_CN || "$PROMPT_LC" =~ $RE_WRITE_EN || "$PROMPT_LC" =~ $RE_WRITE_PATH_EN ]]; then
  WRITE_HIT=1
fi

# --- Compute RO / NEG (verbatim scan/scrub logic, migrated) -------------
RO_HIT=0
[[ "$PROMPT_LC" =~ $RE_RO || "$PROMPT_LC" =~ $RE_RO_DECL ]] && RO_HIT=1

# 否定判定按**命中点**做，不按整段也不按子句做布尔运算。见
# pre-dispatch-readonly-guard.sh 同段注释：双重否定要抵消的只是它自己吃掉的那次
# 否定命中，与同段其他否定无关；用 ␡ 占位抠掉双重否定跨度，再对残文跑 RE_NEG。
SCRUBBED=$PROMPT_LC
while [[ "$SCRUBBED" =~ $RE_DOUBLE_NEG ]]; do
  m=${BASH_REMATCH[0]}
  prev=$SCRUBBED
  # 用 ␡ 占位而非直接删除：直接删会把左右字符拼到一起，可能凭空造出新的否定形态
  SCRUBBED=${SCRUBBED/"$m"/␡}
  # 保险丝：当前词表下每轮长度严格递减（m 非空、无零宽匹配），此分支不可达。留着
  # 是因为将来往 RE_DOUBLE_NEG 加词若引入零宽或 no-op 替换，代价是挂起整个
  # PreToolUse——挂起没有逃生舱，值得一行防御。
  [[ -z "$m" || "$SCRUBBED" == "$prev" ]] && break
done

# WRITE_HIT_A: a judgment-A-only variant of WRITE_HIT, scanned against text
# with every already-recognized absolute-negation span (RE_NEG/RE_NEG_EN)
# scrubbed out first. Root cause this works around: RE_WRITE_CN/RE_WRITE_EN
# are bare substring matches with no clause anchoring, so for "不得不改测试，
# 不修改任何文件" they match "修改任何文件" INSIDE a clause that RE_NEG also
# (correctly) matches as an absolute negation — the same substring is
# simultaneously "a write object" to one regex and "a negated write object"
# to another. This collision predates this patch (WRITE_OBJ additions did
# not cause it — the bare verb 修改 + bare object 文件 already collide with
# RE_NEG on this exact sentence even under the pre-patch word lists) but was
# invisible before because judgment A never consulted WRITE_HIT. Once A
# started requiring !WRITE (this patch's Critical fix), the collision
# surfaced as a regression on a previously-pinned test (cap #25b): a genuine
# absolute-negation declaration stopped triggering A because a write-looking
# substring sat inside its own negated clause. Scoping WRITE_HIT_A to the
# NEG-scrubbed text (reusing the same scrub-by-placeholder mechanism as
# SCRUBBED/RE_DOUBLE_NEG above, applied one level further) resolves it
# without touching RE_WRITE_CN/RE_WRITE_EN themselves, so judgment B's
# WRITE detection (and NEEDS_CAP) are unaffected — only A's local !WRITE
# check looks at text with recognized negations already removed.
WRITE_SRC_A=$SCRUBBED
while [[ "$WRITE_SRC_A" =~ $RE_NEG || "$WRITE_SRC_A" =~ $RE_NEG_EN ]]; do
  nm=${BASH_REMATCH[0]}
  nprev=$WRITE_SRC_A
  WRITE_SRC_A=${WRITE_SRC_A/"$nm"/␡}
  [[ -z "$nm" || "$WRITE_SRC_A" == "$nprev" ]] && break
done
WRITE_HIT_A=0
if [[ "$WRITE_SRC_A" =~ $RE_WRITE_CN || "$WRITE_SRC_A" =~ $RE_WRITE_EN || "$WRITE_SRC_A" =~ $RE_WRITE_PATH_EN ]]; then
  WRITE_HIT_A=1
fi

NEG_HIT=0
if [[ "$SCRUBBED" =~ $RE_NEG || "$SCRUBBED" =~ $RE_NEG_EN ]]; then
  NEG_HIT=1
  # 排他写范围声明修饰的是整个任务的写范围，作用域天然全句，故按整段判定。
  # 同 scrub 的道理：先把「否定词+只改」这类反义形态抠掉，剩下的才算真排他声明。
  SCOPE_SRC=$PROMPT_LC
  while [[ "$SCOPE_SRC" =~ $RE_SCOPE_NEG ]]; do
    sm=${BASH_REMATCH[0]}
    sprev=$SCOPE_SRC
    SCOPE_SRC=${SCOPE_SRC/"$sm"/␡}
    [[ -z "$sm" || "$SCOPE_SRC" == "$sprev" ]] && break
  done
  if [[ "$SCOPE_SRC" =~ $RE_WRITE_SCOPE || "$SCOPE_SRC" =~ $RE_WRITE_SCOPE_EN ]]; then
    NEG_HIT=0
  fi
fi

# --- Derived predicate ----------------------------------------------------
# NEEDS_CAP: this task asks for something beyond read-only capability, and
# nothing in the same prompt declares it read-only after all. Mixed prompts
# (调研根因并修复 hits both RO and WRITE) fall to !RO being false, i.e.
# NEEDS_CAP=0 — a deliberately accepted miss, not a bug: today's behavior for
# such prompts is also "pass", so this is no regression, and it stays on the
# "under-block" side rather than the "over-block" side. Going fail-closed
# (requiring every Explore dispatch to declare read-only explicitly) was
# rejected: it would impose a declaration burden on Explore, and the resulting
# false-positive cost would push dispatchers toward general-purpose instead —
# amplifying exactly the over-privilege risk judgment A exists to catch.
NEEDS_CAP=0
if [ "$EXEC_HIT" -eq 1 ] || [ "$WRITE_HIT" -eq 1 ]; then
  if [ "$RO_HIT" -eq 0 ] && [ "$NEG_HIT" -eq 0 ]; then
    NEEDS_CAP=1
  fi
fi

REJECT=0

# --- Judgment A (condition WIDENED: !EXEC && !WRITE_A, was !EXEC alone) ----
# Read-only declaration (or absolute negation) sent to a full-privilege
# built-in agent, PROVIDED the same prompt carries no write intent either.
# The !WRITE_A addition is this patch's Critical fix (see the "A's exemption"
# block comment near the top of this file for the full trace): without it,
# a mixed prompt like "只读查看现有实现，然后修复 main.py" got told to
# re-dispatch to Explore, whose Edit/Write is physically disabled — a dead
# end the gate manufactured rather than a legitimate rejection. With !WRITE_A,
# such a prompt no longer matches A at all (it needs write capability, so
# staying on general-purpose/claude is the correct dispatch, not an error).
# Uses WRITE_HIT_A (NEG-scrubbed variant), not the raw WRITE_HIT judgment B
# uses: see WRITE_HIT_A's own comment above for why — a write-object
# substring sitting inside an already-recognized absolute-negation clause
# ("不修改任何文件") must not disqualify A's read-only declaration just
# because a bare-substring regex also sees a write-shaped token in it.
case "$TYPE" in
  general-purpose|claude)
    if [ "$EXEC_HIT" -eq 0 ] && [ "$WRITE_HIT_A" -eq 0 ] && { [ "$RO_HIT" -eq 1 ] || [ "$NEG_HIT" -eq 1 ]; }; then
      printf '[dispatch-capability-guard] 命中判据 A: 只读任务声明但派了全权 agent(subagent_type=%s),应改派内置 Explore(Edit/Write/NotebookEdit 物理禁用,越权改不了文件)。\n' "$TYPE" >&2
      printf '[dispatch-capability-guard] 出路: 改派 subagent_type=Explore。需 code-search/web-search 时在 prompt 内 Skill(...) 加载。任务其实要执行脚本/跑测试(Explore 的 Bash 限只读白名单,会拒执行)时,在 prompt 里写明执行意图(如"前台同步执行"/"跑脚本")即豁免——这类任务留 general-purpose 是对的。\n' >&2
      REJECT=1
    fi
    ;;
esac

# --- Judgment B (new): NEEDS_CAP && TYPE in {explore, plan} -----------------
case "$TYPE" in
  explore|plan)
    if [ "$NEEDS_CAP" -eq 1 ]; then
      printf '[dispatch-capability-guard] 命中判据 B: 本任务需要超出只读的能力(subagent_type=%s),但 Explore/Plan 的 Edit/Write/NotebookEdit 被平台物理禁用、Bash 限只读白名单,派过去会空转一轮后 dead-end。\n' "$TYPE" >&2
      printf '[dispatch-capability-guard] 出路: 改派 subagent_type=general-purpose 或 dev(team-ops 场景)。\n' >&2
      REJECT=1
    fi
    ;;
esac

# --- Judgment C (new): NEEDS_CAP && model contains "haiku" -----------------
if [ "$NEEDS_CAP" -eq 1 ] && [[ "$MODEL_LC" == *haiku* ]]; then
  printf '[dispatch-capability-guard] 命中判据 C: 本任务需要超出只读的能力,但 model=%s 落在 haiku 档;解读执行/测试输出并决定下一步属"产出取舍结论"的落地活,daily 模型分层判据把这类工作排除在 haiku 之外。\n' "$MODEL" >&2
  printf '[dispatch-capability-guard] 出路: 把 model 升到 sonnet(或按任务要求的档位)重派。\n' >&2
  REJECT=1
fi

if [ "$REJECT" -eq 1 ]; then
  printf '[dispatch-capability-guard] 逃生舱：在 ~/.claude/settings.json 的 env 段设置 "ALLOW_DISPATCH_CAPABILITY_MISMATCH": "1"（Bash 内 export 对 hook 进程不生效，仅可作直接调用本脚本时的同进程调试用；临时开启后须销账关闭，长期常开会致门禁全局失效）。\n' >&2
  exit 2
fi

exit 0
