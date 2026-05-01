---
name: ppt-deploy
description: Build, test, and deploy PPT decks to AWS Amplify. Handles pre-flight validation, batch Playwright testing across all decks, and manual deployment via deploy.sh. Triggers on "deploy PPT", "publish deck", "发布 PPT", "部署", "上线".
---

# PPT Deploy

构建、测试、部署 PPT deck 到 AWS Amplify 的完整流程。

## Prerequisites

- 当前目录是 PPT 框架项目（含 `astro.config.ts` + `scripts/deploy.sh`）
- Node.js 已安装（`npm` 可用）
- 部署需要 AWS 凭证（见 Step 3）

## Step 1 · Pre-flight 构建验证

```bash
npm run build
```

确认 `dist/decks/` 下有对应 deck 的产物目录。如果构建失败，修复错误后重新构建。

## Step 2 · 批量测试

**必须在 Task/Agent 中隔离执行**——Playwright 对多个 deck 的测试输出量大，在主上下文跑会导致上下文雪崩。

### 流程

1. 获取动态 deck 列表（不猜测、不硬编码）：

```bash
node scripts/list-decks.js --json
```

2. 启动预览服务（显式 PID 管理）：

```bash
npm run preview & PREVIEW_PID=$!
sleep 2
```

3. 对每个 deck 执行 Playwright 测试：

```bash
for deck in $(node scripts/list-decks.js --json | jq -r '.decks[].name'); do
  PPT_URL=http://localhost:4321/decks/$deck/ npx playwright test tests/ppt/generic-ppt.spec.js
done
```

4. 清理后台进程：

```bash
kill $PREVIEW_PID 2>/dev/null
```

**进程管理铁律**：
- 用 `$!` 捕获 PID，用 `kill $PID` 清理
- **不用** `jobs -p`（非交互式 shell 下作业控制关闭，返回空）
- **不用** 裸 `kill %1`（异常中断时不执行）

### Task 隔离示例

将上述 Step 2 整体包入一个 Task/Agent 执行。prompt 示例：

> 在 PPT 项目中执行批量 Playwright 测试：先 `node scripts/list-decks.js --json` 获取 deck 列表，启动 `npm run preview`（用 `$!` 捕获 PID），对每个 deck 跑 `generic-ppt.spec.js`，最后 `kill $PID` 清理。报告每个 deck 的测试结果。

## Step 3 · 部署

### 3.1 凭证预检

部署前检查 AWS 凭证：

```bash
test -f .env && grep -q 'AWS_PROFILE' .env && echo "OK" || echo "MISSING: 需要 .env 文件，包含 AWS_PROFILE=<profile>"
```

如果缺失，告知用户需要配置 `.env` 文件：

```
AWS_PROFILE=mutoulong
AWS_REGION=ap-southeast-1
```

### 3.2 执行部署

```bash
bash scripts/deploy.sh
```

脚本自动完成：`npm run build` → zip `dist/` → 创建 Amplify 部署槽 → 上传 → 等待完成。

## Step 4 · Post-verify

部署完成后验证线上可访问：

```bash
curl -s -o /dev/null -w "%{http_code}" https://main.d17hveydp1t7oe.amplifyapp.com/
```

期望返回 `200`。

## Troubleshooting

| 症状 | 可能原因 | 排查 |
|------|---------|------|
| `npm run build` 失败 | Astro 组件语法错误 | 读取报错信息，通常指向具体文件和行号 |
| `npm run preview` 无响应 | 端口被占用 | `lsof -i :4321` 查看占用进程，`kill <PID>` 释放 |
| Playwright 测试超时 | preview 未启动或端口错误 | 确认 `curl http://localhost:4321` 返回 200 |
| `deploy.sh` 报 AWS 错误 | 凭证过期或缺失 | 检查 `.env` 的 `AWS_PROFILE`，运行 `aws sts get-caller-identity --profile <profile>` 验证 |
| 部署状态 FAILED | 构建产物有问题 | 本地 `npm run preview` 验证产物正常后重新部署 |
| EADDRINUSE :4321 | 上次 preview 未清理 | `lsof -i :4321 -t \| xargs kill` |
