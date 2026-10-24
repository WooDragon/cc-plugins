# Log素材的可复现识图预览

可信DIT规范命名中的`SLOG3CINE`表示已明确的Sony S-Log3/S-Gamut3.Cine模式，`DLOGM`表示对应设备D-Log M模式，可作为输入色彩模式证据。不要再要求用户证明遵守其既有DIT规范的文件名；遇到明确冲突再核实。`NO`表示本规则不套Log LUT。设备型号与模式共同决定映射，不能把D-Log M当D-Log，也不能跨机型随意套用。

通过显式本地LUT映射给已确认Log素材生成SDR Rec709识图预览，原片只读。使用匹配输入gamma/gamut的官方`.cube`，记录来源、LUT SHA256、滤镜、设备/模式、输出目标和是否归一化；缓存身份必须包括变换，不能把不同LUT输出算同一成功缓存。缺少匹配LUT时保留原预览并明确未归一化，不能猜一个LUT或用简单曲线/饱和度冒充准确色彩。普通NO素材不套用Log变换。

官方资源：[Sony S-Log与Rec709监看说明及LUT入口](https://support.d-imaging.sony.co.jp/support/ilc/movie/en/grading/02.html)、[DJI官方LUT目录](https://www.dji.com/lut)。Sony应匹配S-Gamut3.Cine/S-Log3；DJI Air3S和Osmo Action5各有D-Log M→Rec709资源，部分官方文件标为vivid，记录实际采用的显示look，不能宣称是无风格的色度测量。默认分发包不携带厂商LUT；用户提供/从官方资源取得后本地配置，遵守相应使用条件，不下载未知授权替代品。

[FFmpeg lut3d](https://ffmpeg.org/ffmpeg-filters.html#lut3d)可以应用`.cube`；[colorspace](https://ffmpeg.org/ffmpeg-filters.html#colorspace)/[zscale](https://ffmpeg.org/ffmpeg-filters.html#zscale)处理适用的色域、传递特性、矩阵和范围。不能仅标记`bt709`代替实际Log转换。已确认PQ/HLG的HDR→SDR是另一条处理路径，[tonemap](https://ffmpeg.org/ffmpeg-filters.html#tonemap)要求线性光输入；不把所有灰画面当HDR一律tone-map。

未归一化Log仍可提供主体/动作/空间的粗索引证据，但低对比可能增加小细节、暗部和颜色判断的不确定性。除非有合适预览，避免颜色、曝光或审美定论。这是工程判断，不宣称有该模型的准确率对照实验。现有已完成包不因新增LUT配置而自动全量重抽/重看；新运行使用配置；已有run只有ROOT基于明确错漏证据指定少量区间时才建立新预览证据。

固定入口是`init --preview-lut-map LUT_MAP_JSON`；键为可信DIT设备+模式，路径相对该JSON文件解析。例如：

```json
{
  "ZVE1:SLOG3CINE": "luts/sony-matching-rec709.cube",
  "OA5P:DLOGM": "luts/action5-matching-rec709.cube",
  "A3S:DLOGM": "luts/air3s-matching-rec709.cube"
}
```

这是路径示例，不携带或替用户选择厂商LUT。`preview_spec`记录实际应用与警告；缺失匹配不声称应用。提取key包含LUT内容hash及变换参数；同内容LUT换路径不重复处理，不同变换不复用同一媒体缓存。无需新服务、自动创意调色或整片代理转码。

新run的`select_first_v3`先筛选硬件帧再下载，LUT/缩放仍在下载后应用；不是跳过视频解码、修改采样点或变更色彩映射。新旧顺序使用不同媒体缓存身份，原帧记录模式供定点取回复现；既有version2缓存不因Skill升级重算。部署时用相同任务核对实际PTS及像素等价，具体方法及吞吐限制见[并发约定](concurrency.md)。
