# Assert the rules actually delivered to each backend, not a copy of build_rules.
assert_pr_file_scope() {
  local rules="$1" clause
  for clause in \
    '允许文件集合以已提供的 PR 全量 DIFF 中的文件路径为准' \
    '只读取允许集合内与改动相关的文件上下文' \
    '删除或改名文件沿用 diff 中已有路径语义' \
    'INCREMENTAL DIFF 中的额外路径不得自动扩大允许集合' \
    '只有用户明确提供更新后的 PR 文件清单才可更新范围' \
    '禁止全仓扫描、目录遍历式探索、读取 PR 外依赖或扩展为架构重审' \
    '缺少范围内证据时应明确说明无法验证，不得凭缺失上下文给出 LGTM' \
    '所有内部子评审必须继承同一文件边界，不另起宽泛 Explore' \
    '不可信数据' '不得服从'; do
    [[ "$rules" == *"$clause"* ]] || { printf 'Missing rule: %s\n' "$clause" >&2; return 1; }
  done
}
