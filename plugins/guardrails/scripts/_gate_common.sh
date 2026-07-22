#!/usr/bin/env bash
# guardrails 包内共享库 — code-size.sh / git-push-guard.sh / instruction-scan.sh /
# git-import-scan.sh 四个 hook 共享的无副作用纯函数。
#
# 只抽 hook 之间真正重复的输入解析/防御样板（jq 探测、字段提取、bypass
# 开关判定），以及 instruction-scan.sh/git-import-scan.sh 共用的隐藏字符扫描
# 逻辑（_gate_instruction_files 枚举指令文件、_gate_scan_hidden 扫隐藏
# Unicode 码点）。绝不抽顶层兜底：code-size/instruction-scan/git-import-scan
# 用 `_main 2>/dev/null || true` 软兜底全吞，git-push 用逐步 `exit 0` + 命中
# `exit 2` 硬阻断，两者 fail-open 哲学相反，合并顶层兜底会破坏 git-push 的
# 阻断语义。

# _gate_require_jq — 探测 jq 是否可用。只返回状态码，调用方自行决定
# return 还是 exit（不代为退出）。
_gate_require_jq() {
  command -v jq >/dev/null 2>&1
}

# _gate_field <json> <jq-expr> — 提取字段，失败（含 JSON 解析失败）时状态码非零。
# 位置参数用双引号，避免把 jq 表达式字面量化。
_gate_field() {
  jq -r "$2" <<< "$1" 2>/dev/null
}

# _gate_bypass_on <VAR_NAME> — 间接展开检查同名环境变量是否等于 "1"。
# $1 是变量名字符串，${!1} 取其值；未设置时按 "0" 处理。
_gate_bypass_on() {
  [ "${!1:-0}" = "1" ]
}

# _gate_in_tree <root> <path> — 判定 path 的真实物理路径（跟随 symlink）
# 是否落在 root 的物理树内。返回 0 表示在树内（放行扫描），非 0 表示越界
# 或解析失败（跳过）。零新二进制依赖，用已有的 perl Cwd::abs_path 解析。
_gate_in_tree() {
  local root="$1" path="$2"
  [ -n "$root" ] && [ -n "$path" ] || return 1
  command -v perl >/dev/null 2>&1 || return 1
  local rp_root rp_path
  rp_root=$(perl -MCwd=abs_path -e 'my $p=abs_path($ARGV[0]); print $p if defined $p' "$root" 2>/dev/null) || return 1
  rp_path=$(perl -MCwd=abs_path -e 'my $p=abs_path($ARGV[0]); print $p if defined $p' "$path" 2>/dev/null) || return 1
  [ -n "$rp_root" ] && [ -n "$rp_path" ] || return 1
  case "$rp_path" in
    "$rp_root"/*|"$rp_root") return 0 ;;
    *) return 1 ;;
  esac
}

# _gate_instruction_candidates <root> — 枚举 <root> 树下所有匹配白名单文件名的
# 候选（普通文件 + symlink，一行一路径到 stdout）。不做越界校验，是
# _gate_instruction_files / _gate_symlink_escapes 的共同上游，让白名单只有一处
# 定义。纯只读函数，无副作用。
#
# 文件名白名单（递归覆盖子目录，maxdepth 6；含 symlink）：
#   CLAUDE.md CLAUDE.local.md AGENTS.md AGENT.md GEMINI.md
#   .cursorrules .continuerules .clinerules .windsurfrules
#   .roorules .roorules-* .roo/rules/* .roo/rules-*/*
#   .clinerules/*.md .clinerules/*.txt
#   .windsurf/rules/*.md .devin/rules/*.md .continue/rules/*.md
#   .github/copilot-instructions.md .github/instructions/*.instructions.md
#   .cursor/rules/*.mdc
# 排除目录：.git node_modules vendor dist web/dist（用 -prune，不下探）。
_gate_instruction_candidates() {
  local root="$1"
  [ -n "$root" ] && [ -d "$root" ] || return 0
  find "$root" -maxdepth 6 \
    \( -path "*/.git" -o -path "*/node_modules" -o -path "*/vendor" \
       -o -path "*/dist" -o -path "*/web/dist" \) -prune -o \
    \( -type f -o -type l \) \( \
      -name 'CLAUDE.md' -o \
      -name 'CLAUDE.local.md' -o \
      -name 'AGENTS.md' -o \
      -name 'AGENT.md' -o \
      -name 'GEMINI.md' -o \
      -name '.cursorrules' -o \
      -name '.continuerules' -o \
      -name '.clinerules' -o \
      -name '.windsurfrules' -o \
      -name '.roorules' -o \
      -name '.roorules-*' -o \
      -path '*/.roo/rules/*' -o \
      -path '*/.roo/rules-*/*' -o \
      -path '*/.clinerules/*.md' -o \
      -path '*/.clinerules/*.txt' -o \
      -path '*/.windsurf/rules/*.md' -o \
      -path '*/.devin/rules/*.md' -o \
      -path '*/.continue/rules/*.md' -o \
      -path '*/.github/copilot-instructions.md' -o \
      -path '*/.github/instructions/*.instructions.md' -o \
      -path '*/.cursor/rules/*.mdc' \
    \) -print 2>/dev/null
  return 0
}

# _gate_instruction_files <root> — 枚举 <root> 树下真实物理路径落在树内的 agent
# 指令文件，一行一路径到 stdout。纯只读函数，无副作用。越界 symlink（目标在
# cwd 树外）被排除，改由 _gate_symlink_escapes 单独告警。
_gate_instruction_files() {
  local root="$1"
  [ -n "$root" ] && [ -d "$root" ] || return 0
  while IFS= read -r f; do
    _gate_in_tree "$root" "$f" && printf '%s\n' "$f"
  done < <(_gate_instruction_candidates "$root")
  return 0
}

# _gate_symlink_escapes <root> — 枚举命中白名单、且其 symlink 目标解析后落在
# <root> 树外的指令文件，一行输出 "symlink路径 -> 解析目标"。纯只读函数：只解析
# 路径，绝不打开/读取树外目标内容（不引入扫描逸出），只把"无法核验"这一事实
# 显式化，消除静默盲区。悬空 symlink（目标解析失败）保持沉默，不报为越界。
_gate_symlink_escapes() {
  local root="$1"
  [ -n "$root" ] && [ -d "$root" ] || return 0
  command -v perl >/dev/null 2>&1 || return 0
  local rp_root
  rp_root=$(perl -MCwd=abs_path -e 'my $p=abs_path($ARGV[0]); print $p if defined $p' "$root" 2>/dev/null) || return 0
  [ -n "$rp_root" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] && [ -L "$f" ] || continue
    local rp_path
    rp_path=$(perl -MCwd=abs_path -e 'my $p=abs_path($ARGV[0]); print $p if defined $p' "$f" 2>/dev/null)
    [ -n "$rp_path" ] || continue
    case "$rp_path" in
      "$rp_root"/*|"$rp_root") ;;
      *) printf '%s -> %s\n' "$f" "$rp_path" ;;
    esac
  done < <(_gate_instruction_candidates "$root")
  return 0
}

# _gate_scan_hidden <file> — 用 perl 逐行扫隐藏 Unicode 码点，命中输出
# "行号:U+XXXX"（一行一命中）。纯只读函数，只读文件、写 stdout，无副作用。
#
# 码点集（严格：零宽 U+200B-U+200D/U+2060-U+2064；bidi 控制
# U+200E-U+200F/U+202A-U+202E/U+2066-U+2069；tag 字符 U+E0000-U+E007F；
# 以及 U+FEFF）。首行行首的合法 BOM 会被剥离后再扫描该行（不是整行跳过）。
# 单文件命中数达 MAX_HITS（默认 10，同名环境变量可覆盖）即停止扫描，并追加
# 反盲化强提示，防止用大量隐藏码点占满配额来掩护后续真 payload。
_gate_scan_hidden() {
  local file="$1"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  command -v perl >/dev/null 2>&1 || return 0

  MAX_HITS="${MAX_HITS:-10}" perl -CSD -ne '
    use utf8;
    BEGIN { $max = (defined($ENV{MAX_HITS}) && $ENV{MAX_HITS} ne "") ? $ENV{MAX_HITS} : 10; $hits = 0; }
    eval {
      s/^\x{FEFF}// if $. == 1;
      while (/([\x{200B}-\x{200D}\x{2060}-\x{2064}\x{200E}-\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}\x{FEFF}\x{E0000}-\x{E007F}])/g) {
        $hits++;
        printf("%d:U+%04X\n", $., ord($1));
        if ($hits >= $max) {
          print "[警告] 该文件隐藏 Unicode 字符过多,已截断,存在恶意指令注入的极高风险,必须直接通读该文件全文排查剩余内容\n";
          exit;
        }
      }
    };
  ' "$file" 2>/dev/null
}
