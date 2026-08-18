# deep-research 插件

多模型研究采集插件。核心是 `scripts/harvest.py` 及其子模块，跑多模型 panel 采集 → judge → merge → 引用验证 pipeline。

## 代码结构（改代码前必读）

`scripts/harvest.py`（主编排层）+ 三个子模块，单向无环依赖 DAG：

| 模块 | 职责 |
|------|------|
| `scripts/harvest.py` | 主编排：pipeline / worker / judge / merge / verify / CLI |
| `scripts/harvest_handoff.py` | harvest 交接：WIP 校验、compact manifest 与 evidence ledger、hash 绑定。本模块是零外部依赖叶子，不 import harvest。 |
| `scripts/harvest_safety.py` | SSRF 守卫 / 域黑名单 / 路径沙箱 / 限流 / URL 规范化（零外部依赖叶子） |
| `scripts/harvest_search/` | 3 个 web search backend（gemini-grounding/tavily/duckduckgo）+ do_search 编排 |
| `scripts/harvest_search/social.py` | 独立社交搜索链（search_social tool，backend-agnostic，现仅 grok-x） |
| `scripts/harvest_fetch/` | 4 个 URL fetch backend + do_fetch 编排 |
| `scripts/harvest_clients/base.py` | HTTP/SSE 原语 + curl_cffi 传输能力 |
| `scripts/harvest_clients/grok_cli.py` | grok-4.5 panel client，本地 grok CLI 驱动，伪装 run_worker 两阶段 tool-use 契约 |
| `scripts/harvest_clients/grok_exec.py` | grok CLI 共享执行/解析叶子模块（run_grok_plain + parse_embedded_json），grok_cli 与 social.py 共用 |

**铁律**：search 与 fetch 严格平级互不 import；safety 与 clients.base 是叶子，不 import 主模块。social 链（search_social/grok-x）与 web 链（search/do_search）相互独立，一方失败不阻塞另一方；grok_exec 是叶子模块，只被 grok_cli 与 social.py 引用，不 import 主模块或平级 backend。grok CLI 未安装时优雅降级：grok-* panel 模型从 roster 过滤、grok-x social backend 跳过，整管线不因此 FAILED。加 backend、改安全策略、改测试 patch（facade mock 穿透规则）前，先读上表模块地图 + 本节铁律。

**mock 穿透约束**：测试 patch 必须打在符号的真实使用点（`harvest_search.*` / `harvest_fetch.*` / `harvest_clients.base.*`），不要打 `harvest.*` re-export 面——后者靠 stdlib 单例巧合生效，清死 import 后会静默失效。

延伸阅读（本机 research 仓，非安装依赖，缺失不影响插件运行）：完整依赖 DAG 与维护决策树见 `research/docs/architecture/harvest-code-structure.md`；运行时行为 / 数据流 / 产物 schema / verify.json 状态机见 `research/docs/architecture/harvest-architecture.md`。

## 版本

功能性变更（scripts/、skills/、hooks/ 的 bug fix / feature / 重构改外部行为）须同步 bump 两处版本号：
`.claude-plugin/plugin.json` 与仓库根 `.claude-plugin/marketplace.json` 的 deep-research 条目。两处不一致禁止 push。
