# 动态补采与按需镜头复看

初筛仍按既有静态档位。新run启用`shot_v1`补采：初筛只提出有同source两帧以上证据、具体变化和待解决的客观过程疑问的`purpose=dynamic`请求，不自行做动态定论。不因无人机、有人、有云、普通水纹或常规运动类别全量触发。旧run缺此模式时保留原补采/claim/成功缓存，不迁移、不默重算；旧来源动态缺失表示未评估。

## 正常自动分支

初筛全部导入后、第一次`daily-package`前，ROOT执行一次已授权规则的批量动作，再照程序短action桥接原生工具，不逐候选抄字段或主观打分：

```text
python scripts/vlog_daily_index.py accept-dynamic --state LOCAL_STATE --reviewer ROOT --reason AUTHORIZED_ANCHORED_DYNAMIC_POLICY
python scripts/vlog_daily_index.py supplement --state LOCAL_STATE
python scripts/vlog_daily_index.py shot-work --state LOCAL_STATE --native-capabilities CURRENT_CAPABILITIES --available-workers ACTUAL_FREE_SLOTS
```

批量入口重新读取原成功初筛包，只接受非空白字符串question/reason、有限合法源秒及2+同source合法帧锚点的动态请求，留ROOT政策/理由和原请求；地理或其他特殊候选仍走`decide-supplement`。原一轮补采队列保留：新动态请求是闭区间，共用资格/采样计划保留同source冻结表中两个不同的实际帧锚点，2fps参考网格仅替换必要末端以包住锚点，不按锚点数量盲增图片；平均fps不是n/fps真实PTS格点证明；锚点必须落在该采样包络。解码窗口可多一个源帧周期以取到闭端点，但实际分析帧不得超请求范围，不能把额外解码时间冒充覆盖。实际PTS不足两点或越界时返回该请求的ROOT恢复项，不影响其他来源。，旧地理/遮挡用途仍扩前15/后30秒，再合并相交区间。长区间完整计划并分包，不截成前8秒；帧预算仅限制单worker包。提取/包/成功结果可恢复，只看选中区间，不重跑ASR。复看仍不确定时交原片播放，不递归再密采。

补采包只交max一次，同时写逐核心帧可见事实与跨帧变化，不另跑medium看同图。初筛完成但尚有未处置动态候选时`daily-package`明确阻断；复看导入后，日级Sol一次消费完整事实和`visual_changes`，独立地理/ROOT门槛保留。晚到地理补采仍使相关下游过期，定向修订。

`shot-work`返回`spawn`时，只读短action的task_path和原样native_contract；ROOT真实创建worker，再记录真实canonical ID：

```text
python scripts/vlog_daily_index.py shot-work --state LOCAL_STATE --bundle-id BUNDLE --native-agent-id ACTUAL_NATIVE_ID
python scripts/vlog_daily_index.py shot-work --state LOCAL_STATE --bundle-id BUNDLE --outcome complete --reason MATCHING_THIS_BUNDLE_NATIVE_FINAL
```

之后重新`shot-work`机械验证/导入、获取下一步。坏/超预算单段保留明确恢复项，其他合法任务仍可派发；不同冻结提示/schema分组，不把旧任务改成当前合同。`failed`同样必须有本bundle真实FINAL/停止证据；仅已确认failed才保留部分成功并重新安排未完成段。`complete`却缺结果进入root_correction，保留原bundle/native归属，恢复原结果后继续，不能自动重派。`wait`不释放或重派；`recover_bind`必须找回原spawn的真实回执，不能重复创建。未知不能按等待超时或结果文件存在当作native结束。错误先保存其他worker真实回执，原图/task恢复后继续；未恢复不算成功。

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

变化区分`visible_change`与`camera_motion_inference`。每条客观变化至少引用2张不同的本source实际图，`clip.start/end`等于该条evidence_ids首/末实际源秒（浮点容差1微秒），精度`sampled_frames`，写confidence/limits且needs_playback=true。observed全表不能补未引用端点；不能由稀疏图推断完整连续性、无抖动、曝光原因、瞬时动作峰值、精确剪点或默认审美可用性。慢放仍用源文件播放秒，未知倍率不换算真实动作速度。

```json
{"review_id":"validated-review","change":{"topic":"composition","claim_type":"camera_motion_inference","description":"主体相对位置变化，可能含相机运动，需播放核实","clip":{"source_id":"source-id","start":1,"end":2,"precision":"sampled_frames","evidence_ids":["frame-a","frame-b"]},"confidence":"low","limits":["仅比较已显示采样帧"],"needs_playback":true}}
```

结果经`validate --task FROZEN_TASK --result RESULT_JSON`形成独立accepted记录；差异不能覆盖已有接受结果。`report --record ACCEPTED_JSON --output REPORT_MD`重新读取绑定task/result、走同一validator重建整个记录再比对，失败不覆盖旧报告。结构通过不等于语义审定，原片链接是prepare身份快照，不承诺报告时文件已再次联网核验。

自动分支把已验证变化经日语义写入正式`AI_事件与兴趣点.json.visual_changes`、`AI_每日索引.md`及query的`visual_change`类型，保留源文件时码、证据、未知及事实/推断区别；不借event/interest_point触发额外地理。`visual_review_coverage`的缺失表示未评估。已有daily未带新字段时保持原序列化/证据摘要；提示升级不让既有成功初筛缓存静默失效。独立显式复看先输出单独报告/记录，后续发布仍需原日级/地理/ROOT链，不绕审核自动写回。

新建镜头任务（独立prepare及自动动态补采）共用固定4×4像素线索：每个相邻对只给显示灰度变化dB和归一化固定坐标内容残差R；R无法归一化为null。定义随可选块冻结，须回图确认部位与帧证据，不能由数字判断光照/曝光原因、运镜方向或连续性，R高不屏蔽dB。完整输入保留版本/config/实现与图身份，薄包只携短表；不使用未校准可比性标签或排名。旧无块任务/已成功缓存保持冻结，已有query任务优先复用，只有新任务键绑定线索身份；不升级全局提示版本、不后台重算。

旧合同6的像素线索仅在两段同图的单次历史对照中验证：具体亮暗变化得到核图支持，原有早段相对位移观察保留；候选仍可能覆盖整段，阶段起点与精确剪点仍需日级Sol/ROOT及原片回看。未做随机对照，不能推广为总体触发率、完整动态理解或费用改善。

新客观合同版本8使用首帧基线及逐相邻双帧事实，之后只汇总有证据的客观变化/推断与未知；不生成candidate_ranges、edit_cue或剪辑区间/剪点/转场/主观可用性建议。剪辑选择归下游。该版本与已回退实验7区分，未恢复其候选/边界规则。旧合同的candidate_ranges/edit_cue仅按各自冻结schema读取和验收，不迁移、删除或重算旧结果；旧报告保留历史字段，新报告不生成这些段落。唯一提示源为shot_review.INSTRUCTIONS，standalone/自动包共用；bundle取各成员冻结提示，不混绑不同schema。query先以原source/路径/完整区间/preview和图hash核验复用旧精确任务（包括旧提示版本），只有无匹配时创建新任务。

## 恢复与日级事实边界

新轮次在开始提取时冻结全部已存在提案，未决地理仍可由ROOT接受；后到的同包络已授权请求仅关联到已有plan/包的原事实与图像证据，不修改已派发task，不重抽。同轮这些原事实进入日级包，独立地理核验照常消费其观察/帧证据，不能由请求resolved跳过地理门槛。新补采提案不自动成为第二轮。

旧accepted-only轮次无法自动判断遗漏提案原属哪一轮。ROOT先核实原始初筛canonical结果与原轮范围，再执行：

```text
python scripts/vlog_daily_index.py decide-supplement --state LOCAL_STATE --request-id ORIGINAL_REQUEST --decision accept --restore-round-request --reviewer ROOT --reason ORIGINAL_ROUND_PROVENANCE
```

此入口只接受已有pending、成功的原始初筛canonical结果中逐字相同的提案，拒绝supplemental来源；在round另记结果路径/hash及ROOT理由，不改原request_ids、旧task或结果。缺原始证据保持未完成，不猜归属；不能执行的动态提案用原decide-supplement明确reject退出。旧半途plan缺完整冻结包清单时返回恢复项，须恢复原包清单，不以新schema偷偷重建。source-id筛选只在accept-dynamic/supplement执行；shot-work拥有完整冻结bundle，传该筛选会明确拒绝。

日级visual_changes必须逐条原样引用相应review_id中已接受的canonical change，描述/方向/亮暗、topic、claim_type、clip、证据、confidence与limits均不能借同一ID改写；叙事概括写独立summary。query复用visual_change须逐项匹配真实发布记录，不能只信输入kind；query读取仍允许旧edit_cue字段但新分析不产生它。活动缓存的本地/非同步/映射盘校验与init共用，query在任何目录、lock或input写入前拒绝原片目录。

客观合同8本轮只做程序、合成流水线及旧冻结合同兼容验证，没有新增视觉模型试验；旧合同6的小样不作为合同8的真实视觉质量证明，失败实验7未保留。
