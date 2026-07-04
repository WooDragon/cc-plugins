#!/usr/bin/env python3
"""SubagentStop hook: G1 引用校验机械门核验。

职责单一（见 atomic-toasting-hejlsberg plan Step 2 语义澄清）：只核验
"GATE_VERDICT: G1 PASS" 宣称的真实性，不复裁 Gate 本身。
`GATE_VERDICT: G1 FAIL|RECYCLE` 是合法裁决，必须放行送达 Lead 以触发补采/回
G0——block 语义等于把 reviewer 打回重跑，而它的活已经干完了。未命中任何
GATE_VERDICT 标记的消息（harvester/analyst 等非 Gate 类 subagent 同样触发
SubagentStop）一律放行。

技术性不确定（无标记 / 找不到项目目录 / 未启用 harvest.py / import 或校验自身
抛异常）一律 fail-open；业务性失败（PASS 宣称但机械门判 FAIL，含 UNAVAILABLE
墓碑）才 block。两者不可混淆。
"""
import json
import re
import sys
from pathlib import Path

GATE_PASS_RE = re.compile(r"^\s*GATE_VERDICT:\s*G1\s+PASS\s*$", re.MULTILINE)
PROJECT_PATH_RE = re.compile(r"projects/[^\s\"'`)]+")

# hooks/ 的上一级 = 插件根，harvest.py 就在插件根下的 scripts/ 里（两者是
# 插件根下的固定兄弟目录，装到哪都不变）。
PLUGIN_ROOT = Path(__file__).resolve().parent.parent

# 研究项目现在可以在用户任意工作目录下（不再是框架仓库的固定子目录），
# 向上查找 pipeline/ 目录时设一个层数上限，防止无限上溯。
_MAX_WALKUP_LEVELS = 30


def _last_assistant_text(transcript_path: str) -> str:
    """读 SubagentStop 事件的 transcript JSONL，取最后一条 assistant 消息文本。

    流式记录会为同一条最终消息产生多行（逐步增长的 content），后出现的行
    覆盖之前的，天然收敛到该消息的完整文本。
    """
    text_parts = []
    with open(transcript_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if record.get("type") != "assistant":
                continue
            message = record.get("message")
            if not isinstance(message, dict):
                continue
            content = message.get("content")
            if not isinstance(content, list):
                continue
            parts = [
                block.get("text", "")
                for block in content
                if isinstance(block, dict) and block.get("type") == "text"
            ]
            if parts:
                text_parts = parts
    return "\n".join(text_parts)


def _locate_project_dir(event: dict, message_text: str):
    """定位研究项目目录（含 pipeline/ 的目录）。

    插件化后研究项目可以在用户任意工作目录下，不再有固定的框架仓库根做
    查找边界。核心逻辑保留：从候选路径出发，逐级向上查找含 pipeline/ 子
    目录的祖先目录（覆盖 hook 事件 cwd 落在项目子目录如 pipeline/1_raw、
    deliverables 的常见场景）。上溯层数设 _MAX_WALKUP_LEVELS 上限，防止
    在异常目录结构下无限上溯；到文件系统根也会自然停止。

    message_text 里 `projects/xxx` 形式的相对路径候选，相对 event.cwd 解
    析（没有固定仓库根可拼接了）；拿不到 cwd 时跳过该候选，不臆造路径。

    无法可靠定位时返回 None，调用方据此放行——宁可漏检也不能误伤未启用
    harvest.py 的项目或定位到错误目录乱判（fail-open 是硬约束，不能改）。
    """
    candidates = []
    cwd = event.get("cwd")
    if cwd:
        candidates.append(Path(cwd))
        for match in PROJECT_PATH_RE.finditer(message_text):
            candidates.append(Path(cwd) / match.group(0))

    for candidate in candidates:
        try:
            resolved = candidate.resolve()
        except OSError:
            continue
        node = resolved
        for _ in range(_MAX_WALKUP_LEVELS):
            if (node / "pipeline").is_dir():
                return node
            parent = node.parent
            if parent == node:  # 到达文件系统根
                break
            node = parent
    return None


def main():
    try:
        event = json.load(sys.stdin)
        transcript_path = event.get("transcript_path")
        if not transcript_path:
            return

        message_text = _last_assistant_text(transcript_path)
        if not GATE_PASS_RE.search(message_text):
            return

        project_dir = _locate_project_dir(event, message_text)
        if project_dir is None:
            return

        sys.path.insert(0, str(PLUGIN_ROOT / "scripts"))
        from harvest import check_project

        verdict, reason = check_project(str(project_dir))
        if verdict == "FAIL":
            print(json.dumps({
                "decision": "block",
                "reason": f"G1 引用校验机械门未通过/多模型采集不可用: {reason}",
            }))
    except Exception:
        # fail-open：技术性不确定一律放行，不破坏现有流程（never break userspace）
        return


if __name__ == "__main__":
    main()
