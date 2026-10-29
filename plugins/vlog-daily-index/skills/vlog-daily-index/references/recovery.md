# 运行恢复与故障处理

先用同一个state执行`status`；保留manifest/SQLite，不重新init。任何修改同state的CLI只运行一个。`pause-media.request`阻止新块/新ASR，已提交工作完成并保存后退出；需要恢复且用户未要求继续暂停时再移除此state内标记。不要直接杀掉ASR请求后重发。

| 现象 | 证据与动作 |
|---|---|
| 媒体中断/缺图 | 同state重跑对应prepare或continue-day；成功完整块复用，缺失派生块重建。核对实际PTS与计划，不用手造帧记录。 |
| 成功ASR缓存存在 | 复用SQLite成功片；不因WAV/界面暂缺就重发整片。缓存模型/协议/片段身份应相同。 |
| ASR unknown/inflight | 停止新提交；读取原始完整响应与服务端任务状态。只有外部确认旧任务已结束/服务已恢复，记录真实证据后`audio --acknowledge ...`。等待时间、GET models成功、换Client或chat均不算结束证据。 |
| 协议未确认 | 同短WAV先stream=false完整JSON，再stream=true完整消费到真实is_final及EOF，对照全文；发现请求仍锁住队列直到终止语义明确。不能把末条空text当空转写。 |
| 视觉Agent额度或宿主名额不足 | 保留waiting_ai队列，降低并发/分批续作；不减覆盖。同包唯一worker，恢复先看result_path是否已有结果并导入校验。 |
| ready/派生空间背压 | `paused_backpressure`及`queue_state.reason`区分包积压/临时总量/剩余空间。先由主控消费已有ready，或补足本地空间/合理调整阈值，再同state继续；不删未发布证据、不裁覆盖。已在途任务可排空。见[并发约定](concurrency.md)。 |
| 视觉worker中断或名额变化 | `vision-queue`查看领取记录和原result_path；已确认worker终止/派发失败才release该PACKAGE_ID，再按当前真实空闲领取。已有active计入6上限，无TTL自动重派，不用另一个manifest写者绕过总锁。 |
| 并发设备失败/配置变化 | 逐块降级不重注册成功帧；同state复用缓存。多路报告设备身份不匹配则重新小样验证，不能直接换显卡索引；legacy旧run保留包模式，configure不触发全量识图。 |
| 包invalid | 不后台反复校验同一失败文件。协调器安全暂停/批次返回后用`retry-visual --package-id ID --reason ROOT_EVIDENCE`归档原失败结果并清claim，仅一次纠正；若新结果已改写则`import-results --refresh`验证，不删新文件。再次失败留ROOT处置，不能填造analysed_frame_ids凑覆盖。 |
| 补采候选 | ROOT按每个具体区间审查较强错漏证据，记录采纳或拒绝及原因；未决定不能直接执行。已采纳的包全部校验后才解除pending。 |
| 日汇总引用失败 | 语义Agent修正所列源/证据/时码；不可只删除校验或把其他源转写归入当前源。ROOT语义审阅后再render。 |
| ROOT发现实质错漏/矛盾 | 记录具体问题、证据、blocking状态及处置；用现有证据纠正或由ROOT决定局部补采，只回算受影响依赖。问题处置后重新审查绑定；有依据未知可保留，不能用格式通过绕过未决冲突。 |
| 已完成后补充GPS/确认随行 | 用`gps-review-package`仅重关联既有帧与可信时钟/轨迹，不重抽/重看/重转写。语义Agent定向更新并重算受影响geography，render后生成final-review-package，由ROOT再审后approve-final/publish；旧发布版本本地备份，新版须重新回读。 |
| 提示版本升级后的既有run | `prompt_version`变化不自动重建已成功包：帧集未变时`packages`直接跳过旧包；需更新时显式`packages --refresh`，它会重排该源包并使下游geography/终审批准失效。block模式按`(source_id, block_index)`去重，升级后新块带新版本、旧块保留原版本，属预期混用，不重派已完成块。 |
| 重跑geography-package | 重跑后`package_id`变化，旧`geography.result.json`会被判stale，须用新包重跑地理阶段再`import-geography`；不手改state或复用旧结果。 |
| 源或侧车变化 | 暂停；核实来源变化并按新运行重建身份，不覆盖原基线。 |
| NAS发布中断 | 保留本地三成果和temp，核对组run_id/hash；只重试publish，不重跑ASR或视觉Agent。三文件未成组验证不标成功。 |
| 目录命名或迁移中断 | [命名约定](naming.md)：保留原计划/journal，同state用同一`naming-apply --plan`恢复，不重新init/手改CSV。冲突或身份不一致停止。迁移完成后核对当前根和索引，再重render/受影响ROOT终审/approve/publish；成功媒体、视觉、ASR不重跑。仅dry-run未移动目录时无需迁移恢复。 |
| 清理边界拒绝 | 保留文件，检查登记是否越界/有链接或run身份错误；禁止递归删整个临时根代替。 |

完成判据：所有可读源的计划点/实际帧/核心已分析帧对账、包全success、应转写片完成、已采纳补采完成、daily严格引用与ROOT质量审查通过。存在明确不可读原件时可以terminal_with_gaps，但逐项列出损坏，不能说全部源均已看完。最终仅发布三成果，回读通过再清理登记temp；state保留供审计和恢复。
