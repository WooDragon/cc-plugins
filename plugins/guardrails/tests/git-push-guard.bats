#!/usr/bin/env bats
# BDD tests for git-push-guard.sh (PreToolUse:Bash hook)
#
# Converted from hooks/tests/test-pre-git-push-guard.sh (ad-hoc PASS/FAIL
# counter script) to bats. Case set and expectations preserved 1:1.
#
# BLOCK:  git push to main/master, --all, --mirror, refspec, compound commands
# PASS:   non-git, feature branches, bare push, main-prefix names, bypass env

bats_require_minimum_version 1.5.0

setup() {
  load 'test_helper/common-setup'
  common_setup
}

teardown() {
  common_teardown
}

# ============================================================
# PASS cases
# ============================================================

@test "pass: non-git command" {
  run_push_guard "$(mk_payload 'npm install')"
  [ "$status" -eq 0 ]
}

@test "pass: git status" {
  run_push_guard "$(mk_payload 'git status')"
  [ "$status" -eq 0 ]
}

@test "pass: git push origin feature-x" {
  run_push_guard "$(mk_payload 'git push origin feature-x')"
  [ "$status" -eq 0 ]
}

@test "pass: bare git push (fail-open)" {
  run_push_guard "$(mk_payload 'git push')"
  [ "$status" -eq 0 ]
}

@test "pass: git push origin (no branch)" {
  run_push_guard "$(mk_payload 'git push origin')"
  [ "$status" -eq 0 ]
}

@test "pass: git push origin main-backup (prefix, not exact branch)" {
  run_push_guard "$(mk_payload 'git push origin main-backup')"
  [ "$status" -eq 0 ]
}

@test "pass: git push origin maintain" {
  run_push_guard "$(mk_payload 'git push origin maintain')"
  [ "$status" -eq 0 ]
}

@test "pass: empty stdin" {
  run_push_guard ""
  [ "$status" -eq 0 ]
}

@test "pass: git -C main push origin feature-x (push_args extraction must strip the git..push prefix, not leak the -C dir name into branch matching)" {
  run_push_guard "$(mk_payload 'git -C main push origin feature-x')"
  [ "$status" -eq 0 ]
}

# --- prefix/long-option forms must still PASS on feature branches (no FP after hardening) ---

@test "pass: git --no-pager push origin feature-x (long option, feature branch)" {
  run_push_guard "$(mk_payload 'git --no-pager push origin feature-x')"
  [ "$status" -eq 0 ]
}

@test "pass: env git push origin feature-x (env prefix, feature branch)" {
  run_push_guard "$(mk_payload 'env git push origin feature-x')"
  [ "$status" -eq 0 ]
}

@test "pass: sudo -E git push origin feature-x (sudo+flag prefix, feature branch)" {
  run_push_guard "$(mk_payload 'sudo -E git push origin feature-x')"
  [ "$status" -eq 0 ]
}

@test "pass: /usr/bin/git push origin feature-x (full path, feature branch)" {
  run_push_guard "$(mk_payload '/usr/bin/git push origin feature-x')"
  [ "$status" -eq 0 ]
}

@test "pass: GIT_DIR=.git git push origin feature-x (env-var prefix, feature branch)" {
  run_push_guard "$(mk_payload 'GIT_DIR=.git git push origin feature-x')"
  [ "$status" -eq 0 ]
}

# --- git must be in COMMAND position: the literal "git push ... main" as an
#     argument to another command must NOT be flagged (anchor regression) ---

@test "pass: echo git push origin main (git is an echo argument, not a command)" {
  run_push_guard "$(mk_payload 'echo git push origin main')"
  [ "$status" -eq 0 ]
}

@test "pass: grep \"git push origin main\" README.md (literal string search)" {
  run_push_guard "$(mk_payload 'grep "git push origin main" README.md')"
  [ "$status" -eq 0 ]
}

# ============================================================
# BLOCK cases
# ============================================================

@test "block: git push origin main" {
  run_push_guard "$(mk_payload 'git push origin main')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: git push origin master" {
  run_push_guard "$(mk_payload 'git push origin master')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: git push -u origin main" {
  run_push_guard "$(mk_payload 'git push -u origin main')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: git push --force origin main" {
  run_push_guard "$(mk_payload 'git push --force origin main')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: git push origin HEAD:main (refspec)" {
  run_push_guard "$(mk_payload 'git push origin HEAD:main')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: git push origin HEAD:refs/heads/main" {
  run_push_guard "$(mk_payload 'git push origin HEAD:refs/heads/main')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: git push origin HEAD:master" {
  run_push_guard "$(mk_payload 'git push origin HEAD:master')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: git push origin feature main (multi)" {
  run_push_guard "$(mk_payload 'git push origin feature main')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: git push --all" {
  run_push_guard "$(mk_payload 'git push --all')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: git push --mirror" {
  run_push_guard "$(mk_payload 'git push --mirror')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: git push origin --all" {
  run_push_guard "$(mk_payload 'git push origin --all')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: compound with && — git add . && git push origin main" {
  run_push_guard "$(mk_payload 'git add . && git push origin main')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: compound with ; — cd proj; git push origin main" {
  run_push_guard "$(mk_payload 'cd proj; git push origin main')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: git -C /path push origin main" {
  run_push_guard "$(mk_payload 'git -C /tmp/repo push origin main')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: git -c key=val push origin main" {
  run_push_guard "$(mk_payload 'git -c http.sslVerify=false push origin main')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: git push origin +main (force-push shorthand prefix)" {
  run_push_guard "$(mk_payload 'git push origin +main')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: git push origin +master (force-push shorthand prefix)" {
  run_push_guard "$(mk_payload 'git push origin +master')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: git push origin refs/heads/main (full ref, no colon)" {
  run_push_guard "$(mk_payload 'git push origin refs/heads/main')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test 'block: git push origin "main" (double-quoted branch name)' {
  run_push_guard "$(mk_payload 'git push origin "main"')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: git push origin 'main' (single-quoted branch name)" {
  run_push_guard "$(mk_payload "git push origin 'main'")"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

# ============================================================
# BLOCK cases — long options, prefixes, full path (#118 hardening)
# ============================================================

@test "block: git --no-pager push origin main (long option, real bug)" {
  run_push_guard "$(mk_payload 'git --no-pager push origin main')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: git --git-dir=.git push origin main (long option with =value)" {
  run_push_guard "$(mk_payload 'git --git-dir=.git push origin main')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: sudo -E git push origin main (sudo with flag)" {
  run_push_guard "$(mk_payload 'sudo -E git push origin main')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: env git push origin main (env prefix)" {
  run_push_guard "$(mk_payload 'env git push origin main')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: GIT_DIR=.git git push origin main (env-var assignment prefix)" {
  run_push_guard "$(mk_payload 'GIT_DIR=.git git push origin main')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: /usr/bin/git push origin main (full binary path)" {
  run_push_guard "$(mk_payload '/usr/bin/git push origin main')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

# ============================================================
# PROTECTED_BRANCHES generalization (#118)
# ============================================================

@test "block: PROTECTED_BRANCHES=trunk — git push origin trunk" {
  run_push_guard "$(mk_payload 'git push origin trunk')" PROTECTED_BRANCHES=trunk
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "block: PROTECTED_BRANCHES='trunk develop' — git push origin develop" {
  run_push_guard "$(mk_payload 'git push origin develop')" "PROTECTED_BRANCHES=trunk develop"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

@test "pass: PROTECTED_BRANCHES=trunk — git push origin main (main no longer protected)" {
  run_push_guard "$(mk_payload 'git push origin main')" PROTECTED_BRANCHES=trunk
  [ "$status" -eq 0 ]
}

@test "block: default PROTECTED_BRANCHES still protects main when unset" {
  run_push_guard "$(mk_payload 'git push origin main')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git-push-guard"* ]]
}

# ============================================================
# BYPASS case
# ============================================================

@test "bypass: ALLOW_PUSH_MAIN=1 allows push to main" {
  run_push_guard "$(mk_payload 'git push origin main')" ALLOW_PUSH_MAIN=1
  [ "$status" -eq 0 ]
}
