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
# BYPASS case
# ============================================================

@test "bypass: ALLOW_PUSH_MAIN=1 allows push to main" {
  run_push_guard "$(mk_payload 'git push origin main')" ALLOW_PUSH_MAIN=1
  [ "$status" -eq 0 ]
}
