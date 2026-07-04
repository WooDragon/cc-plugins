# Playbooks 索引

研究类型剧本。执行研究任务时，Lead 根据研究类型选择对应剧本。

> 本文件对应原框架的 `playbooks/INDEX.md`，搬入插件后改名为 `playbooks-INDEX.md` 以与 `framework-INDEX.md` 区分。

## 选型决策树

```
研究任务 →
  ├─ 主要通过公开 Web 信息搜集？ → web-research.md
  ├─ 需要从 API/CLI 提取私有数据？ → data-extraction.md
  └─ 其他类型（文献综述/代码审计）→ 暂无专用剧本，参考上述最接近的剧本 + 项目 CLAUDE.md 定制
```

## 剧本列表

| 剧本 | 适用场景 | 核心特征 |
|------|----------|----------|
| [web-research.md](./web-research.md) | 技术调研、行业分析、竞品对比 | 双语搜索矩阵、Gemini CLI 工具链、信息源黑白名单 |
| [data-extraction.md](./data-extraction.md) | API 数据提取、多维表格分析、数据库审计 | tier 分层采集、hash 脱敏、域并行拆解、报告矩阵 |

## 扩展指南

新增剧本时：
1. 在本目录创建 `{type}.md`
2. 遵循 7 Stage 管线结构（可省略不适用的 Stage）
3. 更新本索引
4. 更新 `../assets/project-claude-md.tmpl` 的研究类型枚举
