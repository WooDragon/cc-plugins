# 检索现有素材与已发布分析

检索模式只读取配置范围内的DIT CSV与三成果，不读原视频、不发起ASR或模型分析，不要求行程、FFmpeg或完整分析依赖。近源文件仍是权威；DuckDB是本机可删除重建的缓存，不能回写近源索引。查询不到不表示素材库没有该素材。

## 安装与配置

Python 3.12环境仅需安装`requirements-query.txt`（实测`duckdb==2.0.0`）。已有分析环境也可额外安装；分析本身不依赖DuckDB。配置和数据库放本地非同步目录，配置中的库根必须是本次确认的绝对路径；不从旧盘符推定设备。

```json
{
  "schema": 1,
  "libraries": [
    {
      "root": "D:/ExampleMedia",
      "index": "_索引/素材.csv",
      "publication_globs": ["2030/2030*"],
      "publications": ["special-day"]
    }
  ]
}
```

示例为合成路径。`index`可省略以只读分析；发布目录字段可省略以只读DIT。多个库并列配置。`publications`列出相对库根的正式日目录；`publication_globs`仅匹配目录、最多五层、允许普通`*`而禁止`**`递归。使用库已有年/日期结构限制范围。它只枚举指定层目录，并读取固定三个文件名，不遍历媒体文件。自动排除隐藏目录、独立revision/backup/history/archive/temp/tmp及中文修订、备份、历史、临时标签，也识别`修订3`、`day_修订_3`等版本目录；旅游主题中的`历史博物馆`等普通词不受影响。不要选择历史副本、工作state或修订输出。

DIT仅支持原十列UTF-8 BOM CSV：`路径,原名,来源,大小,SHA256,校验,状态,配套,关联,备注`。未知schema、重复当前路径、非法路径或不完整行会明确报错，该输入保留旧缓存。不会改列或自动迁移CSV；配套/关联字段按原CSV保留，不猜多文件分隔符。

## 固定入口

在Skill目录内运行；全部命令输出JSON，各自支持`--help`：

```text
python scripts/query_index.py refresh --config LOCAL_CONFIG.json --db LOCAL_CACHE.duckdb
python scripts/query_index.py search --db LOCAL_CACHE.duckdb 瀑布
python scripts/query_index.py search --db LOCAL_CACHE.duckdb --kind transcript 河流
python scripts/query_index.py search --db LOCAL_CACHE.duckdb --kind media --status 已移除
python scripts/query_index.py status --db LOCAL_CACHE.duckdb
```

`search`支持一个连续关键词（大小写不敏感的字面子串），以及`--kind media|event|interest_point|transcript`、`--library 绝对库根`、`--path 相对路径片段`、`--status DIT或分析状态`、`--date YYYY-MM-DD`、`--limit 1..10000`。默认最多50条。未分析DIT没有分析日期，不会被分析日期筛选命中；需要按日期找这类素材时用库原路径约定筛选。不是语义搜索，关键词相近不保证命中。

结果包含近源`publication`（正式三成果目录）、`dit_index`（CSV路径）、两者各自的最后成功读取时间，以及当前库根下的`original_path`、`relative_path`、文件内`start_s/end_s`、原`precision`与`evidence`、结构化`geography`及其候选/置信度/依据。事件每个clip单独返回，可跨文件；不能把多个clip视为一个连续区间。chunk转写仍为原片段范围，不能当词时码。纯DIT仅有素材记录，时码和分析证据为空。已移除行保留历史信息且`original_path=null`，不提供可打开媒体。

路径只按“正式发布日目录＋sources.relative_path”在库根内精确联接DIT当前路径，兼容schema 1在Windows生成的反斜杠相对路径，校验后规范为`/`；DIT路径仍须POSIX格式。忽略分析中历史绝对`path`；不按basename或未知SHA猜合并。所有本地ID仅在发布位置内有效，返回的run/revision只用于溯源。未匹配DIT的分析来源与未分析DIT均保留。CLI不会探测原视频是否在线，`original_path`是索引定位而非已验证可访问承诺。

## 刷新与失效

`refresh`读取索引字节摘要做增量；先校验完整快照，按DIT文件或正式日发布目录在事务内替换该输入，重复刷新不追加记录。三成果复用run/revision/context/hash链，并比较读取前后的Markdown提交标记；半发布或不一致组拒绝进入新快照。不会用mtime/size代替内容校验。

读取失败、NAS离线、schema冲突或半发布时保留该输入的上次成功数据，`status`给出`stale=true/error/last_success/checked_at`；搜索结果标出对应旧快照。首次失败没有旧数据可供搜索。glob曾发现的目录即使暂时消失仍保留并标stale，不能把离线等同删除。发现层本身失败也作为`kind=discovery`的状态显示。修复输入后重跑相同refresh；部分输入失败退出码为2，配置或运行错误为1，全部成功为0。

从配置移除一个显式输入或其发现规则，会移除该范围的缓存；这不删除近源文件。删除本机数据库后用相同配置refresh可重建全部在线输入，离线输入须恢复连接后刷新。

## DuckDB直接查询

可用DuckDB客户端只读打开本机缓存，例如Python的`duckdb.connect(CACHE, read_only=True)`，再查询公开视图：

| 视图 | 一行含义 | 常用字段 |
|---|---|---|
| `media` | DIT素材与精确联接的分析来源；保留未匹配双方 | library、relative_path、original_path、dit_status、analysis_status、sha256、dit_data、source_data、stale |
| `events` | 发布位置内的一条事件或兴趣点 | scope、finding_id、kind、title、reason、geography、data、stale |
| `segments` | 一个事件/兴趣点的独立clip | kind、title、original_path、start_s、end_s、precision、evidence、geography、stale |
| `transcriptions` | 原始转写segment | text、original_path、start_s、end_s、precision、evidence、data、stale |

`dit_data/source_data/data/geography/evidence`是原结构的JSON文本，可在DuckDB中解析；CLI将命中结果的evidence/geography解码为JSON。`snapshots`记录每个输入的最后成功读取及错误。不要修改缓存表或依赖内部行号作为永久素材ID。未知缓存schema需使用新数据库重建；不自动迁移缓存。直接查询API见[DuckDB Python DB API](https://duckdb.org/docs/stable/clients/python/dbapi)。
