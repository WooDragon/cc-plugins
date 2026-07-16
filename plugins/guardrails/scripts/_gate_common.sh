#!/usr/bin/env bash
# guardrails 包内共享库 — code-size.sh / git-push-guard.sh 共享的无副作用纯函数。
#
# 只抽两个 hook 之间真正重复的输入解析/防御样板（jq 探测、字段提取、bypass
# 开关判定）。绝不抽顶层兜底：code-size 用 `_main 2>/dev/null || true` 软兜底
# 全吞，git-push 用逐步 `exit 0` + 命中 `exit 2` 硬阻断，两者 fail-open 哲学
# 相反，合并顶层兜底会破坏 git-push 的阻断语义。

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

# _gate_instruction_files <root> — 枚举 <root> 树下的 agent 指令文件，一行
# 一个绝对/相对路径输出到 stdout。纯只读函数，无副作用。
#
# 文件名白名单（递归覆盖子目录，maxdepth 6）：
#   CLAUDE.md AGENTS.md GEMINI.md .cursorrules .clinerules .windsurfrules
#   .github/copilot-instructions.md .cursor/rules/*.mdc
# 排除目录：.git node_modules vendor dist web/dist（用 -prune，不下探）。
_gate_instruction_files() {
  local root="$1"
  [ -n "$root" ] && [ -d "$root" ] || return 0
  find "$root" -maxdepth 6 \
    \( -path "*/.git" -o -path "*/node_modules" -o -path "*/vendor" \
       -o -path "*/dist" -o -path "*/web/dist" \) -prune -o \
    -type f \( \
      -name 'CLAUDE.md' -o \
      -name 'AGENTS.md' -o \
      -name 'GEMINI.md' -o \
      -name '.cursorrules' -o \
      -name '.clinerules' -o \
      -name '.windsurfrules' -o \
      -path '*/.github/copilot-instructions.md' -o \
      -path '*/.cursor/rules/*.mdc' \
    \) -print 2>/dev/null
}

# _gate_scan_hidden <file> — 用 perl 逐行扫隐藏 Unicode 码点，命中输出
# "行号:U+XXXX"（一行一命中）。纯只读函数，只读文件、写 stdout，无副作用。
#
# 码点集（严格：零宽 U+200B-U+200D/U+2060-U+2064；bidi 控制
# U+200E-U+200F/U+202A-U+202E/U+2066-U+2069；tag 字符 U+E0000-U+E007F；
# 以及 U+FEFF）。首行行首的合法 BOM 会被剥离后再扫描该行（不是整行跳过）。
# 单文件命中数达 MAX_HITS（默认 10，同名环境变量可覆盖）即停止扫描，并追加
# 反盲化强提示，防止用合法 emoji 占满配额来掩护后续真 payload。
_gate_scan_hidden() {
  local file="$1"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  command -v perl >/dev/null 2>&1 || return 0

  MAX_HITS="${MAX_HITS:-10}" perl -CSD -ne '
    use utf8;
    BEGIN { $max = $ENV{MAX_HITS} || 10; $hits = 0; }
    eval {
      s/^\x{FEFF}// if $. == 1;
      while (/([\x{200B}-\x{200D}\x{2060}-\x{2064}\x{200E}-\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}\x{FEFF}\x{E0000}-\x{E007F}])/g) {
        $hits++;
        printf("%d:U+%04X\n", $., ord($1));
        if ($hits >= $max) {
          print "[警告] 扫描已截断,存在利用 emoji 掩护恶意指令的极高风险,必须直接读取该文件排查剩余内容\n";
          exit;
        }
      }
    };
  ' "$file" 2>/dev/null
}
