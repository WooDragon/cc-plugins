# cc-plugins

WooDragon 的 Claude Code 插件 marketplace。

## 项目结构

```
.claude-plugin/marketplace.json   # marketplace 元数据（插件注册、版本）
plugins/
  plan-review/                    # 对抗性审阅插件
    .claude-plugin/plugin.json    # 插件元数据
    hooks/hooks.json              # PreToolUse hook 声明
    scripts/plan-review.sh        # 核心脚本
```

## 开发踩坑记录

### Marketplace 命名限制

marketplace name 禁止包含 `claude`、`anthropic`、`official` 等关键词（反冒充机制）。最初用 `claude-plugins` 被拒，改为 `cc-plugins` 通过。

### hooks 声明重复加载

`hooks/hooks.json` 是框架约定路径，会被自动加载。若在 `plugin.json` 中再声明 `"hooks": "./hooks/hooks.json"`，会触发 `Duplicate hooks file detected` 错误。plugin.json 的 hooks 字段仅用于声明**非约定路径**的额外 hook 文件。

### 版本号双写对齐

插件版本号存在于两处：`marketplace.json` 的 plugins 条目和插件自身的 `plugin.json`。bump 版本时必须两处同步修改，否则 `claude plugin update` 检测不到新版本。

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `REVIEW_ENGINE` | `gemini` | 审阅引擎：`gemini` 或 `claude` |
| `REVIEW_DISABLED` | `0` | `1` 全局关闭 |
| `REVIEW_DRY_RUN` | `0` | `1` 跳过引擎调用 |
| `REVIEW_MAX_ROUNDS` | `3` | 最大磋商轮次 |

旧变量 `GEMINI_REVIEW_OFF`、`GEMINI_DRY_RUN`、`GEMINI_MAX_REVIEWS` 通过脚本内 fallback 继续生效。
