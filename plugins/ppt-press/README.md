# ppt-press

"电子杂志 × 电子墨水"风格网页 PPT 发布系统——完全自包含的 AI 技能包。

安装插件 → scaffold 新项目 → 开发内容 → 测试 → 部署，全链路通过 Claude Code 驱动，使用者不需要懂 Astro 或前端代码。

## 快速开始

```bash
# 安装插件
claude plugin add ppt-press@WooDragon-cc-plugins

# 在空目录中初始化 PPT 框架
mkdir my-ppt && cd my-ppt
# 然后对 Claude Code 说："初始化 PPT 项目"
```

## Skills

| Skill | 触发词 | 职责 | 前置依赖 |
|-------|--------|------|----------|
| **ppt-init** | "初始化 PPT"、"scaffold PPT"、"ppt init" | 从零 scaffold 完整框架 | Node.js ≥ 18 |
| **ppt-create** | "做 PPT"、"杂志风"、"web deck" | 需求澄清 → 大纲 → Astro 页面 → 自检 | 已初始化的框架 |
| **ppt-deploy** | "部署"、"发布"、"上线" | build → Playwright 测试 → Amplify 部署 | 框架 + Playwright + AWS |
| **ppt-manage** | "有哪些 PPT"、"找 deck" | 列表 / 搜索 / JSON / URL 复制 | 框架 |

## 依赖矩阵

| 依赖 | init | create | deploy | manage |
|------|:----:|:------:|:------:|:------:|
| Node.js ≥ 18 | ✓ | ✓ | ✓ | ✓ |
| npm install | · | ✓ | ✓ | · |
| Playwright browsers | · | · | ✓ | · |
| AWS CLI | · | · | ✓ | · |
| .env (AWS credentials) | · | · | ✓ | · |

**唯一硬依赖是 Node.js ≥ 18**——其余按使用的 skill 按需安装。

## 运行时依赖检查

插件内置 `scripts/check-deps.sh`，每个 skill 执行前自动验证对应 scope 的依赖。缺失项输出修复命令，LLM 可自行执行修复后重试，无需人工干预：

```
[PASS] node >= 18 (v22.6.0)
[PASS] npm (10.8.2)
[FAIL] node_modules/ — 不存在
       修复: npm install
```

## 典型工作流

```
用户: "帮我搭一个 PPT 项目"
  → ppt-init: scaffold 框架 → npm install → npm run build → 完成

用户: "帮我做一个关于 XX 的分享 PPT"
  → ppt-create: 6 问澄清 → 叙事弧 → 生成 Astro 页面 → checklist 自检

用户: "部署上线"
  → ppt-deploy: build → test all decks → deploy.sh → curl 验证 200

用户: "之前那个 MaaS 的链接是什么"
  → ppt-manage: node scripts/list-decks.js --search maas
```

## 安装

```bash
# 从 marketplace 安装
claude plugin add ppt-press@WooDragon-cc-plugins

# 验证
claude plugin list | grep ppt
```

安装后在任何目录启动 Claude Code，说"初始化 PPT 项目"即可开始。

## 包含什么

- **完整 PPT 框架 scaffold**（`assets/scaffold/`）——Astro 项目、WebGL shader、CSS 样式、JS 导航、Playwright 测试
- **4 个 AI Skills**——覆盖 init / create / deploy / manage 全生命周期
- **运行时依赖检查脚本**（`scripts/check-deps.sh`）——LLM 自助修复
- **可选部署模块**（`assets/optional/`）——AWS Amplify 部署脚本，init 时按需启用
