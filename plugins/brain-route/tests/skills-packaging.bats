#!/usr/bin/env bats
# Structural assertions for the brain-recall / brain-curate skill packaging
# migration (issue #248). These lock invariants of the migration itself —
# NOT hook behavior (that's covered by brain-route-gate.bats's 20 cases).
#
# All paths are relative to BATS_TEST_DIRNAME. Do not use $HOME or absolute
# paths — this suite runs inside a git worktree, and $HOME-based lookups
# resolve to the main worktree's stale copy instead of this checkout.

PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."

RECALL_SKILL_MD="${PLUGIN_DIR}/skills/brain-recall/SKILL.md"
CURATE_SKILL_MD="${PLUGIN_DIR}/skills/brain-curate/SKILL.md"
PLUGIN_JSON="${PLUGIN_DIR}/.claude-plugin/plugin.json"
MARKETPLACE_JSON="${REPO_ROOT}/.claude-plugin/marketplace.json"
GATE_SCRIPT="${PLUGIN_DIR}/scripts/brain-route-gate.sh"
FIXTURE_EXPORT="${BATS_TEST_DIRNAME}/fixtures/export-shape.json"

# Extract lines inside ```bash ... ``` fences, prefixed with their 1-based
# line number as "NR:content". Matching is anchored on the fence token
# itself (with optional leading whitespace), not on column 0 — this is
# required to cover brain-curate's "合并决策规约" fences, which sit inside a
# numbered list and are indented 3 spaces. A column-0-anchored matcher
# silently skips those blocks (verified: only counts 3 of the file's 5
# Authorization headers).
_fenced_bash_lines() {
  awk '
    /^[[:space:]]*```bash[[:space:]]*$/ { infence=1; next }
    /^[[:space:]]*```[[:space:]]*$/ { if (infence) { infence=0; next } }
    infence { print NR":"$0 }
  ' "$1"
}

# --- 1. Both skill files exist and are non-empty ---

@test "brain-recall SKILL.md exists and is non-empty" {
  [ -s "$RECALL_SKILL_MD" ]
}

@test "brain-curate SKILL.md exists and is non-empty" {
  [ -s "$CURATE_SKILL_MD" ]
}

# --- 2. Zero hardcoded endpoint in either SKILL.md ---

@test "brain-recall SKILL.md has zero hardcoded brain.tbps.one occurrences" {
  local count
  count=$(grep -c 'brain\.tbps\.one' "$RECALL_SKILL_MD" || true)
  [ "${count:-0}" -eq 0 ]
}

@test "brain-curate SKILL.md has zero hardcoded brain.tbps.one occurrences" {
  local count
  count=$(grep -c 'brain\.tbps\.one' "$CURATE_SKILL_MD" || true)
  [ "${count:-0}" -eq 0 ]
}

# --- 3. Endpoint is env-derived ---

@test "brain-recall SKILL.md references SECOND_BRAIN_URL" {
  grep -q 'SECOND_BRAIN_URL' "$RECALL_SKILL_MD"
}

@test "brain-curate SKILL.md references SECOND_BRAIN_URL" {
  grep -q 'SECOND_BRAIN_URL' "$CURATE_SKILL_MD"
}

# --- 3b. Endpoint and token are fail-loud, not just env-derived (core: PR #179 review) ---
#
# Assertion 3 above only checks the bare string "SECOND_BRAIN_URL" appears
# somewhere in the file — a plain unguarded "$SECOND_BRAIN_URL" satisfies it
# just as well as "${SECOND_BRAIN_URL:?...}". That was the actual defect
# under review: TOKEN silently sent an unauthenticated-looking request
# instead of erroring out when unset. These assertions pin the fail-loud
# `${VAR:?...}` form specifically, so reverting to a bare variable turns
# these red even though assertion 3 would stay green.

@test "brain-recall SKILL.md uses fail-loud \${SECOND_BRAIN_URL:?...} form" {
  grep -qE '\$\{SECOND_BRAIN_URL:\?' "$RECALL_SKILL_MD"
}

@test "brain-curate SKILL.md uses fail-loud \${SECOND_BRAIN_URL:?...} form" {
  grep -qE '\$\{SECOND_BRAIN_URL:\?' "$CURATE_SKILL_MD"
}

@test "brain-recall SKILL.md uses fail-loud \${SECOND_BRAIN_TOKEN:?...} form" {
  grep -qE '\$\{SECOND_BRAIN_TOKEN:\?' "$RECALL_SKILL_MD"
}

@test "brain-curate SKILL.md uses fail-loud \${SECOND_BRAIN_TOKEN:?...} form" {
  grep -qE '\$\{SECOND_BRAIN_TOKEN:\?' "$CURATE_SKILL_MD"
}

# --- 3c. Universality: EVERY bash-fenced auth header / URL ref is fail-loud ---
#
# The 3b assertions above are existence checks — one compliant occurrence
# anywhere in the file satisfies them even if four other occurrences in the
# same file regressed to a bare variable. That's the realistic regression
# shape (partial revert on a multi-occurrence file), and it's more dangerous
# than a full revert because a full revert would still be caught by 3b.
# These assertions require every fenced-code occurrence to be fail-loud, not
# just one. Prose occurrences outside fences (e.g. the explanatory sentences
# at brain-recall:30 and brain-curate:24) are deliberately excluded — they
# describe the mechanism in running text and are not runtime code.

@test "brain-recall SKILL.md: every fenced Authorization header is fail-loud" {
  local bad
  bad=$(_fenced_bash_lines "$RECALL_SKILL_MD" | grep 'Authorization: Bearer' | grep -vE '\$\{SECOND_BRAIN_TOKEN:\?' || true)
  if [ -n "$bad" ]; then
    echo "Non-fail-loud Authorization header(s) in fenced bash code:"
    echo "$bad"
    return 1
  fi
  # Sanity: must have found at least one Authorization header to guard
  # against a broken fence parser vacuously passing on an empty set.
  local total
  total=$(_fenced_bash_lines "$RECALL_SKILL_MD" | grep -c 'Authorization: Bearer' || true)
  [ "${total:-0}" -gt 0 ]
}

@test "brain-curate SKILL.md: every fenced Authorization header is fail-loud" {
  local bad
  bad=$(_fenced_bash_lines "$CURATE_SKILL_MD" | grep 'Authorization: Bearer' | grep -vE '\$\{SECOND_BRAIN_TOKEN:\?' || true)
  if [ -n "$bad" ]; then
    echo "Non-fail-loud Authorization header(s) in fenced bash code:"
    echo "$bad"
    return 1
  fi
  local total
  total=$(_fenced_bash_lines "$CURATE_SKILL_MD" | grep -c 'Authorization: Bearer' || true)
  [ "${total:-0}" -gt 0 ]
}

@test "brain-recall SKILL.md: every fenced SECOND_BRAIN_URL reference is fail-loud" {
  local bad
  # Match any SECOND_BRAIN_URL occurrence, then exclude the compliant
  # ${SECOND_BRAIN_URL:?...} form — whatever's left is bare ($SECOND_BRAIN_URL
  # or ${SECOND_BRAIN_URL}).
  bad=$(_fenced_bash_lines "$RECALL_SKILL_MD" | grep 'SECOND_BRAIN_URL' | grep -vE '\$\{SECOND_BRAIN_URL:\?' || true)
  if [ -n "$bad" ]; then
    echo "Non-fail-loud SECOND_BRAIN_URL reference(s) in fenced bash code:"
    echo "$bad"
    return 1
  fi
  local total
  total=$(_fenced_bash_lines "$RECALL_SKILL_MD" | grep -c 'SECOND_BRAIN_URL' || true)
  [ "${total:-0}" -gt 0 ]
}

@test "brain-curate SKILL.md: every fenced SECOND_BRAIN_URL reference is fail-loud" {
  local bad
  bad=$(_fenced_bash_lines "$CURATE_SKILL_MD" | grep 'SECOND_BRAIN_URL' | grep -vE '\$\{SECOND_BRAIN_URL:\?' || true)
  if [ -n "$bad" ]; then
    echo "Non-fail-loud SECOND_BRAIN_URL reference(s) in fenced bash code:"
    echo "$bad"
    return 1
  fi
  local total
  total=$(_fenced_bash_lines "$CURATE_SKILL_MD" | grep -c 'SECOND_BRAIN_URL' || true)
  [ "${total:-0}" -gt 0 ]
}

# --- 3d. mktemp portability: no BSD-only "-t <name>" form ---
#
# `mktemp -t brain_export` works on BSD/macOS but dies on GNU coreutils
# (`mktemp: too few X's in template`, rc=1) — a Linux runner would fail
# before ever reaching the curl call. The fix in place uses an explicit
# XXXXXX template, which is portable across both. This pins that form.

@test "brain-curate SKILL.md: any mktemp call uses a portable XXXXXX template, not BSD -t" {
  local mktemp_lines bad
  mktemp_lines=$(grep -n 'mktemp' "$CURATE_SKILL_MD" || true)

  if [ -z "$mktemp_lines" ]; then
    skip "no mktemp call present in brain-curate SKILL.md"
  fi

  bad=$(echo "$mktemp_lines" | grep -E 'mktemp[[:space:]]+-t[[:space:]]+[^X]' || true)
  if [ -n "$bad" ]; then
    echo "BSD-only 'mktemp -t <name>' form found (fails on GNU coreutils):"
    echo "$bad"
    return 1
  fi

  bad=$(echo "$mktemp_lines" | grep -v 'XXXXXX' || true)
  if [ -n "$bad" ]; then
    echo "mktemp call without an explicit XXXXXX template:"
    echo "$bad"
    return 1
  fi
}

# --- 3e. /export jq filter shape: entries[] not bare .[], created_at as epoch-ms ---
#
# `/export` returns a top-level OBJECT {ok, version, exported_at, entries,
# edges} — a bare `.[]` on that object iterates into `ok` (a boolean) and
# blows up with "Cannot index boolean with string ...". The fix reads
# through `.entries[]` instead. Separately, `created_at` is an epoch
# millisecond NUMBER on every endpoint, not an ISO 8601 string, so
# `fromdateiso8601` (which only parses strings) fails outright on it; the
# correct conversion divides by 1000. Both defects were verified live
# against a real /export response before the SKILL.md fix landed.


# Extracts the /export jq filter expression from fenced bash code. Anchored
# on CONTENT (the filter body containing "recall_count"), not on POSITION
# ("the first fenced line containing jq"). A position anchor silently
# retargets whenever an unrelated jq block is inserted earlier in the file --
# exactly what happened when brain-curate's tag-hygiene section (three more
# jq filters, none of them this one) landed above this block: the old
# position anchor grabbed the wrong block, and the red it produced pointed
# nowhere near the actual filter being pinned.
#
# Mechanics: scan for candidate jq programs, each starting at a line whose
# fenced content begins with "jq" (optionally reflowed as "jq \\" alone with
# the opening "'[.entries[]" on the next line -- a semantically-identical
# rewrite that a same-line text grep cannot survive, verified live) and
# accumulating (stripping "\" line-continuations) until a line ending in
# "]'" closes the single-quoted jq program. Whenever a new "jq"-opening line
# is seen, the previous (possibly still-open, if it never hit "]'") candidate
# is discarded unless its body already contains "recall_count", in which
# case that candidate is the answer and extraction stops immediately. This
# naturally skips over the tag-hygiene filters -- none of them mention
# recall_count -- regardless of how many of them sit before this block or in
# what order.
_extract_export_jq_filter() {
  local file="$1" sq="'" raw expr
  raw=$(_fenced_bash_lines "$file" | awk -F: '
    { line = substr($0, index($0, ":") + 1) }
    line ~ /^[[:space:]]*jq([[:space:]]|\\|$)/ {
      if (capturing && buf ~ /recall_count/) { found = buf; exit }
      capturing = 1; buf = ""
    }
    capturing {
      sub(/\\[[:space:]]*$/, "", line)
      buf = buf line "\n"
      if (line ~ /\]'"'"'/) {
        if (buf ~ /recall_count/) { found = buf; exit }
        capturing = 0; buf = ""
      }
    }
    END {
      if (found == "" && capturing && buf ~ /recall_count/) found = buf
      printf "%s", found
    }
  ')
  expr="${raw#*$sq}"
  expr="${expr%$sq*}"
  printf '%s' "$expr"
}

@test "brain-curate SKILL.md: /export jq filter reads entries via .entries[], not bare .[]" {
  # Executes the actual jq filter extracted from fenced bash code against a
  # fixed fixture (fixtures/export-shape.json) and asserts the exact
  # selected id set, instead of grepping for a specific token arrangement.
  # A prior text-form state machine here required "jq" and "[.entries[]" on
  # the SAME line -- reflowing them across two lines (a semantically
  # identical, legal rewrite) turned it red with zero behavior change
  # (verified live). Executing the real filter against a real fixture
  # survives that reflow and catches the real defect (a boolean-indexing
  # crash on bare `.[]`, or selecting the wrong entries) by its real
  # symptom instead of by text shape.
  local expr result status ids

  expr="$(_extract_export_jq_filter "$CURATE_SKILL_MD")"
  [ -n "$expr" ] || {
    echo "Could not extract a jq filter expression from fenced bash code in $CURATE_SKILL_MD -- the /export filter block may have been deleted"
    return 1
  }

  result=$(printf '%s' "$expr" | jq -f /dev/stdin "$FIXTURE_EXPORT" 2>&1)
  status=$?

  if [ "$status" -ne 0 ]; then
    echo "Extracted jq filter failed to execute against fixture (exit $status):"
    echo "Filter: $expr"
    echo "Error: $result"
    return 1
  fi

  ids=$(printf '%s' "$result" | jq -r '[.[].id] | sort | join(",")')
  [ "$ids" = "entry-old-zero-recall" ] || {
    echo "Expected selected id set to be exactly {entry-old-zero-recall}, got: $ids"
    echo "Filter: $expr"
    return 1
  }
}

@test "brain-curate SKILL.md: created_at treated as epoch milliseconds, not ISO date string" {
  # fromdateiso8601 only parses ISO 8601 strings; created_at is an
  # epoch-millisecond number on every endpoint (per the format table),
  # so applying fromdateiso8601 to it fails outright. Must never reappear
  # in runnable jq code. Scoped to fenced bash blocks (via
  # _fenced_bash_lines), NOT the whole file -- the prose at line 88
  # deliberately names fromdateiso8601 as the documented anti-pattern to
  # avoid, so a whole-file grep would false-positive on that sentence.
  local bad
  bad=$(_fenced_bash_lines "$CURATE_SKILL_MD" | grep 'fromdateiso8601' || true)
  if [ -n "$bad" ]; then
    echo "fromdateiso8601 found in fenced bash code -- created_at is an epoch-millisecond number, not an ISO string:"
    echo "$bad"
    return 1
  fi

  # The correct handling divides created_at by 1000 to convert ms -> s.
  # Tolerate whitespace variance around the '/' (e.g. "created_at / 1000"
  # or "created_at/1000"). Scoped to fenced bash blocks -- the prose at
  # line 78 also mentions "created_at/1000" as running text (a worked
  # example for humans, not runnable jq), which would let this check pass
  # even after the real division in the executable jq filter was removed.
  _fenced_bash_lines "$CURATE_SKILL_MD" | grep -qE '\.created_at[[:space:]]*/[[:space:]]*1000' || {
    echo "No '.created_at / 1000' (epoch-ms to seconds) conversion found in fenced bash code in $CURATE_SKILL_MD"
    return 1
  }
}

# --- 4. Deny text's referenced skill resolves inside this plugin (core: issue #248) ---

@test "every skill name referenced by gate deny text resolves in plugin.json AND has an on-disk SKILL.md" {
  # Extract skill names the gate script's deny/comment text refers to,
  # matching the "<name> skill" phrasing used in brain-route-gate.sh.
  local referenced_skills
  referenced_skills=$(grep -oE '[a-zA-Z][a-zA-Z0-9-]* skill\b' "$GATE_SCRIPT" | awk '{print $1}' | sort -u)

  [ -n "$referenced_skills" ]

  while IFS= read -r skill_name; do
    [ -n "$skill_name" ] || continue

    # Resolve against plugin.json's "skills" array: entries are paths like
    # "./skills/brain-recall" — compare by basename, not substring match.
    local resolved_path
    resolved_path=$(jq -r --arg name "$skill_name" \
      '.skills[] | select((. | split("/") | last) == $name)' \
      "$PLUGIN_JSON")

    [ -n "$resolved_path" ] || {
      echo "Skill '$skill_name' referenced by gate deny text has no matching entry in plugin.json's skills array"
      return 1
    }

    # The resolved path's SKILL.md must actually exist on disk.
    local resolved_skill_md
    resolved_skill_md="${PLUGIN_DIR}/${resolved_path#./}/SKILL.md"
    [ -f "$resolved_skill_md" ] || {
      echo "Skill '$skill_name' resolves to plugin.json path '$resolved_path' but $resolved_skill_md does not exist"
      return 1
    }
  done <<< "$referenced_skills"
}

# --- 4b. Every on-disk skill is declared in plugin.json (reverse of #4) ---
#
# Assertion 4 walks gate-deny-text -> plugin.json and only catches a skill
# that's referenced by the gate script but undeclared or missing on disk.
# It is blind to a skill that exists on disk but was never referenced by the
# gate script at all (brain-curate is never mentioned in brain-route-gate.sh's
# deny/comment text — only brain-recall is), so an undeclared brain-curate
# would sail through assertion 4 with zero red. This assertion walks the
# opposite direction, disk -> plugin.json, closing that blind spot: every
# directory under skills/ that has a SKILL.md must resolve to a declared
# entry in plugin.json's "skills" array. The two are complementary, not
# duplicates — dropping either one reopens a distinct hole.

@test "every on-disk skill directory (with a SKILL.md) is declared in plugin.json" {
  local skill_dir skill_name resolved_path found_any
  found_any=0

  for skill_dir in "${PLUGIN_DIR}"/skills/*/; do
    [ -f "${skill_dir}SKILL.md" ] || continue
    found_any=1
    skill_name=$(basename "$skill_dir")

    resolved_path=$(jq -r --arg name "$skill_name" \
      '.skills[] | select((. | split("/") | last) == $name)' \
      "$PLUGIN_JSON")

    [ -n "$resolved_path" ] || {
      echo "On-disk skill '$skill_name' (has SKILL.md) has no matching entry in plugin.json's skills array"
      return 1
    }
  done

  # Sanity: the discovery loop itself must have found at least one skill,
  # otherwise a broken glob would make this test vacuously pass.
  [ "$found_any" -eq 1 ]
}

# --- 5. Version double-write consistency (plugin.json <-> marketplace.json) ---

@test "plugin.json version matches marketplace.json brain-route entry version" {
  local plugin_version marketplace_version
  plugin_version=$(jq -r '.version' "$PLUGIN_JSON")
  marketplace_version=$(jq -r '.plugins[] | select(.name == "brain-route") | .version' "$MARKETPLACE_JSON")

  [ -n "$plugin_version" ]
  [ -n "$marketplace_version" ]
  [ "$plugin_version" = "$marketplace_version" ]
}

# --- 6. Tag contract convention (brain-recall write-time rule + brain-curate hygiene sweep) ---
#
# Locks EXISTENCE, not wording. The 三档 table's row wording, the 正反例
# array contents, and the exact prose phrasing are all expected to drift as
# the docs get maintained — pinning them would manufacture false reds on
# every routine edit. What must never silently disappear is: (a) the
# write-time /tags lookup call, (b) the three-tier skeleton (topic domain /
# specific mechanism / forbidden), (c) the three named forbidden categories,
# (d) the hygiene section header that anchors 6.4's extractor, and (e) the
# three hygiene jq filters actually being runnable code, not prose that
# silently bit-rotted into something jq can no longer parse.

@test "brain-recall SKILL.md: write section has a /tags lookup call before capture" {
  # Must be scoped to fenced bash code -- prose elsewhere in the write
  # section discusses "/tags" as a concept without it being a runtime call.
  local hits
  hits=$(_fenced_bash_lines "$RECALL_SKILL_MD" | grep -E '/tags"$' || true)
  if [ -z "$hits" ]; then
    echo "No fenced bash line ending in a '/tags' URL reference found in $RECALL_SKILL_MD -- the pre-write tag-vocabulary lookup call may have been removed"
    return 1
  fi
}

@test "brain-recall SKILL.md: three-tier tag table names all three tiers" {
  local missing=""
  for tier in "主题域" "具体机制" "禁止"; do
    grep -q "$tier" "$RECALL_SKILL_MD" || missing="${missing}${tier} "
  done
  if [ -n "$missing" ]; then
    echo "Missing tag-tier name(s) in $RECALL_SKILL_MD: $missing"
    return 1
  fi
}

@test "brain-recall SKILL.md: forbidden tag tier names all three category markers" {
  local missing=""
  grep -q 'cc-mem' "$RECALL_SKILL_MD" || missing="${missing}cc-mem(全覆盖来源标记示例) "
  grep -q '纯数字' "$RECALL_SKILL_MD" || missing="${missing}纯数字(说明文字) "
  for prefix in 'kind:' 'status:' 'volatility:'; do
    grep -qF "$prefix" "$RECALL_SKILL_MD" || missing="${missing}${prefix} "
  done
  if [ -n "$missing" ]; then
    echo "Missing forbidden-tag category marker(s) in $RECALL_SKILL_MD: $missing"
    return 1
  fi
}

@test "brain-curate SKILL.md: tag hygiene section header is present" {
  grep -qF '**tag 卫生**' "$CURATE_SKILL_MD"
}

# Extracts the three tag-hygiene jq filter programs from fenced bash code in
# brain-curate's "tag 卫生" block. Scoped between the "# 1. 纯数字" comment
# marker (the block's first labeled filter) and the following "rm -f"
# cleanup line, so it cannot drift onto the unrelated /export filters
# earlier in the file or the /update|/forget calls later in the file.
# _extract_export_jq_filter (used by assertion 3e above) accumulates until a
# line ending in "]'" closes a single-quoted jq program -- it stops at the
# FIRST such close, so it cannot be reused here where three separate jq
# programs sit back to back in the same fenced block. This extractor
# instead treats each "jq " line as opening a new program and closes each
# one on its own trailing `' "$BRAIN_EXPORT"` invocation line.
_extract_tag_hygiene_jq_filters() {
  local file="$1" region
  region=$(_fenced_bash_lines "$file" | awk -F: '
    {
      line = ""
      for (i = 2; i <= NF; i++) { line = (i==2) ? $i : line ":" $i }
    }
    line ~ /^# 1\. 纯数字/ { inregion=1 }
    inregion { print line }
    inregion && line ~ /^rm -f/ { exit }
  ')
  printf '%s\n' "$region" | awk '
    /^jq / { capturing=1; buf=$0 }
    !/^jq / && capturing { buf = buf "\n" $0 }
    capturing && $0 ~ /\x27[[:space:]]+"\$BRAIN_EXPORT"$/ { print buf; print "@@@FILTER@@@"; capturing=0; buf="" }
  '
}

_strip_jq_single_quotes() {
  local jqraw="$1" sq="'" jqexpr
  jqexpr="${jqraw#*$sq}"
  jqexpr="${jqexpr%$sq*}"
  printf '%s' "$jqexpr"
}

@test "brain-curate SKILL.md: tag hygiene jq filters are extractable and runnable" {
  local raw fcount=0 current="" line jqexpr jqresult jqrc

  raw="$(_extract_tag_hygiene_jq_filters "$CURATE_SKILL_MD")"
  [ -n "$raw" ] || {
    echo "Could not extract any tag-hygiene jq filter from fenced bash code in $CURATE_SKILL_MD -- the '# 1. 纯数字' ... 'rm -f' block may have been deleted or restructured"
    return 1
  }

  while IFS= read -r line; do
    if [ "$line" = "@@@FILTER@@@" ]; then
      fcount=$((fcount + 1))
      jqexpr="$(_strip_jq_single_quotes "$current")"
      jqresult=$(printf '%s' "$jqexpr" | jq -f /dev/stdin "$FIXTURE_EXPORT" 2>&1)
      jqrc=$?
      if [ "$jqrc" -ne 0 ]; then
        echo "Tag-hygiene jq filter #$fcount failed to execute against fixture (exit $jqrc):"
        echo "Filter: $jqexpr"
        echo "Error: $jqresult"
        return 1
      fi
      if [ "$fcount" -eq 2 ]; then
        # This is the coverage-sweep filter (jq program #2, the "全覆盖 tag"
        # check). All 4 fixture entries share the same stub tag "fixture" --
        # 100% coverage -- so this is the one filter whose result we can pin
        # to an exact value without over-fitting to prose. It's a real
        # logic anchor, not just a syntax check: a bug in the group_by /
        # coverage arithmetic (e.g. wrong denominator, off-by-one on the
        # >=0.5 threshold) would silently produce a different count/coverage
        # here even though the filter still parses and runs.
        local tag coverage
        tag=$(printf '%s' "$jqresult" | jq -r '.[0].tag // "MISSING"')
        coverage=$(printf '%s' "$jqresult" | jq -r '.[0].coverage // "MISSING"')
        if [ "$tag" != "fixture" ] || [ "$coverage" != "1" ]; then
          echo "Coverage-sweep filter (#2) expected exactly one tag 'fixture' at coverage 1 on the fixture, got:"
          echo "$jqresult"
          echo "Filter: $jqexpr"
          return 1
        fi
      fi
      current=""
    else
      current="${current}${line}"$'\n'
    fi
  done <<EOF
$raw
EOF

  # Sanity: must have extracted exactly the three documented filters (pure
  # numeric / full-coverage / singleton), not a broken extractor vacuously
  # passing on an empty or partial set.
  [ "$fcount" -eq 3 ] || {
    echo "Expected exactly 3 tag-hygiene jq filters, extracted $fcount"
    return 1
  }
}
