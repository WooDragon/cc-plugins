---
name: ppt-create
description: Generate "editorial magazine × e-ink" horizontal-swipe web presentations using Astro component architecture with WebGL fluid backgrounds, serif/sans-serif typography, chapter dividers, data dashboards, and image grids. Triggers on "magazine-style PPT", "horizontal swipe deck", "editorial magazine", "e-ink presentation", "web PPT", "网页 PPT", "杂志风".
---

# PPT Create

## Prerequisites

本 skill 需要在 PPT 框架项目中使用。检查以下标志文件：

- `astro.config.ts` — Astro 项目配置
- `src/layouts/DeckLayout.astro` — PPT 核心布局组件

如果缺失，说明当前目录不是 PPT 框架项目。告知用户需先获取 PPT 框架（联系项目管理员获取，或从模板仓库克隆）。

## 这个 Skill 做什么

在本仓库的 **Astro 组件架构**下生成一个横向翻页网页 PPT，视觉基调是：

- **电子杂志 + 电子墨水**混血风格
- **WebGL 流体 / 等高线 / 色散背景**（hero 页可见）
- **衬线标题（Noto Serif SC + Playfair Display）+ 非衬线正文（Noto Sans SC + Inter）+ 等宽元数据（IBM Plex Mono）**
- **Lucide 线性图标**（不用 emoji）
- **横向左右翻页**（键盘 ← →、滚轮、触屏滑动、底部圆点、ESC 索引）
- **主题平滑插值**：翻到 hero 页时颜色和 shader 柔顺过渡
- **翻页入场动效**（Motion One 驱动,5 种 recipe 自动匹配布局,本地 + CDN 双保险,离线可用）

这个 skill 的美学不是"商务 PPT"，也不是"消费互联网 UI"——它像 *Monocle* 杂志贴上了代码后的样子。

## 何时使用

**合适的场景**：
- 线下分享 / 行业内部讲话 / 私享会
- AI 新产品发布 / demo day
- 带有强烈个人风格的演讲
- 需要"一次做完，不用翻页工具"的网页版 slides

**不合适的场景**：
- 大段表格数据、图表叠加（用常规 PPT）
- 培训课件（信息密度不够）

## 工作流

### Step 1 · 需求澄清(**动手前必做**)

**如果用户已经给了完整的大纲 + 图片**,可以跳过直接进 Step 2。

**如果用户只给了主题或一个模糊想法**,用这 6 个问题逐个对齐后再动手。不要基于猜测就开始写 slide——一旦结构定错,后期翻修代价很高:

#### 运行环境适配

- **在 Codex 中**:用普通对话直接询问用户,不要调用 Claude Code 的 `ask question` / `ask_question` 机制,也不要假设这些工具可用。一次最多问 1-3 个最关键问题;如果信息缺口不影响开工,先做合理假设并在回复里说明。
- **在 Claude Code 中**:可以继续使用原有的 `ask question` 交互方式来逐项澄清。

#### 6 问澄清清单

| # | 问题 | 为什么要问 |
|---|------|-----------|
| 1 | **受众是谁?分享场景?**(行业内部 / 商业发布 / demo day / 私享会) | 决定语言风格和深度 |
| 2 | **分享时长?** | 15 分钟 ≈ 10 页,30 分钟 ≈ 20 页,45 分钟 ≈ 25-30 页 |
| 3 | **有没有原始素材?**(文档 / 数据 / 旧 PPT / 文章链接) | 有素材就基于素材,没有就帮他搭 |
| 4 | **有没有图片?放在哪?** | 详见下方"图片约定" |
| 5 | **想要哪套主题色?** | 见 `references/themes.md`,5 套预设挑一 |
| 6 | **有没有硬约束?**(必须包含 XX 数据 / 不能出现 YY) | 避免返工 |

#### 大纲协助(如果用户没有大纲)

用"叙事弧"模板搭骨架,再填内容:

```
钩子(Hook)       → 1 页   : 抛一个反差 / 问题 / 硬数据让人停下来
定调(Context)    → 1-2 页 : 说明背景 / 你是谁 / 为什么讲这个
主体(Core)       → 3-5 页 : 核心内容,用 Layout 4/5/6/9/10 穿插
转折(Shift)      → 1 页   : 打破预期 / 提出新观点
收束(Takeaway)   → 1-2 页 : 金句 / 悬念问题 / 行动建议
```

叙事弧 + 页数规划 + 主题节奏表(见 `layouts.md`),**三张表对齐后**再进 Step 2。

大纲建议保存为 `项目记录.md` 或 `大纲-v1.md`,便于后续迭代。

#### 图片约定(告知用户)

在动手前向用户说清:

- **文件夹位置**:`public/decks/<name>/` 下（`<name>` 是 deck 目录名，如 `maas`）
- **命名规范**:`{页号}-{语义}.{ext}`,例如 `01-cover.jpg` / `03-figma.jpg` / `05-dashboard.png`
  - 页号补零便于排序
  - 语义用英文,短、具体、和内容对应
- **规格建议**:
  - 单张 ≥ 1600px 宽(避免大屏模糊)
  - JPG 用于照片/截图,PNG 用于透明 UI/图表
  - 总大小控制在 10MB 内(影响翻页流畅度)
- **在 .astro 文件里引用**：用绝对路径 `/decks/<name>/01-cover.jpg`（Astro 构建时 `public/` 原样拷贝到 `dist/`，路径稳定）
- **没图怎么办**:和用户对齐,可以先用占位色块生成结构,等图片后期补;但要告知 layout 4/5/10 等图文混排页没图就没法验证视觉效果

#### Codex 配图生成(可选)

如果当前运行环境是 **Codex**,完成 deck 初稿后,主动问用户是否需要用 GPT-M 2.0 生成配图并插入 PPT。不要默认生成。

推荐询问方式:

> 要不要为这份 PPT 生成几张配图?可以做成人文纪实照片、杂志风信息图、流程/对比/系统关系图,或把截图再设计成统一的杂志风视觉。

如果用户确认生成,再问他想要哪种图片类型或风格;如果用户没有偏好,根据页面内容自行推荐 1-3 张最值得生成的配图。

生成配图时遵守:

- 提示词保持简短,只框定主题、用途、风格和比例,不要写长篇摄影指导
- 图片风格必须贴合本 skill 的"电子杂志 × 电子墨水"基调
- 信息图、图表、截图再设计里的文字语言必须跟随用户正在使用的语言;中文 deck 用中文,英文 deck 用英文
- 先看 `references/image-prompts.md` 选择图片类型和基础提示词
- 配图比例必须匹配最终落位:主视觉 16:9,左文右图 16:10 / 4:3,信息图 16:9 / 16:10,截图再设计 16:10,图文混排小图 3:2 / 3:4,网格图统一高度裁切
- 生成后的图片放到 `images/` 下,命名遵守 `{页号}-{语义}.{ext}`

### Step 2 · 创建 Astro 页面

项目已迁移到 Astro 组件架构。在 `src/pages/decks/<name>/index.astro` 创建新 deck，无需拷贝 template.html。

```bash
mkdir -p src/pages/decks/<name>
```

然后创建 `src/pages/decks/<name>/index.astro`，参考本 skill 的 `assets/template.astro`（或项目中已有的 deck）：

```astro
---
import DeckLayout  from '@/layouts/DeckLayout.astro';
import Slide       from '@/components/slides/Slide.astro';
import Chrome      from '@/components/slides/Chrome.astro';
import Foot        from '@/components/slides/Foot.astro';
// 按需 import 内容组件（Grid/StatCard/Pipeline/Pillar/Callout/Rowline/...）
---

<DeckLayout title="PPT 标题 · Deck Title" theme="indigo-porcelain">

  <!-- 封面：hero dark -->
  <Slide theme="dark" hero animate="hero">
    <Chrome left="主题 · Theme" right="01 / 12" />
    <div class="frame" style="...">
      ...内容...
    </div>
    <Foot title="Section Name" />
  </Slide>

</DeckLayout>
```

#### 2.1 · 必改占位符（**容易漏**）

| 位置 | 需改为 |
|------|--------|
| `DeckLayout title=` | 实际 deck 标题（如 `一种新的工作方式 · Luke Wroblewski`） |
| `DeckLayout theme=` | 见 2.2 |

#### 2.2 · 选定主题（**当前实现了 2 套**）

| prop 值 | 名称 | 适合 |
|---------|------|------|
| `ink-classic` | 🖋 墨水经典 | 通用 / 商业发布 / 不知道选啥的默认 |
| `indigo-porcelain` | 🌊 靛蓝瓷 | 科技 / 研究 / 数据 / 技术发布会 |

**注意**：原有的 🌿 森林墨、🍂 牛皮纸、🌙 沙丘 三套主题尚未在 Astro 中实现对应 WebGL shader，暂不可用。如需使用，需先在 `src/shaders/` 添加对应 glsl 文件并扩展 DeckLayout。

**硬规则**：
- 一份 deck 只用一套主题，不要中途换色
- 不要混搭主题变量

### Step 3 · 填充内容

#### 3.0 · 规划主题节奏（**动手前必做**）

**在挑布局之前**,必须先列出每一页的主题 class(`hero dark` / `hero light` / `light` / `dark`)并写到文档或草稿里对齐。详细规则看 `references/layouts.md` 开头的"主题节奏规划"一节。

**强制规则**:

- 每页 section 必须带 `light` / `dark` / `hero light` / `hero dark` 之一,不要只写 `hero`
- 连续 3 页以上同主题 = 视觉疲劳,不允许
- 8 页以上必须有 ≥1 个 `hero dark` + ≥1 个 `hero light`
- 整个 deck 不能只有 `light` 正文页,必须有 `dark` 正文页制造呼吸
- 每 3-4 页插入 1 个 hero 页(封面/幕封/问题/大引用)

**生成后自检**：在 `.astro` 文件里搜索 `<Slide`，列出每个 Slide 的 `theme=` 和 `hero` 属性，人工确认节奏合理再交付。

#### 3.1 · 挑布局

**不要从零写 slide**。打开 `references/layouts.md`,里面有 10 种现成布局骨架,每种都是完整可粘贴的 `<Slide>` 组件块:

| Layout | 用途 |
|---|---|
| 1. 开场封面 | 第 1 页 |
| 2. 章节幕封 | 每幕开场 |
| 3. 数据大字报 | 抛硬数据 |
| 4. 左文右图(Quote + Image) | 身份反差 / 故事 |
| 5. 图片网格 | 多图对比 / 截图实证 |
| 6. 两列流水线(Pipeline) | 工作流程 |
| 7. 悬念收束 / 问题页 | 幕末 / 收尾 |
| 8. 大引用页(Big Quote) | 衬线金句 / takeaway |
| 9. 并列对比(Before / After) | 旧模式 vs 新模式 |
| 10. 图文混排(Lead Image + Side Text) | 信息密集的图文页 |

选对应 layout,粘过去,改文案和图片路径即可。**务必先完成 3.0 预检**。

#### 3.2 · 图片比例规范

永远用**标准比例**,不要用原图奇葩比例(如 `2592/1798`):

| 场景 | 推荐比例 |
|------|---------|
| 左文右图 主图 | 16:10 或 4:3 + `max-height:56vh` |
| 图片网格(多图对比) | **固定 `height:26vh`**,不用 aspect-ratio |
| 左小图 + 右文字 | 1:1 或 3:2 |
| 全屏主视觉 | 16:9 + `max-height:64vh` |
| 图文混排小插图 | 3:2 或 3:4 |

**图片绝不使用 `align-self:end`**——会滑到 cell 底被浏览器工具栏遮挡。用 grid 容器 + `align-items:start`(template 已预设)让图片贴顶即可;左列若想贴底,用 flex column + `justify-content:space-between`。

组件细节(字体、颜色、网格、图标、callout、stat-card 等)在 `references/components.md`。

### Step 4 · 对照检查清单自检

生成完一定要打开 `references/checklist.md`，逐项对照。里面总结了**真实迭代过程中踩过的所有坑**，P0 级别的问题（emoji、图片撑破、标题换行、字体分工）必须全部通过。

特别要注意的几条：

1. **大标题必须是衬线字体**——如果显示成非衬线,检查是否用了 `.h-hero` / `.h-xl` 类（这些由共享 CSS 定义，无需手动引入）
2. **图片网格里只用 `height:Nvh`,不用 `aspect-ratio`**(会撑破)
3. **图片不能堆到页面底部**——不要用 `align-self:end`,用 grid + `align-items:start`(见 Step 3.2)
4. **图片只能用标准比例**(16:10 / 4:3 / 3:2 / 1:1 / 16:9),不要复制原图的奇葩比例
5. **中文大标题 ≤ 5 字且 `nowrap`**(避免 1 字 1 行)
6. **用 Lucide,不用 emoji**
7. **标题用衬线,正文用非衬线,元数据用等宽**

### Step 5 · 本地预览

Astro 产物使用根相对路径，必须通过 HTTP 服务预览：

```bash
# 开发时热重载（推荐）
npm run dev
# 浏览器打开 http://localhost:4321/decks/<name>/

# 或预览构建产物
npm run build && npm run preview
```

图片放在 `public/decks/<name>/`，在浏览器中通过 `/decks/<name>/xxx.png` 访问（无需服务器特殊配置）。

Deck 完成本地验证后，使用 **ppt-deploy** skill 进行批量测试和线上部署。

### Step 6 · 迭代

根据用户反馈修改——模板的 CSS 已经高度参数化，90% 的调整都是改 inline style（字号 `font-size:Xvw` / 高度 `height:Yvh` / 间距 `gap:Zvh`）。

---

## 资源文件导览

```
ppt-create/
├── SKILL.md              ← 你正在读
├── assets/
│   └── template.astro    ← 新 Deck 的完整 Astro 起点模板（含所有组件 import）
└── references/
    ├── components.md     ← 组件使用手册（Astro 语法，字体、图标、ghost、动效...）
    ├── layouts.md        ← 10 种页面布局骨架（Astro 组件语法，可直接粘贴）
    ├── themes.md         ← 2 套已实现主题 + 3 套待实现预设
    ├── image-prompts.md  ← GPT-M 2.0 配图类型、比例和基础提示词
    └── checklist.md      ← 质量检查清单（P0/P1/P2/P3 分级）
```

**加载顺序建议**：
1. 先读完 `SKILL.md`（这个文件）了解整体
2. Step 1 需求澄清完成后，读 `themes.md` 帮用户选定一套主题色
3. 读 `layouts.md` 挑布局（顶部有主题节奏规划、动效 recipe 决策树，代码块可直接粘贴进 `.astro` 文件）
4. 如果在 Codex 中生成配图，读 `image-prompts.md` 挑图片类型、比例和基础提示词
5. 细节调整时读 `components.md` 查组件 Astro Props 和特殊用法
6. 生成后读 `checklist.md` 自检（顶部 P0-0 规则强制预检 + 动效自检块）

**动效相关**：Motion One 的加载和 5 种 recipe 由 `src/scripts/animation.ts` 处理，已打包进 DeckLayout。你不需要改 JS，只需要在 `<Slide animate="X">` 上选 recipe，在需要入场动画的元素上加 `data-anim` 即可。离线演示靠 `public/assets/motion.min.js`，断网时自动降级为"无动画但内容可读"。

**权威参考**：Astro 组件 Props 的完整定义见仓库 `docs/components.md`（`references/components.md` 是使用模式手册，两者互补）。

## 核心设计原则（哲学）

> 这些原则是"一人公司"分享 PPT 的 5 轮迭代总结出来的。违反其中任何一条，视觉感都会垮。

1. **克制优于炫技** — WebGL 背景只在 hero 页透出，普通页几乎看不见
2. **结构优于装饰** — 不用阴影、不用浮动卡片、不用 padding box，一切信息靠**大字号 + 字体对比 + 网格留白**
3. **内容层级由字号和字体共同定义** — 最大衬线 = 主标题，中衬线 = 副标，大非衬线 = lead，小非衬线 = body，等宽 = 元数据
4. **图片是第一公民** — 图片只裁底部，保证顶部和左右完整；网格用 `height:Nvh` 固定，不要用 `aspect-ratio` 撑
5. **节奏靠 hero 页** — hero 和 non-hero 交替，才不累眼睛
6. **术语统一** — Skills 就是 Skills，不要中英混合翻译

## 参考作品

本 skill 的视觉基调参考了：

- 歸藏 "一人公司：被 AI 折叠的组织" 分享（2026-04-22，27 页）
- *Monocle* 杂志的版式
- YC 总裁 Garry Tan "Thin Harness, Fat Skills" 那篇博客的 demo

可以把它们当做风格锚点。
