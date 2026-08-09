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
