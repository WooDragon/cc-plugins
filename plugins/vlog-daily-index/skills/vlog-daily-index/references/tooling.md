# 固定工具、Agent职责与配置边界

普通运行使用包内CLI和harness/连接器现有工具，不临时手写媒体、地图、状态迁移、结果转换或验收脚本。以下命令均由`scripts/vlog_daily_index.py`提供，除init显式路径外均使用同一`--state STATE`；具体参数用对应`--help`。数据JSON是有来源的配置或Agent结果，不是可执行代码。

| 依赖顺序 | 固定入口与产物 | Agent或配置职责 |
|---|---|---|
| 1. 必需背景 | harness聊天列表/读取、Notion search/fetch；`init`、`attach-itinerary` | 查找行程、保留出处/计划实际冲突；明确素材/GPS/可信DIT，未找到先讨论 |
| 2. 输入校准 | `configure-source`、`gps-build`、`hardware` | 有证据设置角色、带时区capture_time、正常速标志；配置显式LUT map |
| 并发验证与配置 | `hardware-benchmark`、`configure-concurrency` | 独立本地小样验证设备槽位，按实际证据配置1–4媒体路、Luna上限6及ready/空间高水位；不从利用率推定速度，详见[并发约定](concurrency.md) |
| 3. 协议验证 | `asr-json-sample`、`audio --discover`、`audio --acknowledge`、`adopt-json-sample` | 检查完整JSON与NDJSON终止记录，填已验证protocol JSON；unknown恢复须外部结束证据 |
| 4. 媒体/音频 | `continue-day`、`packages`；旧`prepare --blocks`/`audio`用于有界诊断 | 正常并发流水线用continue-day确定性抽样/匹配Log预览/单ASR及背压，prepare不冒充多设备调度器，harness控制vision slots |
| 5. 视觉 | `vision-queue`、`import-results`、`retry-visual`及包内schema/result_path | 新run稳定块ready即按真实空闲弹性claim/派发，最多6 Luna；脚本不spawn，Luna实际读取全图，事件/兴趣点仅候选，Sol后续带完整转写；invalid只显式归档纠正一次 |
| 6. 语义 | `daily-package`导出完整包/schema/result_path | Sol high跨文件汇总事件/兴趣点/主要主体，保留源时码和原话归属 |
| 7. 地图 | `map-lookup --requests FILE --provider photon\|osm --output FILE` | Agent按事件对应可信GPS选择查询点/对象；工具保存实际响应和缓存，不编造地图成功 |
| 8. 专项主体 | `subject-targets --template FILE`、`subject-targets --targets FILE` | Sol标需核验的主要地标/自然主体并填目标JSON；不能用空targets绕过明显主体 |
| 9. 地理 | `geography-package --daily FILE [--research-evidence FILE]`、`import-geography --result FILE` | 专门Sol high填自动生成geography.template.json；引用现有帧、GPS、路线、地图，给近似/候选/未知与主体核验 |
| 10. 局部证据 | `review-frames --frame-id ID --reviewer ROOT --reason ...`；`supplement --list-requests`、`decide-supplement`、`supplement` | ROOT决定已有时码取回或一轮补采；已有证据取回不改计划/原包身份；Luna/Sol仅回流受影响依赖 |
| 11. 完整输出 | `attach-review-context --context FILE`、`render --daily FILE` | 记录路线/停留/矛盾/覆盖说明，生成实际待审三成果 |
| 12. 实质终审 | `final-review-package`、`approve-final --review-result FILE --reviewer ROOT --reason ...` | ROOT阅读审查JSON/preview，填写模板全部维度与问题处置，未决blocking为0才批准 |
| 13. 发布恢复 | `publish`、`cleanup`、`status` | 回读一致才清登记temp；同state恢复，原片只读，无额外用户确认 |
| 可选每日目录命名 | `naming-plan --config FILE --library-root ROOT --index CSV`、`naming-review --plan FILE`、`naming-apply --plan FILE` | 先审证据，再选固定行程区域＋2–3主题，ROOT核验；默认dry-run，实际迁移须用户已授权，随后重渲染/受影响终审再发布，详见[命名约定](naming.md) |
| 开发交付 | `tools/build_release.py`、`tools/verify_release.py`、unittest、官方quick_validate.py | 固定测试、打包、解压新路径核验，不临时写验收代码 |

`configure-source --source-id ID --capture-time ISO_WITH_OFFSET --normal-speed --role camera --reason EVIDENCE`仅在证据可靠时使用；未知可用`--unverified-clock`/`--unknown-speed`。它使下游关联失效但不重跑媒体。禁止手改manifest绕过门槛。

`gps-build --fit-dir FIT_DIR --output GPS_JSON --date YYYY-MM-DD --timezone ZONE`调用包内官方SDK流程。`asr-json-sample`复用已完成同源/服务/模型短样本；核实NDJSON终止后`adopt-json-sample --protocol FILE --reason VERIFIED_EVIDENCE`导入正式成功缓存，重复导入不重复segment、不请求ASR。protocol JSON由真实响应确定，不靠脚本猜终止语义。

## 地图查询与缓存

固定提供商为Photon逆地理和OSM对象几何查询，属于“高德或类似地图接口”的可用路径，不需要在用户机器新建服务。输入请求列表示例（示例值非本项目位置）：

```json
[{"coordinates":{"latitude":1,"longitude":2,"crs":"EPSG:4326"},"radius_km":10,"limit":5}]
```

Photon输入WGS84；OSM对象查询还需已查明的`object_type`和正整数`object_id`。固定入口顺序查询、缓存成功/空/失败，恢复复用cache；只有明确需要重试失败时加`--retry-failed`。输出脱敏请求/响应、时间、坐标系、候选和标签点距离，距离不代表湖岸/山体边界。失败或空响应不能作为成功地图证据。查询后用attach-itinerary加载合并后的map evidence，再生成新地理包；不用手写HTTP抓取或缓存脚本。

[Photon官方API](https://github.com/komoot/photon/blob/master/docs/api-v1.md)说明reverse接口及结果；[公共示范服务说明](https://github.com/komoot/photon#demo-server)允许合理请求量、可能限流且无可用性保证。工具小批顺序/缓存使用，不重试风暴。需要高德时通过用户已有授权连接器取得符合[坐标规范](https://developer.amap.com/api/webservice/guide/api/convert)的实际查询缓存，再以相同证据接口导入；本包不虚构已实现的高德凭据客户端。

## 恢复与结果填写

同一次日级、地理或终审工作已产生package/template时，先复用现有文件与指定result_path。Agent按模板/schema填写原生JSON，不用临时转换脚本；未填写的TODO模板不能导入或批准。地理输入、targets或证据变化才重新生成受影响包；重新生成后旧package_id结果必须拒绝。

最终审查模板包含行程与实际、GPS路线/全部停留、时间地点一致性、视觉与转写、主体地标、补采处置六维。ROOT记录支持证据、错漏/矛盾的处置和有依据未知；不能仅勾完字段当作语义审查。审后行程/GPS/语音/视觉记录/targets/补采/审查context或三成果变化使批准失效。
