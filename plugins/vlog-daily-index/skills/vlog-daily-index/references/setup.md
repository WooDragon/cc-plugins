# 安装、配置与本地验证

本包为源码Skill，不携带Python、FFmpeg或模型权重，不自动全局安装。将整个`vlog-daily-index`文件夹解压到选择的Skill位置；也可以先在工作区显式按路径调用。源码和文档可在同步目录，活跃state/temp必须在本地非同步目录。

语义工作流依赖Codex原生Agent工具、可用的Luna/GPT-6.1 Sol及ROOT审查能力；模型明确指定时遵从用户选择。Python只执行确定性工具，不自动提供模型或模拟Agent。已验证宿主是Windows上的Codex，不能宣称其他Agent宿主自动兼容。

## 固定依赖

验证基线：CPython 3.12；`requirements.lock`固定运行依赖及其传递依赖，不包含pytest等非运行工具，也不是带wheel哈希的可重现构建锁。安装时按锁文件，运行期间不升级。依赖从配置的可信Python包源安装；本包未附wheelhouse，离线环境须预先在有网的同平台Python 3.12机器上下载匹配wheels。跨平台依赖解析与二进制兼容性未实测。

Windows PowerShell示例（先在Skill根目录；各路径为示例）:

```powershell
py -3.12 -m venv "$env:LOCALAPPDATA\VlogIndex\venv"
$vlogPython = "$env:LOCALAPPDATA\VlogIndex\venv\Scripts\python.exe"
& $vlogPython -m pip install -r .\requirements.lock
& $vlogPython -m pip check
& $vlogPython -m unittest discover -s tests -v
& $vlogPython .\scripts\vlog_daily_index.py --help
```

FFmpeg/ffprobe基线为9.0.2 essentials Windows x64，来源为FFmpeg下载页列出的Gyan构建：<https://ffmpeg.org/download.html>、<https://www.gyan.dev/ffmpeg/builds/>。该ZIP归档SHA256为`60f467265b1e312373dbcd92200c2618a74850f98d3d078e94296bb3fa2047ba`；此摘要仅对应该确切归档，不能套用到另一个构建。下载后用`Get-FileHash -Algorithm SHA256`比对对应发行来源的校验记录。记录下载URL、归档hash、`ffmpeg -version`、`ffprobe -version`；显式传入可执行路径。没有可靠相同版本时先建立新基线并跑合成抽帧测试，不在运行中自动下载或升级。

媒体合成测试额外设置：

```powershell
$env:VLOG_TEST_FFMPEG = 'C:\Tools\ffmpeg\bin\ffmpeg.exe'
$env:VLOG_TEST_FFPROBE = 'C:\Tools\ffmpeg\bin\ffprobe.exe'
& $vlogPython -m unittest discover -s tests -v
```

这些测试只处理临时合成媒体和HTTP mock，不访问真实ASR/NAS。未设置工具路径时真实抽帧合成测试会明确skip，不能报告为已通过。

## 每次运行输入

必须明确：素材目录、归档日期、state/temp根、ffmpeg/ffprobe路径、ASR基础URL与模型、设备角色与可信时间规则；最终交付必需有来源的行程和专门地点关联。先检索本项目聊天/Notion获取行程，确实找不到再讨论。用户为本次行程提供GPS即确认随行，不再要求同行相机ID；只有明确冲突才澄清。可选时间修正、显式官方LUT映射。需要每日目录命名时，另配置当前行程的`main_region`固定前缀及受控`library_root/index`，不能继承另一项目的区域；规则和dry-run见[命名约定](naming.md)。服务URL由当前部署者提供，示例地址不可运行。CLI参数及manifest是运行配置，不另建配置服务。

```powershell
& $vlogPython .\scripts\vlog_daily_index.py init `
  --source '\\example-nas.invalid\media\day' --state "$env:LOCALAPPDATA\VlogIndex\runs\example" `
  --temp "$env:TEMP\vlog-index" --date '2030-01-02' `
  --ffmpeg 'C:\Tools\ffmpeg\bin\ffmpeg.exe' --ffprobe 'C:\Tools\ffmpeg\bin\ffprobe.exe' `
  --service 'http://asr.example.invalid:8000' --asr-model 'your/service-model-id' --vision-concurrency 6
```

`example.invalid`不可运行，仅示意可迁移配置。先用`init --help`确认参数；设备角色/时钟用`configure-source --source-id ID --role camera --capture-time ISO_WITH_OFFSET --normal-speed --reason EVIDENCE`固定入口按证据设置。未知时间/速率用对应未验证标志，不手改manifest或源ID/帧。ASR模型通过`--asr-model`配置，preflight确认服务实际列出该模型。

新run的6是动态Luna上限，少包少开，实际还受harness真实名额约束；并非启动6个常驻Agent。媒体未配置时保守单路；用独立本地`hardware-benchmark`报告及`configure-concurrency`配置已验证1–4槽位与ready/空间阈值，不能按显卡型号猜或跨机器复制设备索引。完整命令与恢复边界见[并发约定](concurrency.md)。已存在state保留旧模式/缓存，不重新init以启用新纯视觉模式。

固定工具可将已验证本机profile保存至`%LOCALAPPDATA%/VlogIndex/hardware-profile.json`，新run核对设备后自动发现；不用把某项目报告路径写进Skill，profile也不进ZIP。若另外把宿主子Agent上限改为8，须重启Codex并新建聊天生效；这与Skill文件安装分开，旧会话仍按真实可用名额运行。

初次采样前按[预览规则](preview.md)配置设备+可信DIT模式对应的本地官方LUT，普通NO不套。行程与地图证据获取、attach入口、专门Sol阶段读[geography.md](geography.md)；已有run升级复用现有帧/ASR/包，不重init。没有必需行程或地理阶段未完成，不能直接render完整报告后发布。

先选短相机/短无人机/长片跨块各验证一次；硬件检查必须真实输出可读图片。正常访问不到NAS时按执行环境权限流程解决，不复制整天原片来绕过。使用GPS前读[gps.md](gps.md)；生产顺序和任务包读[interfaces.md](interfaces.md)。

## 发布包检验

发布ZIP包含单一`vlog-daily-index/`根。SHA256文件对ZIP计算；解压后对照`release-manifest.json`逐文件校验。格式验证需skill-creator附带`quick_validate.py`和其PyYAML依赖，属于开发校验工具，不是运行依赖。解压后在新路径运行本地测试和CLI帮助，能证明本包未依赖原源码绝对路径；不能替代新主机硬件/ASR协议小样验证。

开发者可使用`requirements-dev.txt`安装格式校验依赖，并运行本地skill-creator的`quick_validate.py SKILL_PATH`。开发打包执行`python tools/build_release.py --output DIST_DIR`；它按允许清单收集源码，排除媒体/用户run/缓存，生成逐文件manifest、ZIP和SHA256。打包不会安装Skill。固定验证命令为：

```text
python tools/verify_release.py --archive ZIP --output REPORT_DIR --ffmpeg FFMPEG --ffprobe FFPROBE --validator QUICK_VALIDATE_PY
```

验证器核对ZIP/逐文件摘要，在新临时路径解压运行测试、CLI帮助、依赖检查和可选官方格式校验，再由解压源码重建ZIP核对一致性，写验证JSON与测试日志。`--validator`省略时报告明确未做该项，不能宣称格式已验证。无需临时编写验收脚本。
