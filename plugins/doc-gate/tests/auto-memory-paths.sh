#!/usr/bin/env bash
# Execute the shared auto-memory path matrix under the caller's Bash binary.
set -u

fixture_path="${1:?fixture path is required}"
exclude_script="${2:?exclude script is required}"
root="/tmp/auto-memory-fixture/.claude"
ordinary_root="/tmp/auto-memory-fixture/ordinary"
case_count=0

if ! expected_count=$(jq -er \
  'if (type == "array" and length > 0) then length else error("fixture must be a non-empty array") end' \
  "$fixture_path"); then
  printf 'invalid auto-memory fixture: %s\n' "$fixture_path" >&2
  exit 1
fi

source "$exclude_script"

while IFS= read -r -d $'\036' path && \
      IFS= read -r -d $'\036' case_root && \
      IFS= read -r -d $'\036' expected; do
  path="${path//ORDINARY_ROOT/$ordinary_root}"
  path="${path//ROOT/$root}"
  case_root="${case_root//ORDINARY_ROOT/$ordinary_root}"
  case_root="${case_root//ROOT/$root}"
  if doc_gate_is_auto_memory_path "$path" "$case_root"; then
    actual=0
  else
    actual=1
  fi
  if [ "$actual" -ne "$expected" ]; then
    printf 'case %s failed: path=%q root=%q expected=%s actual=%s\n' \
      "$case_count" "$path" "$case_root" "$expected" "$actual" >&2
    exit 1
  fi
  case_count=$((case_count + 1))
done < <(jq -j '.[] | .path, "", .root, "", (if .expected then "0" else "1" end), ""' "$fixture_path")

if [ "$case_count" -ne "$expected_count" ]; then
  printf 'auto-memory matrix count mismatch: expected=%s actual=%s\n' \
    "$expected_count" "$case_count" >&2
  exit 1
fi
printf 'auto-memory shared cases=%s\n' "$case_count"
