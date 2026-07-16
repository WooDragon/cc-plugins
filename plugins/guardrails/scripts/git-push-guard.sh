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

# Protected branch names (space-separated), default main/master. Built into
# an alternation fragment for the branch-matching regexes below. Only plain
# word chars are expected; names containing regex metacharacters are a
# documented limitation (see README).
PROTECTED_BRANCHES="${PROTECTED_BRANCHES:-main master}"
PROTECTED_ALT=$(printf '%s' "$PROTECTED_BRANCHES" | tr -s '[:space:]' '|')
PROTECTED_ALT="${PROTECTED_ALT#|}"
PROTECTED_ALT="${PROTECTED_ALT%|}"
[ -z "$PROTECTED_ALT" ] && exit 0

# Strip a leading run of prefix tokens that precede the actual `git` command
# so alternate invocation shapes normalize to a bare `git ... push ...`:
#   - environment assignments   GIT_DIR=.git git push ...   (VAR=val)
#   - sudo (and its own flags)   sudo -E git push ...
#   - env                        env git push ...
# This is a slip-catcher: `sudo -u user`, nested shells (bash -c), etc. are
# still out of scope (see README "Known limitations").
normalize_git_prefix() {
  local stmt="$1" tok
  # Strip leading whitespace each round.
  while :; do
    stmt="${stmt#"${stmt%%[![:space:]]*}"}"
    tok="${stmt%%[[:space:]]*}"
    case "$tok" in
      # env-var assignment: NAME=value (NAME starts with letter/underscore)
      [A-Za-z_]*=*) ;;
      sudo)         ;;
      env)          ;;
      # sudo/env flags (e.g. -E, -i) — only stripped mid-prefix, i.e. after
      # we have already seen sudo/env, so a bare leading `-x` (not a valid
      # command start) will not falsely trigger. Guarded by prev token below.
      *) break ;;
    esac
    # Drop this token and continue.
    stmt="${stmt#"$tok"}"
    # After sudo/env, also drop any immediately-following short flags.
    if [ "$tok" = "sudo" ] || [ "$tok" = "env" ]; then
      while :; do
        stmt="${stmt#"${stmt%%[![:space:]]*}"}"
        local nxt="${stmt%%[[:space:]]*}"
        case "$nxt" in
          -*) stmt="${stmt#"$nxt"}" ;;
          *)  break ;;
        esac
      done
    fi
  done
  printf '%s' "$stmt"
}

# Split compound command into sub-statements on &&, ||, ;, newline
# then check each for git push to main/master
check_push_target() {
  local stmt="$1"

  # Strip leading whitespace, then peel off invocation-prefix tokens
  # (VAR=val / sudo / env and their flags) so all shapes normalize to a
  # bare `git ... push ...` before pattern matching.
  stmt="${stmt#"${stmt%%[![:space:]]*}"}"
  stmt=$(normalize_git_prefix "$stmt")

  # Must contain "git" in command position (optionally a full/relative path
  # like /usr/bin/git) followed (eventually) by "push". Options between git
  # and push are matched by:
  #   -[-a-zA-Z][^space]*   short or long option (git -C, git --no-pager,
  #                          git --git-dir=.git) — one dash-or-letter after
  #                          the leading dash, then any non-space run, so
  #                          =value / dotted paths inside the token are fine
  #   [^space-][^space]*    non-option arg token (git -C's path, -c's k=v)
  #
  # NOTE: [[:space:]] (not \s) throughout this function — \s is a GNU
  # grep/sed extension. macOS ships BSD grep/sed as /usr/bin/{grep,sed},
  # which do NOT support \s: it silently fails to match as a metachar,
  # degrading the sed extraction below to a no-op (push_args ends up as
  # the whole original statement instead of just the push arguments).
  # After normalize_git_prefix the statement starts at the git token (bare
  # or full-path), so no leading anchor alternation is needed — keeping the
  # fragment anchor-free lets the SAME fragment be reused inside the sed
  # `s/^.*RE//` extraction (a leading `(^|...)` alternation breaks BSD sed).
  local git_push_re='([^[:space:]]*/)?git([[:space:]]+(-[-a-zA-Z][^[:space:]]*|[^[:space:]-][^[:space:]]*))*[[:space:]]+push'
  if ! grep -Eq "$git_push_re" <<< "$stmt"; then
    return 1
  fi

  # Extract everything after "push" (the push arguments). Use `#` as the sed
  # delimiter — the path-prefix group ([^space]*/) contains a literal `/`,
  # which would otherwise be parsed as the s/// delimiter and break the RE.
  local push_args
  push_args=$(sed -E "s#^.*${git_push_re}##" <<< "$stmt")

  # Strip quote characters so quoted branch names (e.g. "main", 'main')
  # line up with the same bare word-boundary checks below.
  push_args=$(printf '%s' "$push_args" | tr -d "\"'")

  # --all / --mirror → blocks all branches including main
  if grep -Eq '(^|[[:space:]])--(all|mirror)([[:space:]]|$)' <<< "$push_args"; then
    return 0
  fi

  # Check for a protected branch as exact branch name (optionally prefixed
  # with the force-push shorthand "+" and/or the full "refs/heads/" ref path)
  # or as a colon-refspec destination. $PROTECTED_ALT is the pipe-joined
  # alternation of PROTECTED_BRANCHES (default "main|master").
  # Word-boundary: preceded by space/start(/plus), followed by space/end
  # Bare/prefixed: main, +main, refs/heads/main, +refs/heads/main
  # Refspec: :main, :refs/heads/main, :master, :refs/heads/master
  if grep -Eq "(^|[[:space:]])\+?(refs/heads/)?(${PROTECTED_ALT})([[:space:]]|\$)" <<< "$push_args"; then
    return 0
  fi
  if grep -Eq ":(refs/heads/)?(${PROTECTED_ALT})([[:space:]]|\$)" <<< "$push_args"; then
    return 0
  fi

  return 1
}

# Split on ;, &&, ||, newline — process each sub-statement
while IFS= read -r stmt; do
  if [ -n "$stmt" ] && check_push_target "$stmt"; then
    printf '[git-push-guard] 禁止直接 push 到保护分支 (%s)。请推送到功能分支并提 PR。\n' "$PROTECTED_BRANCHES" >&2
    printf '[git-push-guard] 无特殊情况不得绕过此检查。紧急放行: export ALLOW_PUSH_MAIN=1\n' >&2
    exit 2
  fi
done < <(printf '%s\n' "$COMMAND" | sed -E 's/(\&\&|\|\||;)/\n/g')

exit 0
