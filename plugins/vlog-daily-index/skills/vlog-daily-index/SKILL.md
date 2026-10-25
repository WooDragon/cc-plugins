---
name: vlog-daily-index
description: "旅行记忆分析师：读取一天旅行原视频，检索必需行程，结合拍摄时间、GPS与地图证据生成可回到原片的每日事件、兴趣点、地点关联和完整转写。适用于原始旅游素材索引，不剪辑或修改原素材。"
---

在 Codex 或 Claude Code 宿主内运行，同一套规则；下表是角色到宿主的绑定，宿主差异见[宿主说明](references/hosts.md)。

| 角色 | 职责 | Codex 绑定 | Claude Code 绑定 |
|---|---|---|---|
| 视觉Agent | 逐帧读图，只记可见事实 | Luna | `vlog-daily-index:vlog-vision` |
| 语义Agent | 跨帧/跨文件/ASR/GPS 汇总（high） | GPT-6.1 Sol (high) | `vlog-daily-index:vlog-semantic` |
| 地理Agent | 专门的地点与主体身份核验（必须另派） | 专门 GPT-6.1 Sol (high) | `vlog-daily-index:vlog-geography` |
| ROOT | 最终实质审查与补采裁决 | 主控会话 | 主控会话 |

Python负责确定性媒体/GPS/转写/引用校验；视觉Agent记录逐帧可见内容与证据，事件和兴趣点仅为候选；语义Agent（high）负责跨帧、跨文件及ASR/GPS语义汇总；ROOT当前旗舰负责最终质量审查，且只有ROOT根据较强的错漏证据决定定向补采。复用已有有效结果，不全量重审。脚本不调用隐藏模型接口，也不另建调度服务。

纯视觉逐帧识图允许 Luna、Haiku、DeepSeek，路由由当前session的原生工具能力快照与本run声明的视觉角色共同决定：Codex按模型名派发并固定Luna medium，Claude Code按`subagent_type`派发并由agent frontmatter承载模型与档位。新claim必须传`--native-capabilities CURRENT_SESSION_CAPABILITIES_JSON`，ROOT按返回`dispatch_contract`真实派发；不静默改派Sol/旗舰、不按宿主名猜模型。领取前读[纯视觉路由](references/vision-routing.md)。

输入：素材目录（递归）、归档日期、FIT目录、ASR服务和模型、必需行程，以及可选设备映射/时间校正/官方预览LUT映射。先从本项目已有聊天与Notion检索行程并保留来源；确实找不到或有重要冲突才与用户讨论，不能静默省略。未确认设备角色不提交音频；无人机始终跳过音频，DJI运动相机仍转写。时间不明或慢放速率未核实只给文件内时间，精确位置必须满足[GPS约定](references/gps.md)；有依据的大概区域/景点推断另存[地点关联](references/geography.md)，区分相机/记录者与远景主体。

版本见`VERSION`，验收边界见[发布与验证记录](references/release-verification.md)。开始运行先读[固定工具与职责表](references/tooling.md)：每步使用已落地CLI或宿主/连接器工具，不临时手搓媒体、地图、状态或结果转换脚本；Agent填模板做语义判断。首次部署读[安装](references/setup.md)，维护/排错读[架构](references/architecture.md)、[恢复](references/recovery.md)。入口`scripts/vlog_daily_index.py`，各命令`--help`；固定依赖见`requirements.lock`，运行中不升级。显式传FFmpeg/ffprobe并记录来源/版本/hash。活跃state本地非同步，派生媒体本地temp；原片和既有SRT/XML/FIT只读。

工作流程：

协议已验证后，`continue-day --protocol PROTOCOL_JSON --gps GPS_JSON` 从同一state自动续跑：每个≤5分钟源块直接NAS读取产生图片和块WAV；已有图片只补所需块WAV；ASR的30秒片段从本地块WAV切出且始终单请求。媒体多路只用已验证设备槽位，队列/临时磁盘背压不截断覆盖，只有协调器写SQLite/manifest。`pause-media.request`停止新块/新请求，已提交工作安全完成后保存退出。新运行`block_visual_v1`以稳定完整块先产纯视觉包，视觉Agent不等ASR；语义Agent随后仍汇总全部适用音频的完整转写。旧run保留legacy包/缓存，不自动换模式。固定命令、名额与恢复边界见[并发约定](references/concurrency.md)。

1. `init` 读取全目录来源并保存全部采样计划。常规沙箱不可见的 NAS 使用正常权限升级，不能据盘符不可见认定素材丢失。原视频直接交给 FFmpeg，不预拷整天或整个视频。Claude Code宿主须传`--host claude-code`，Codex宿主省略即可（默认codex）。
2. `hardware`实测“解码→下载/缩放→可读图片”，DXGI身份匹配Arc A380 QSV→该卡D3D11VA→核显→CPU；多路另需`hardware-benchmark`及`configure-concurrency`验证。正常抽取用`continue-day`按最多5分钟块调度，10秒采样并保首尾/短片首中尾，记录实际PTS；旧`prepare --blocks`仅有界诊断，不替代新流水线的背压。可信DIT规范文件名中的SLOG3CINE/DLOGM可确认模式，按设备+模式显式匹配官方LUT转Rec709预览；普通NO不套，缺匹配则标未归一化，禁止猜LUT或把HDR当Log。配置、LUT hash和滤镜参与预览证据/缓存身份，读[预览约定](references/preview.md)。无每日总帧数/时长/模型预算截断；批次边界后必须继续剩余计划。
3. 首次`asr-json-sample`验证完整单JSON，再以`audio --discover --chunks 1`完整消费同短样本流；按Content-Type选择SSE/NDJSON解析器，不收到文字就中断。已验证一种NDJSON为增量`text/is_final=false`，末条空text且`is_final=true`；拼接终止前增量，读到终止及EOF才成功。真实终止语义核实后写protocol配置，`adopt-json-sample`导入成功样本缓存，不重复转整片。增量start/end未证明是可靠词时码，当前保持30秒片段精度。无终止、断流、上传后超时/未知5xx均阻断新提交；`audio --acknowledge`只接受服务端旧任务已结束的明确证据，GET models或时间经过不算。ASR固定1请求，机器同服务锁防多chat叠加，不随媒体或Agent并发增加。详见[接口](references/interfaces.md)。
4. `gps-build`用官方Garmin SDK及MovingPandas生成JSON；用户为本行程提供GPS即确认随行，不再要求同行参数，仅明确冲突才澄清。可信时钟/倍率和缺口门槛仍在，无人机优先自身SRT，(0,0)占位无效。用`configure-source`显式配置角色/可信带时区时间，不手改state。`packages`生成约10图的小包及固定结构。
5. 主控以 **视觉Agent** 按ready图片队列弹性派包（用户明确指定的模型优先）：ready即派、少包少开、积压最多6；独立于媒体槽位及单并发ASR，不是3路抽帧固定配6个视觉Agent。实际并发为`min(配置上限, 当前真实空闲worker名额扣除所需语义Agent名额, ready包数)`；本地目标8子Agent不改变已有会话真实名额，不能保持6空转或假装有8槽。脚本只提供ready/领取/建议，native Agent派发由宿主执行。每包唯一分派、结果文件独立，统一校验导入；名额不足只排队，不裁减覆盖。每包只给所需路径，不携带全部聊天。要求子Agent实际读取全部图片、逐帧回传 `analysed_frame_ids` 并提供含“无明显事件”的观察，不凭文件名/行程臆造结论、不递归委派、不请求ASR、不写状态库/发布/删除。结果仅写包内 `result_path`。读取[输出约定](references/interfaces.md)后派发。
6. `import-results`检查图片对账、来源/时间/证据/位置；invalid不后台无限重校验，协调器安全暂停或批次返回后用`retry-visual`归档并安排一次纠正，仍失败保存待ROOT处置。已有改写新结果用`import-results --refresh`，不删除新文件。视觉Agent标记主要视觉主体和事实证据；`supplemental_requests`只是候选，留给事件/地理分析后ROOT统一判断，不自动执行。转写回述不冒充当时现场事件，30秒片精度不冒充词时码，GPS停留不自动等于活动。
7. 媒体、应转写音频和核心视觉覆盖后，`daily-package`导出已校验记录与完整转写，由主控委派 **语义Agent（high）** 做事件/兴趣点及主要视觉主体语义分析，写`daily.result.json`；保留独立来源片段和证据，不拼片段summary。然后必须另派专门的 **地理Agent（high）**，结合必需行程、时间对应GPS及高德或类似地图证据做地点关联。画面重心是地标/自然景观且GPS不能识别主体时，必须专项核验：查看已有关键帧，结合可用朝向、路线与地形/地图资料，给身份候选、依据、缺证据及必要补采候选。拍摄位置与远景主体独立，近似推断合法但不伪精确；按[地理接口](references/geography.md)导入并绑定当前输入摘要。
8. ROOT综合行程、GPS路线/全部停留、拍摄时间/倍率、视觉主体、原始语音及地图核查错漏、归属、时空矛盾和补采。逐区间`decide-supplement`采纳/拒绝；仅采纳后`supplement`，扩前15/后30秒、合并1fps，只一轮。新增证据仅回流受影响的语义与地理结果，不重跑成功ASR或全量识图。`attach-review-context`保存补充说明，`render --daily ...`生成完整待审三成果，再`final-review-package`提供综合证据及模板。ROOT记录六维审查与逐问题处置，有依据未知可留，未决实质blocking禁止批准；`approve-final --review-result ...`绑定当前证据/三成果hash，变化后定向重审，无额外用户确认。`publish`依次发原NAS并回读、Markdown最后；共享run_id/revision/摘要，不宣称整体原子。未知同名冲突或源变化停止发布。
9. 全部可读素材的提取、ASR、视觉、已采纳补抽、日汇总及专门地点关联完成，但存在明确不可读源损坏时，最终状态为`terminal_with_gaps`：保留`source_failures`，报告写“可读素材处理完成，N项源损坏未覆盖”，不能宣称全部来源均已观看。服务unknown、待包、缺抽或必需地理阶段未完成仍是partial。可终结状态且发布回读成功后才cleanup本run登记临时产物；阶段partial保留恢复资料。

恢复：使用原 `--state` 运行对应未完成命令；成功缓存不重复调用ASR/视觉Agent。不要重新 `init` 覆盖状态。`status`分别返回来源数/计划/提取/分析数量、失败及未完成项。改变抽帧策略时建立新运行；普通提示版本升级不自动重建成功包。明确要求更新旧提示时用`packages --refresh`重建受影响legacy包并使下游过期，block模式保留已派block身份，不混用新旧结果。

每日目录采用`YYYYMMDD_主行程区域_2到3个主要景物或活动`。区域前缀来自用户或当前已确认行程，保留大区域且不跨项目沿用；语义Agent从已审证据选每日主题，ROOT核验，不用未确认峰岛名、不堆全行程、不重跑已有分析。使用[naming固定入口](references/naming.md)先dry-run；实际迁移只在用户已授权范围内执行，已有自动改名授权不反复确认。迁移后保留源/帧/包/转写身份，重绑当前路径、使旧发布批准失效，再走受影响终审与发布链。

最终仅发布 `AI_每日索引.md`、`AI_事件与兴趣点.json`、`AI_音频转写.json`。报告写明均匀抽帧可能漏掉两次采样之间的短瞬间，地点依据是记录者/相机位置，不能当远处景物坐标。
