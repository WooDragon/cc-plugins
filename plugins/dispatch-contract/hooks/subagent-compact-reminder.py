"""Read-only PostToolUse advisory for completed, instance-owned auto compacts."""
import json
import os
from pathlib import Path
import re
import stat
import sys
from contextlib import contextmanager
from dataclasses import dataclass, field


TOOLS = {"Agent", "Task", "SendMessage", "TaskOutput"}

# Two completed auto compactions mean the instance has already burned its working
# context once and is rebuilding state from summaries. Warn at two: by the time a
# third lands, the rebuild-and-reread loop is established and the instance is
# spending its budget re-deriving what it already knew. Keep in sync with README
# and the test cases.
REMINDER_THRESHOLD = 2

# os.O_NONBLOCK does not exist on Windows. Its only job here is to stop a FIFO
# with no writer from hanging the hook at open(); Windows has no POSIX FIFOs, so
# omitting the flag loses nothing there. What the flag still buys on POSIX is the
# open() itself not blocking, so it is kept wherever it exists rather than being
# replaced by a pre-check everywhere — the POSIX path stays byte-identical.
_NONBLOCK = getattr(os, "O_NONBLOCK", 0)


class Unknown(ValueError):
    """The available native provenance cannot establish an exact count."""


def native_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", value):
        raise Unknown("invalid native identity")
    return value


@contextmanager
def regular_text(path):
    # Nonblocking open + fstat also handles a file replaced by a FIFO between
    # discovery and open. Adopted transcript symlinks to regular files work.
    #
    # Where O_NONBLOCK is unavailable (Windows), the open() cannot be made
    # nonblocking, so the regular-file test moves ahead of it: os.stat follows
    # the same symlinks and reads only metadata, so it cannot hang. The fstat
    # below still runs afterwards, which keeps the TOCTOU window the same width
    # it already was on POSIX rather than widening it.
    if not _NONBLOCK and not stat.S_ISREG(os.stat(path).st_mode):
        raise Unknown("not a regular file")
    descriptor = os.open(path, os.O_RDONLY | _NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise Unknown("not a regular file")
        stream = os.fdopen(descriptor, encoding="utf-8")
        descriptor = None
        with stream:
            yield stream
    finally:
        if descriptor is not None:
            os.close(descriptor)


def metadata(path):
    with regular_text(path.with_suffix(".meta.json")) as stream:
        result = json.load(stream)
    if not isinstance(result, dict):
        raise Unknown("invalid metadata")
    return result


@dataclass
class History:
    boundaries: set = field(default_factory=set)
    own_auto: set = field(default_factory=set)
    copied: set = field(default_factory=set)
    calls: dict = field(default_factory=dict)
    sessions: set = field(default_factory=set)
    refs: list = field(default_factory=list)

    def record(self, row, agent):
        if row.get("type") == "fork-context-ref":
            if agent and row.get("agentId") != agent:
                raise Unknown("fork ref identity mismatch")
            self.refs.append(row)
        if row.get("type") == "system" and row.get("subtype") == "compact_boundary":
            self.boundary(row, agent)
        if row.get("agentId") != agent:
            return
        if isinstance(row.get("sessionId"), str):
            self.sessions.add(native_id(row["sessionId"]))
        self.tool_calls(row)

    def boundary(self, row, agent):
        uuid = native_id(row.get("uuid"))
        self.boundaries.add(uuid)
        if "forkedFrom" in row:
            self.copied.add(uuid)
        details = row.get("compactMetadata")
        if (row.get("agentId") == agent and isinstance(details, dict)
                and details.get("trigger") == "auto" and "forkedFrom" not in row):
            self.own_auto.add(uuid)

    def tool_calls(self, row):
        if row.get("type") != "assistant" or "forkedFrom" in row:
            return
        message = row.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        if not isinstance(content, list):
            return
        for block in content:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            if block.get("name") not in ("Agent", "Task"):
                continue
            tool = native_id(block.get("id"))
            uuid = native_id(row.get("uuid"))
            self.calls.setdefault(tool, set()).add(uuid)


def read_history(path, agent=None, stop=None):
    history = History()
    with regular_text(path) as stream:
        for line in stream:
            if not line.strip():
                continue
            row = json.loads(line)
            if not isinstance(row, dict):
                raise Unknown("invalid transcript row")
            history.record(row, agent)
            if stop is not None and row.get("uuid") == stop:
                return history
    if stop is not None:
        raise Unknown("fork prefix endpoint missing")
    return history


class Check:
    def __init__(self, transcript):
        self.main = transcript
        self.project = transcript.parent
        self.subagents = transcript.with_suffix("") / "subagents"
        self.paths = {}
        self.cache = {}
        self.active = set()

    def discover(self):
        for directory, _, files in os.walk(self.subagents, followlinks=False):
            for name in sorted(files):
                match = re.fullmatch(r"agent-([A-Za-z0-9_-]+)\.jsonl", name)
                if match:
                    self.paths.setdefault(match[1], []).append(Path(directory) / name)

    def history(self, path, agent=None, stop=None):
        key = (path, agent, stop)
        if key not in self.cache:
            self.cache[key] = read_history(path, agent, stop)
        return self.cache[key]

    def source_boundaries(self, path, agent=None, stop=None):
        key = (path, agent, stop)
        if key in self.active:
            raise Unknown("cyclic fork reference")
        self.active.add(key)
        try:
            history = self.history(path, agent, stop)
            result = set(history.boundaries)
            for ref in history.refs:
                session = native_id(ref.get("parentSessionId"))
                endpoint = native_id(ref.get("parentLastUuid"))
                parent = self.project / f"{session}.jsonl"
                result.update(self.source_boundaries(parent, stop=endpoint))
            return result
        finally:
            self.active.remove(key)

    def parent_path(self, path, meta, session=None):
        parent = meta.get("parentAgentId")
        if not parent:
            return (self.project / f"{session}.jsonl" if session else self.main), None
        parent = native_id(parent)
        if session:
            relative = path.parent.relative_to(self.subagents)
            return self.project / session / "subagents" / relative / f"agent-{parent}.jsonl", parent
        matches = self.paths.get(parent, [])
        if len(matches) != 1:
            raise Unknown("parent missing or ambiguous")
        return matches[0], parent

    def launch_source(self, path, meta, history):
        tool = native_id(meta.get("toolUseId"))
        parent_id = meta.get("parentAgentId")
        if parent_id is not None:
            native_id(parent_id)
        if len(self.paths.get(parent_id, [])) > 1:
            raise Unknown("ambiguous parent identity")
        candidates = []
        try:
            candidates.append(self.parent_path(path, meta))
        except Unknown:
            # An adopted instance may refer to a parent in its original session.
            if not history.sessions:
                raise
        for session in sorted(history.sessions):
            candidate = self.parent_path(path, meta, session)
            if candidate not in candidates:
                candidates.append(candidate)
        matches = []
        for parent, agent in candidates:
            try:
                source = self.history(parent, agent)
            except FileNotFoundError:
                continue
            if len(source.calls.get(tool, set())) > 1:
                raise Unknown("ambiguous launch tool id in parent")
            if len(source.calls.get(tool, set())) == 1:
                matches.append((parent, agent))
        if len(matches) != 1:
            raise Unknown("launch source missing or ambiguous")
        return matches[0]

    def count(self, agent, path):
        meta = metadata(path)
        history = self.history(path, agent)
        inherited = set()
        for ref in history.refs:
            session = native_id(ref.get("parentSessionId"))
            endpoint = native_id(ref.get("parentLastUuid"))
            inherited.update(self.source_boundaries(self.project / f"{session}.jsonl", stop=endpoint))
        if meta.get("taskKind") != "in_process_teammate":
            parent, parent_agent = self.launch_source(path, meta, history)
            inherited.update(self.source_boundaries(parent, parent_agent))
        return len(history.own_auto - inherited - history.copied)

    def reminders(self):
        self.discover()
        result = []
        for agent, paths in sorted(self.paths.items()):
            if len(paths) != 1:
                continue
            try:
                count = self.count(agent, paths[0])
            except (OSError, ValueError, UnicodeError, RecursionError):
                continue
            if count >= REMINDER_THRESHOLD:
                result.append(f"{agent}: {count}")
        return result


def run(payload):
    if not isinstance(payload, dict) or payload.get("agent_id") not in (None, ""):
        return None
    tool = payload.get("tool_name")
    if payload.get("hook_event_name") != "PostToolUse" or not isinstance(tool, str) or tool not in TOOLS:
        return None
    transcript = payload.get("transcript_path")
    if not isinstance(transcript, str) or not Path(transcript).is_absolute():
        return None
    transcript = Path(transcript)
    if transcript.suffix != ".jsonl":
        return None
    with regular_text(transcript):
        pass
    reminders = Check(transcript).reminders()
    if not reminders:
        return None
    context = ("[dispatch-contract] 子实例自身已完成的自动压缩次数达到提醒阈值：\n"
               + "\n".join(reminders)
               + "\n请检查当前交付负载，保持未完成交付的执行连续性；"
                 "此提醒不要求自动结束、关停或更换实例。"
                 "检查发生在主会话调度工具返回后，不代表同步调用期间的实时唤醒。")
    return {"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": context}}


def main():
    try:
        # Read bytes, not text: sys.stdin decodes with the process locale (GBK on
        # this platform), and GBK can pair a UTF-8 continuation byte with a
        # following backslash, swallowing it and leaving invalid JSON behind.
        # The payload is always UTF-8. json.loads accepts bytes and decodes UTF-8.
        output = run(json.loads(sys.stdin.buffer.read()))
    except (OSError, ValueError, UnicodeError, RecursionError):
        return
    if output:
        print(json.dumps(output, ensure_ascii=True))


if __name__ == "__main__":
    main()
