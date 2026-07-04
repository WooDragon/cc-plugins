---
name: ppt-init
description: |
  初始化 PPT 框架项目。在空目录中 scaffold 完整的 Astro 横向翻页 PPT 框架，
  包含 WebGL 背景、组件库、样式系统、导航逻辑和 Playwright 测试套件。
  Triggers: "初始化 PPT 项目", "scaffold PPT", "新建 PPT 框架", "ppt init",
  "create PPT project", "setup PPT framework".
---

# PPT Init

从零 scaffold 一个完整的 PPT 框架项目。执行完成后你将得到一个可直接 `npm run dev` 的 Astro 项目，具备横向翻页、WebGL 流体背景、组件化内容系统和 Playwright 测试。

## Step 0 · 依赖检查

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-deps.sh" --scope init
```

如果有 `[FAIL]` 项，按输出的「修复」命令逐一解决后重新运行。全部通过再继续。

## Step 1 · 目标目录确认

检查当前目录：

- 如果已有 `astro.config.ts` → **停止**，告知用户"当前目录已是 PPT 框架项目，无需重复初始化"
- 如果目录非空（有其他文件）→ 警告用户，确认是否继续
- 如果是空目录或用户确认 → 继续

## Step 2 · 复制框架文件

将 `${CLAUDE_PLUGIN_ROOT}/assets/scaffold/` 下的全部文件递归复制到当前目录：

```bash
cp -R "${CLAUDE_PLUGIN_ROOT}/assets/scaffold/." .
```

复制后确认关键文件存在：
```bash
ls astro.config.ts src/layouts/DeckLayout.astro src/styles/base.css
```

## Step 3 · 安装依赖

```bash
npm install
```

## Step 4 · 验证构建

```bash
npm run build
```

构建成功说明框架完整。如果报错，读取错误信息修复后重试。

## Step 5 · 可选 — 部署配置

询问用户：**"是否需要配置 AWS Amplify 部署能力？"**

### 如果是：

1. 复制部署文件：
```bash
cp "${CLAUDE_PLUGIN_ROOT}/assets/optional/deploy.sh" scripts/deploy.sh
cp "${CLAUDE_PLUGIN_ROOT}/assets/optional/amplify.yml" .
chmod +x scripts/deploy.sh
```

2. 询问用户提供：
   - **Amplify App ID**（在 AWS Console 创建 Amplify App 后获得）
   - **站点 URL**（如 `https://main.<app-id>.amplifyapp.com`）
   - **AWS Profile 名称**（AWS CLI 中配置的 profile）

3. 创建 `.env` 文件：
```bash
cat > .env << 'EOF'
AWS_PROFILE=<用户提供的 profile>
AWS_REGION=ap-southeast-1
PPT_AMPLIFY_APP_ID=<用户提供的 app-id>
PPT_SITE_URL=<用户提供的站点 URL>
EOF
```

4. 更新 `astro.config.ts` 中的 `site` 为用户提供的站点 URL

### 如果否：

跳过。项目仍然完全可用于本地开发（`npm run dev`）和预览（`npm run preview`）。后续需要部署时再调用 **ppt-deploy** skill 引导配置。

## Step 6 · 初始化 Git

```bash
git init
git add .
git commit -m "init: scaffold PPT framework via ppt-init"
```

## 完成

告知用户：

> PPT 框架初始化完成。你可以：
> - `npm run dev` 启动开发服务器（localhost:4321）
> - 使用 **ppt-create** skill 创建新 deck
> - 使用 **ppt-manage** skill 管理已有 deck

## 框架内容说明

scaffold 包含：

| 目录 | 内容 |
|------|------|
| `src/layouts/` | DeckLayout — 每个 deck 的 HTML 骨架（WebGL、导航、动画） |
| `src/components/slides/` | Slide / Chrome / Foot — 幻灯片结构组件 |
| `src/components/content/` | 11 个内容组件（Grid / StatCard / Pipeline 等） |
| `src/styles/` | 7 个共享 CSS（base / typography / grids / components / animation / nav / responsive） |
| `src/scripts/` | webgl / navigation / animation / overview — 运行时逻辑 |
| `src/shaders/` | 5 个 GLSL 着色器（2 主题 × 2 明暗 + vertex） |
| `tests/ppt/` | Playwright 通用测试套件（18 项验收） |
| `public/assets/` | Motion One 本地 fallback |

两套可用主题：`ink-classic`（暖灰）、`indigo-porcelain`（靛蓝）
