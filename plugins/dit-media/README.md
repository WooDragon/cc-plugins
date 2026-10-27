# dit-media — 素材归档与 DIT

按使用者现有规范，将相机视频从存储卡或备份盘归档到素材库，核对复制结果、统一同卷归位、维护近源 CSV，并按需分析或修复损坏视频。原名、历史来源与当前相对路径分别保留；不剪辑、调色或制作成片。

## 安装

此插件版本为 `0.1.0`，技能位于 [`skills/dit-media/`](./skills/dit-media/)。

Claude Code：

```text
claude plugin install dit-media@cc-plugins
```

Codex：

```text
npx skills add WooDragon/cc-plugins -g
```

选择 `dit-media` 和 Codex 安装目标，或将整个 `skills/dit-media` 目录复制到自己的技能目录。使用时请求“按现有规范归档这张卡的视频并校验索引”，并指定本次源目录、素材根和任务范围。

## 依赖与配置

归档工具使用 Python 3.10+ 标准库。Windows 优先 FastCopy，Linux/macOS 优先 rsync；媒体判读使用 FFmpeg/ffprobe、ExifTool，修复按需使用 untrunc。第三方工具由使用者从官方来源安装，源码不携带工具二进制。

每次提供实际的源根、素材根及工具位置；盘符、UNC、挂载点和工具目录均无固定默认值。先读取目标库现有规范，不自动创建或迁移索引，也不自动清卡或删除媒体。工作流与命令见 [`SKILL.md`](./skills/dit-media/SKILL.md) 和[工具说明](./skills/dit-media/references/tools.md)。

## 索引与查询配合

索引继续使用 UTF-8 BOM CSV 十列：`路径,原名,来源,大小,SHA256,校验,状态,配套,关联,备注`。当前路径、配套和关联相对于素材根；来源保留历史位置。CSV 与库内说明由原归档流程维护，格式见[索引说明](./skills/dit-media/references/index.md)。

需要跨日或跨库检索时，可另用 [vlog-daily-index](https://github.com/WooDragon/cc-plugins/tree/main/plugins/vlog-daily-index) 的可选 DuckDB 查询层读取明确指定的 DIT CSV 和每日索引产物。查询不改变 CSV 格式，也不代替归档校验；归档完成后按需刷新查询库。

## 验证

在技能目录运行：

```text
python -m unittest discover -s scripts -p "test_dit_tools.py" -v
python scripts/dit_tools.py --help
```

测试使用独立临时目录与合成数据，不访问真实媒体库。FastCopy 日志解析当前支持 4.2.1 英文 UTF-8 格式；工具版本、日志格式或平台变化时，先用小样验证。
