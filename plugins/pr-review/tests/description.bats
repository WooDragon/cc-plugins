#!/usr/bin/env bats

SKILL_PATH="$BATS_TEST_DIRNAME/../skills/pr-review/SKILL.md"
PLUGIN_PATH="$BATS_TEST_DIRNAME/../.claude-plugin/plugin.json"
PLUGIN_NAME="pr-review"
SKILL_NAME="pr-review"
BASELINE_DESCRIPTION_BYTES=1485

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

@test "description preserves open-PR scope and four backend route categories" {
  local description
  description="$(metadata '.description')"
  local normalized_description
  normalized_description="$(printf '%s' "$description" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  assert_contains_all "$normalized_description" \
    "已开的 github pr" "本地未提交 working diff" \
    "本地未提交 working diff 的即时 review 走 /code-review" \
    "grok" "claude" "codex" "copilot" "重新触发" "状态查询" \
    "grok/claude 默认自动路由" "codex 显式选择" \
    "copilot 异步回帖 pr"
  [[ "$description" == *"首次触发"* || "$description" == *"gh 触发"* ]]
  [[ "$description" == *"异步"* ]]
}
