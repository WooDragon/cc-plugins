# 标准化归档工具

入口：[scripts/dit_tools.py](../scripts/dit_tools.py)。Python 3.10+，仅用标准库；用本机实际 Python 路径运行，不写死盘符、设备、日期或运行时位置。`--help` 查看参数。

成熟工具负责复制、媒体哈希与元数据读取：FastCopy/rsync、标准哈希工具、ffprobe、ExifTool（大文件加 `-api LargeFileSupport=1`）。本工具负责稳定的盘点、校验记录核对、同卷归位和索引发布；不转码、不猜测拍摄参数、不跨卷搬运、不清卡。新增能力应扩展本工具并补测试，不再为同一流程手写临时执行脚本。

所有 JSON 使用 UTF-8；输出文件必须不存在。清单、计划和回执放在同一个任务临时目录，不能放进被盘点的源目录。以下 `python` 指已确认的解释器，路径参数按实际环境填写并加引号。

## 1. 源清单

```text
python dit_tools.py snapshot --root <本次源目录> --out <source.json>
python dit_tools.py check-source --snapshot <source.json>
```

记录完整文件集合、大小和纳秒修改时间；第二条在复制结束后检查源是否变化。它不计算媒体哈希，不把大小/时间一致冒充内容校验。拒绝链接或越界目录。

## 2. 复制结果回执

先按 transfer.md 调用 FastCopy 并保存真实退出码。每批使用新的逐文件日志，不追加旧运行。准备期望清单：

```json
[{"path":"<临时目标文件绝对路径>","size":12345}]
```

```text
python dit_tools.py verify-fastcopy --log <逐文件日志> --manifest <期望清单.json> --exit-code <实际退出码> --out <receipt.json>
```

当前支持 FastCopy 4.2.1 英文 UTF-8 日志，核对成功结尾、错误数、VerifyFiles、每个预期文件的 SHA-256 和大小，以及目标实际大小。漏项、跳过、重复记录、其他哈希算法或不支持的格式均停止。回执复用工具已经完成的校验，不重新读取全部媒体。日志版本改变时先用真实小样扩展解析器；rsync 或其他标准哈希工具的证据应添加相应适配器，不伪装成 FastCopy 日志。

## 3. 同卷改名和归位

每个素材库分别准备映射；视频、字幕、原片逐文件列出，原片目录名取成片去掉扩展名后的名称：

```json
[{"source":"<库内临时文件或待改名文件绝对路径>","destination":"<最终文件绝对路径>"}]
```

```text
python dit_tools.py relocate-plan --root <本次素材库根> --mapping <映射.json> --receipt <receipt.json> --out <move-plan.json>
python dit_tools.py relocate-apply --plan <move-plan.json>
```

新复制文件必须带回执；仅整理已有库内文件可省略 `--receipt`，此时只证明同卷归位及文件身份/大小/时间未变，不新增哈希结论。工具拒绝越界、跨卷/共享、重复目标、同名覆盖和循环映射；先全量预检，再创建必要父目录并归位。Windows 使用不覆盖的同卷重命名；POSIX 使用同卷硬链接后解除旧名称，不支持硬链接的文件系统会停止，不降级为复制。

中断后保留计划，再次调用同一计划按文件身份检查已完成项。多文件操作不具备整体事务性；身份无法确认就停止，不盲目重跑。目录级关联变更需在索引变更清单中明确填写。不会自动删除空目录或媒体。

## 4. 索引预检与发布

仅适配 references/index.md 的十字段基线；不自动新建或迁移索引。变更 JSON 是数组，每项包含 `before` 和 `after`：新增的 `before` 为 `null`；更新的 `before` 必须是最新 CSV 中完整原行；`after` 为完整目标行，十个字段值均为字符串。原名和来源不随改名更新。

新增/更改 SHA256 或哈希校验声明时，同项增加：

```json
{"evidence":{"receipt":"<回执绝对路径>","path":"<回执中的已验证临时目标绝对路径>"}}
```

这只是变更项中的附加字段，不能单独作为完整变更项。工具核对回执的哈希、大小及最终文件修改时间；调用顺序必须是校验回执→同卷归位→索引发布。原有历史哈希可以保留，不把仅改名说成重新校验。无哈希证据时保留 SHA256 空值并如实填写校验方式。

```text
python dit_tools.py index-plan --root <素材根> --index <素材.csv> --changes <changes.json> --out <index-plan.json>
python dit_tools.py index-apply --plan <index-plan.json>
python dit_tools.py index-check --root <素材根> --index <素材.csv>
```

预检不写索引。发布重新读取最新索引，核对计划基线、路径唯一、实际大小、配套和关联，再在同目录写 UTF-8 BOM 临时 CSV、回读校验并替换。无关行字段保留；同一计划重复执行不新增记录。已完成视频改名的当前路径引用自动同步，已移除行保留历史字段并清空引用；目录或侧车的引用变更需显式列入受影响行。删除媒体仍须另行授权，工具仅维护索引。

默认每个配套/关联字段为一个路径；已有库使用多个路径时，显式提供其既有 `--separator`，不得另创分隔约定。受影响行严格检查；全库只读检查使用 `index-check`。不支持的字段结构或证据类型应扩展共用工具，不能为了通过检查清空字段或降低验证结论。

同一工具的并行写入通过独占锁拒绝；发布前另查索引是否变化。其他编辑器不遵循此锁，发布期间应避免同时编辑。异常断电留下锁时，先确认没有活跃进程、核对实际状态，再清理本任务的残留锁；不自动抢锁。

## 验证与收尾

```text
python -m unittest discover -s <技能目录>/scripts -p "test_dit_tools.py" -v
```

测试在独立临时目录运行，不碰真实媒体。共享工具和测试保留在技能目录；每次只生成输入数据与执行回执。成功且当前路径、索引、源状态均核对后，清理本任务临时清单和日志；失败时保留计划及证据用于续作。
