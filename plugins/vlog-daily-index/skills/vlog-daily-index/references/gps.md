# GPS 接口与可信边界

`scripts/vlog_index/gps.py` 使用 Garmin 官方 `garmin-fit-sdk` 解码 FIT，并启用完整性检查和解码 CRC 校验。经纬度依据官方 Profile 的 semicircles 字段转为 WGS84（EPSG:4326）。不实现 FIT 协议、停留聚类或位置插值算法。

```python
build_gps(fit_dir: str, output_path: str,
          timezone='Asia/Shanghai', date=None) -> dict
locate(gps_data: dict, timestamp_utc: str,
       max_gap_seconds=120) -> dict | None
```

`build_gps` 读取目录顶层全部 FIT，按记录时间而非文件名判断日期。`date` 为展示时区内的 `YYYY-MM-DD`；为空则保留全部日期。原 FIT 始终只读，JSON 输出必须在 FIT 源目录之外。输出有 `points/stops/gaps/quality/sources/versions/parameters`：

- 时间均为带 `Z` 的 UTC，`timezone` 保存展示时区。
- 每个点保留源文件、记录序号、原始 semicircles 字段和分段 ID。
- 每个来源保留 CRC、解码异常、内容摘要、大小/修改时间、真实记录日期、有效坐标日期与筛选数量。
- 缺坐标/时间、重复冲突、明显异常速度单独记录；相邻可信点超过 120 秒则断开。冲突点删除，完全重复的时间/坐标保留一条。超过 100 m/s 的短间隔跳点保守拒绝，并保留质量隔断；该阈值是异常保护，不用于判断交通方式。
- `quality.decode_status` 表示源文件解码情况；`quality.status` 会因轨迹缺口/无效记录标为 `partial`。有坐标起止时间不等于全天连续覆盖，须同时看 `coverage_windows` 和 `gaps`。

每个连续分段交给 MovingPandas。停留调用 `TrajectoryStopDetector.get_stop_points(max_diameter=100, min_duration=120秒)`；输出位置仅表示空间停留，目的未知。位置查询调用 `Trajectory.get_position_at`；仅允许同一文件、同一分段且相邻采样间隔不超过 120 秒的插值，禁止越界外推。精度分为 `recorded_sample` 和 `interpolated_estimate`，不虚构米级精度。不同 FIT 同时提供相差超过 100 米的位置时返回空值，需人工核对。

MovingPandas 的时间索引通过明确的 UTC-naive 适配器传入；导出立即恢复 UTC。外部输入和持久化时间仍必须带时区，不能把本地无时区时间当 UTC。

媒体关联入口：

```python
locate_media(gps_data, timestamp_utc=None, *,
             time_mapping_verified=False, playback_rate_verified=False,
             device_with_garmin=False, drone_srt_points=None,
             video_seconds=None)
```

用户为本次行程提供GPS即视为确认随行，不额外询问或要求同行参数；只有明确不同人、日期等冲突才澄清。上游据此传入`device_with_garmin=True`，低层`locate_media`仍保持保守默认，防止脱离运行上下文误关联。Garmin关联还要求真实时间映射和播放/拍摄经过时间关系可信。未知拍摄时间、慢放/延时映射不明时返回空值。已明确的慢放映射可由上游先换算为真实UTC，再明确传入已验证标志。

无人机配套坐标优先，独立保存为 `drone_srt`，不与 Garmin 持有者混淆。SRT 点形状是 `{start_seconds, end_seconds, latitude, longitude, trusted: true, crs: 'EPSG:4326', source_file}`，按字幕真实区间关联文件内时间；区间外不外推，重叠冲突返回空值。提供无人机轨迹后缺失区间也不会退回 Garmin。所有坐标均表示记录者/相机位置，不能当作远处画面主体的坐标。

验证版本：Python 3.12.14；`garmin-fit-sdk==21.218.0`、`movingpandas==0.23.0`、`geopandas==1.2.0`、`pandas==3.1.0`、`shapely==2.2.0`、`geopy==2.5.0`、`tzdata==2026.5`。MovingPandas 的可选平滑依赖 Stone Soup 不用于本模块；Pandas 3.1 会产生上游未来弃用警告，当前锁定组合已通过关键测试和真实数据验证。运行时不得自动升级。

必要验证：`python -m unittest discover -s tests -p test_gps.py -v`。合成测试覆盖官方SDK编码/解码及CRC、跨时区日期筛选、源文件保护、120秒边界、停留不跨缺口、不确定时间禁用、无人机优先与坐标占位；不需要任何私人轨迹。

依据：[Garmin 官方 SDK](https://github.com/garmin/fit-python-sdk)、[MovingPandas 停留接口](https://movingpandas.readthedocs.io/en/main/api/trajectorystopdetector.html)、[MovingPandas 位置查询](https://movingpandas.readthedocs.io/en/main/api/api/movingpandas.Trajectory.get_position_at.html)。
