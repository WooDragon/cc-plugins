#!/usr/bin/env bash
# PreToolUse hook (Bash): guards against accidental direct push to
# main/master branches (a slip-catcher, not a hard security boundary —
# see README "Known limitations" for evasion vectors this does not cover).
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

# Split compound command into sub-statements on &&, ||, ;, newline
# then check each for git push to main/master
check_push_target() {
  local stmt="$1"

  # Strip leading whitespace
  stmt="${stmt#"${stmt%%[![:space:]]*}"}"

  # Must contain "git" in command position followed (eventually) by "push"
  # Allow global options between git and push: git -C path push, git -c k=v push
  #
  # NOTE: [[:space:]] (not \s) throughout this function — \s is a GNU
  # grep/sed extension. macOS ships BSD grep/sed as /usr/bin/{grep,sed},
  # which do NOT support \s: it silently fails to match as a metachar,
  # degrading the sed extraction below to a no-op (push_args ends up as
  # the whole original statement instead of just the push arguments).
  if ! grep -Eq '(^|sudo[[:space:]]+)git([[:space:]]+(-[a-zA-Z][^ ]*|[^ -][^ ]*))*[[:space:]]+push' <<< "$stmt"; then
    return 1
  fi

  # Extract everything after "push" (the push arguments)
  local push_args
  push_args=$(sed -E 's/^.*git([[:space:]]+(-[a-zA-Z][^ ]*|[^ -][^ ]*))*[[:space:]]+push//' <<< "$stmt")

  # Strip quote characters so quoted branch names (e.g. "main", 'main')
  # line up with the same bare word-boundary checks below.
  push_args=$(printf '%s' "$push_args" | tr -d "\"'")

  # --all / --mirror → blocks all branches including main
  if grep -Eq '(^|[[:space:]])--(all|mirror)([[:space:]]|$)' <<< "$push_args"; then
    return 0
  fi

  # Check for main/master as exact branch name (optionally prefixed with
  # the force-push shorthand "+" and/or the full "refs/heads/" ref path)
  # or as a colon-refspec destination.
  # Word-boundary: preceded by space/start(/plus), followed by space/end
  # Bare/prefixed: main, +main, refs/heads/main, +refs/heads/main
  # Refspec: :main, :refs/heads/main, :master, :refs/heads/master
  if grep -Eq '(^|[[:space:]])\+?(refs/heads/)?(main|master)([[:space:]]|$)' <<< "$push_args"; then
    return 0
  fi
  if grep -Eq ':(refs/heads/)?(main|master)([[:space:]]|$)' <<< "$push_args"; then
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
