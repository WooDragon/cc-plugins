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
  run search_mapping_contract "$description"
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    return 1
  fi
}
