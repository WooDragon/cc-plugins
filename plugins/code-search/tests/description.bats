#!/usr/bin/env bats

SKILL_PATH="$BATS_TEST_DIRNAME/../skills/code-search/SKILL.md"
PLUGIN_PATH="$BATS_TEST_DIRNAME/../.claude-plugin/plugin.json"
PLUGIN_NAME="code-search"
SKILL_NAME="code-search"
BASELINE_DESCRIPTION_BYTES=1125

read_frontmatter() {
  python3 - "$SKILL_PATH" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
if not text.startswith("---\n"):
    raise SystemExit("missing frontmatter opener")
frontmatter, separator, _ = text[4:].partition("\n---\n")
if not separator:
    raise SystemExit("missing frontmatter closer")
sys.stdout.write(frontmatter + "\n")
PY
}

metadata() {
  local expression="$1" frontmatter
  frontmatter="$(read_frontmatter)" || return
  printf '%s\n' "$frontmatter" | yq -r "$expression" -
}

description_bytes() {
  python3 -c 'import sys; print(len(sys.stdin.read().strip().encode("utf-8")))' <<<"$1"
}

assert_contains_all() {
  local description="$1" phrase
  shift
  for phrase in "$@"; do
    if [[ "$description" != *"$phrase"* ]]; then
      printf 'description is missing required route category: %s\n' "$phrase" >&2
      return 1
    fi
  done
}

search_mapping_contract() {
  python3 - "$1" <<'PY'
import re
import sys

text = sys.argv[1]
separator = re.compile(r"([，,。；;\n])")
parts = separator.split(text)
segments = [part.strip() for part in parts[::2] if part.strip()]

def has_tool(segment, tool):
    pattern = rf"(?<![A-Za-z0-9_-]){re.escape(tool)}(?![A-Za-z0-9_-])"
    return re.search(pattern, segment, re.IGNORECASE) is not None

def has_definition(segment):
    return re.search(r"定义|找定义|符号定义", segment) is not None

def has_ast_structure(segment):
    return re.search(r"AST.{0,12}(?:结构|语法树)|(?:结构|语法树).{0,12}AST", segment, re.IGNORECASE) is not None

def has_caller_reference_text(segment):
    has_caller = re.search(r"调用点|caller|谁调用|调用", segment, re.IGNORECASE)
    has_reference_or_text = re.search(r"引用|纯文本|文本|字符串", segment)
    return has_caller is not None and has_reference_or_text is not None

def mapped(predicate, tool, candidates=segments):
    return any(predicate(segment) and has_tool(segment, tool) for segment in candidates)

def valid(description):
    clauses = [part.strip() for part in separator.split(description)[::2] if part.strip()]
    return (
        mapped(has_definition, "ctags", clauses)
        and mapped(has_ast_structure, "ast-grep", clauses)
        and mapped(has_caller_reference_text, "grep", clauses)
    )

def token_pattern(tool):
    return re.compile(rf"(?<![A-Za-z0-9_-]){re.escape(tool)}(?![A-Za-z0-9_-])", re.IGNORECASE)

def matching_index(predicate, tool):
    for index in range(0, len(parts), 2):
        if predicate(parts[index]) and has_tool(parts[index], tool):
            return index
    raise SystemExit(f"cannot form mutation for {tool} mapping")

if not valid(text):
    raise SystemExit("description does not bind each search intent to its required tool")
definition_index = matching_index(has_definition, "ctags")
ast_index = matching_index(has_ast_structure, "ast-grep")
swapped_parts = parts.copy()
swapped_parts[definition_index], count = token_pattern("ctags").subn("ast-grep", swapped_parts[definition_index], count=1)
if count != 1:
    raise SystemExit("could not swap definition mapping")
swapped_parts[ast_index], count = token_pattern("ast-grep").subn("ctags", swapped_parts[ast_index], count=1)
if count != 1:
    raise SystemExit("could not swap AST mapping")
if valid("".join(swapped_parts)):
    raise SystemExit("swapped definition/AST mappings were accepted")

caller_index = matching_index(has_caller_reference_text, "grep")
removed_parts = parts.copy()
removed_parts[caller_index], count = token_pattern("grep").subn("", removed_parts[caller_index], count=1)
if count != 1:
    raise SystemExit("could not remove independent grep mapping")
if valid("".join(removed_parts)):
    raise SystemExit("missing independent grep mapping was accepted")
print("correct mappings accepted; swapped and unmapped in-memory copies rejected")
PY
}

# Execute only the three marked, single-line source examples, never shell text.
source_example_scenario() {
  python3 - "$SKILL_PATH" "$BATS_TEST_TMPDIR" "$1" <<'PY'
import json
from pathlib import Path
import shlex
import subprocess
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
root = Path(sys.argv[2])
fixture = root / "Component.tsx"
tags = root / "navigation.tags"
fixture.write_text('''export function SearchPanel() {
  return <Panel active={true} />;
}
// <Panel active={true} />
const text = "<Panel active={true} />";
''', encoding="utf-8")
replacements = {"<file.tsx>": str(fixture), "<tags>": str(tags), "<symbol>": "SearchPanel"}

def example(marker):
    anchor = "# example: " + marker
    assert source.count(anchor) == 1, f"missing or duplicate source marker: {anchor}"
    command = shlex.split(source[source.index(anchor) + 1])
    return [replacements.get(arg, arg) for arg in command]

def execute(command, expected):
    result = subprocess.run(command, cwd=root, text=True, capture_output=True)
    assert result.returncode == expected, (command, result.returncode, result.stdout, result.stderr)
    return result.stdout

def assert_jsx_match(output):
    matches = json.loads(output)
    assert len(matches) == 1, matches
    match = matches[0]
    assert Path(match["file"]) == fixture, match
    assert match["range"]["start"]["line"] == 1, match
    assert match["text"] == "<Panel active={true} />", match

if sys.argv[3] == "tsx":
    command = example("tsx-node")
    assert command[:2] == ["ast-grep", "run"], command
    command += ["--json=compact"]
    assert_jsx_match(execute(command, 0))
    language = command.index("--lang") + 1
    assert command[language] == "tsx", command
    mutated = command.copy()
    mutated[language] = "typescript"
    result = subprocess.run(mutated, cwd=root, text=True, capture_output=True)
    assert result.returncode in (0, 1), (mutated, result.stderr)
    try:
        assert_jsx_match(result.stdout)
    except (AssertionError, json.JSONDecodeError):
        print("source TSX matches only the real node; tsx→typescript mutation rejected")
    else:
        raise AssertionError("known wrong TypeScript parser escaped the JSX oracle")
else:
    build = example("tags-build")
    query = example("tags-query")
    assert build[0] == "ctags" and query[0] == "readtags", (build, query)
    assert build[build.index("-f") + 1] == query[query.index("-t") + 1] == str(tags)
    execute(build, 0)
    for _ in range(2):
        output = execute(query, 0)
        entries = [line.split("\t") for line in output.splitlines()]
        assert len(entries) == 1, output
        name, path, address, *fields = entries[0]
        assert name == "SearchPanel" and Path(path) == fixture, entries
        assert address.startswith("/^export function SearchPanel()"), address
        assert "kind:f" in fields or "f" in fields, fields
    print("source ctags/readtags examples navigate the real TSX definition twice")
PY
}

@test "description metadata stays registered and shorter than its baseline" {
  local name description bytes
  name="$(metadata '.name')"
  description="$(metadata '.description')"
  [ "$name" = "$PLUGIN_NAME" ]
  [ "$(metadata '.name | tag')" = "!!str" ]
  [ "$(metadata '.description | tag')" = "!!str" ]
  [ -n "$description" ]

  run jq -e --arg name "$PLUGIN_NAME" --arg skill "./skills/$SKILL_NAME" \
    '.name == $name and .skills == [$skill]' "$PLUGIN_PATH"
  [ "$status" -eq 0 ]

  bytes="$(description_bytes "$description")"
  [ "$bytes" -lt "$BASELINE_DESCRIPTION_BYTES" ]
}

@test "description maps definition, AST, and caller/text intents to their tools" {
  local description
  description="$(metadata '.description')"
  assert_contains_all "$description" "调用链" "影响面" "LSP/SCIP"
  run search_mapping_contract "$description"
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    return 1
  fi
}

@test "Given a known file and exact name, local text lookup needs no index" {
  run python3 - "$SKILL_PATH" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
rows = [line for line in text.splitlines() if line.startswith("|")]
assert any("已知文件" in row and "准确名称" in row and "grep" in row for row in rows)
assert any("消歧" in row and "ctags" in row for row in rows)
assert "不要求先建索引" in text
assert "O(1)" not in text
assert "旧式裸 `sg -p` 不对" not in text
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "Given incomplete searches, scope and empty results do not prove absence or completeness" {
  run python3 - "$SKILL_PATH" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
for boundary in ("tracked", "未跟踪", "已跟踪生成物", "当前源码", "空结果不证明", "截断", "不完整"):
    assert boundary in text, f"missing search boundary: {boundary}"
assert "天然避开" not in text
assert "typescript`，TSX 用 `tsx`，JS/JSX 用 `javascript`" in text
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "Given real JSX and lookalike text, the source TSX command matches only the node" {
  command -v ast-grep >/dev/null || skip "ast-grep missing; required acceptance incomplete"
  run source_example_scenario tsx
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  [[ "$output" == *"tsx→typescript mutation rejected"* ]]
}

@test "Given repeated TSX navigation, source ctags/readtags commands share temporary tags" {
  command -v ctags >/dev/null || skip "ctags missing; required acceptance incomplete"
  command -v readtags >/dev/null || skip "readtags missing; required acceptance incomplete"
  run ctags --version
  [[ "$output" == *"Universal Ctags"* ]] || skip "Universal Ctags missing; required acceptance incomplete"
  run source_example_scenario tags
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "Given packaged guidance, versions and short-path descriptions stay synchronized" {
  local marketplace="$BATS_TEST_DIRNAME/../../../.claude-plugin/marketplace.json"
  [ "$(jq -r '.version' "$PLUGIN_PATH")" = "1.1.2" ]
  [ "$(jq -r '.plugins[] | select(.name == "code-search") | .version' "$marketplace")" = "1.1.2" ]
  run python3 - "$BATS_TEST_DIRNAME/../README.md" "$BATS_TEST_DIRNAME/../../../CLAUDE.md" <<'PY'
from pathlib import Path
import sys
readme = Path(sys.argv[1]).read_text()
overview = Path(sys.argv[2]).read_text().split("### 代码搜索技能\n", 1)[1].split("\n### ", 1)[0]
assert "never grep for definitions" not in readme
assert "known file" in readme and "exact name" in readme
assert "tracked" in readme and "untracked" in readme
assert "禁 grep 找定义" not in overview
assert "已知文件" in overview and "grep" in overview
PY
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}
