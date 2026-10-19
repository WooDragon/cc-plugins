#!/usr/bin/env bats

setup() {
  ROOT="${BATS_TEST_DIRNAME}/.."
  HOOK="$ROOT/hooks/dispatch-convergence-reminder.sh"
  STDERR_FILE="$BATS_TEST_TMPDIR/hook.stderr"
  EXPECTED='以下用于判断下一步，不需要逐项作答。
这是用户要求的吗？这是必要的吗？有什么实际可达的证据？省略它会导致当前哪项验收失败？
已有证据对最终状态仍然有效，就复用。
不要仅为了满足本 Skill，再增加一轮最终审计。'
}

invoke_hook() {
  local payload="$1"
  shift
  run bash -c 'payload=$1; shift; printf "%s" "$payload" | env "$@" /bin/bash "$HOOK" 2>"$STDERR_FILE"' _ "$payload" "$@"
  [ "$status" -eq 0 ]
  [ ! -s "$STDERR_FILE" ]
}

assert_context() {
  printf '%s' "$output" | jq -es --arg expected "$EXPECTED" '
    length == 1 and (.[0] == {hookSpecificOutput: {
      hookEventName: "PostToolUse", additionalContext: $expected}})'
}

@test "convergence: completed Agent and Task remind callers with or without agent_id" {
  export HOOK STDERR_FILE
  local tool caller payload
  for tool in Agent Task; do
    for caller in missing empty pm; do
      payload=$(jq -nc --arg tool "$tool" --arg caller "$caller" '
        {hook_event_name:"PostToolUse", tool_name:$tool,
         tool_response:{status:"completed"}} +
        (if $caller == "missing" then {} elif $caller == "empty" then {agent_id:""}
         else {agent_id:$caller} end)')
      invoke_hook "$payload"
      assert_context
    done
  done
}

@test "convergence: launch and unknown statuses stay silent even with synchronous input" {
  export HOOK STDERR_FILE
  local state payload
  for state in async_launched teammate_spawned remote_launched running failed unknown COMPLETED ''; do
    payload=$(jq -nc --arg state "$state" '{hook_event_name:"PostToolUse",
      tool_name:"Agent",tool_input:{run_in_background:false},tool_response:{status:$state}}')
    invoke_hook "$payload"
    [ -z "$output" ]
  done
}

@test "convergence: completed is return status, not business success or input background flag" {
  export HOOK STDERR_FILE
  invoke_hook '{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"run_in_background":true},"tool_response":{"status":"completed","content":"FAILED: acceptance not met"}}'
  assert_context
}

@test "convergence: unrelated tools and events stay silent" {
  export HOOK STDERR_FILE
  local tool event payload
  for tool in Agent Task SendMessage TaskOutput Bash AgentExtra mcp__x__Agent TaskCreate ''; do
    for event in PostToolUse PreToolUse PostToolUseFailure SubagentStop ''; do
      if [[ "$event" == PostToolUse && ( "$tool" == Agent || "$tool" == Task ) ]]; then
        continue
      fi
      payload=$(jq -nc --arg tool "$tool" --arg event "$event" '{hook_event_name:$event,
        tool_name:$tool,tool_response:{status:"completed"}}')
      invoke_hook "$payload"
      [ -z "$output" ]
    done
  done
}

@test "convergence: empty, damaged, multiple JSON values and wrong field types stay silent" {
  export HOOK STDERR_FILE
  local payload field value
  for payload in '' '   ' '{' 'null' '[]' 'true' '42' '"text"' '{}' \
    '{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_response":{"status":"completed"}} {' \
    '{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_response":{"status":"completed"}} {}'; do
    invoke_hook "$payload"
    [ -z "$output" ]
  done
  for field in hook_event_name tool_name tool_response status; do
    for value in missing null '""' 7 true '[]' '{}'; do
      payload=$(jq -nc --arg field "$field" --arg value "$value" '
        {hook_event_name:"PostToolUse",tool_name:"Agent",tool_response:{status:"completed"}}
        | (if $field == "status" then ["tool_response","status"] else [$field] end) as $path
        | if $value == "missing" then delpaths([$path]) else setpath($path; $value|fromjson) end')
      invoke_hook "$payload"
      [ -z "$output" ]
    done
  done
}

@test "convergence: missing jq and a failing jq leave both streams empty" {
  export HOOK STDERR_FILE
  mkdir "$BATS_TEST_TMPDIR/bin"
  invoke_hook '{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_response":{"status":"completed"}}' "PATH=$BATS_TEST_TMPDIR/bin"
  [ -z "$output" ]
  printf '%s\n' '#!/bin/bash' 'printf "partial JSON"' 'printf "failure" >&2' 'exit 1' > "$BATS_TEST_TMPDIR/bin/jq"
  chmod +x "$BATS_TEST_TMPDIR/bin/jq"
  invoke_hook '{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_response":{"status":"completed"}}' "PATH=$BATS_TEST_TMPDIR/bin"
  [ -z "$output" ]
}

@test "convergence: repeated matches are identical and create no runtime files" {
  run python3 - "$HOOK" "$BATS_TEST_TMPDIR" <<'PY'
import json, os, pathlib, subprocess, sys
hook = pathlib.Path(sys.argv[1]).resolve()
root = pathlib.Path(sys.argv[2])
(root / "home").mkdir()
(root / "work").mkdir()
env = dict(os.environ, HOME=str(root / "home"), TMPDIR=str(root), CLAUDE_PLUGIN_ROOT=str(hook.parent.parent))
payload = json.dumps(dict(hook_event_name="PostToolUse", tool_name="Agent", tool_response={"status":"completed"}))
def snapshot():
    return {str(p.relative_to(root)): (p.is_dir(), None if p.is_dir() else p.read_bytes()) for p in root.rglob("*")}
before = snapshot()
results = [subprocess.run(["/bin/bash", str(hook)], input=payload, text=True,
                          capture_output=True, cwd=root / "work", env=env, timeout=5) for _ in range(2)]
assert all(r.returncode == 0 and not r.stderr and r.stdout for r in results), results
assert results[0].stdout == results[1].stdout
assert before == snapshot(), "hook created or modified runtime files"
PY
  [ "$status" -eq 0 ]
}

@test "convergence: production registration matches exactly once and runs from a path with spaces" {
  run python3 - "$ROOT" "$BATS_TEST_TMPDIR" <<'PY'
import json, os, pathlib, re, shutil, subprocess, sys
root = pathlib.Path(sys.argv[1]).resolve()
copy = pathlib.Path(sys.argv[2]) / "plugin with spaces"
shutil.copytree(root, copy)
hooks = json.loads((copy / "hooks/hooks.json").read_text())["hooks"]
for tool in ("Agent", "Task", "SendMessage", "TaskOutput", "AgentExtra", "mcp__x__Agent", "TaskCreate"):
    entries = [h for block in hooks.get("PostToolUse", []) if re.search(block["matcher"], tool)
               for h in block["hooks"] if "dispatch-convergence-reminder.sh" in h["command"]]
    assert len(entries) == (1 if tool in ("Agent", "Task") else 0), (tool, entries)
    for entry in entries:
        assert entry["type"] == "command" and entry["timeout"] == 5, entry
        env = dict(os.environ, CLAUDE_PLUGIN_ROOT=str(copy))
        payload = json.dumps(dict(hook_event_name="PostToolUse", tool_name=tool, tool_response={"status":"completed"}))
        result = subprocess.run(["/bin/bash", "-c", entry["command"]], input=payload,
                                text=True, capture_output=True, env=env, timeout=6)
        assert result.returncode == 0 and not result.stderr, result
        assert json.loads(result.stdout)["hookSpecificOutput"]["hookEventName"] == "PostToolUse"
all_entries = [(event, h) for event, blocks in hooks.items() for block in blocks
               for h in block["hooks"] if "dispatch-convergence-reminder.sh" in h["command"]]
assert len(all_entries) == 1 and all_entries[0][0] == "PostToolUse", all_entries
PY
  [ "$status" -eq 0 ]
}
