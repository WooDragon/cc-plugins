# vlog-daily-index — 旅行记忆分析师

在 Windows 上的 Codex 中，为一天旅行原片建立可恢复、可回到原文件与时码的每日事件、兴趣点、地点关联及完整转写索引。原素材只读，不剪辑或修改原片。

## 安装

此仓库沿用现有 marketplace 布局。技能源码位于 [`skills/vlog-daily-index/`](./skills/vlog-daily-index/)，版本为 `0.1.6`。

```bash
npx skills add WooDragon/cc-plugins -g
```

在技能选择中选取 `vlog-daily-index`，并确认安装目标为 Codex；也可以将整个 `skills/vlog-daily-index` 目录复制到自己的 Codex skills 目录。使用时请求“用旅行记忆分析师为这一天的旅行原片建立每日索引”。

## 宿主与依赖

语义工作流需要 Codex 提供真实原生子 Agent 工具和所需模型：当前主 session 原生能力允许的 Luna、Haiku 或 DeepSeek 读取视觉证据（Luna 仅 medium），Sol 汇总语义与地理证据，ROOT 审查并验收；纯视觉新领取必须提供当前 session 的原生工具/图像能力快照，默认按显式偏好或声明顺序选择，不能静默改派 Sol/旗舰。详见[路由合同](./skills/vlog-daily-index/references/vision-routing.md)；快照与请求不证明实际运行模型。Python 工具只处理确定性工作，不能替代或模拟这些 Agent。

需要用户配置 Python 3.12、FFmpeg/ffprobe、兼容的 ASR 服务和模型，以及运行所需的素材、行程和 GPS/地图证据。凭证、服务地址、本机工具路径和硬件配置由使用者在本地提供，不包含在发布源码中。实际依赖、安装和配置步骤见[安装说明](./skills/vlog-daily-index/references/setup.md)。

已验证环境为 Windows 上的 Codex。仓库的 Claude marketplace 注册只描述插件位置，不表示 Claude Code、其他 CLI 或其他宿主已具备此工作流所需的 Agent 工具和模型，也不承诺跨宿主直接兼容。

## 使用与验证

先让技能检查依赖、运行配置、行程证据和恢复状态，再按 [`SKILL.md`](./skills/vlog-daily-index/SKILL.md) 执行。输入和产物可能含精确位置、私人对话及旅行信息，应保存在使用者控制的位置；发给外部 ASR 或其他服务前遵从用户当前授权。

安装后可以在技能根目录使用本地 Python 运行：

```text
python -m unittest discover -s tests -v
python scripts/vlog_daily_index.py --help
```

测试使用合成数据和 mock。未配置 FFmpeg/ffprobe 时，真实合成媒体测试会明确跳过；测试成功不能替代新主机上的工具、ASR 协议与硬件小样验证。相关方法见[发布检验](./skills/vlog-daily-index/references/release-verification.md)。
