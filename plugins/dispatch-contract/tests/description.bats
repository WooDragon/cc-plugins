#!/usr/bin/env bats

SKILL_PATH="$BATS_TEST_DIRNAME/../skills/subagent-dispatch/SKILL.md"
PLUGIN_PATH="$BATS_TEST_DIRNAME/../.claude-plugin/plugin.json"
PLUGIN_NAME="dispatch-contract"
SKILL_NAME="subagent-dispatch"
BASELINE_DESCRIPTION_BYTES=1388

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

@test "description metadata stays registered and shorter than its baseline" {
  local name description bytes
  name="$(metadata '.name')"
  description="$(metadata '.description')"
  [ "$name" = "$SKILL_NAME" ]
  [ "$(metadata '.name | tag')" = "!!str" ]
  [ "$(metadata '.description | tag')" = "!!str" ]
  [ -n "$description" ]

  run jq -e --arg name "$PLUGIN_NAME" --arg skill "./skills/$SKILL_NAME" \
    '.name == $name and .skills == [$skill]' "$PLUGIN_PATH"
  [ "$status" -eq 0 ]

  bytes="$(description_bytes "$description")"
  [ "$bytes" -lt "$BASELINE_DESCRIPTION_BYTES" ]
}

@test "description preserves dispatch necessity and route boundaries" {
  local description
  description="$(metadata '.description')"
  assert_contains_all "$description" \
    "派发必要性" "证据缺口" "卸载" "模型档位" "Explore" "回传" \
    "活性" "TaskStop" "JSON schema" "persona" "Team"
  [[ "$description" == *"Workflow JSON schema"* || "$description" == *"Workflow agent()"* ]]
  [[ "$description" == *"team-ops"* || "$description" == *"Team 的适用范围"* ]]
}
