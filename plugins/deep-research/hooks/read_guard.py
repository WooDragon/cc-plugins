#!/usr/bin/env python3
"""PreToolUse(Read|Bash) hook: 主 session 绝对规则门禁。

绝对规则（见 docs/main-session-isolation-contracts.md 契约①）：主 session（agent_id
为空）对 pipeline/** 与 deliverables/** 下的文件只能持路径指针，禁止读取内容
（Read 工具 + Bash cat 类读取）。subagent（agent_id 非空）不受限——它们必须读
pipeline 才能干活。

威胁模型分层（诚实分级）：Read 工具＝硬拦截（Lead 读文件默认主路径）；Bash＝
尽力护栏（拦意外/习惯性读取模式，非对抗性沙盒——Lead 是协作方非攻击者）；不做
chmod/容器级隔离（会同时禁掉同 UID 的 subagent，且对协作威胁模型是过度工程）。

fail-open 是硬约束（never break userspace）：非 deep-research 项目、拿不到
agent_id、路径解析异常、Bash 命令解析不出明确读大文件意图——一律放行。宁可漏检
不可误伤。判定逻辑集中在纯函数 _should_block()，便于单测；main() 只负责 IO。
"""
import json
import os
import re
import shlex
import sys
from pathlib import Path

# 受管路径：项目内这两个目录下的文件是主 session 禁读对象。
_MANAGED_DIRS = ("pipeline", "deliverables")

# 向上查 pipeline/ 定位项目根的层数上限（与 gate_check.py 同款，防无限上溯）。
_MAX_WALKUP_LEVELS = 30

# 小指针文件白名单：主 session 合法持有（receipt/manifest/goal/index/verdict）。
_WHITELIST_BASENAMES = ("research-goal.md", "INDEX.md")
_WHITELIST_PATTERNS = (
    re.compile(r"-manifest\.[^/]+$"),
    re.compile(r"-receipt\.[^/]+$"),
    re.compile(r"\.verdict$"),
    re.compile(r"-verdict\.md$"),
)
# 体积阈值：低于此值视为指针/receipt 量级，放行。
_SIZE_THRESHOLD_BYTES = 8 * 1024

# Bash 读取命令：命中这些且参数指向受管路径 → 拦截。
_READ_COMMANDS = frozenset(
    {"cat", "head", "tail", "less", "more", "sed", "awk"}
)

# stderr 指导语（拦截时输出，防协作 agent 盲目重试）。
_BLOCK_MESSAGE = (
    "[read_guard] Action blocked: Lead 主 session 禁读 pipeline/deliverables "
    "全文（绝对规则，见 docs/main-session-isolation-contracts.md）。\n"
    "你必须 spawn 一个 subagent 读该文件并回传结构化 receipt（含所需字段），"
    "而不是重试本次读取。\n"
    "Blocked path: {path}"
)


def _locate_project_root(start: Path):
    """从 start 向上查含 pipeline/ 的祖先目录（即研究项目根）。

    复用 gate_check._locate_project_dir 的核心逻辑：设层数上限，到文件系统根
    自然停止。查不到返回 None（调用方据此 fail-open 放行——非 deep-research 项目
    不该被门禁误伤）。
    """
    try:
        node = start.resolve()
    except OSError:
        return None
    for _ in range(_MAX_WALKUP_LEVELS):
        if (node / "pipeline").is_dir():
            return node
        parent = node.parent
        if parent == node:  # 文件系统根
            break
        node = parent
    return None


def _is_whitelisted(abs_path: str) -> bool:
    """小指针文件放行判定：文件名匹配白名单，或体积低于阈值。"""
    base = os.path.basename(abs_path)
    # Evidence ledger is line-addressable raw claims — never a Lead pointer,
    # even when the file is far below the 8KiB receipt threshold.
    if base == "harvest-evidence.jsonl" or base.endswith("-harvest-evidence.jsonl"):
        return False
    if base in _WHITELIST_BASENAMES:
        return True
    for pat in _WHITELIST_PATTERNS:
        if pat.search(base):
            return True
    # 体积检查：读不到大小（文件不存在等）不作为放行依据，交给路径判定。
    try:
        if os.path.getsize(abs_path) < _SIZE_THRESHOLD_BYTES:
            return True
    except OSError:
        pass
    return False


def _under_managed_dir(abs_path: str, project_root: Path) -> bool:
    """abs_path 是否落在 project_root 下的 pipeline/ 或 deliverables/ 内。"""
    try:
        real = os.path.realpath(abs_path)
    except OSError:
        return False
    for d in _MANAGED_DIRS:
        prefix = os.path.realpath(str(project_root / d)) + os.sep
        if real.startswith(prefix):
            return True
    return False


def _resolve(path: str, cwd: str) -> str:
    """相对路径按 cwd 解析为绝对路径。"""
    if os.path.isabs(path):
        return path
    return os.path.join(cwd or os.getcwd(), path)


def _managed_target(path: str, cwd: str):
    """给定一个候选文件路径，返回它是否受管且非白名单（即应拦截）。

    返回 (should_block, abs_path)。非受管 / 白名单 / 定位不到项目 → (False, _)。
    """
    abs_path = _resolve(path, cwd)
    project_root = _locate_project_root(Path(os.path.dirname(abs_path) or cwd or "."))
    if project_root is None:
        return False, abs_path  # 非研究项目 → fail-open
    if not _under_managed_dir(abs_path, project_root):
        return False, abs_path
    if _is_whitelisted(abs_path):
        return False, abs_path
    return True, abs_path


def _extract_bash_read_targets(command: str):
    """从 Bash 命令解析出「读取大文件」意图的目标路径列表。

    只认明确的读取模式，不确定一律返回空（fail-open）：
      - cat/head/tail/less/more/sed/awk <file>
      - grep 空 pattern 全量读（grep "" file / grep '' file）
      - echo "$(<file)" 进程替换读取
    grep 带真实 pattern 的检索、ls、find、git 等 → 不视为读大文件，返回空。
    """
    targets = []
    try:
        tokens = shlex.split(command)
    except ValueError:
        return targets  # 引号不闭合等 → 解析不出意图，fail-open
    if not tokens:
        return targets

    # 处理管道/多命令：按 | && ; 粗分段，逐段判首命令。
    segments = re.split(r"[|;]|&&|\|\|", command)
    for seg in segments:
        try:
            seg_tokens = shlex.split(seg)
        except ValueError:
            continue
        if not seg_tokens:
            continue
        cmd = os.path.basename(seg_tokens[0])
        args = seg_tokens[1:]

        if cmd in _READ_COMMANDS:
            # 取非选项参数作为文件目标（sed/awk 首个非选项可能是脚本，保守全收——
            # 命中受管路径才拦，误收无害路径不会拦）。
            for a in args:
                if a.startswith("-"):
                    continue
                targets.append(a)
        elif cmd == "grep":
            # 仅「空 pattern 全量读」视为读大文件；带 pattern 的检索放行。
            non_opt = [a for a in args if not a.startswith("-")]
            if non_opt and non_opt[0] == "":
                targets.extend(non_opt[1:])

    # echo "$(<file)" 或裸 "$(<file)" 进程替换读取
    for m in re.finditer(r"\$\(\s*<\s*([^\s)]+)\s*\)", command):
        targets.append(m.group(1))
    for m in re.finditer(r"<\s*([^\s;|&<>]+)", command):
        # 输入重定向 `< file`（排除 <<here-doc，已被 [^<] 挡掉部分）
        targets.append(m.group(1))

    return targets


def _should_block(agent_id, tool_name, tool_input, cwd):
    """核心判定纯函数。返回 (should_block: bool, blocked_path: str|None)。

    fail-open 保护落在**项目/路径/白名单层**（非研究项目、非受管路径、白名单文件
    一律放行），不在 agent_id 层——这一点很关键，见下。

    agent_id 语义（对齐 pre-edit-write.sh 的既有判据 `.agent_id // ""`）：
      - **非空** → 确定是 subagent → 放行。
      - **空字符串 / None / 缺失** → 视作主 session（Lead 的 PreToolUse 事件本就
        携带空/缺失 agent_id）→ 继续走路径判定。**不能**把 None 当技术不确定去
        fail-open——若那样，主 session 的事件（agent_id 恰恰为空/缺失）将永远
        绕过门禁，绝对规则彻底失效。真正的 fail-open 由后续「非研究项目/非受管
        路径/白名单」三道路径层放行提供：即便把某个 agent_id 丢失的 subagent 误
        判为主 session，也只有在「研究项目内 + 受管路径 + 大文件」时才会拦，且带
        明确 stderr 指引，代价远小于让主 session 整体绕过。
    """
    # None / 缺失归一化为空字符串，与主 session 同路径处理（见上 docstring）。
    agent_id = agent_id or ""
    # subagent（agent_id 非空）不受限
    if agent_id:
        return False, None

    tool_input = tool_input or {}

    if tool_name == "Read":
        path = tool_input.get("file_path")
        if not path:
            return False, None
        blocked, abs_path = _managed_target(path, cwd)
        return (blocked, abs_path) if blocked else (False, None)

    if tool_name == "Bash":
        command = tool_input.get("command", "")
        if not command:
            return False, None
        for target in _extract_bash_read_targets(command):
            blocked, abs_path = _managed_target(target, cwd)
            if blocked:
                return True, abs_path
        return False, None

    return False, None


def main():
    try:
        event = json.load(sys.stdin)
        agent_id = event.get("agent_id") or ""
        tool_name = event.get("tool_name") or ""
        tool_input = event.get("tool_input") or {}
        cwd = event.get("cwd") or ""

        should_block, blocked_path = _should_block(
            agent_id, tool_name, tool_input, cwd
        )
        if should_block:
            # PreToolUse 阻断：stderr 指导语 + exit 2（与 pre-edit-write.sh 同款
            # deny 契约——exit 2 使 stderr 反馈给模型）。
            print(_BLOCK_MESSAGE.format(path=blocked_path), file=sys.stderr)
            sys.exit(2)
    except SystemExit:
        raise
    except Exception:
        # fail-open：技术性不确定一律放行（never break userspace）
        return


if __name__ == "__main__":
    main()
