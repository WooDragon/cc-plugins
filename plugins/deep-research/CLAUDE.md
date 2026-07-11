# deep-research 插件

多模型研究采集插件。核心是 `scripts/harvest.py` 及其子模块，跑多模型 panel 采集 → judge → merge → 引用验证 pipeline。

## 代码结构（改代码前必读）

`scripts/harvest.py`（主编排层）+ 三个子模块，单向无环依赖 DAG：

| 模块 | 职责 |
|------|------|
| `scripts/harvest.py` | 主编排：pipeline / worker / judge / merge / verify / CLI |
| `scripts/harvest_safety.py` | SSRF 守卫 / 域黑名单 / 路径沙箱 / 限流 / URL 规范化（零外部依赖叶子） |
| `scripts/harvest_search/` | 4 个 web search backend + do_search 编排 |
| `scripts/harvest_fetch/` | 4 个 URL fetch backend + do_fetch 编排 |
| `scripts/harvest_clients/base.py` | HTTP/SSE 原语 + curl_cffi 传输能力 |

**铁律**：search 与 fetch 严格平级互不 import；safety 与 clients.base 是叶子，不 import 主模块。加 backend、改安全策略、改测试 patch（facade mock 穿透规则）前，先读完整代码地图——模块地图、依赖 DAG、维护决策树、mock 穿透约束都在其中：

@../../../../research/docs/architecture/harvest-code-structure.md

运行时行为 / 数据流 / 产物 schema / verify.json 状态机是另一篇正交文档（67KB，按需读，不常驻）：`research/docs/architecture/harvest-architecture.md`。

## 版本

功能性变更（scripts/、skills/、hooks/ 的 bug fix / feature / 重构改外部行为）须同步 bump 两处版本号：
`.claude-plugin/plugin.json` 与仓库根 `.claude-plugin/marketplace.json` 的 deep-research 条目。两处不一致禁止 push。
