# 原包工作组与原生worker

默认用 `scripts/vlog_daily_index.py vision-work --state RUN_STATE --available-workers ACTUAL_FREE --reserve-sol 1 --native-capabilities CURRENT_SESSION_CAPABILITIES_JSON`。ROOT每轮重新读取真实native空闲名额；程序不调用模型、不自己spawn。模型例外与能力合同继续遵守[纯视觉路由](vision-routing.md)。

组调度保留run声明角色的优先级：Codex的Luna走model路由，Claude Code的声明agent走subagent_type路由、模型与档位仍由frontmatter承载；显式模型按原合同选择。续派前角色、agent/model路由、原生工具/参数或session变化均换新worker。两个宿主的工具能力须由各自真实会话提供，合成合同测试不代表Claude Code原生流水线已实测。

每次只照 `next_action` 执行一步，再调用同一入口；无需心算组大小、选包或worker寿命：

| next_action | ROOT的动作 |
|---|---|
| `spawn` | 用原样 `native_contract.native_spawn_parameters` 真正新建Agent，任务仅给 `task_path`；随即同入口加 `--group-id GROUP --native-agent-id ACTUAL_NATIVE_ID` 保存回执 |
| `followup` | 向返回的实际 `native_agent_id` 原生续派 `task_path`；原生工具明确接受后，同入口加 `--group-id GROUP --followup-confirmed --reason NATIVE_ACCEPTANCE_EVIDENCE`，才进入running；不创建别名worker |
| `wait` | 等返回实际Agent的原生完成；确认这一turn已结束后，同入口加 `--group-id GROUP --outcome complete`（异常用 `failed` 或 `context_warning`）；收到部分结果不代表turn结束 |
| `import_results` | 运行原 `import-results --state RUN_STATE`。长媒体命令持RunLock时等其安全边界；已有成功逐包跳过。原来的全帧/source/time/evidence校验不变 |
| `retire_worker` | 此native worker不再续派；确认原生turn已完成/已关闭后，同入口加 `--retire-confirmed WORKER_ID --reason NATIVE_COMPLETION_EVIDENCE`；重新读取真实空闲名额。有的宿主无关闭工具，仍不得把逻辑退休当腾出native名额 |
| `recover_bind` | 恢复尚未记账的真实spawn回执，不能再spawn一次。只有明确派发失败且未创建Agent时才 `--group-id GROUP --spawn-failed --reason EVIDENCE` |
| `recover_followup` | 返回同一预留组、task_path、原native ID与合同。先核原生当前turn/group：已接受就幂等记录 `--followup-confirmed --reason EVIDENCE`；只有明确未发送才发送该任务一次；未知则等待，不盲重发 |
| `root_package_recovery` | 按返回的具体包路径、原manifest记录与expected_digest恢复原身份，保留claims。原生状态未知先核本组turn；确认结束后可先记录该组 `--outcome failed`，再恢复原文件/记录并重复next。无法恢复仍为未完成，不提供丢弃/接受变化的解锁权限 |
| `root_correction` | 按具体错误使用已有 `retry-visual` 或 `import-results --refresh`；不自动无限重试 |
| `visual_complete` | 视觉阶段完成，继续独立语义、专门地理与ROOT实质审查门槛 |

bind/followup-confirmed/report/retire/failed回执操作先独立原子保存原生事实，只返回 `next`，不读取其他组原包或顺带派下一组；一个坏包不回滚健康worker的回执。新建/续派后保存 `group_id`；等待结果也可读 `vision-dispatch/groups.json` 取worker当前组。只有ROOT根据真实工具结果记录完成；模型自报与能力快照不是运行时模型证明。

`followup`返回时持久化为pending_followup；发送前中断或已发送但ack丢失，下一次都返回完整recover_followup。若确已取得**本组**真实FINAL而接受回执丢失，可直接 `--group-id GROUP --outcome complete --reason MATCHING_GROUP_NATIVE_FINAL_EVIDENCE`；pending状态的这条路径必须有非空证据，不能沿用上一组completed。只有明确本组未启动或已停止的原生证据才记录本组 `failed --reason EVIDENCE` 并退休重排。旧版已running的在途组不猜测迁移，wait也返回完整active_groups供核对。接入 `vision-work` 后同run禁止 `vision-queue` 新claim，已有legacy claim可继续完成/安全释放，不双轨派新包。

包缺失、读取失败、JSON/摘要或已保存package_path/result_path/source_id变化按组记录package_errors，返回ROOT修复项；该组及下游保持阻塞，其他worker的真实回执仍可保存。下游共用gate只读重验未结组的当前原包/manifest，不依赖先运行next或缓存错误；恢复原身份后也能直接重新验证。即使坏组原生已结束，也不能把缺包算成功。恢复与原摘要一致的文件/manifest后，再运行vision-work和原import-results逐包校验；只补未完成，不绕source/time/evidence门槛，不自动释放未知native的owner。

工作组按原包 `frames` 实际呈现数计，含边界上下文（多次呈现仍多次计）；不拆、不剪、不重建原包。下一整包会使本组超过10图则结束当前组，已有ready不足也立即派小组；首包本身11图等超过目标时整包单组。同source按时间相邻优先，同归档目录次之，不跨目录。目录键包含本run/库根，调度邻近不构成同场景/同事件证据。

worker一组在途；导入全部成功并收到真实turn完成回执后才能续派第二组。两组后退休，换目录、路由/session变化或原包边界的失败/上下文告警提前退休。少包少开，真实native slots决定能否开新worker，逻辑worker ID仅用于账本。部分完成先沿旧入口逐包校验，成功缓存永不重新识图；确认turn结束后只重新领取未完成原包，invalid仍需ROOT一次纠正。

最后结果已导入但native turn未知时仍返回wait。队列排空后的idle worker也明确退休；日汇总、地理、render、终审、批准、发布与清理入口统一阻断未收到完成回执的native视觉组，原有媒体/音频/地理/ROOT门槛继续生效。

`vision-dispatch/groups.json`记录组成员/状态、逻辑worker与实际native ID；`claims.json`保留逐原包唯一owner及旧claim兼容。两文件共用原有小锁，通过原子redo journal恢复，旧队列/纠正入口也先恢复journal；与媒体主RunLock互不争写manifest。未知native状态不按超时释放。结果文件已到但未导入只要求校验，媒体背压仍按真实未完原包与磁盘计算，不按组数缩水。

只读离线规划可用 `tools/replay_vision_work.py --manifest LOCAL_MANIFEST [--manifest ...] --output ISOLATED_OUTPUT`；它只读原manifest/包JSON，在隔离目录输出明确标为metadata模拟的分组、覆盖对账和worker轮换统计，不读图片、不写观察、不调用Agent，不代表真实识图质量或配额收益。
