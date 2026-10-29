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

@test "B2: --dirty-superset-file pipeline — basename-excluded SKILL.md still counts as touched for self-termination" {
  # SKILL.md is basename-excluded (doc_gate_is_excluded_basename) so it never
  # enters FILTERED_PATHS / the report set -- but it IS a real dirty file and
  # must still count as "touched" via the unfiltered superset passed through
  # --dirty-superset-file. If that transport pipe were silently dropped,
  # B.md's stale_inlinks would wrongly keep naming SKILL.md forever (an
  # unsatisfiable finding), because build_report would only see the
  # exclusion-filtered set and never learn SKILL.md was edited too.
  write_md "SKILL.md" $'# Skill\n\n[b](B.md)\n'
  write_md "B.md" $'# B\n\noriginal content\n'
  git_commit_all "init"

  write_md "B.md" $'# B\n\nedited content\n'
  write_md "SKILL.md" $'# Skill updated\n\n[b](B.md)\n'

  run_exit_gate
  # SKILL.md itself is excluded from the report set entirely -- it must
  # never appear as a reported file header.
  if echo "$HOOK_STDERR" | grep -qF -- "--- SKILL.md ---"; then
    echo "unexpected: excluded SKILL.md was reported as a file in the exit gate output" >&2
    return 1
  fi
  # B.md's stale_inlinks must NOT still name SKILL.md as untouched -- it was
  # edited too, just outside the report set. This is the assertion that
  # catches the transport pipe being silently dropped (B2, #219): without
  # --dirty-superset-file reaching Python, dirty_set falls back to the
  # filtered-only set (which excludes SKILL.md), so SKILL.md would look
  # permanently untouched and this finding would never self-terminate.
  if [ "$HOOK_EXIT" -eq 2 ]; then
    if echo "$HOOK_STDERR" | grep -qF "以下文件链向它且自身未被改动，其中的描述可能已经陈旧：SKILL.md"; then
      echo "unexpected: B.md's stale_inlinks still names excluded-but-touched SKILL.md" >&2
      return 1
    fi
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

@test "A6: Y-column rename (worktree-only, git add -N) consumes old-path segment correctly" {
  # `git mv` always stages the rename itself, so it can only ever produce
  # the X-column form (`R `) already covered above. To exercise the
  # Y-column form (` R`, X is a space or D) the rename must arrive at the
  # index via `git add -N` on a plain filesystem `mv` -- NOT `git mv` --
  # which git's own rename detection then reports as an UNSTAGED rename
  # (实测 git 2.48.1: plain `mv old new` + `git add -N new` emits
  # ` R new\0old\0`, confirming the header comment's claimed byte layout).
  write_md "OLD2.md" $'# Old2\n\ncontent\n'
  write_md "THIRD2.md" $'# Third2\n\n[old](OLD2.md)\n'
  git_commit_all "init"

  mv "${REPO_DIR}/OLD2.md" "${REPO_DIR}/NEW2.md"
  git -C "$REPO_DIR" add -N NEW2.md

  # Precondition: confirm this really is the Y-column form before trusting
  # the rest of the assertions to mean anything (X is a space, Y is 'R').
  local xy
  xy=$(git -C "$REPO_DIR" status --porcelain=v1 -z --untracked-files=all | head -c 2)
  [ "$xy" = " R" ]

  run_exit_gate
  [ "$HOOK_EXIT" -eq 2 ]
  # (a) NEW2.md entered the check set
  echo "$HOOK_STDERR" | grep -qF -- "--- NEW2.md ---"
  # (b) OLD2.md's own block is not duplicated (old-path segment consumed
  # exactly once, not misparsed as an independent record).
  local old_section_count
  old_section_count=$(echo "$HOOK_STDERR" | grep -cF -- "--- OLD2.md ---")
  [ "$old_section_count" -eq 1 ]
  # (c) THIRD2.md is reported as still linking the now-renamed-away OLD2.md
  echo "$HOOK_STDERR" | grep -qF "THIRD2.md"
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

@test "recall batch: real Stop fixture renders the shared reference for two dirty duplicate-term documents" {
  # The untouched hub provides a deterministic stale-inlinks finding for both
  # dirty documents. That proves the full Stop pipeline ran; the assertions
  # below then verify each rendered recall block contains the expected stable
  # reference candidate rather than merely sharing the same exit code.
  write_md "reference.md" $'# Reference\n\nalpha alpha alpha beta beta shared vocabulary.\n'
  write_md "draft-one.md" $'# Draft One\n\nplaceholder one.\n'
  write_md "draft-two.md" $'# Draft Two\n\nplaceholder two.\n'
  write_md "hub.md" $'# Hub\n\n[one](draft-one.md) [two](draft-two.md)\n'
  git_commit_all "init"

  write_md "draft-one.md" $'# Draft One\n\nalpha alpha alpha beta beta shared vocabulary.\n'
  write_md "draft-two.md" $'# Draft Two\n\nalpha alpha alpha beta beta shared vocabulary.\n'

  DOC_EXIT_GATE_THRESHOLD=0.10 run_exit_gate
  [ "$HOOK_EXIT" -eq 2 ]
  echo "$HOOK_STDERR" | grep -qF -- "--- draft-one.md ---"
  echo "$HOOK_STDERR" | grep -qF -- "--- draft-two.md ---"
  echo "$HOOK_STDERR" | grep -qF "相关文档（可能存在内容重叠）："
  local first_block="${HOOK_STDERR#*--- draft-one.md ---}"
  first_block="${first_block%%--- *}"
  local second_block="${HOOK_STDERR#*--- draft-two.md ---}"
  second_block="${second_block%%--- *}"
  echo "$first_block" | grep -qF "reference.md"
  echo "$second_block" | grep -qF "reference.md"
  echo "$HOOK_STDERR" | grep -qF "以下文件链向它且自身未被改动，其中的描述可能已经陈旧：hub.md"
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

@test "A4: linked UPPER.MD is not misjudged orphan, and its linker is not misjudged dangling" {
  # recall-gate.py's os.walk previously used a bare `.endswith('.md')`
  # (case-sensitive), so UPPER.MD never entered all_files/backward at all --
  # it would report orphan=True even WITH a real inlink, and the linker
  # would be told its link is dangling (target "doesn't exist"). Before A4
  # this test would have been a false green on the OLD "UPPER.MD enters the
  # check set" test above, which only asserted exit=2 without checking
  # WHICH finding produced it -- exit=2 was true either way (correct orphan
  # signal pre-fix here, since it had no inlink; this test adds the inlink
  # to isolate the bug precisely).
  write_md "linker.md" $'# Linker\n\n[upper](UPPER.MD)\n'
  write_md "UPPER.MD" $'# Upper\n\ncontent\n'
  git_commit_all "init"

  write_md "UPPER.MD" $'# Upper\n\nedited\n'

  run_exit_gate
  [ "$HOOK_EXIT" -eq 2 ]
  echo "$HOOK_STDERR" | grep -qF -- "--- UPPER.MD ---"
  # UPPER.MD must NOT be reported as orphan (it has a real inlink). A bare
  # `! cmd` here would be exempt from errexit unless it's the function's
  # LAST statement (bash: a `!`-negated pipeline never triggers -e on its
  # own), so a failing negated assertion followed by more statements would
  # silently NOT fail the test -- use an explicit if/return instead.
  if echo "$HOOK_STDERR" | grep -qF "建议补充索引链接"; then
    echo "unexpected: UPPER.MD reported as orphan despite having a real inlink" >&2
    return 1
  fi
  # linker.md's link to UPPER.MD must NOT be reported dangling anywhere.
  if echo "$HOOK_STDERR" | grep -qF "断链反查"; then
    echo "unexpected: UPPER.MD's real inlink reported as dangling" >&2
    return 1
  fi
  # And UPPER.MD's stale_inlinks must correctly name the untouched linker.
  echo "$HOOK_STDERR" | grep -qF "linker.md"
}

@test "exclusion: dirty node_modules/x.md is not checked" {
  write_md "node_modules/pkg/x.md" $'# X\n\ncontent\n'
  git_commit_all "init"
  write_md "node_modules/pkg/x.md" $'# X\n\nedited\n'

  run_exit_gate
  [ "$HOOK_EXIT" -eq 0 ]
}

@test "exclusion: dirty research/foo.md is not checked (A3: aligned with EXCLUDED_DIRS)" {
  write_md "research/foo.md" $'# Foo\n\ncontent\n'
  git_commit_all "init"
  write_md "research/foo.md" $'# Foo\n\nedited\n'

  run_exit_gate
  [ "$HOOK_EXIT" -eq 0 ]
}

# ============================================================
# Untracked new directory (A1: --untracked-files=all)
# ============================================================

@test "A1: untracked new directory's .md enters the check set and produces a finding" {
  # git status --porcelain -z with the default --untracked-files=normal
  # folds an entirely-untracked directory into one '?? dir/' record whose
  # basename never matches *.[mM][dD] -- the whole new doc tree is silently
  # dropped. A brand-new, never-committed directory with one orphan .md
  # inside it is a forced, deterministic finding once correctly picked up.
  mkdir -p "${REPO_DIR}/brand-new"
  printf '%s' $'# Guide\n\ncontent\n' > "${REPO_DIR}/brand-new/guide.md"
  # Nothing committed yet in this repo at all -- but init_test_git_repo only
  # creates an empty repo, so there is no HEAD; that's fine, git status
  # still reports the untracked file relative to the (empty) index.

  run_exit_gate
  [ "$HOOK_EXIT" -eq 2 ]
  echo "$HOOK_STDERR" | grep -qF -- "--- brand-new/guide.md ---"
}

@test "A1: status.showUntrackedFiles=no still surfaces untracked .md (explicit --untracked-files=all overrides config)" {
  git -C "$REPO_DIR" config status.showUntrackedFiles no

  mkdir -p "${REPO_DIR}/brand-new2"
  printf '%s' $'# Guide2\n\ncontent\n' > "${REPO_DIR}/brand-new2/guide2.md"

  run_exit_gate
  [ "$HOOK_EXIT" -eq 2 ]
  echo "$HOOK_STDERR" | grep -qF -- "--- brand-new2/guide2.md ---"
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

@test "A7: budget exceeded during graph build itself degrades with no partial findings" {
  # The old degrade test above only proves the RECALL pass can be skipped
  # under budget pressure -- with a single-file corpus, the graph-build
  # budget check (which fires only once per _GRAPH_BUDGET_CHECK_INTERVAL=25
  # scanned files) never triggers, so that test cannot distinguish "graph
  # build itself ran out of budget" from "recall pass was skipped after a
  # complete graph". This test forces a corpus large enough (30 filler
  # files) that the graph-build check interval is crossed at least once,
  # so DOC_EXIT_GATE_BUDGET_SEC=0 raises GraphBudgetExceeded during
  # build_corpus_and_graph itself, before any per-file structural check
  # (stale_inlinks/orphan/dangling_refs) ever runs.
  for i in $(seq 1 30); do
    write_md "filler${i}.md" "# Filler ${i}"$'\n\ncontent number '"${i}"$'.\n'
  done
  write_md "TARGET.md" $'# Target\n\ncontent\n'
  git_commit_all "init"
  write_md "TARGET.md" $'# Target\n\nedited\n'

  DOC_EXIT_GATE_BUDGET_SEC=0 run_exit_gate
  [ "$HOOK_EXIT" -eq 2 ]
  echo "$HOOK_STDERR" | grep -qF "[降级]"
  # Names both adjustable knobs, per spec.
  echo "$HOOK_STDERR" | grep -qF "DOC_EXIT_GATE_BUDGET_SEC"
  echo "$HOOK_STDERR" | grep -qF "DOC_EXIT_GATE_DISABLED"
  # Names the scan count, distinguishing this from the recall-only degrade.
  echo "$HOOK_STDERR" | grep -qF "已扫描"
  # No per-file structural block must appear -- a partial graph must never
  # be used to render findings (files={} on this path).
  if echo "$HOOK_STDERR" | grep -qF -- "--- TARGET.md ---"; then
    echo "unexpected: a structural finding block rendered from a partial (budget-exceeded) graph" >&2
    return 1
  fi
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

# ============================================================
# Claude Code auto-memory — a real .claude git root
# ============================================================

@test "auto-memory: add, modify, delete are ignored while docs CLAUDE and plans remain governed" {
  # The root itself must be .claude: relative git-status paths otherwise lack
  # the leading component that distinguishes Claude Code auto-memory from an
  # ordinary repository memory directory.
  rm -rf "$REPO_DIR"
  REPO_DIR="${TEST_TEMP_DIR}/.claude"
  mkdir -p "$REPO_DIR"
  git -C "$REPO_DIR" init -q
  git -C "$REPO_DIR" config user.email "doc-gate-test@example.com"
  git -C "$REPO_DIR" config user.name "doc-gate-test"
  export REPO_DIR

  # Untracked add is ignored.
  write_md "projects/example/memory/new.md" $'# Private\n\nnew memory\n'
  run_exit_gate
  [ "$HOOK_EXIT" -eq 0 ]

  # An untouched formal document links memory so deleting it would produce a
  # dangling finding without the new exclusion; this makes the delete case
  # discriminate against the old implementation rather than merely exit 0.
  write_md "projects/example/docs/guide.md" $'# Guide\n\ninitial guide\n'
  write_md "projects/example/CLAUDE.md" $'# Project rules\n\ninitial rules\n'
  write_md "plans/example.md" $'# Plan\n\ninitial plan\n'
  write_md "projects/example/docs/index.md" $'# Index\n\n[memory](../memory/new.md) [guide](guide.md) [rules](../CLAUDE.md) [plan](../../../plans/example.md)\n'
  git_commit_all "add memory and governed documents"

  # Modification is ignored.
  write_md "projects/example/memory/new.md" $'# Private\n\nchanged memory\n'
  run_exit_gate
  [ "$HOOK_EXIT" -eq 0 ]

  git -C "$REPO_DIR" checkout -- "projects/example/memory/new.md"
  # Deletion is ignored even though index.md remains an untouched inlink.
  rm "${REPO_DIR}/projects/example/memory/new.md"
  run_exit_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDERR" ]

  git -C "$REPO_DIR" checkout -- "projects/example/memory/new.md"
  write_md "projects/example/memory/new.md" $'# Private\n\nchanged again\n'
  write_md "projects/example/docs/guide.md" $'# Guide\n\nupdated guide\n'
  write_md "projects/example/CLAUDE.md" $'# Project rules\n\nupdated rules\n'
  write_md "plans/example.md" $'# Plan\n\nupdated plan\n'
  run_exit_gate
  [ "$HOOK_EXIT" -eq 2 ]
  echo "$HOOK_STDERR" | grep -qF -- "--- projects/example/docs/guide.md ---"
  echo "$HOOK_STDERR" | grep -qF -- "--- projects/example/CLAUDE.md ---"
  echo "$HOOK_STDERR" | grep -qF -- "--- plans/example.md ---"
  if echo "$HOOK_STDERR" | grep -qF -- "--- projects/example/memory/new.md ---"; then
    echo "unexpected: auto-memory was reported beside governed documents" >&2
    return 1
  fi
}

@test "auto-memory: deleting memory with an untouched formal inlink is silent" {
  rm -rf "$REPO_DIR"
  REPO_DIR="${TEST_TEMP_DIR}/.claude"
  mkdir -p "$REPO_DIR"
  git -C "$REPO_DIR" init -q
  git -C "$REPO_DIR" config user.email "doc-gate-test@example.com"
  git -C "$REPO_DIR" config user.name "doc-gate-test"
  export REPO_DIR

  write_md "projects/example/memory/entry.md" $'# Private\n\ncontent\n'
  write_md "projects/example/docs/index.md" $'# Index\n\n[memory](../memory/entry.md)\n'
  git_commit_all "add memory and formal inlink"

  rm "${REPO_DIR}/projects/example/memory/entry.md"
  run_exit_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDERR" ]
}
