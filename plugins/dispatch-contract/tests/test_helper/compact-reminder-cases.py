"""Temporary native JSONL scenarios; invoke the shipped hook via hooks.json."""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(sys.argv[1]).resolve()

# Mirrors REMINDER_THRESHOLD in hooks/subagent-compact-reminder.py. Scenarios are
# written in terms of it so a threshold change is one edit, not a hunt for
# literals that happen to mean "one short of the threshold".
THRESHOLD = 2
BELOW = THRESHOLD - 1


def write(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row) + "\n" for row in rows))
    return path


def boundary(agent, uuid, **fields):
    return dict(type="system", subtype="compact_boundary", agentId=agent,
                uuid=uuid, sessionId="session", compactMetadata={"trigger": "auto"}, **fields)


def compacts(agent, count, prefix=None):
    return [boundary(agent, f"{prefix or agent}-{n}") for n in range(count)]


def call_row(agent, tool="launch", fork=False):
    row = dict(type="assistant", uuid=f"call-{tool}", sessionId="session",
               message={"content": [{"type": "tool_use", "id": tool, "name": "Agent",
                                      "input": {"subagent_type": "fork" if fork else "dev"}}]})
    if agent:
        row["agentId"] = agent
    return row


def bash_path():
    path = shutil.which("bash")
    if path is None:
        raise SystemExit("bash not found on PATH; the compact-reminder harness needs one")
    return path


class Fixture:
    def __init__(self, directory):
        self.project = Path(directory)
        self.main = write(self.project / "session.jsonl", [call_row(None)])
        self.sub = self.project / "session" / "subagents"
        self.sub.mkdir(parents=True)
        self.payload = dict(hook_event_name="PostToolUse", tool_name="Agent",
                            session_id="session", transcript_path=str(self.main))

    def agent(self, agent, rows, meta=None, subdir=""):
        path = write(self.sub / subdir / f"agent-{agent}.jsonl", rows)
        if meta is None:
            meta = {"taskKind": "in_process_teammate", "name": agent, "spawnDepth": 0}
        path.with_suffix(".meta.json").write_text(json.dumps(meta))
        return path

    def run(self, payload=None, env=None, ensure_ascii=True):
        hooks = json.loads((ROOT / "hooks/hooks.json").read_text())["hooks"]
        entries = [h for block in hooks.get("PostToolUse", [])
                   if re.fullmatch(block["matcher"], "Agent") for h in block["hooks"]
                   if "subagent-compact-reminder" in h["command"]]
        assert len(entries) == 1, "production PostToolUse compact reminder must be wired exactly once"
        command = entries[0]["command"].replace("${CLAUDE_PLUGIN_ROOT}", str(ROOT))
        argv = shlex.split(command)
        assert argv[0] == "bash", argv
        argv[0] = bash_path()
        result = subprocess.run(argv,
                                input=json.dumps(payload or self.payload, ensure_ascii=ensure_ascii),
                                text=True, encoding="utf-8", capture_output=True, timeout=8, env=env)
        assert result.returncode == 0, (result.returncode, result.stderr)
        assert not result.stderr, result.stderr
        if not result.stdout:
            return ""
        # The reminder text is Chinese. Emitting it raw makes the wire bytes
        # locale-encoded on a non-UTF-8 console, which the consumer cannot
        # decode. Asserting on the bytes keeps this platform-independent.
        assert result.stdout.isascii(), "hook stdout must be ASCII-escaped JSON"
        out = json.loads(result.stdout)
        assert set(out) == {"hookSpecificOutput"}, out
        specific = out["hookSpecificOutput"]
        assert specific["hookEventName"] == "PostToolUse", out
        assert isinstance(specific["additionalContext"], str), out
        return specific["additionalContext"]

    def expect(self, agent, count):
        text = self.run()
        assert f"{agent}: {count}" in text, (agent, count, text)
        assert "未完成交付" in text and "负载" in text, text
        return text


def thresholds(f):
    for count in (0, BELOW, THRESHOLD, THRESHOLD + 1):
        path = f.agent("pm", compacts("pm", count))
        before = {str(p): p.read_bytes() for p in f.project.rglob("*") if p.is_file()}
        for _ in range(2):
            if count < THRESHOLD:
                assert f.run() == "", count
            else:
                f.expect("pm", count)
        after = {str(p): p.read_bytes() for p in f.project.rglob("*") if p.is_file()}
        assert before == after, "hook must not create state or change logs"
    # Resume extends the same file; a newly-created instance starts independently.
    write(path, compacts("pm", 5))
    f.agent("new", compacts("new", BELOW))
    assert "new:" not in f.expect("pm", 5)


def events(f):
    write(f.main, compacts(None, 6) + [call_row(None)])
    assert f.run() == "", "main is never a reminder object"
    rows = compacts("worker", BELOW)
    rows += [rows[0], boundary("worker", "manual"),
             {"type": "system", "subtype": "pre_compact", "agentId": "worker", "uuid": "attempt"},
             boundary("other", "foreign"), boundary("worker", "copied", forkedFrom={"agentId": "old"})]
    rows[BELOW + 1]["compactMetadata"]["trigger"] = "manual"
    rows += [boundary("worker", "copied")]
    f.agent("worker", rows)
    assert f.run() == "", "manual/attempt/duplicate/foreign/forkedFrom must not count"
    f.agent("worker", rows + [boundary("worker", "third")])
    assert "SECRET_PROMPT" not in f.expect("worker", THRESHOLD)


def inheritance(f):
    inherited = compacts(None, 4, "inherited")
    write(f.main, inherited + [call_row(None, fork=True)])
    copied = [dict(row, agentId="child") for row in inherited]
    f.agent("child", copied + compacts("child", BELOW), {"toolUseId": "launch", "isFork": True})
    assert f.run() == "", "root fork copied UUIDs with rewritten agentId are inherited"
    f.agent("child", copied + compacts("child", THRESHOLD), {"toolUseId": "launch", "isFork": True})
    f.expect("child", THRESHOLD)
    parent = compacts("parent", 4, "nested-old") + [call_row("parent", "nested", True)]
    f.agent("parent", parent)
    f.agent("nested", [dict(r, agentId="nested") for r in parent[:4]] + compacts("nested", BELOW),
            {"parentAgentId": "parent", "toolUseId": "nested", "isFork": True})
    assert "nested:" not in f.run(), "nested inherited rows must be excluded"
    f.agent("nested", [dict(r, agentId="nested") for r in parent[:4]] + compacts("nested", THRESHOLD),
            {"parentAgentId": "parent", "toolUseId": "nested", "isFork": True})
    f.expect("nested", THRESHOLD)


def ref(agent, session, last):
    return dict(type="fork-context-ref", agentId=agent, parentSessionId=session,
                parentLastUuid=last, contextLength=4)


def parents(f):
    write(f.project / "older.jsonl", compacts(None, 4, "external"))
    write(f.project / "old.jsonl", [ref("unused", "older", "external-3"),
                                  {"type": "user", "uuid": "old-end", "parentUuid": "external-3"}])
    parent_rows = [ref("parent", "old", "old-end"), call_row("parent", "nested", True)]
    f.agent("parent", parent_rows)
    # Same tool id in main is not the child's parent, even if found first.
    write(f.main, [call_row(None, "nested", True)])
    meta = {"parentAgentId": "parent", "toolUseId": "nested", "isFork": True}
    copied = compacts("child", 4, "external")
    f.agent("child", copied + compacts("child", BELOW), meta)
    assert f.run() == "", "parent's external fork prefix must participate in exclusion"
    f.agent("child", copied + compacts("child", THRESHOLD), meta)
    f.expect("child", THRESHOLD)
    # A direct root ref omits its prefix locally and still counts own new events.
    f.agent("rootfork", [ref("rootfork", "old", "old-end")] + compacts("rootfork", THRESHOLD),
            {"toolUseId": "nested", "isFork": True})
    f.expect("rootfork", THRESHOLD)
    f.agent("rootfork", [ref("rootfork", "old", "old-end")]
            + compacts("rootfork", 4, "external") + compacts("rootfork", BELOW),
            {"toolUseId": "nested", "isFork": True})
    assert "rootfork:" not in f.run(), "direct fork ref must also exclude locally copied prefix UUIDs"


def adopt(f):
    rows = compacts("adopted", THRESHOLD)
    for row in rows:
        row["sessionId"] = "previous"
    target = write(f.project / "adopted-source.jsonl", rows)
    path = f.agent("adopted", [], subdir="native/subdir")
    path.unlink()
    try:
        path.symlink_to(target)
    except OSError:
        print(f"scenario group adopt skipped on {sys.platform}: symlink requires privilege")
        return False
    f.expect("adopted", THRESHOLD)
    # An ordinary adopted instance locates its original explicitly named session.
    write(f.project / "previous.jsonl", [call_row(None, "old-launch")])
    f.agent("adopted", rows, {"toolUseId": "old-launch"}, subdir="native/subdir")
    f.expect("adopted", THRESHOLD)
    return True


def unknown(f):
    f.agent("good", compacts("good", THRESHOLD))
    bad = f.agent("bad", compacts("bad", 5), {"toolUseId": "missing"})
    assert "bad:" not in f.expect("good", THRESHOLD)
    bad.with_suffix(".meta.json").unlink()
    assert "bad:" not in f.expect("good", THRESHOLD)
    bad.with_suffix(".meta.json").write_text('{"taskKind":')
    assert "bad:" not in f.expect("good", THRESHOLD)
    f.agent("bad", compacts("bad", 5))
    with bad.open("a") as stream:
        stream.write('{"type":')
    assert "bad:" not in f.expect("good", THRESHOLD)
    f.agent("cycle", [ref("cycle", "missing", "absent")] + compacts("cycle", 4))
    assert "cycle:" not in f.expect("good", THRESHOLD)
    f.agent("wrong", compacts("wrong", 4), {"parentAgentId": "missing", "toolUseId": "launch"})
    assert "wrong:" not in f.expect("good", THRESHOLD)
    # Ambiguous parent identity must not choose a convenient duplicate.
    f.agent("duplicate", [call_row("duplicate", "dup")])
    f.agent("duplicate", [call_row("duplicate", "dup")], subdir="other")
    f.agent("ambiguous", compacts("ambiguous", 4), {"parentAgentId": "duplicate", "toolUseId": "dup"})
    assert "ambiguous:" not in f.expect("good", THRESHOLD)
    f.agent("badshape", compacts("badshape", 4), {"parentAgentId": [], "toolUseId": "launch"})
    assert "badshape:" not in f.expect("good", THRESHOLD)
    write(f.project / "cycle-session.jsonl", [ref("cycle-parent", "cycle-session", "end"),
                                             {"type": "user", "uuid": "end"}])
    f.agent("cycle", [ref("cycle", "cycle-session", "end")] + compacts("cycle", 4))
    assert "cycle:" not in f.expect("good", THRESHOLD)
    parent = f.agent("brokenparent", [call_row("brokenparent", "broken-launch")])
    with parent.open("a") as stream:
        stream.write('{"unfinished":')
    f.agent("unproven", compacts("unproven", 4),
            {"parentAgentId": "brokenparent", "toolUseId": "broken-launch"})
    assert "unproven:" not in f.expect("good", THRESHOLD)


def wiring(f):
    f.agent("child", compacts("child", THRESHOLD))
    hooks = json.loads((ROOT / "hooks/hooks.json").read_text())["hooks"]
    blocks = [b for b in hooks.get("PostToolUse", [])
              if any("subagent-compact-reminder" in h["command"] for h in b["hooks"])]
    assert len(blocks) == 1, "reminder must have one PostToolUse registration"
    matcher = blocks[0]["matcher"]
    for tool in ("Agent", "Task", "SendMessage", "TaskOutput"):
        assert re.search(matcher, tool), (matcher, tool)
        f.expect("child", THRESHOLD) if tool == "Agent" else None
        assert f"child: {THRESHOLD}" in f.run(dict(f.payload, tool_name=tool))
    for tool in ("Bash", "AgentExtra", "mcp__x__Agent", "TaskCreate", "OtherSendMessage"):
        assert not re.search(matcher, tool), (matcher, tool)
        assert f.run(dict(f.payload, tool_name=tool)) == ""
    assert f.run(dict(f.payload, agent_id="subagent")) == ""
    assert f.run(dict(f.payload, hook_event_name="PreToolUse")) == ""
    assert f"child: {THRESHOLD}" in f.run(dict(f.payload, agent_id=""))
    # Non-ASCII payloads must survive stdin decoding. GBK can pair a UTF-8
    # continuation byte with a following backslash, so a Windows path inside a
    # Chinese message is the shape that used to fail open silently.
    hostile = dict(f.payload, note="请看中" + chr(92) + "Github 和 引号")
    assert f"child: {THRESHOLD}" in f.run(hostile, ensure_ascii=False)


def files(f):
    f.agent("good", compacts("good", THRESHOLD))
    assert f.run(dict(f.payload, transcript_path=str(f.project / "missing.jsonl"))) == ""
    for data in ("", "{", "[]", "null", '{"agent_id":"subagent"}'):
        result = subprocess.run([bash_path(), str(ROOT / "hooks/subagent-compact-reminder.sh")],
                                input=data, text=True, capture_output=True, timeout=8)
        assert result.returncode == 0 and not result.stdout, (data, result)
    # The guard under test is "no python3 -> exit 0 silently". Blanking PATH
    # also strips the MSYS bin directory bash itself needs to start, so keep
    # that one directory and prove the interpreter is still absent.
    path = str(f.project / "no-tools")
    if sys.platform == "win32":
        path += os.pathsep + str(Path(bash_path()).parent)
    env = dict(os.environ, PATH=path)
    # BASH_ENV is startup code for every non-interactive shell. This host sets
    # it to a shim that prepends an interpreter directory to PATH, which would
    # defeat the isolation this check exists to create.
    env.pop("BASH_ENV", None)
    probe = subprocess.run([bash_path(), "-c", "command -v python3"], env=env,
                           capture_output=True, text=True)
    assert not probe.stdout.strip(), ("PATH still resolves python3", probe.stdout)
    assert f.run(env=env) == ""
    if not hasattr(os, "mkfifo"):
        print(f"scenario group files ran without the FIFO part on {sys.platform}: no os.mkfifo")
        return True
    fifo = f.project / "fifo.jsonl"
    os.mkfifo(fifo)
    assert f.run(dict(f.payload, transcript_path=str(fifo))) == ""
    f.agent("fifo", compacts("fifo", 4))
    side = f.sub / "agent-fifo.jsonl"
    side.unlink()
    os.mkfifo(side)
    f.expect("good", THRESHOLD)
    side.unlink()
    side.mkdir()
    f.expect("good", THRESHOLD)
    return True


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="compact-reminder-") as directory:
        result = globals()[sys.argv[2]](Fixture(directory))
    if result is False:
        print(f"scenario group {sys.argv[2]} skipped")
    else:
        print(f"scenario group {sys.argv[2]} passed")
