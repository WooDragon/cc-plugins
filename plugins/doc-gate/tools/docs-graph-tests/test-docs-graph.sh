#!/usr/bin/env bash
# docs-graph.py BDD 测试套件
# 用法：./test-docs-graph.sh [--verbose]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL="${SCRIPT_DIR}/../docs-graph.py"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures"

VERBOSE=false
if [[ "${1:-}" == "--verbose" ]]; then
    VERBOSE=true
fi

PASS=0
FAIL=0

# 颜色（如果终端支持）
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    NC='\033[0m'
else
    GREEN=''
    RED=''
    NC=''
fi

pass() {
    local name="$1"
    PASS=$((PASS+1))
    echo -e "${GREEN}PASS${NC} $name"
}

fail() {
    local name="$1"
    local reason="$2"
    FAIL=$((FAIL+1))
    echo -e "${RED}FAIL${NC} $name: $reason"
}

vlog() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "  >> $*"
    fi
}

# 运行命令，返回 exit code，stdout 到变量
run_tool() {
    local output
    local rc=0
    output=$(python3 "$TOOL" "$@" 2>&1) || rc=$?
    echo "$output"
    return $rc
}

# run_tool_rc: 返回 exit code，不 set -e
run_tool_rc() {
    python3 "$TOOL" "$@" 2>&1 || true
}

################################################################################
# 解析边界
################################################################################

# chinese_filename: 中文文件名链接正确解析
scenario_chinese_filename() {
    local name="chinese_filename"
    local out rc=0
    out=$(python3 "$TOOL" --root "$FIXTURES_DIR" backlinks "subdir/child.md" 2>&1) || rc=$?
    vlog "backlinks subdir/child.md output: $out"
    if echo "$out" | grep -qF "中文文档.md"; then
        pass "$name"
    else
        fail "$name" "中文文档.md not found in backlinks of subdir/child.md (got: $out)"
    fi
}

# anchor_stripping: root.md#section 识别为指向 root.md
scenario_anchor_stripping() {
    local name="anchor_stripping"
    local out rc=0
    out=$(python3 "$TOOL" --root "$FIXTURES_DIR" links "anchored.md" 2>&1) || rc=$?
    vlog "links anchored.md: $out"
    if echo "$out" | grep -qF "root.md"; then
        pass "$name"
    else
        fail "$name" "root.md not found in links of anchored.md (got: $out)"
    fi
}

# url_encoding: %E4%B8%AD... 正确解码
scenario_url_encoding() {
    local name="url_encoding"
    local out rc=0
    out=$(python3 "$TOOL" --root "$FIXTURES_DIR" links "encoded.md" 2>&1) || rc=$?
    vlog "links encoded.md: $out"
    if echo "$out" | grep -qF "中文文档.md"; then
        pass "$name"
    else
        fail "$name" "中文文档.md not in links of encoded.md (got: $out)"
    fi
}

# deep_backtrack: ../../root.md 多级回溯正确解析
scenario_deep_backtrack() {
    local name="deep_backtrack"
    local out rc=0
    out=$(python3 "$TOOL" --root "$FIXTURES_DIR" links "subdir/deep/nested.md" 2>&1) || rc=$?
    vlog "links subdir/deep/nested.md: $out"
    if echo "$out" | grep -qF "root.md"; then
        pass "$name"
    else
        fail "$name" "root.md not in links of nested.md (got: $out)"
    fi
}

# codeblock_ignored: code block 内伪链接不计入
scenario_codeblock_ignored() {
    local name="codeblock_ignored"
    local out rc=0
    # check 只应报 root.md→nonexistent.md，不报 codeblock.md→nonexistent_in_codeblock.md
    out=$(python3 "$TOOL" --root "$FIXTURES_DIR" check 2>&1) || rc=$?
    vlog "check output: $out"
    if echo "$out" | grep -qF "nonexistent_in_codeblock.md"; then
        fail "$name" "nonexistent_in_codeblock.md should not appear in check (got: $out)"
    else
        pass "$name"
    fi
}

# image_excluded: ![img](x) 不计入，[text](x) 计入
scenario_image_excluded() {
    local name="image_excluded"
    local out rc=0
    out=$(python3 "$TOOL" --root "$FIXTURES_DIR" links "images.md" 2>&1) || rc=$?
    vlog "links images.md: $out"
    # photo.png should not appear, root.md should appear
    local img_found=false
    local real_found=false
    if echo "$out" | grep -qF "photo.png"; then img_found=true; fi
    if echo "$out" | grep -qF "root.md"; then real_found=true; fi

    if [[ "$img_found" == "true" ]]; then
        fail "$name" "photo.png (image) should not appear in links (got: $out)"
    elif [[ "$real_found" == "false" ]]; then
        fail "$name" "root.md should appear in links (got: $out)"
    else
        pass "$name"
    fi
}

# mixed_content: CLAUDE.md 式混合文件抽链完整
scenario_mixed_content() {
    local name="mixed_content"
    local out rc=0
    out=$(python3 "$TOOL" --root "$FIXTURES_DIR" links "mixed-claude.md" 2>&1) || rc=$?
    vlog "links mixed-claude.md: $out"
    local count
    count=$(echo "$out" | grep -c "\.md" || true)
    # mixed-claude.md has 3 links: root.md, subdir/child.md, subdir/sibling.md
    if [[ "$count" -ge 3 ]]; then
        pass "$name"
    else
        fail "$name" "expected 3+ links from mixed-claude.md, got $count (output: $out)"
    fi
}

################################################################################
# 子命令
################################################################################

# check_finds_broken: check 发现 root.md→nonexistent.md 断链，exit 1
scenario_check_finds_broken() {
    local name="check_finds_broken"
    local out
    local rc=0
    out=$(python3 "$TOOL" --root "$FIXTURES_DIR" check 2>&1) || rc=$?
    vlog "check output (rc=$rc): $out"
    if [[ "$rc" -eq 1 ]] && echo "$out" | grep -qF "nonexistent.md"; then
        pass "$name"
    else
        fail "$name" "expected exit 1 with nonexistent.md in output (rc=$rc, out=$out)"
    fi
}

# check_clean: 无断链时 exit 0
scenario_check_clean() {
    local name="check_clean"
    local out
    local rc=0
    out=$(python3 "$TOOL" --root "$FIXTURES_DIR/clean" check 2>&1) || rc=$?
    vlog "check clean output (rc=$rc): $out"
    if [[ "$rc" -eq 0 ]]; then
        pass "$name"
    else
        fail "$name" "expected exit 0 for clean fixtures (rc=$rc, out=$out)"
    fi
}

# backlinks_correct: backlinks subdir/child.md 返回所有引用方
scenario_backlinks_correct() {
    local name="backlinks_correct"
    local out rc=0
    out=$(python3 "$TOOL" --root "$FIXTURES_DIR" backlinks "subdir/child.md" 2>&1) || rc=$?
    vlog "backlinks: $out"
    # Expected: root.md, 中文文档.md, subdir/sibling.md, codeblock.md, mixed-claude.md
    local ok=true
    for expected in "root.md" "中文文档.md" "subdir/sibling.md"; do
        if ! echo "$out" | grep -qF "$expected"; then
            fail "$name" "expected '$expected' in backlinks (got: $out)"
            ok=false
            break
        fi
    done
    if [[ "$ok" == "true" ]]; then
        pass "$name"
    fi
}

# links_correct: links root.md 返回所有被引用方
scenario_links_correct() {
    local name="links_correct"
    local out rc=0
    out=$(python3 "$TOOL" --root "$FIXTURES_DIR" links "root.md" 2>&1) || rc=$?
    vlog "links root.md: $out"
    local ok=true
    for expected in "subdir/child.md" "中文文档.md"; do
        if ! echo "$out" | grep -qF "$expected"; then
            fail "$name" "expected '$expected' in links root.md (got: $out)"
            ok=false
            break
        fi
    done
    if [[ "$ok" == "true" ]]; then
        pass "$name"
    fi
}

# orphans_found: orphan.md 出现在 orphans 输出中
scenario_orphans_found() {
    local name="orphans_found"
    local out rc=0
    out=$(python3 "$TOOL" --root "$FIXTURES_DIR" orphans 2>&1) || rc=$?
    vlog "orphans: $out"
    if echo "$out" | grep -qF "orphan.md"; then
        pass "$name"
    else
        fail "$name" "orphan.md not in orphans output (got: $out)"
    fi
}

# orphans_whitelist: CLAUDE.md/README.md 不出现在 orphans 中
scenario_orphans_whitelist() {
    local name="orphans_whitelist"
    local out rc=0
    out=$(python3 "$TOOL" --root "$FIXTURES_DIR" orphans 2>&1) || rc=$?
    vlog "orphans: $out"
    local fail_found=false
    for whitelist in "CLAUDE.md" "README.md"; do
        # Match exact filename (not as part of path), use grep with line anchors
        if echo "$out" | grep -qE "(^|/)${whitelist}$"; then
            fail "$name" "$whitelist should not appear in orphans (got: $out)"
            fail_found=true
            break
        fi
    done
    if [[ "$fail_found" == "false" ]]; then
        pass "$name"
    fi
}

# hubs_ranking: 被引用最多的文件排第一
scenario_hubs_ranking() {
    local name="hubs_ranking"
    local out rc=0
    out=$(python3 "$TOOL" --root "$FIXTURES_DIR" hubs -n 3 2>&1) || rc=$?
    vlog "hubs: $out"
    # root.md has the most inlinks
    local first_line
    first_line=$(echo "$out" | head -1)
    if echo "$first_line" | grep -qF "root.md"; then
        pass "$name"
    else
        fail "$name" "expected root.md as top hub (first line: $first_line, full: $out)"
    fi
}

# related_2hop: related root.md 包含 2 跳可达文件
scenario_related_2hop() {
    local name="related_2hop"
    local out rc=0
    out=$(python3 "$TOOL" --root "$FIXTURES_DIR" related "root.md" 2>&1) || rc=$?
    vlog "related root.md: $out"
    # 1-hop: subdir/child.md, 中文文档.md
    # 2-hop from child.md: subdir/sibling.md
    local ok=true
    for expected in "subdir/child.md" "subdir/sibling.md" "中文文档.md"; do
        if ! echo "$out" | grep -qF "$expected"; then
            fail "$name" "expected '$expected' in related root.md (got: $out)"
            ok=false
            break
        fi
    done
    if [[ "$ok" == "true" ]]; then
        pass "$name"
    fi
}

# related_3hop_excluded: related A.md does not include D.md (3 hops away)
scenario_related_3hop_excluded() {
    local name="related_3hop_excluded"
    local out rc=0
    out=$(python3 "$TOOL" --root "$FIXTURES_DIR/chain" related "A.md" 2>&1) || rc=$?
    vlog "chain related A.md: $out"
    # B.md (1 hop), C.md (2 hops) should appear; D.md (3 hops) should NOT
    local b_found=false c_found=false d_found=false
    echo "$out" | grep -qF "B.md" && b_found=true
    echo "$out" | grep -qF "C.md" && c_found=true
    echo "$out" | grep -qF "D.md" && d_found=true

    if [[ "$d_found" == "true" ]]; then
        fail "$name" "D.md (3 hops) should not be in related A.md (got: $out)"
    elif [[ "$b_found" == "false" ]] || [[ "$c_found" == "false" ]]; then
        fail "$name" "B.md and C.md should be in related A.md (got: $out)"
    else
        pass "$name"
    fi
}

################################################################################
# 契约
################################################################################

# exit_code_0: 无断链 check → exit 0
scenario_exit_code_0() {
    local name="exit_code_0"
    local rc=0
    python3 "$TOOL" --root "$FIXTURES_DIR/clean" check > /dev/null 2>&1 || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        pass "$name"
    else
        fail "$name" "expected exit 0, got $rc"
    fi
}

# exit_code_1: 有断链 check → exit 1
scenario_exit_code_1() {
    local name="exit_code_1"
    local rc=0
    python3 "$TOOL" --root "$FIXTURES_DIR" check > /dev/null 2>&1 || rc=$?
    if [[ "$rc" -eq 1 ]]; then
        pass "$name"
    else
        fail "$name" "expected exit 1, got $rc"
    fi
}

# exit_code_2_bad_file: backlinks nonexistent.md → exit 2
scenario_exit_code_2_bad_file() {
    local name="exit_code_2_bad_file"
    local rc=0
    python3 "$TOOL" --root "$FIXTURES_DIR" backlinks "totally_nonexistent_file.md" > /dev/null 2>&1 || rc=$?
    if [[ "$rc" -eq 2 ]]; then
        pass "$name"
    else
        fail "$name" "expected exit 2, got $rc"
    fi
}

# exit_code_2_bad_cmd: 无效子命令 → exit 2
scenario_exit_code_2_bad_cmd() {
    local name="exit_code_2_bad_cmd"
    local rc=0
    python3 "$TOOL" --root "$FIXTURES_DIR" invalidsubcmd > /dev/null 2>&1 || rc=$?
    if [[ "$rc" -eq 2 ]]; then
        pass "$name"
    else
        fail "$name" "expected exit 2, got $rc"
    fi
}

# json_parseable: --json 输出可被 python3 解析
scenario_json_parseable() {
    local name="json_parseable"
    local out rc=0
    out=$(python3 "$TOOL" --root "$FIXTURES_DIR" --json check 2>&1) || rc=$?
    vlog "json check output: $out"
    if echo "$out" | python3 -c "import json,sys;json.load(sys.stdin)" 2>/dev/null; then
        pass "$name"
    else
        fail "$name" "output is not valid JSON (output: $out)"
    fi
}

################################################################################
# 排除
################################################################################

# agents_excluded: .agents/vendored.md 不出现在任何输出中
scenario_agents_excluded() {
    local name="agents_excluded"
    local out rc=0

    # check output
    out=$(python3 "$TOOL" --root "$FIXTURES_DIR" check 2>&1) || rc=$?
    if echo "$out" | grep -qi "vendored"; then
        fail "$name" "vendored.md appeared in check output (got: $out)"
        return
    fi

    # orphans output
    rc=0
    out=$(python3 "$TOOL" --root "$FIXTURES_DIR" orphans 2>&1) || rc=$?
    if echo "$out" | grep -qi "vendored"; then
        fail "$name" "vendored.md appeared in orphans output (got: $out)"
        return
    fi

    # hubs output
    rc=0
    out=$(python3 "$TOOL" --root "$FIXTURES_DIR" hubs 2>&1) || rc=$?
    if echo "$out" | grep -qi "vendored"; then
        fail "$name" "vendored.md appeared in hubs output (got: $out)"
        return
    fi

    pass "$name"
}

# external_links_filtered: https/mailto 链接不出现在 links 输出中
scenario_external_links_filtered() {
    local name="external_links_filtered"
    local out rc=0
    out=$(python3 "$TOOL" --root "$FIXTURES_DIR" links "file-with-external.md" 2>&1) || rc=$?
    vlog "links file-with-external.md: $out"
    if echo "$out" | grep -qE "https://|mailto:"; then
        fail "$name" "external links should not appear (got: $out)"
    else
        pass "$name"
    fi
}

################################################################################
# 负向
################################################################################

# empty_vault: 空目录扫描不报错，check exit 0
scenario_empty_vault() {
    local name="empty_vault"
    local tmpdir
    tmpdir=$(mktemp -d)
    local rc=0
    python3 "$TOOL" --root "$tmpdir" check > /dev/null 2>&1 || rc=$?
    rmdir "$tmpdir"
    if [[ "$rc" -eq 0 ]]; then
        pass "$name"
    else
        fail "$name" "expected exit 0 for empty vault, got $rc"
    fi
}

################################################################################
# 主流程
################################################################################

echo "docs-graph.py BDD 测试套件"
echo "TOOL: $TOOL"
echo "FIXTURES: $FIXTURES_DIR"
echo "---"

# 解析边界
scenario_chinese_filename
scenario_anchor_stripping
scenario_url_encoding
scenario_deep_backtrack
scenario_codeblock_ignored
scenario_image_excluded
scenario_mixed_content

# 子命令
scenario_check_finds_broken
scenario_check_clean
scenario_backlinks_correct
scenario_links_correct
scenario_orphans_found
scenario_orphans_whitelist
scenario_hubs_ranking
scenario_related_2hop
scenario_related_3hop_excluded

# 契约
scenario_exit_code_0
scenario_exit_code_1
scenario_exit_code_2_bad_file
scenario_exit_code_2_bad_cmd
scenario_json_parseable

# 排除
scenario_agents_excluded
scenario_external_links_filtered

# 负向
scenario_empty_vault

echo "---"
echo "结果: ${PASS} PASS / ${FAIL} FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
else
    exit 0
fi
