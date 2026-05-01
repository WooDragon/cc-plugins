# ppt-press

"电子杂志 × 电子墨水"风格网页 PPT 发布系统的 AI 技能包。

团队成员通过 Claude Code 驱动全流程：需求澄清 → 内容生产 → 构建测试 → 线上发布 → 检索管理。使用者不需要懂 Astro 或前端代码。

## 依赖

### 必须

| 依赖 | 说明 |
|------|------|
| **PPT 框架项目** | 包含 `astro.config.ts`、`src/layouts/DeckLayout.astro`、`scripts/deploy.sh` 的 Astro 仓库。联系项目管理员获取，或从模板仓库克隆 |
| **Node.js ≥ 18** | Astro 构建 + 预览服务 |
| **Claude Code** | AI 读取 skill 并执行操作 |

### 部署时需要

| 依赖 | 说明 |
|------|------|
| **AWS CLI** | `deploy.sh` 通过 Amplify API 上传构建产物 |
| **`.env` 文件** | 项目根目录，包含 `AWS_PROFILE` 和 `AWS_REGION` |

### 测试时需要

| 依赖 | 说明 |
|------|------|
| **Playwright** | `npx playwright install` 安装浏览器引擎 |

## Skills

| Skill | 触发词 | 职�� |
|-------|--------|------|
| **ppt-create** | "做 PPT"、"杂志风"、"web deck" | 需求澄清 → 大纲 → Astro 页面生成 → 质量自检 → 本地预览 |
| **ppt-deploy** | "部署"、"发布"、"上线" | `npm run build` → 批量 Playwright 测试 → `deploy.sh` 上传 Amplify → 线上验证 |
| **ppt-manage** | "有哪些 PPT"、"找 deck" | 列表 / 搜索 / JSON 导出 / URL 复制 |

### 典型工作流

```
用户: "帮我做一个关于 XX 的分享 PPT"
  → ppt-create: 6 问澄清 → 叙事弧 → 生成 Astro 页面 → checklist 自检

用户: "部署上线"
  → ppt-deploy: build → test all decks → deploy.sh → curl 验证 200

用户: "之前那个 MaaS 的链接是什么"
  → ppt-manage: node scripts/list-decks.js --search maas
```

## 安装

```bash
# 全局安装（推荐）
npx skills add WooDragon/cc-plugins -g

# 验证
npx skills ls -g | grep ppt
```

安装后在任何 PPT 框架项目目录启动 Claude Code，skills 自动可用。

## 不包含什么

- **不包含 PPT 框架本身**（Astro 项目、WebGL shader、CSS 样式、JS 导航逻辑）——这些在用户的项目仓库里
- **不包含可执行脚���**（`deploy.sh`、`list-decks.js`）——脚本留在项目中，skill 只教 AI 怎么用
- **不包含 hooks**——当前是纯 skills 插件，预留 hooks 扩展点（如未来的 ppt-guard 质量门禁）
