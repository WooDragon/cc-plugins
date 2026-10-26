# vlog-daily-index — 旅行记忆分析师

在 Codex 或 Claude Code 中，为一天旅行原片建立可恢复、可回到原文件与时码的每日事件、兴趣点、地点关联及完整转写索引。原素材只读，不剪辑或修改原片。

## 安装

此仓库沿用现有 marketplace 布局。技能源码位于 [`skills/vlog-daily-index/`](./skills/vlog-daily-index/)，版本为 `0.2.0`。两个宿主并列支持。

Codex：

```bash
npx skills add WooDragon/cc-plugins -g
```

在技能选择中选取 `vlog-daily-index`，并确认安装目标为 Codex；也可以将整个 `skills/vlog-daily-index` 目录复制到自己的 Codex skills 目录。

Claude Code：

```bash
claude plugin install vlog-daily-index@cc-plugins
```

三个子Agent（`vlog-daily-index:vlog-vision`、`vlog-daily-index:vlog-semantic`、`vlog-daily-index:vlog-geography`）随插件提供。宿主差异见[宿主说明](./skills/vlog-daily-index/references/hosts.md)。

每个子Agent 定义正文都带一节 `## Execution Discipline`（窄读，以及压缩后以工作树为准恢复）。它放在 agent 正文而不是预加载 skill 里，是因为 agent 正文进入 system prompt、每次请求原样重发，不受压缩影响；`skills:` 预加载走 user 角色消息，压缩后不保留。

使用时请求“用旅行记忆分析师为这一天的旅行原片建立每日索引”。

## 宿主与依赖

语义工作流需要宿主（Codex 或 Claude Code）提供真实原生子Agent工具和所需模型：视觉Agent读取视觉证据，语义Agent与地理Agent汇总语义与地理证据，ROOT 审查并验收；各角色的宿主绑定见[宿主说明](./skills/vlog-daily-index/references/hosts.md)；用户明确指定模型时按用户选择执行。Python 工具只处理确定性工作，不能替代或模拟这些 Agent。

需要用户配置 Python 3.12、FFmpeg/ffprobe、兼容的 ASR 服务和模型，以及运行所需的素材、行程和 GPS/地图证据。凭证、服务地址、本机工具路径和硬件配置由使用者在本地提供，不包含在发布源码中。实际依赖、安装和配置步骤见[安装说明](./skills/vlog-daily-index/references/setup.md)。

各宿主的验证边界：Windows 上的 Codex 已端到端验证；Claude Code 侧只核对了插件清单与 agent frontmatter 结构，插件加载、agent 解析与完整流水线均未实测。其他宿主未验证。

## 使用与验证

先让技能检查依赖、运行配置、行程证据和恢复状态，再按 [`SKILL.md`](./skills/vlog-daily-index/SKILL.md) 执行。输入和产物可能含精确位置、私人对话及旅行信息，应保存在使用者控制的位置；发给外部 ASR 或其他服务前遵从用户当前授权。

安装后可以在技能根目录使用本地 Python 运行：

```text
python -m unittest discover -s tests -v
python scripts/vlog_daily_index.py --help
```

测试使用合成数据和 mock。未配置 FFmpeg/ffprobe 时，真实合成媒体测试会明确跳过；测试成功不能替代新主机上的工具、ASR 协议与硬件小样验证。相关方法见[发布检验](./skills/vlog-daily-index/references/release-verification.md)。
