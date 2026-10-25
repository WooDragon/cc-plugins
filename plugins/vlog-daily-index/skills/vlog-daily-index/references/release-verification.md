# 验证方法与交付边界

版本以`VERSION`为准。发行包只含Skill说明、运行代码、通用参考、固定依赖清单、合成测试和构建工具；不携带Python/FFmpeg运行时、厂商LUT、模型权重、媒体/FIT、用户行程、转写、坐标、凭据、运行状态、本机硬件profile或真实日志。

## 本地验证

先按[安装说明](setup.md)准备Python与FFmpeg。测试使用临时合成媒体、合成FIT和HTTP mock，不连接部署者的ASR、地图或NAS；真实FFmpeg测试需要显式设置工具路径，缺失时的skip不能报告为通过。

```text
python -m unittest discover -s tests -v
python tools/build_release.py --output LOCAL_DIST
python tools/verify_release.py --archive SKILL_ZIP --output LOCAL_VERIFICATION --ffmpeg FFMPEG --ffprobe FFPROBE
```

`verify_release.py`校验ZIP安全路径、精确manifest成员及逐文件SHA256；在新目录解压后运行同组测试、CLI帮助、依赖检查和文档链接检查，并要求重建ZIP摘要一致。可另传`--validator`调用Codex skill-creator的格式检查。验证输出仅保存在本地，不把含本机路径的日志/安装回读报告加入公共仓库。

测试覆盖实际行为：采样首尾/非零PTS/跨块音频、缓存恢复、完整ASR终止与未知状态互斥、包/引用归属、GPS时间缺口与坐标占位、逐区间补采、地理来源与主体核验、发布回读/清理越界、命名迁移中断恢复、有界并发/单写者/单ASR、领取防重及一次视觉纠正。测试中的地址、日期、路线与坐标均为合成夹具，不能作为出行事实。

硬件基准另用固定工具处理受控小样，核对物理设备、PTS、像素等价与持续队列吞吐。基准结果和用户运行证据不进入公共发行；不能根据总体GPU利用率、短样本或某台机器的速度推断任意设备、ASR/模型或整日端到端性能。详见[并发约定](concurrency.md)。

## 能力与限制

- 已验证运行环境为Windows、Python 3.12及[安装说明](setup.md)指定FFmpeg组合；其他平台和其他Agent宿主未实测。Windows + Codex已端到端验证。Claude Code侧已验证插件加载与agent解析，完整流水线未在真实素材上跑过。语义阶段要求宿主原生Agent工具及相应模型可用，Python工具不会自动调用模型。
- 均匀采样可能漏掉采样间短瞬间；完整时间轴覆盖不等于逐帧观看。短ASR片段保持chunk精度，未经验证不得冒充词级时码。
- ASR服务协议须在目标服务完整小样核实；未知状态不能凭等待或服务可访问解除。OS锁仅协调同机同用户客户端，不提供全网络互斥。
- 相机时钟/倍率未核实、GPS缺口或主体身份缺证据时需保留未知；记录者/相机位置不等于远景目标位置。地图空结果/失败不冒充成功。
- 源视频身份使用大小/mtime、侧车另hash，不能防保持大小与mtime的恶意篡改。三成果不是跨文件原子事务，恢复依赖run/revision与摘要对账。
- 明确不可读源可以列为未覆盖缺口；服务unknown、待包、缺采样和必需分析未完成仍是partial，不能作为成功结案。
- 依赖清单固定版本，但不含wheel hash或离线运行时。厂商LUT由使用者按设备/模式和许可取得，不猜映射或自动创意调色。

安装见[setup.md](setup.md)，固定入口见[tooling.md](tooling.md)，数据流见[architecture.md](architecture.md)，故障续作见[recovery.md](recovery.md)。
