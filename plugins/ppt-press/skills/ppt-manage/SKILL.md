---
name: ppt-manage
description: List, search, and retrieve PPT deck URLs. Query the deck inventory by name or keyword, get JSON metadata, or copy URLs to clipboard. Triggers on "list decks", "find PPT", "查找 PPT", "有哪些 deck", "deck URL".
---

# PPT Manage

PPT deck 检索与管理工具。

## Prerequisites

- 当前目录是 PPT 框架项目（含 `scripts/list-decks.js`）
- 需先执行过 `npm run build`（检索依赖 `dist/manifest.json`）

## 命令

所有命令在项目根目录执行：

```bash
# 列出全部 deck（序号 / name / 类型 / 标题 + URL）
node scripts/list-decks.js

# 按 name 或标题模糊搜索（大小写不敏感）
node scripts/list-decks.js --search <keyword>

# 获取原始 JSON（编程处理或需要完整元数据时）
node scripts/list-decks.js --json

# 复制指定 deck 的 URL 到剪贴板（仅用户明确要求时）
node scripts/list-decks.js --copy <deck-name>
```

## 输出字段

| 字段 | 含义 |
|------|------|
| `name` | deck 目录名，用于 `--copy` 的精确匹配参数 |
| `title` | HTML `<title>` 内容，无则显示 name |
| `type` | `public`（明文公开）/ `encrypted`（AES-GCM 加密）/ `unknown` |
| `url` | 完整访问地址 |

## 使用规则

- **默认用列表模式**：人类可读，直接展示给用户
- **用 `--json` 的时机**：需要引用多个字段，或用户要求 JSON
- **用 `--copy` 的时机**：用户明确说"复制到剪贴板"
- **`--search` vs 无参数**：知道关键词用 `--search`，否则列全部

## 跨 Skill 导航

| 需求 | 使用 |
|------|------|
| 创建新 deck | **ppt-create** skill |
| 构建 + 测试 + 部署 | **ppt-deploy** skill |
