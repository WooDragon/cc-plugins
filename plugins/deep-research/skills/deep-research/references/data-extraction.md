# Playbook: API 数据抓取型研究

**类型**：data-extraction | **适用**：API/CLI 提取结构化数据（SaaS 拆解、多维表格审计、CMDB 盘点等）

**前置条件**：(1) API 凭证就绪 (2) 项目 CLAUDE.md 声明 base 标识 + 认证身份 + 脱敏豁免 (3) CLI 手工验证通过

---

## Stage 1: Sources — 端点发现与 Tier 标注

端点发现优先级：官方文档/OpenAPI spec → CLI help/reference → API 探索（list→detail→relation） → 逆向抓包（标注风险）

**产出**：table-manifest（TSV）`id | name | tier | record_limit | 备注`，tier 定义：
- **core**：全 schema + views + records（按 record_limit 拉取）
- **noncore**：全 schema + views + 首页 records（不翻页）
- **skip**：仅 schema + views，跳过 records（test/副本/废弃对象）

---

## Stage 2: Acquisition — 分层采集

**翻页**：元数据接口（schema/views）**必须全量翻页**；records 按 tier 截断，`has_more=true` 在 fetch-report 登记。翻页间隔 ≥ 0.3s。

**限流**：429 → 指数退避（1s→2s→4s→8s→16s），5 次仍失败标记 T3 | 5xx → 重试 2 次 | 403 → 不重试，记录权限不足

**错误恢复**：单对象失败不阻塞全局；fetch-report 记录失败详情；Lead 在 G1 Gate 决定补采

**落盘**：`pipeline/1_raw/{00_meta.json, 01_object_list.json, _table_manifest.tsv, _fetch_report.md, objects/<id>_<name>/{schema,views,records_sample}.json}`

---

## Stage 3: Sanitization — 双层脱敏

**L1 schema-aware**（按字段名正则匹配）：

| 字段名模式 | 策略 |
|------------|------|
| 客户/公司/单位/组织 名称 | `sha1[:8]` 稳定 hash → `CUST_xxxxxxxx`（保留跨表关联性） |
| 联系人/姓名/name | `[REDACTED_NAME]` |
| 电话/邮箱/身份证 | `[PHONE]` / `[EMAIL]` / `[ID]` |
| 金额/价格/费用 | `[¥xxx]`（数值和文本均替换） |
| 备注/remark/comment | 仅做 L2 正则扫描 |

**L2 值正则兜底**（递归遍历所有 string）：手机 `1[3-9]\d{9}` → `[PHONE]`、邮箱 → `[EMAIL]`、身份证 18 位 → `[ID]`

**豁免机制**：项目 CLAUDE.md 声明豁免清单，粒度必须精确到 `(object_id, field_name)`，禁止全局豁免值正则

**落盘**：`pipeline/2_cleaned/{redact.py, objects/<id>/{schema,views,records}_redacted.json}`

**隔离铁律**：下游所有 subagent 只读 `pipeline/2_cleaned/`，**严禁读 `pipeline/1_raw/`**

---

## Stage 4: Decomposition — 域并行拆解

Lead 按业务语义划分 3-6 个域，每域独立 analyst subagent 并行执行。

**域拆解文件标准章节**：一、表清单与体量 → 二、字段语义（每表一节） → 三、表间关联（域内+跨域） → 四、ER 图 → 五、视图体系 → 六、核心流程字段流转 → 七、设计现象（事实陈述） → 八、test/副本残留

**铁律**：域拆解只陈述事实，禁止观点。跨域关联在各域拆解中从本域视角分别记录。

---

## Stage 5+: Synthesis — 报告矩阵

API 抓取型研究通常交付多份报告（而非单一综合报告）：

| 序号 | 报告 | 内容 | 性质 |
|------|------|------|------|
| 01 | 原始数据结构 | 数据字典、字段清单、类型分布 | 事实 |
| 02 | 数据关系分析 | ER 图、关联矩阵、治理负债登记 | 事实 |
| 03 | 演进建议 | 架构改进方向、字段规范化建议 | 观点 |
| 04 | 可行性分析 | 特定技术方案的落地评估 | 观点 |
| 00 | 综合报告 | 路线图 + 执行摘要 | 综合 |

事实类报告可由 analyst subagent 基于域拆解文件生成；观点类报告由 Lead 主导。

---

## 反模式清单

| 反模式 | 正确做法 |
|--------|----------|
| 不分 tier 一把全抓 | 先建 manifest，按 tier 差异化采集 |
| 脱敏后丢失关联性 | 实体名称用 hash 而非固定占位符 |
| 分析阶段读 raw 数据 | 只读 cleaned 目录 |
| 单一巨型报告 | 按内容性质拆分报告矩阵 |
| 域拆解掺杂观点 | 事实与观点严格分离到不同 Stage |
| 全局豁免值正则 | 豁免必须精确到 (object_id, field_name) |

---

**关联文件**：[pipeline.md](./pipeline.md) · 见 deep-research 插件的 research-harvester subagent · [redact.py.tmpl](../assets/redact.py.tmpl) · [fetch-report.md.tmpl](../assets/fetch-report.md.tmpl)
