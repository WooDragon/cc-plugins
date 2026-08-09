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
