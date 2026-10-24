# 运行与任务包接口

本地状态manifest.json + state.sqlite3由协调器单写，不要同时运行两个修改同一主状态的命令。媒体多路仅使用已验证设备槽位，ASR固定1请求；Luna可与本地处理并行，但不得改manifest/SQLite。独立视觉领取小状态允许与长媒体命令并行，详见[并发约定](concurrency.md)。

`config.vision_concurrency`是Luna上限，最高6；由harness结合ready积压与当前真实空闲名额消费，不建立额外后台调度器。少包少开，实际为`min(配置上限, 真实空闲名额扣除所需Sol名额, ready包数)`；已有claim计入正在运行数量，不能重复领取或保持6空转。它独立于媒体槽位与`asr_concurrency=1`。本地配置的8子Agent目标不等于当前会话可用8槽。同包只分派一个worker，每包写自己的result_path，主控统一导入；排队背压不减少采样/视觉覆盖，Luna不得调用ASR。

模型职责由harness执行：Luna仅负责逐帧可见内容及证据记录，其events/interest_points是候选；GPT-6.1 Sol以high推理汇总跨帧、跨文件、ASR与GPS；ROOT当前旗舰做最终质量审查，且仅ROOT依据较强错漏证据决定定向补采。`config.model_roles` 记录这项约定。复用已有结果，不全量重审；模型补抽请求不自动触发提取。最终审查通过后才能发布和清理。

Python 3.12；`requirements.lock` 是固定版本依赖。FFmpeg 记录真实来源/版本/哈希，路径通过 init 参数提供，运行中不下载更新。全部 paths 可含中文与空格，调用进程使用参数数组。

先检索必需行程并确认素材/GPS/可信DIT，随后按依赖调用；有已采纳补采时局部回流，不重新init：

```text
vlog_daily_index.py init --source SOURCE --state LOCAL_STATE --temp LOCAL_TEMP --date YYYY-MM-DD --ffmpeg FFMPEG --ffprobe FFPROBE --service URL --asr-model MODEL_ID
vlog_daily_index.py attach-itinerary --state LOCAL_STATE --itinerary ITINERARY_JSON --map-evidence MAP_CACHE_JSON
vlog_daily_index.py hardware --state LOCAL_STATE --source-id SOURCE_ID
vlog_daily_index.py prepare --state LOCAL_STATE
vlog_daily_index.py audio --state LOCAL_STATE --discover --chunks 1 --source-id CAMERA_ID
vlog_daily_index.py audio --state LOCAL_STATE --acknowledge VERIFIED_TERMINAL_EVIDENCE
vlog_daily_index.py audio --state LOCAL_STATE --protocol VERIFIED_PROTOCOL_JSON
vlog_daily_index.py continue-day --state LOCAL_STATE --protocol VERIFIED_PROTOCOL_JSON --gps GPS_JSON
vlog_daily_index.py packages --state LOCAL_STATE --gps GPS_JSON
vlog_daily_index.py import-results --state LOCAL_STATE
vlog_daily_index.py daily-package --state LOCAL_STATE
Sol事件/兴趣点结果后：
vlog_daily_index.py geography-package --state LOCAL_STATE --daily DAILY_JSON
专门Sol完成地点及主要地标/自然景观身份核验后：
vlog_daily_index.py import-geography --state LOCAL_STATE --result GEOGRAPHY_JSON
ROOT逐区间决定补采候选，有采纳时仅补局部并回流受影响依赖：
vlog_daily_index.py supplement --state LOCAL_STATE --list-requests
vlog_daily_index.py decide-supplement --state LOCAL_STATE --request-id REQUEST_HASH --decision accept --reviewer ROOT --reason EVIDENCE_BASED_REASON
vlog_daily_index.py supplement --state LOCAL_STATE
vlog_daily_index.py render --state LOCAL_STATE --daily DAILY_JSON
vlog_daily_index.py final-review-package --state LOCAL_STATE
ROOT填写自动生成的final-review.template.json后：
vlog_daily_index.py approve-final --state LOCAL_STATE --reviewer ROOT --reason REVIEW_SUMMARY --review-result ROOT_REVIEW_JSON
vlog_daily_index.py publish --state LOCAL_STATE
vlog_daily_index.py cleanup --state LOCAL_STATE
```

`--blocks`/`--chunks` 是有界批次，用完当前批次继续同一state，不能当总预算。`--source-id` 可重复给来源id或相对文件名，适合3类小样；整日运行省略该筛选。

`continue-day`是单协调器的自动续跑入口：每个≤5分钟源块只有一个在途任务，已验证媒体槽位可并行；未有图片时同时出图/WAV，已提取的块只补WAV。本地PCM块再切30秒ASR片，单ASR worker完整消费流；worker只返回结果，协调器写SQLite/manifest。新run的`block_visual_v1`仅按完整稳定块生成纯视觉包，ASR随后到达不改变其包身份，Sol日汇总仍带全程适用音频转写；旧run缺省legacy保留既有包和缓存。ready/在途/派生空间阈值产生背压并保存原因，暂停后同state继续，不重抽成功块。显式纠正已有结果可用`import-results --refresh --source-id SOURCE_ID`重新校验，不触发模型或改原始转写。

ASR协议JSON的终止条件必须来自真实完整响应：可以是`terminal_field/terminal_value`或明确的`final_event`，`text_field`必须存在于终止负载，`precision`为`chunk`或验证过的服务片段精度。支持`text/event-stream`（httpx-sse）和`application/x-ndjson`（HTTPX逐行+标准JSON解码）；完整响应不以EOF单独判成功。发现样本保存流事件与终止证据。配置错误不重试；未知状态全局gate持久阻断。显式恢复必须有旧任务已结束/服务恢复证据。

已实测一种非diarize协议：`terminal_field=is_final`、`terminal_value=true`、`text_field=text`、`text_mode=deltas_before_final`、`precision=chunk`。末条text为空但is_final=true，全文来自此前增量，完整读至结束再提交；增量start/end未表现为可靠音频词时码。普通运行用`asr-json-sample`、`audio --discover`及核实后的`adopt-json-sample --protocol FILE --reason EVIDENCE`，不临时写客户端脚本；成功缓存复用，不重新转整片。

视觉包：`package_id`、`source`、`core_frame_ids`、`frames`（含必要边界上下文）、`transcripts`、`gps`、`interval`、`result_schema`、`result_path`。新模式另有`visual_package_mode/transcript_policy`且transcripts为空；完整独立ASR仍交Sol。帧ID和时间不可改写；所有图片实际读取后回传，GPS只允许引用提供的记录。

结果遵循包内 JSON Schema。顶层：`package_id, analysed_frame_ids, observations, events, interest_points, supplemental_requests, summary`。每个 observation 用合法来源/开始/结束/description/evidence_ids 覆盖全部核心帧；每个 finding 包含 title/type/reason/confidence/priority/needs_review/clips/location。clip含 source_id/start/end/precision/evidence_ids。事实引用必须可核验；priority与confidence分开；无明显事件可写明确观察并给空events/interest_points。

补抽候选`{source_id,start,end,reason}`。`supplement --list-requests`给出`request_id`（原请求字典稳定摘要）；ROOT用`decide-supplement --decision accept|reject --reviewer ROOT --reason ...`逐项记录。拒绝仅移除该pending并保留审计，采纳仍保留pending直至对应包全部验证；未决定不执行。首轮开始后不能采纳新的第二轮区间；首轮包仍可指出不确定性，保留复核说明而不递归自动补抽。reviewer字段是harness约定和审计，不是身份认证系统。

`final-review-package`生成综合证据JSON/preview/模板；ROOT完成行程与实际、GPS路线/全部停留、时间地点、视觉/转写、主体地标、补采六维审查，逐问题写处置，有依据未知可作为限制。`approve-final --review-result FILE`要求ROOT结论、全维度覆盖、每问题disposition与blocking_remaining=0，绑定输入及三SHA256。`publish`复核完整覆盖/终态/组摘要/审查与未变依赖；证据或成果变化须定向重审，不新增用户确认。程序只检查记录和绑定，不替代语义审查或提供身份认证。

日汇总JSON最小结构：`summary`、`summary_evidence_ids`、`events`、`interest_points`。finding结构与视觉包相同，clip可跨合法source。Sol high读取已校验记录与完整转写做语义合并；程序检查来源、时间、证据及原精确位置。未完成音频/核心视觉不生成日汇总；未决定补采候选可供后续专门地理分析，已采纳未完成补采不能当作最终完成。v0.1.1最终render还要求必需行程与专门地理阶段；缺阶段只保留state/status，不把不传daily的旧用法当完整报告。

## 每日目录命名

已审过的语义/地理证据之后，用`naming-plan --config FILE --library-root ROOT --index CSV`保存dry-run计划；配置含`date/main_region/themes/reviewer/reason`，主题2–3个，区域为当前用户/行程确认的固定前缀。`naming-review --plan FILE --reviewer ROOT --reason ...`绑定计划；用户已授权实际改名时才`naming-apply --plan FILE`。不新增逐次用户确认。支持边界、当前路径与历史证据区别、迁移后重渲染/终审及原计划恢复见[命名约定](naming.md)。本轮仅更新规则时不调用apply。

原`location`字段只能逐字引用提供的精确GPS记录或null；不要把有依据的近似地区/景点推断塞入该字段。v0.1.1另有必需的[行程与专门地点关联](geography.md)阶段，用独立`geography`表达有来源的近似判断、置信度与替代候选。无证据不猜具体山名；原始转写保留原话与重叠边界，禁止Luna改写转写JSON。

只有ASR证据的clip不能使用视频帧精度，粗chunk必须保留所引转写的完整起止范围与chunk精度；服务端确实验证过的service_segment按其原小区间引用。混合真实画面证据不因此禁用已观测的帧时间。正常首次`geography-package`会从当前GPS/已验证帧位置构建关联与停留覆盖，不开启新revision；`gps-review-package`仅用于已完成后的定向修订。

## 已完成索引的GPS定向修订

用户为本次行程提供GPS即确认随行；仍保留可信时钟/播放倍率/120秒缺口门槛。对已完成可读覆盖的run，可运行：

```text
vlog_daily_index.py gps-review-package --state LOCAL_STATE --gps GPS_JSON --reason USER_SUPPLIED_TRIP_GPS_EVIDENCE
```

该入口只关联现有frame_id、源时钟、GPS窗口与停留，不读媒体、不调用ASR、不重建视觉包。它在state写`gps-association.json`和`gps-review.package.json`，包含此前daily、原已校验观察/完整转写、新关联和结果schema。旧包ID/视觉结果保留；已发布版本的本地三成果先备份到state内revision目录，并保存publication_history，当前published_verified失效。每次调用开启一次新revision；中断后复用已有`gps-review.package.json`和指定结果路径继续，不能反复调用该入口当作恢复。

主控让Sol high仅分析受影响的时间/GPS/停留关联，写指定`gps-review.result.json`完整DailyResult；停留相交只代表空间时间重叠，不自动变活动或触发补采。v0.1.1随后按必需行程重新生成受影响geography并完成专门地点/主体分析，再render、final-review-package、ROOT实质审查、approve-final/publish及回读；成功视觉/转写不重跑。新增精确location逐字引用`gps_association.frame_locations`完整记录且clip含其帧/来源，旧location由证据帧确定归属。
