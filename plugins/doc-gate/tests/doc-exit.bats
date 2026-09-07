#!/usr/bin/env bats
# BDD tests for doc-exit.sh (Stop hook — exit judgment layer)
#
# Input signal is real `git status`, so every test that needs a "dirty"
# state creates a real temporary git repo (init_test_git_repo) rather than
# faking a payload field.

setup() {
  source "${BATS_TEST_DIRNAME}/test_helper/common-setup.bash"
  common_setup
  init_test_git_repo
}

teardown() {
  common_teardown
}

# ============================================================
# Core regression: stale_inlinks list (not a boolean)
# ============================================================

@test "stale_inlinks: A links B, both committed, only B edited -> B reports A as stale_inlinks" {
  write_md "A.md" $'# A\n\n[b](B.md)\n'
  write_md "B.md" $'# B\n\noriginal content\n'
  git_commit_all "init"

  write_md "B.md" $'# B\n\nedited content\n'

  run_exit_gate
  [ "$HOOK_EXIT" -eq 2 ]
  echo "$HOOK_STDERR" | grep -qF "B.md"
  echo "$HOOK_STDERR" | grep -qF "A.md"
}

@test "self-termination: once A is also edited, B's stale_inlinks no longer names A" {
  write_md "A.md" $'# A\n\n[b](B.md)\n'
  write_md "B.md" $'# B\n\noriginal content\n'
  git_commit_all "init"

  write_md "B.md" $'# B\n\nedited content\n'
  write_md "A.md" $'# A updated\n\n[b](B.md)\n'

  run_exit_gate
  # Findings may still fire (e.g. an orphan signal), but the stale_inlinks
  # relation between A and B specifically must have self-terminated: the
  # message must not claim A is a stale inlink of B once A is also dirty.
  if [ "$HOOK_EXIT" -eq 2 ]; then
    ! echo "$HOOK_STDERR" | grep -qF "以下文件链向它且自身未被改动，其中的描述可能已经陈旧：A.md"
  fi
}

# ============================================================
# dangling — reverse edge to a deleted target
# ============================================================

@test "dangling: A links B, B deleted, A untouched -> report names A still linking deleted B" {
  write_md "A.md" $'# A\n\n[b](B.md)\n'
  write_md "B.md" $'# B\n\ncontent\n'
  git_commit_all "init"

  rm "${REPO_DIR}/B.md"

  run_exit_gate
  [ "$HOOK_EXIT" -eq 2 ]
  echo "$HOOK_STDERR" | grep -qF "B.md"
  echo "$HOOK_STDERR" | grep -qF "A.md"
  echo "$HOOK_STDERR" | grep -qF "断链反查"
}

# ============================================================
# rename — two-segment `git status -z` record
# ============================================================

@test "rename: git mv consumes old-path segment correctly (new tracked, old not double-counted, third party reports dangling)" {
  write_md "OLD.md" $'# Old\n\ncontent\n'
  write_md "THIRD.md" $'# Third\n\n[old](OLD.md)\n'
  git_commit_all "init"

  git -C "$REPO_DIR" mv OLD.md NEW.md

  run_exit_gate
  [ "$HOOK_EXIT" -eq 2 ]
  # (a) NEW.md entered the check set
  echo "$HOOK_STDERR" | grep -qF -- "--- NEW.md ---"
  # (b) OLD.md's own block must not look like a routine independent finding
  # record beyond what dangling reverse-lookup produces for it — assert its
  # section exists (it does, as the target of THIRD.md's dangling link) but
  # is not duplicated.
  local old_section_count
  old_section_count=$(echo "$HOOK_STDERR" | grep -cF -- "--- OLD.md ---")
  [ "$old_section_count" -eq 1 ]
  # (c) THIRD.md is reported as still linking the now-deleted OLD.md
  echo "$HOOK_STDERR" | grep -qF "THIRD.md"
}

# ============================================================
# Newline-embedded path survives NUL-delimited transfer intact
# ============================================================

@test "newline in filename: path with a literal newline reaches Python as a single path" {
  local nl=$'weird'$'\n'"name.md"
  write_md "$nl" $'# Weird\n\ncontent that will not match any recall bait\n'
  git_commit_all "init"

  write_md "$nl" $'# Weird\n\nedited so it is dirty\n'
  write_md "linker.md" "# Linker

[weird](${nl})
"
  git_commit_all "add linker"
  # dirty the newline-named file again post-commit so it's the thing under test
  write_md "$nl" $'# Weird\n\nedited again\n'

  run_exit_gate
  # Must not crash the pipeline. Prove the embedded newline survived as ONE
  # path (not split into two independent records) by stripping all newlines
  # from the rendered message and checking "weird" and "name.md" are then
  # directly adjacent — if the pipeline had instead split on the embedded
  # newline, something else (another section header, other content) would
  # sit between them even after this stripping.
  local joined
  joined=$(printf '%s' "$HOOK_STDERR" | tr -d '\n')
  echo "$joined" | grep -qF "weirdname.md"
}

# ============================================================
# Recall must use the FINAL full-text content, not a fragment
# ============================================================

@test "recall uses final full-text content: overlap only exists in final state, not any single edit fragment" {
  write_md "topic.md" $'# Topic\n\n关于配置文件热重载与动态刷新机制的详细说明文档正文内容。\n'
  write_md "other.md" $'# Other\n\n完全无关的初始占位内容。\n'
  git_commit_all "init"

  # Final content overlaps heavily with topic.md; if the tool only looked at
  # a diff fragment or the pre-edit content, this overlap would be invisible.
  write_md "other.md" $'# Other\n\n关于配置文件热重载与动态刷新机制的详细说明文档正文内容，补充说明。\n'

  DOC_EXIT_GATE_THRESHOLD=0.10 run_exit_gate
  [ "$HOOK_EXIT" -eq 2 ]
  echo "$HOOK_STDERR" | grep -qF "topic.md"
}

# ============================================================
# Skip conditions
# ============================================================

@test "skip: stop_hook_active=true -> silent exit 0" {
  write_md "A.md" $'# A\n\ncontent\n'
  git_commit_all "init"
  write_md "A.md" $'# A\n\nedited\n'

  INPUT=$(build_stop_input stop_hook_active=true)
  run_exit_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDERR" ]
}

@test "skip: stop_hook_active=null (undeterminable) fails open toward exit 0, not toward blocking" {
  # Whitelist rule: only an explicit boolean false continues past the gate.
  # A field that is present but not a boolean (null here) must be treated
  # the same as "can't tell" — exit 0 — never as license to proceed and
  # potentially block, since the platform's cap on Stop re-entry retries is
  # unverified.
  write_md "A.md" $'# A\n\ncontent\n'
  git_commit_all "init"
  write_md "A.md" $'# A\n\nedited\n'

  INPUT=$(build_stop_input stop_hook_active=null)
  run_exit_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDERR" ]
}

@test "skip: background_tasks has a running entry -> silent exit 0" {
  write_md "A.md" $'# A\n\ncontent\n'
  git_commit_all "init"
  write_md "A.md" $'# A\n\nedited\n'

  INPUT=$(build_stop_input background_tasks='[{"status":"running"}]')
  run_exit_gate
  [ "$HOOK_EXIT" -eq 0 ]
}

@test "no-skip pair: background_tasks all completed -> normal check runs and reports" {
  write_md "A.md" $'# A\n\n[b](B.md)\n'
  write_md "B.md" $'# B\n\ncontent\n'
  git_commit_all "init"
  write_md "B.md" $'# B\n\nedited\n'

  INPUT=$(build_stop_input background_tasks='[{"status":"completed"}]')
  run_exit_gate
  [ "$HOOK_EXIT" -eq 2 ]
}

@test "skip: non-git directory -> silent exit 0" {
  local nongit="${TEST_TEMP_DIR}/nongit"
  mkdir -p "$nongit"
  echo "not markdown related" > "${nongit}/whatever.txt"

  INPUT=$(jq -n --arg cwd "$nongit" '{hook_event_name:"Stop",cwd:$cwd,stop_hook_active:false,background_tasks:[]}')
  run_exit_gate
  [ "$HOOK_EXIT" -eq 0 ]
}

@test "skip: no dirty .md files -> silent exit 0" {
  write_md "A.md" $'# A\n\ncontent\n'
  git_commit_all "init"
  # nothing dirty

  run_exit_gate
  [ "$HOOK_EXIT" -eq 0 ]
}

# ============================================================
# Exit code / channel contract
# ============================================================

@test "on finding: exit code is 2 and message is on stderr, not stdout" {
  write_md "A.md" $'# A\n\n[b](B.md)\n'
  write_md "B.md" $'# B\n\ncontent\n'
  git_commit_all "init"
  write_md "B.md" $'# B\n\nedited\n'

  run_exit_gate
  [ "$HOOK_EXIT" -eq 2 ]
  [ -n "$HOOK_STDERR" ]
  [ -z "$HOOK_STDOUT" ]
}

# ============================================================
# Exclusion still applies
# ============================================================

@test "exclusion: dirty MEMORY.md is not checked" {
  write_md "MEMORY.md" $'# Memory\n\ncontent\n'
  git_commit_all "init"
  write_md "MEMORY.md" $'# Memory\n\nedited\n'

  run_exit_gate
  [ "$HOOK_EXIT" -eq 0 ]
}

@test "case-insensitive .MD extension: dirty UPPER.MD enters the check set, dirty notes.txt does not" {
  # No `-- '*.md'` pathspec anymore (FIX-8): git pathspec matching is
  # case-sensitive so that pathspec used to silently drop a dirty UPPER.MD
  # before the shell's own *.[mM][dD] filter ever saw it. Removing the
  # pathspec means git now reports every dirty path (all extensions), and
  # the shell-side case filter alone must correctly keep non-.md paths out.
  write_md "UPPER.MD" $'# Upper\n\ncontent\n'
  write_md "notes.txt" "plain text, not markdown"
  git_commit_all "init"

  write_md "UPPER.MD" $'# Upper\n\nedited\n'
  write_md "notes.txt" "edited plain text"

  run_exit_gate
  # UPPER.MD has no inlinks -> orphan is a forced, deterministic finding.
  [ "$HOOK_EXIT" -eq 2 ]
  echo "$HOOK_STDERR" | grep -qF -- "--- UPPER.MD ---"
  ! echo "$HOOK_STDERR" | grep -qF -- "--- notes.txt ---"
}

@test "exclusion: dirty node_modules/x.md is not checked" {
  write_md "node_modules/pkg/x.md" $'# X\n\ncontent\n'
  git_commit_all "init"
  write_md "node_modules/pkg/x.md" $'# X\n\nedited\n'

  run_exit_gate
  [ "$HOOK_EXIT" -eq 0 ]
}

# ============================================================
# Multi-file single scan
# ============================================================

@test "multi-file: three dirty files, all three findings appear in one output" {
  # HUB.md links all three targets and is itself never touched, so editing
  # L1/L2/TARGET together deterministically produces a stale_inlinks finding
  # (naming HUB.md) for each of the three, independent of any cross-linking
  # among L1/L2/TARGET themselves (which would self-terminate since they're
  # all dirty together) — this is what makes the outcome forced rather than
  # "may or may not fire".
  write_md "HUB.md" $'# Hub\n\n[l1](L1.md) [l2](L2.md) [t](TARGET.md)\n'
  write_md "L1.md" $'# L1\n\ncontent\n'
  write_md "L2.md" $'# L2\n\ncontent\n'
  write_md "TARGET.md" $'# Target\n\ncontent\n'
  git_commit_all "init"

  write_md "TARGET.md" $'# Target\n\nedited\n'
  write_md "L1.md" $'# L1 v2\n\nedited\n'
  write_md "L2.md" $'# L2 v2\n\nedited\n'

  run_exit_gate
  [ "$HOOK_EXIT" -eq 2 ]
  # All three findings appear in the SAME output — proving the batch reached
  # doc-exit-report.py in one call, not three separate invocations.
  echo "$HOOK_STDERR" | grep -qF -- "--- L1.md ---"
  echo "$HOOK_STDERR" | grep -qF -- "--- L2.md ---"
  echo "$HOOK_STDERR" | grep -qF -- "--- TARGET.md ---"
  echo "$HOOK_STDERR" | grep -qF "HUB.md"
}

@test "multi-file: independently-dirty targets each produce a stale_inlinks finding in the same run" {
  write_md "H1.md" $'# H1\n\ncontent one\n'
  write_md "H2.md" $'# H2\n\ncontent two\n'
  write_md "LinkerA.md" $'# LinkerA\n\n[h1](H1.md)\n'
  write_md "LinkerB.md" $'# LinkerB\n\n[h2](H2.md)\n'
  git_commit_all "init"

  write_md "H1.md" $'# H1\n\nedited one\n'
  write_md "H2.md" $'# H2\n\nedited two\n'

  run_exit_gate
  [ "$HOOK_EXIT" -eq 2 ]
  echo "$HOOK_STDERR" | grep -qF -- "--- H1.md ---"
  echo "$HOOK_STDERR" | grep -qF -- "--- H2.md ---"
  echo "$HOOK_STDERR" | grep -qF "LinkerA.md"
  echo "$HOOK_STDERR" | grep -qF "LinkerB.md"
}

# ============================================================
# Budget degrade — P8-motivated safety valve (a hook that times out is
# killed silently by the platform with no trace; DOC_EXIT_GATE_BUDGET_SEC
# lets the recall pass abandon itself before that happens). Renders a
# "[降级]" notice so the degrade is visible instead of silent.
# ============================================================

@test "budget degrade: DOC_EXIT_GATE_BUDGET_SEC=0 renders the degrade notice" {
  # Single file with no inlinks -> orphan=true is a forced, deterministic
  # finding, so has_findings is guaranteed true independent of the recall
  # pass this test is actually targeting.
  write_md "LONE.md" $'# Lone\n\ncontent\n'
  git_commit_all "init"
  write_md "LONE.md" $'# Lone\n\nedited\n'

  DOC_EXIT_GATE_BUDGET_SEC=0 run_exit_gate
  [ "$HOOK_EXIT" -eq 2 ]
  echo "$HOOK_STDERR" | grep -qF "[降级]"
  echo "$HOOK_STDERR" | grep -qF "耗时预算"
}

# ============================================================
# Fail-open
# ============================================================

@test "fail-open: malformed JSON payload -> silent exit 0" {
  INPUT='not json at all {{{'
  run_exit_gate
  [ "$HOOK_EXIT" -eq 0 ]
}

@test "fail-open: empty stdin -> silent exit 0" {
  INPUT=""
  run_exit_gate
  [ "$HOOK_EXIT" -eq 0 ]
}

@test "fail-open: DOC_EXIT_GATE_DISABLED=1 -> silent exit 0 even with findings present" {
  write_md "A.md" $'# A\n\n[b](B.md)\n'
  write_md "B.md" $'# B\n\ncontent\n'
  git_commit_all "init"
  write_md "B.md" $'# B\n\nedited\n'

  DOC_EXIT_GATE_DISABLED=1 run_exit_gate
  [ "$HOOK_EXIT" -eq 0 ]
}

# ============================================================
# Robustness: Chinese filenames, spaces, deleted files
# ============================================================

@test "robustness: Chinese filename does not crash the pipeline" {
  # No other file links this one, and it's not in ORPHAN_WHITELIST, so
  # orphan=true is forced — the outcome is deterministic, not "may or may
  # not fire".
  write_md "中文文档.md" $'# 中文标题\n\n内容正文。\n'
  git_commit_all "init"
  write_md "中文文档.md" $'# 中文标题\n\n修改后的正文。\n'

  run_exit_gate
  [ "$HOOK_EXIT" -eq 2 ]
  echo "$HOOK_STDERR" | grep -qF -- "--- 中文文档.md ---"
  echo "$HOOK_STDERR" | grep -qF "建议补充索引链接"
}

@test "robustness: path with a space does not crash the pipeline" {
  # Same forced-orphan determinism as the Chinese-filename case above.
  write_md "has space here.md" $'# Spaced\n\ncontent\n'
  git_commit_all "init"
  write_md "has space here.md" $'# Spaced\n\nedited\n'

  run_exit_gate
  [ "$HOOK_EXIT" -eq 2 ]
  echo "$HOOK_STDERR" | grep -qF -- "--- has space here.md ---"
  echo "$HOOK_STDERR" | grep -qF "建议补充索引链接"
}

@test "robustness: deleted file (no rename) does not crash the pipeline" {
  # A.md (untouched) still links the now-deleted GONE.md -> dangling_refs is
  # forced to fire for GONE.md, naming A.md. Deterministic, same shape as
  # the dedicated "dangling" test above but exercising the plain-delete
  # (no rename byte-layout) code path specifically.
  write_md "A.md" $'# A\n\n[gone](GONE.md)\n'
  write_md "GONE.md" $'# Gone\n\ncontent\n'
  git_commit_all "init"

  rm "${REPO_DIR}/GONE.md"

  run_exit_gate
  [ "$HOOK_EXIT" -eq 2 ]
  echo "$HOOK_STDERR" | grep -qF "断链反查"
  echo "$HOOK_STDERR" | grep -qF -- "--- GONE.md ---"
  echo "$HOOK_STDERR" | grep -qF "A.md"
}

@test "deleted file with dangling_refs shows no orphan suggestion" {
  write_md "A.md" $'# A\n\n[b](B.md)\n'
  write_md "B.md" $'# B\n\ncontent\n'
  git_commit_all "init"

  rm "${REPO_DIR}/B.md"

  run_exit_gate
  [ "$HOOK_EXIT" -eq 2 ]
  # Must report that B.md is referenced but gone (dangling check).
  echo "$HOOK_STDERR" | grep -qF "断链反查"
  echo "$HOOK_STDERR" | grep -qF "A.md"
  # Must NOT report orphan signal — deleted files have orphan=false.
  ! echo "$HOOK_STDERR" | grep -qF "建议补充索引链接"
}
