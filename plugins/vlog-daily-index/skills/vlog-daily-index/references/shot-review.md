# 动态补采与按需镜头复看

初筛仍按既有静态档位。新run启用`shot_v1`补采：初筛只提出有同source两帧以上证据、具体变化和待解决剪辑问题的`purpose=dynamic`请求，不自行做动态定论。不因无人机、有人、有云、普通水纹或常规运动类别全量触发。旧run缺此模式时保留原补采/claim/成功缓存，不迁移、不默重算；旧来源动态缺失表示未评估。

## 正常自动分支

初筛全部导入后、第一次`daily-package`前，ROOT执行一次已授权规则的批量动作，再照程序短action桥接原生工具，不逐候选抄字段或主观打分：

```text
python scripts/vlog_daily_index.py accept-dynamic --state LOCAL_STATE --reviewer ROOT --reason AUTHORIZED_ANCHORED_DYNAMIC_POLICY
python scripts/vlog_daily_index.py supplement --state LOCAL_STATE
python scripts/vlog_daily_index.py shot-work --state LOCAL_STATE --native-capabilities CURRENT_CAPABILITIES --available-workers ACTUAL_FREE_SLOTS
```

批量入口重新读取原成功初筛包，只接受非空白字符串question/reason、有限合法源秒及2+同source合法帧锚点的动态请求，留ROOT政策/理由和原请求；地理或其他特殊候选仍走`decide-supplement`。原一轮补采队列保留：动态按请求完整源秒区间2fps加末帧，旧地理/遮挡用途仍扩前15/后30秒，再合并相交区间。长区间完整计划并分包，不截成前8秒；帧预算仅限制单worker包。提取/包/成功结果可恢复，只看选中区间，不重跑ASR。复看仍不确定时交原片播放，不递归再密采。

补采包只交max一次，同时写逐核心帧可见事实与跨帧变化，不另跑medium看同图。初筛完成但尚有未处置动态候选时`daily-package`明确阻断；复看导入后，日级Sol一次消费完整事实和`visual_changes`，独立地理/ROOT门槛保留。晚到地理补采仍使相关下游过期，定向修订。

`shot-work`返回`spawn`时，只读短action的task_path和原样native_contract；ROOT真实创建worker，再记录真实canonical ID：

```text
python scripts/vlog_daily_index.py shot-work --state LOCAL_STATE --bundle-id BUNDLE --native-agent-id ACTUAL_NATIVE_ID
python scripts/vlog_daily_index.py shot-work --state LOCAL_STATE --bundle-id BUNDLE --outcome complete --reason MATCHING_THIS_BUNDLE_NATIVE_FINAL
```

之后重新`shot-work`机械验证/导入、获取下一步。`failed`同样必须有本bundle真实FINAL/停止证据；仅已确认failed才保留部分成功并重新安排未完成段。`complete`却缺结果进入root_correction，保留原bundle/native归属，恢复原结果后继续，不能自动重派。`wait`不释放或重派；`recover_bind`必须找回原spawn的真实回执，不能重复创建。未知不能按等待超时或结果文件存在当作native结束。错误先保存其他worker真实回执，原图/task恢复后继续；未恢复不算成功。

每个bundle最多2段、34幅实际呈现图，原段完整，同source相邻优先、同归档目录次之；新bundle新worker，绝不无限复用/循环压缩。这是当前保守策略，不是模型硬容量。ROOT传当前真实空闲原生槽，预留Sol；程序不调用隐藏模型或假称后台自主spawn。普通成功只组末一次摘要，异常立即报完成/未开始清单并停止。

独立shot合同要求当前工具明确支持图像输入的`gpt-6-luna`和`max`；不支持返回blocked/错误，不降档。旧Codex/Claude静态角色和agent frontmatter路由不变；只支持Claude agent-owned路由不能满足此新增max请求。capability快照/请求不证明实际运行模型。日常不强制high对照或额外开发审查worker。

## 已发布检索候选的显式入口

```text
python scripts/query_index.py search --db LOCAL_QUERY_DB KEYWORD --kind event > CANDIDATES_JSON
python scripts/shot_review.py plan --candidates CANDIDATES_JSON --select 1 --select 2 --output LOCAL_NONSYNC_STATE --ffmpeg FFMPEG
python scripts/shot_review.py next --output LOCAL_NONSYNC_STATE --native-capabilities CURRENT_CAPABILITIES --available-workers ACTUAL_FREE_SLOTS
```

适配真实query输出的publication/run/revision/source_id和原relative_path/original_path，重新核发布三文件及媒体身份；AI标题不参与找文件、改名或推导路径。缺映射、离线陈旧候选、无准备metadata或模糊/越界时间均拒绝。大于8秒的显式候选返回`select_interval`保留原完整区间和未覆盖标志，需`--start/--end`显式收窄，不默选前8秒。自动补采长区间则完整分包。

精确缓存绑定原片/侧车身份、源区间、preview、采样和prompt，命中不抽取/不重复模型。邻接/重叠显式query区间暂不复杂合并，保留候选到job的映射。`kind=visual_change`直接`use_existing_review`；`needs_playback`表示播放原片，不是未评估，不回动态队列。必要新语义仍须真实看图，不靠worker记忆或旧文字。

也保留`prepare --manifest ... --source-id ... --start ... --end ... --frames 17 --output ... --ffmpeg ...`独立入口。活跃state/images本地非同步，原媒体/名称只读；不自动写NAS。

## 证据、输出与限制

完整task保存source身份、实际PTS/图hash、preview/LUT细节、prompt/schema；预派薄bundle自身SHA及公共合同/原成员映射也冻结，验证和下游都重新核对，真实native回执仍先独立保存；缺预派摘要的历史原型账本不自动当成已绑定。薄bundle仅一次公共指令/schema和每段id/源秒/路径、共同preview状态、时钟/倍率与采样限制。无需ROOT读取大task/result；Luna逐source实际按序打开全部图，`observed_frame_ids`必须完整同序；补采observations覆盖全部core，每条为自己所引帧的精确首尾包络，单帧为时间点，不把静图扩成未显示时段的事实；该新增max约束不改旧静态合同。缺字段/未观察是未评估，不是无运动。

变化区分`visible_change`与`camera_motion_inference`。每条变化及候选至少引用2张不同的本source实际图，`clip.start/end`等于该条evidence_ids首/末实际源秒（浮点容差1微秒），精度`sampled_frames`，写confidence/limits且needs_playback=true。observed全表不能补未引用端点；不能由稀疏图推断完整连续性、无抖动、曝光原因、瞬时动作峰值、精确剪点或默认审美可用性。慢放仍用源文件播放秒，未知倍率不换算真实动作速度。

```json
{"review_id":"validated-review","change":{"topic":"composition","claim_type":"camera_motion_inference","description":"主体相对位置变化，可能含相机运动，需播放核实","clip":{"source_id":"source-id","start":1,"end":2,"precision":"sampled_frames","evidence_ids":["frame-a","frame-b"]},"confidence":"low","limits":["仅比较已显示采样帧"],"needs_playback":true}}
```

结果经`validate --task FROZEN_TASK --result RESULT_JSON`形成独立accepted记录；差异不能覆盖已有接受结果。`report --record ACCEPTED_JSON --output REPORT_MD`重新读取绑定task/result、走同一validator重建整个记录再比对，失败不覆盖旧报告。结构通过不等于语义审定，原片链接是prepare身份快照，不承诺报告时文件已再次联网核验。

自动分支把已验证变化经日语义写入正式`AI_事件与兴趣点.json.visual_changes`、`AI_每日索引.md`及query的`visual_change`类型，保留源文件时码、证据、未知及事实/推断区别；不借event/interest_point触发额外地理。`visual_review_coverage`的缺失表示未评估。已有daily未带新字段时保持原序列化/证据摘要；提示升级不让既有成功初筛缓存静默失效。独立显式复看先输出单独报告/记录，后续发布仍需原日级/地理/ROOT链，不绕审核自动写回。

新建镜头任务（独立prepare及自动动态补采）共用固定4×4像素线索：每个相邻对只给显示灰度变化dB和归一化固定坐标内容残差R；R无法归一化为null。定义随可选块冻结，须回图确认部位与帧证据，不能由数字判断光照/曝光原因、运镜方向或连续性，R高不屏蔽dB。完整输入保留版本/config/实现与图身份，薄包只携短表；不使用未校准可比性标签或排名。旧无块任务/已成功缓存保持冻结，已有query任务优先复用，只有新任务键绑定线索身份；不升级全局提示版本、不后台重算。

像素线索仅在两段同图的单次历史对照中验证：具体亮暗变化得到核图支持，原有早段相对位移观察保留；候选仍可能覆盖整段，阶段起点与精确剪点仍需日级Sol/ROOT及原片回看。未做随机对照，不能推广为总体触发率、完整动态理解或费用改善。

提示版本6把相邻比较落为可核查observations：首帧基线，其后逐相邻双帧记录当前事实与可见变化/未见明确变化/不可比；再据差异合并阶段/恢复与用途候选。显示变化与未知原因分开，不强凑阶段或可用性；schema与校验器保持，旧逐帧记录仍合法。唯一提示源为shot_review.INSTRUCTIONS，新standalone/自动包共用；bundle继续取各成员已冻结提示，升级不改在途或已成功记录。query plan的精确键包含提示版本：再次显式plan是请求新版复看，不是后台失效旧缓存或全量重算；先完成旧在途bundle，再准备新版任务，不能混绑不同冻结提示。
