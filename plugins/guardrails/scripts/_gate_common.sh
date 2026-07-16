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
