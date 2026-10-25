# 并发、队列与恢复

媒体、视觉Agent和ASR是三类独立资源。媒体路数由经过验证的设备槽位决定；视觉Agent数量由ready图片包积压和宿主真实空闲名额决定；ASR固定1请求。不存在“3路抽帧就固定6个视觉Agent”的比例，也不保持6个空闲Agent等待。

## 宿主与程序职责

ready包一出现就由主控按需派发：少队列少开，积压最多6个视觉Agent，同时给语义Agent保留所需名额。实际数量受当前已创建Agent、宿主报告的空闲名额及已领取任务约束；本地配置目标8个子Agent不代表已有会话即时具备8个名额。宿主不足时排队收敛，不伪造并发、不删减图片覆盖。日级由语义Agent（high）负责，专门地理由地理Agent（high）负责；ROOT最终审查和定向补采权保持不变。

脚本提供确定性ready队列、领取与建议并发数据；真正创建/等待/释放native Agent由宿主执行，脚本不调用模型API或自动spawn。每个包只给一个worker，每个worker只写自身result_path，协调器校验导入。恢复先检查已有结果和领取记录，避免同包再次派发。媒体worker仅返回派生结果，manifest和SQLite由单一协调器提交；领取状态须与长媒体命令的总锁兼容，不能为了派包另开manifest写者。

## 固定命令

以下入口均为`scripts/vlog_daily_index.py`，路径用当前机器配置，不复制他人的设备索引或私有报告：

```text
hardware-benchmark --state INDEPENDENT_LOCAL_STATE --ffmpeg FFMPEG --ffprobe FFPROBE --output LOCAL_BENCHMARK_DIR
hardware-benchmark --state INDEPENDENT_LOCAL_STATE --ffmpeg FFMPEG --ffprobe FFPROBE --output EXISTING_BENCHMARK_DIR --summarize-only --save-profile
configure-concurrency --state RUN_STATE --hardware-report HARDWARE_REPORT_JSON --media-slots N --vision-concurrency 6 --ready-package-limit 24 --temp-limit-gib 256 --min-free-gib 5
vision-queue --state RUN_STATE --available-workers ACTUAL_FREE --reserve-sol 1
vision-queue --state RUN_STATE --available-workers ACTUAL_FREE --reserve-sol 1 --claim-worker UNIQUE_WORKER
vision-queue --state RUN_STATE --available-workers ACTUAL_FREE --reserve-sol 1 --release PACKAGE_ID
retry-visual --state RUN_STATE --package-id INVALID_PACKAGE_ID --reason ROOT_CORRECTION_EVIDENCE
continue-day --state RUN_STATE --protocol VERIFIED_PROTOCOL_JSON --gps GPS_JSON
```

`hardware-benchmark`使用独立本地state/output；默认生成短合成4K10bit样本，也可重复给`--source READ_ONLY_VIDEO --start SECONDS`指定只读小区间，`--seconds`范围1–120，`--tasks`为3–9个相同总任务；`--compare-filter-order`对比下载/筛选顺序。新增槽位比较可用`--profiles '3,4' --select-first-only`，只测新顺序三/四路，报告只返回实际已测的槽位。它记录设备、FFmpeg日志、实际PTS/图片、FFmpeg与验证耗时及可用的可靠PID/LUID性能计数；输出报告留在本地，不混入业务state或分发包。性能比较须让各配置处理相同总任务，关注持续队列images/min及瓶颈；短样本不能定最终路数。

`configure-concurrency`的N只能为1–4且显式指定；多路要求固定工具的`validated_slots`报告，且设备身份与当前DXGI枚举一致。四路目标是A380两槽＋核显两槽，必须先有实际四路验证，三路报告不能当四路报告。未配置时媒体保持单路，已有run不自动切视觉模式；视觉Agent上限1–6，ASR固定1。队列和空间参数是高水位，不是删证据或减少覆盖的授权。报告记录当前机器和格式证据，不能跨机器直接复用。

验证后`--save-profile`把本机槽位profile保存在`%LOCALAPPDATA%/VlogIndex/hardware-profile.json`，可与`--summarize-only`复用已有报告而不重跑样本。`configure-concurrency`省略`--hardware-report`时查该标准位置；新run的hardware阶段也会发现并核对当前设备后导入。profile不依赖项目路径、不进ZIP、不跨机器复制；旧run不自动改变配置，身份变化则拒绝并重新验证。

日常有界并发入口为`continue-day`。旧`prepare`仍是串行诊断/手动有界批次，使用`--blocks`时保留剩余计划，不能把它描述为新的多设备队列调度器，也不要用它绕过正常流水线的背压。

`vision-queue`读取manifest，但只写`state/vision-dispatch/claims.json`并用独立小锁；它可与持主RunLock的`continue-day`并行。`--available-workers`必须来自当前宿主真实空闲名额，`--reserve-sol`从空闲中预留，不能用全局目标8代替。`recommended_vision_workers`表示可新增的视觉Agent数量，已领取且未完成的包计入总上限6。`--claim-worker`可重复，但worker标识唯一且每个只能持一个未完包；成功领取后主控按返回包实际派发。结果文件已到但尚未导入时计入`awaiting_validation_count`，由协调器验证，不重新派模型。派发失败或已确认worker结束才显式release，未收到结果不能靠时间经过自动释放重派。

导入失败的包保存`invalid`，后台不会反复校验同一失败文件。协调器安全暂停或批次返回后，使用`retry-visual`按ROOT具体错误依据归档旧invalid结果、清旧claim、重排一次纠正；第二次仍失败留ROOT处置，不无限重派。若worker已改写为新结果，先`import-results --refresh`显式验证，retry不会删掉它。

## 设备与证据

当前多槽基准支持明确识别的Intel QSV组合，例如Arc A380两槽加Intel核显两槽；这是工具支持的配置形状，不是任意机器的能力或速度保证。GPU按DXGI身份绑定，启动时再核对index/vendor/device，防重启后顺序变化。未知硬件保留单路回退或明确停止，不复制另一机器的设备索引。

部署者用相同来源、相同区间/采样计划和总任务数对比配置，记录实际解码、下载、预览滤镜、输出图片、PTS、设备绑定、错误和images/min。比较滤镜顺序时还要核对对应帧像素等价；总体GPU百分比不能单独证明某解码引擎饱和。系统负载、驱动、OS/SMB缓存均会影响结果；不跨轮拼倍率，也不把媒体路径基准当真实ASR、视觉Agent/语义Agent或整日端到端速度。

`select_first_v3`在下载硬件帧前先筛选需要的帧，仍正常解码/读取完整块，随后执行相同预览与实际PTS校验。v3单独进入媒体缓存键，帧记录模式，review-frames按原帧模式复现；旧run缺字段时沿用原version2键和顺序，升级不触发旧成功缓存重算。

## 背压与中断

ready积压、在途任务和本地派生磁盘均需有界。队列达到高水位时暂停新媒体提交，让已有任务排空、结果可导入后继续；这只是背压，不是每日帧数/时长/token预算或覆盖截断。磁盘空间/派生上限不足时保存明确原因并安全暂停，保留原state和未发布证据；不得通过提前删除尚未发布的图片/WAV绕过原清理规则。

`pause-media.request`阻止新媒体块和新ASR请求；已提交任务完成后由协调器登记结果，保存`paused`退出。若用户暂停整个任务，主控也停止新Agent派发；单纯媒体背压时仍可消费已有ready图片。ready/磁盘高水位保存`paused_backpressure`及`queue_state.reason`，可排空已有本地ASR，但不再提交新媒体；并非后台自动无限等待。高水位按协调器提交边界检查，已在途块可能继续产出，预留空间须覆盖这些块，不是精确硬磁盘配额。

设备失败、暂停或进程重启后使用原state，成功完整缓存不重复提取/上传/分析；缺失或不完整的派生物按原身份重建。新块QSV失败可按同卡D3D11VA再CPU重试，不永久把源/NAS错误当作显卡坏；同块仅协调器成功提交一次。ASR上传后状态未知仍按原服务gate阻断，媒体并发不放宽终止及外部确认证据条件。所有可读来源完成并终审发布回读后，才清理本run登记临时文件。
