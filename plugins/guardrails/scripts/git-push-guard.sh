#!/usr/bin/env bash
# PreToolUse hook (Bash): block git push to main/master branches.
#
# Fail-open: parse errors, missing fields, or ambiguous commands pass through.
# Temporary bypass: export ALLOW_PUSH_MAIN=1

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_gate_common.sh"

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

# Fast path: no git mention at all
[[ "$INPUT" != *"git"* ]] && exit 0
[[ "$INPUT" != *"push"* ]] && exit 0

# Bypass switch
_gate_bypass_on ALLOW_PUSH_MAIN && exit 0

COMMAND=$(_gate_field "$INPUT" '.tool_input.command // empty') || exit 0
[ -z "$COMMAND" ] && exit 0
[[ "$COMMAND" != *"push"* ]] && exit 0

# Split compound command into sub-statements on &&, ||, ;, |, newline
# then check each for git push to main/master
check_push_target() {
  local stmt="$1"

  # Strip leading whitespace
  stmt="${stmt#"${stmt%%[![:space:]]*}"}"

  # Must contain "git" in command position followed (eventually) by "push"
  # Allow global options between git and push: git -C path push, git -c k=v push
  if ! grep -Eq '(^|sudo\s+)git(\s+(-[a-zA-Z][^ ]*|[^ -][^ ]*))*\s+push' <<< "$stmt"; then
    return 1
  fi

  # Extract everything after "push" (the push arguments)
  local push_args
  push_args=$(sed -E 's/^.*git(\s+(-[a-zA-Z][^ ]*|[^ -][^ ]*))*\s+push//' <<< "$stmt")

  # --all / --mirror → blocks all branches including main
  if grep -Eq '(^|\s)--(all|mirror)(\s|$)' <<< "$push_args"; then
    return 0
  fi

  # Check for main/master as exact branch name or in refspec
  # Word-boundary: preceded by space/start, followed by space/end/colon
  # Refspec: :main, :refs/heads/main, :master, :refs/heads/master
  if grep -Eq '(^|\s)(main|master)(\s|$)' <<< "$push_args"; then
    return 0
  fi
  if grep -Eq ':(refs/heads/)?(main|master)(\s|$)' <<< "$push_args"; then
    return 0
  fi

  return 1
}

# Split on ;, &&, ||, newline — process each sub-statement
while IFS= read -r stmt; do
  if [ -n "$stmt" ] && check_push_target "$stmt"; then
    printf '[git-push-guard] 禁止直接 push 到 main/master。请推送到功能分支并提 PR。\n' >&2
    printf '[git-push-guard] 无特殊情况不得绕过此检查。紧急放行: export ALLOW_PUSH_MAIN=1\n' >&2
    exit 2
  fi
done < <(printf '%s\n' "$COMMAND" | sed -E 's/(\&\&|\|\||;)/\n/g')

exit 0
