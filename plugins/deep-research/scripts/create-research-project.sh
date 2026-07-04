#!/bin/bash

# 深度研究项目初始化脚本 (v3)
#
# 用法:
#   ./create_research_project.sh "研究主题"                       # 交互式选择类型
#   ./create_research_project.sh "研究主题" --type web-research   # 指定类型
#   ./create_research_project.sh "研究主题" --type data-extraction
#   ./create_research_project.sh --help

set -euo pipefail

# ---------------------------------------------------------------------------
# 脚本所在目录（用于定位模板文件）
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/../skills/deep-research/assets"

# ---------------------------------------------------------------------------
# 支持的研究类型
# ---------------------------------------------------------------------------
VALID_TYPES=("web-research" "data-extraction")

# ---------------------------------------------------------------------------
# 帮助信息
# ---------------------------------------------------------------------------
show_help() {
    cat <<'USAGE'
用法: ./create_research_project.sh "研究主题" [--type <类型>]

参数:
  "研究主题"              研究主题名称（必填，第一个非 flag 参数）
  --type <类型>           研究类型，可选值：web-research | data-extraction
                          不指定时交互式提示选择
  --help                  显示本帮助信息

示例:
  ./create_research_project.sh "AI Agent 架构演进"
  ./create_research_project.sh "供应链数据分析" --type data-extraction
USAGE
    exit 0
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
TOPIC_NAME=""
PROJECT_TYPE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            show_help
            ;;
        --type)
            if [[ -z "${2:-}" ]]; then
                echo "错误: --type 需要参数值" >&2
                exit 1
            fi
            PROJECT_TYPE="$2"
            shift 2
            ;;
        -*)
            echo "错误: 未知参数 $1" >&2
            echo "使用 --help 查看用法" >&2
            exit 1
            ;;
        *)
            if [[ -z "$TOPIC_NAME" ]]; then
                TOPIC_NAME="$1"
            else
                echo "错误: 主题名称已指定，多余参数: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# 主题名称必填
if [[ -z "$TOPIC_NAME" ]]; then
    echo "错误: 请提供研究主题名称" >&2
    echo "用法: $0 \"研究主题名称\" [--type web-research|data-extraction]" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 类型验证 / 交互式选择
# ---------------------------------------------------------------------------
validate_type() {
    local t="$1"
    for valid in "${VALID_TYPES[@]}"; do
        [[ "$t" == "$valid" ]] && return 0
    done
    return 1
}

if [[ -n "$PROJECT_TYPE" ]]; then
    if ! validate_type "$PROJECT_TYPE"; then
        echo "错误: 不支持的类型 '$PROJECT_TYPE'" >&2
        echo "可选值: ${VALID_TYPES[*]}" >&2
        exit 1
    fi
else
    # 交互式选择——不做静默 fallback，必须由用户决定
    echo "请选择研究类型:"
    echo "  1) web-research     -- Web 信息搜集与综合分析"
    echo "  2) data-extraction  -- 结构化数据提取与清洗"
    echo ""
    while true; do
        read -rp "输入编号 (1/2): " choice
        case "$choice" in
            1) PROJECT_TYPE="web-research"; break ;;
            2) PROJECT_TYPE="data-extraction"; break ;;
            *) echo "无效选择，请输入 1 或 2" ;;
        esac
    done
fi

# ---------------------------------------------------------------------------
# 目录名和路径
#
# 项目建在用户当前工作目录（$(pwd)）下，因此 DIR_NAME 必须净化为安全 slug：
# 剥除路径分隔符 '/'、'..' 等，防止 topic="../foo" 或含 '/' 的主题穿越到
# 非预期路径。净化后为空（如主题全是特殊字符）则报错退出，不静默降级。
# ---------------------------------------------------------------------------
DIR_NAME=$(echo "$TOPIC_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
# 只保留字母/数字/下划线/连字符/CJK，其余（含 / . 空白等）一律替换为下划线，
# 再压缩连续下划线、去掉首尾下划线。
DIR_NAME=$(printf '%s' "$DIR_NAME" | sed -E 's#[^[:alnum:]_-]#_#g; s#_+#_#g; s#^_+##; s#_+$##')

if [[ -z "$DIR_NAME" ]]; then
    echo "错误: 主题名 '$TOPIC_NAME' 无法生成安全目录名（净化后为空），请换一个含字母/数字的主题" >&2
    exit 1
fi

PROJECT_DIR="$(pwd)/$DIR_NAME"

if [[ -d "$PROJECT_DIR" ]]; then
    echo "错误: 目录 $PROJECT_DIR 已存在" >&2
    exit 1
fi

echo "正在创建研究项目: $TOPIC_NAME"
echo "  类型: $PROJECT_TYPE"
echo "  目录: $PROJECT_DIR"

# ---------------------------------------------------------------------------
# 创建 v3 目录结构
# ---------------------------------------------------------------------------
mkdir -p "$PROJECT_DIR"/{pipeline/{1_raw,2_cleaned,3_structured,4_extracted},deliverables/{draft/{v1,review},final},intake/{requirements,background,constraints}}

# ---------------------------------------------------------------------------
# 在每个空目录放 .gitkeep
# ---------------------------------------------------------------------------
find "$PROJECT_DIR" -type d -empty -exec touch {}/.gitkeep \;

# ---------------------------------------------------------------------------
# 安全强制 -- .gitignore 注入
#
# 从模板复制项目 .gitignore。不提供 --no-gitignore 跳过开关。
# 原因：pipeline/1_raw/ 和 pipeline/2_cleaned/ 包含未脱敏的原始数据，
# 误提交到 Git 可能泄漏敏感信息。.gitignore 是最后一道防线，
# 删除它需要有意识地编辑文件，而不是传个 flag 就绕过。
# ---------------------------------------------------------------------------
GITIGNORE_TMPL="$TEMPLATE_DIR/project-gitignore.tmpl"
if [[ -f "$GITIGNORE_TMPL" ]]; then
    cp "$GITIGNORE_TMPL" "$PROJECT_DIR/.gitignore"
else
    echo "警告: 未找到 .gitignore 模板 ($GITIGNORE_TMPL)，使用内置默认值" >&2
    cat > "$PROJECT_DIR/.gitignore" << 'FALLBACK_GITIGNORE'
# v3 项目结构
pipeline/1_raw/
pipeline/2_cleaned/

# 敏感文件
*.local.env
*.credentials.json
*.pem
*.key

# 临时文件
*.tmp
*.log
*.cache
.DS_Store

# 保留目录结构
!**/.gitkeep
FALLBACK_GITIGNORE
fi

# ---------------------------------------------------------------------------
# sed 替换值转义
#
# TOPIC_NAME 是用户原始输入，直接插入 sed 替换式的 RHS 会被 sed 特殊字符
# （分隔符 | @、& 回引用、反斜杠）破坏或注入。统一转义后再用于所有替换。
# 转义顺序：先反斜杠，再 & 和两种分隔符 | @（一条字符类里 & 自引用即可）。
# ---------------------------------------------------------------------------
sed_escape() {
    printf '%s' "$1" | sed -e 's#[\\&|@]#\\&#g'
}
TOPIC_ESC=$(sed_escape "$TOPIC_NAME")

# ---------------------------------------------------------------------------
# 项目 CLAUDE.md -- 从模板复制并替换占位符
# ---------------------------------------------------------------------------
CLAUDE_TMPL="$TEMPLATE_DIR/project-claude-md.tmpl"
if [[ -f "$CLAUDE_TMPL" ]]; then
    # 注：研究类型占位符 {web-research | data-extraction} 内部含 '|'，
    # 故该条 sed 改用 '@' 作分隔符，避免与占位符内的 '|' 冲突（否则 sed 表达式被截断）。
    sed \
        -e "s|{TOPIC_NAME}|$TOPIC_ESC|g" \
        -e "s|{DATE}|$(date '+%Y-%m-%d')|g" \
        -e "s|{PLAYBOOK}|$PROJECT_TYPE|g" \
        -e "s@{web-research | data-extraction}@$PROJECT_TYPE@g" \
        "$CLAUDE_TMPL" > "$PROJECT_DIR/CLAUDE.md"
else
    echo "警告: 未找到 CLAUDE.md 模板 ($CLAUDE_TMPL)，跳过" >&2
fi

# ---------------------------------------------------------------------------
# research-goal.md -- 举证责任锚定（元原则 0）的物理载体
#
# G0 与用户对齐后填充 primary_job + Non-Goals + sign-off。
# 落在 intake/requirements/ 下（与现有 intake 结构一致），不污染项目根。
# ---------------------------------------------------------------------------
GOAL_TMPL="$TEMPLATE_DIR/research-goal.md.tmpl"
GOAL_DEST="$PROJECT_DIR/intake/requirements/research-goal.md"
if [[ -f "$GOAL_TMPL" ]]; then
    sed -e "s|{TOPIC_NAME}|$TOPIC_ESC|g" "$GOAL_TMPL" > "$GOAL_DEST"
else
    echo "警告: 未找到 research-goal.md 模板 ($GOAL_TMPL)，跳过" >&2
fi

# ---------------------------------------------------------------------------
# 项目 README.md -- 简化版，指向 CLAUDE.md
# ---------------------------------------------------------------------------
cat > "$PROJECT_DIR/README.md" << EOF
# $TOPIC_NAME

研究类型: $PROJECT_TYPE | 创建日期: $(date '+%Y-%m-%d')

## 目录结构

- \`intake/\` -- 需求、背景、约束文档
- \`pipeline/\` -- 管线中间产物（1_raw / 2_cleaned / 3_structured / 4_extracted）
- \`deliverables/\` -- 草稿与最终报告

## 详情

查看 \`CLAUDE.md\` 获取项目配置、框架引用和研究进度。
EOF

# ---------------------------------------------------------------------------
# 再次确保所有空目录有 .gitkeep（模板复制后可能新增空目录）
# ---------------------------------------------------------------------------
find "$PROJECT_DIR" -type d -empty -exec touch {}/.gitkeep \;

# ---------------------------------------------------------------------------
# 完成
# ---------------------------------------------------------------------------
echo ""
echo "项目创建成功"
echo ""
echo "目录结构:"
if command -v tree &>/dev/null; then
    tree -a --dirsfirst "$PROJECT_DIR"
else
    find "$PROJECT_DIR" -print | sort | sed "s|$PROJECT_DIR|.|"
fi
echo ""
echo "下一步:"
echo "  1. cd $PROJECT_DIR"
echo "  2. 编辑 CLAUDE.md 定义研究目标和范围"
echo "  3. 在 intake/ 中添加预置资料"
echo "  4. 按 playbook ($PROJECT_TYPE) 执行研究流程"
