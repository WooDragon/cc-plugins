# 页面布局库（Layouts）

本文档收录 10 种最常用的页面布局骨架。每种都是完整可粘贴的 `<Slide>` 组件块（Astro 语法），直接复制进 `src/pages/decks/<name>/index.astro` 替换文案/图片即可使用。

使用前确保 `.astro` 文件顶部 import 了所需组件（参考 `assets/template.astro`）。

---

## ⚠️ 生成前必读（Pre-flight）

### A. 使用 Astro 组件，不要手写 CSS 类

layouts.md 的所有代码块使用 Astro 组件（`<Slide>` / `<Chrome>` / `<Foot>` / `<Grid>` / `<StatCard>` / `<Pipeline>` / `<PipelineStep>` / `<Callout>` / `<FrameImg>` / `<QuoteBlock>`）。组件内部 CSS 类已由共享样式表提供，无需手动引入。

裸 HTML 元素（`<div class="frame">` / `<div class="kicker">` / `<h2 class="h-xl">` 等）继续使用 CSS class，这些类已全部在 `src/styles/` 中定义，**不要发明新类名**，自定义排版用 `style="..."` inline。

可用 CSS class 完整列表见 `src/styles/typography.css`、`grids.css`、`components.css`。

### B. 图片比例规范（非常重要）

**永远用标准比例**，不要用原图 `aspect-ratio: 2592/1798` 这种奇葩比例：

| 场景 | 推荐比例 | 写法 |
|------|---------|------|
| 左文右图 主图 | 16:10 或 4:3 | `.frame-img.r-16x10` 或 `.frame-img.r-4x3` |
| 图片网格（多图对比） | 统一 | `.frame-img.h-22` / `.frame-img.h-26`，不用 aspect-ratio |
| 小型面板组 | 统一 | `.frame-img.h-16` / `.frame-img.h-18`，同组必须同高 |
| 左小图 + 右文字 | 1:1 或 3:2 | `.frame-img.r-1x1` 或 `.frame-img.r-3x2` |
| 全屏主视觉 | 16:9 | `.frame-img.r-16x9` |
| 信息图 / 截图再设计 | 16:9 或 16:10 | `.frame-img.r-16x9.fit-contain` 或 `.frame-img.r-16x10.fit-contain` |
| 图文混排小插图 | 3:2 或 3:4 | `.frame-img.r-3x2` 或 `.frame-img.r-3x4` |

图片必须包在 `<figure class="frame-img">` 里。默认照片会 `object-fit:cover + object-position:top center`,只裁底部,不裁顶/左/右。信息图和截图再设计必须加 `.fit-contain`,避免文字或标注被裁切。

### B2. 图片与内容的垂直对齐

图片应该跟正文内容区对齐,不要默认贴到大标题顶端。特别是左文右图和图文混排页:

- 如果左列是 kicker + 大标题 + 正文 + callout,右列图片通常从正文高度开始,可给图片加 `style="margin-top:7vh"` 到 `9vh`
- 如果图片是信息图或 UI 情景图,优先对齐正文首行或说明文字,不要和超大标题顶端齐平
- 如果一张截图/UI 情景图在横向页面里变成很长的条,不要硬拉满宽;改成极宽横图素材,或拆成 2-3 个局部面板拼排
- 多图面板必须使用同一个高度类,不要混用 `h-16` / `h-22` 或手写不同 `height`

### B3. 标题与正文的间距

- 两段式页面(顶部标题 + 下方长正文/引用/图表)必须在标题和内容之间留出明显间距,推荐 `margin-top:6vh` 到 `8vh`
- 居中大标题页必须让主标题在页面水平居中,使用 `.center` 或 `text-align:center; margin-inline:auto`
- 复杂内容页(大标题 + 小标题 + 详细内容)要让大标题和下方内容分层,下方内容使用左右两端对齐的 grid 或 rowline,不要全部堆在一条中轴线上

### C. 图片定位准则（避免图片堆到页面最底部、被浏览器工具栏遮挡）

**错误做法**（已踩坑，不要再犯）：
- 在非 grid 容器里用 `align-self:end`：`align-self` 在 flex/grid 之外完全无效，图片会掉到文档流末尾堆底
- 用 `position:absolute + bottom:0` 把图"固定"到底：会被底部 `.foot` 和 `#nav` 圆点遮挡
- 单张图片只写 `height:N vh` 不限 `max-height`：在低分屏会撑出视口

**正确做法**：
- 图文混排**必须用 `.frame.grid-2-7-5`**（或 `.grid-2-6-6` / `.grid-2-8-4`）的 grid 结构
- grid 容器默认 `align-items:start`（已在 template 中设置），图片自然贴到 cell 顶端
- 如果需要"图片底对齐左列 callout"：**左列用 flex column + `justify-content:space-between`**（让 callout 自己贴左列底），**右列 figure 直接保持 align-items:start 即可**，不要加 `align-self:end`
- 所有 grid 父容器建议加 inline `style="padding-top:6vh"`，给标题区留呼吸空间

### D. 主题色与主题节奏

- 主题色从 `references/themes.md` 的 5 套预设里选一套,不允许自定义 hex 值
- 主题节奏(每页用 light / dark / hero light / hero dark 哪一个)在下文"主题节奏规划"一节有硬规则,生成前必读
- 两件事都要在挑布局之前决定,避免返工

### E. 动效系统(默认开启 · Motion One 驱动)

**核心机制**：DeckLayout 已包含完整的 Motion One 初始化，翻到当前页时所有带 `data-anim` 的元素依次淡入。

**动效策略**：在 `<Slide animate="<recipe>">` 上选择动画 recipe；每个需要入场动画的元素加 `data-anim`（可选附值：`left` / `right` / `line` / `step`）。Hero slide（`hero` prop）自动用 `hero` recipe，无需显式指定。

| recipe | 用法 | 适合布局 |
|---|---|---|
| 默认(cascade) | 什么也不加,自动级联淡入 | 大部分正文页(Layout 3 / 4 / 5 / 10) |
| `hero` | `.hero` 页自动启用,节奏更慢更仪式感 | Layout 1 / 2 / 7(所有 hero 页) |
| `quote` | 一句一句揭示,慢节奏(550ms stagger) | Layout 8 大引用 |
| `directional` | 左进 → 分割 → 右进,用于对比 | Layout 9 Before/After |
| `pipeline` | 手动推进,按 →/空格 一步步点亮 | Layout 6 流水线 |

**降级保底**:如果 motion.min.js 本地 + CDN 都加载失败,脚本会强制把所有 `data-anim` 元素设为 `opacity:1`,内容永远可读。

**不需要动效的页面**:如果某页想完全跳过动效,不加任何 `data-anim` 即可 —— Motion One 只对带标记的元素生效。

---

## 0. 基础结构（所有 slide 都一样）

```astro
<Slide theme="[light|dark]" [hero] [animate="cascade|hero|quote|directional|pipeline"]>
  <Chrome left="上下文标签 · 子标签" right="ACT · 页号 / 总页数" />
  <!-- 主内容 -->
  <Foot title="页码说明 · Page Description" />
</Slide>
```

- `theme="dark"` 或 `theme="light"`，必填；`hero` prop 让 WebGL 背景大幅透出（章节封面/开场/收束）
- `<Chrome>` 和 `<Foot>` 是可选但推荐保留的上下元数据条
- `animate=` 选 recipe（默认 cascade；hero slide 自动用 hero，无需显式写）

### ⚠️ chrome 和 kicker 不要写同一句话

这是最常见的内容重复问题。两者在语义上完全不同的维度：

| 位置 | 角色 | 内容性质 | 例子 |
|------|------|---------|------|
| `.chrome` 左上 | **杂志页眉 / 导航元数据** | 稳定的"栏目名"或"章节分类"，跨多页可以相同 | "Act II · Workflow" / "Data · Result" / "lukew.com · 2026.04" |
| `.chrome` 右上 | **页号 + 幕号** | 固定格式 | "Act II · 15 / 25" |
| `.kicker` | **这一页独一份的引导句** | 是大标题的"小前缀"，像杂志大标题上方的一行话，每页都应不同 | "BUT" / "一个人,做了什么。" / "Phase 01 · 设计阶段" |

**反例**（已踩坑）：chrome 写"设计先行 · Design First"，kicker 又写"Phase 01 · 设计阶段"——意思重复，读者一眼就觉得 AI 生成的。

**正确做法**：chrome 是**栏目标签**（稳定、跨页可复用），kicker 是**本页钩子**（短句、有戏剧性），两者互为补充，不互相翻译。

### ⚠️ 主题节奏规划（必读 · 生成前必做)

**核心机制**:每页 `<section>` 必须带 `light` / `dark` / `hero light` / `hero dark` 之一。JS 根据 class 推断主题,决定 body 加不加 `light-bg`,从而切换暗/亮两张 WebGL canvas 哪张在前。不带主题或写自定义名 = fallback 出错。

#### 按布局的主题默认值

| Layout | 默认主题 | 原因 |
|---|---|---|
| 1. 开场封面 | `hero dark` | 开场仪式感,暗底强冲击 |
| 2. 章节幕封 | `hero dark` 与 `hero light` **必须交替** | 呼吸节奏 |
| 3. 大字报(数据) | `light` | 数字需纸白底;多幕连发时可偶插 `dark` |
| 4. 左文右图 | **`light` / `dark` 交替** | 正文节奏主力 |
| 5. 图片网格 | `light` | 截图需亮底 |
| 6. Pipeline | `light` | 流程图需清晰 |
| 7. 问题页 | `hero dark` | 强视觉冲击默认 |
| 8. 大引用 | **`dark` 优先**,偶用 `light` | 金句仪式感靠暗底 |
| 9. 对比页 | `light` | 双列需清晰 |
| 10. 图文混排 | **`light` / `dark` 交替** | 节奏 |

#### 节奏硬规则(生成后 grep 自检)

- ❌ **禁止**连续 3 页以上相同主题(包括 light 堆叠和 dark 堆叠)
- ❌ **禁止**8 页以上的 deck 没有至少 1 个 `hero dark` + 1 个 `hero light`
- ❌ **禁止**整个 deck 只有 `light` 正文页没有任何 `dark` 正文页——会显得平淡、没呼吸
- ✅ **推荐**每 3-4 页插入 1 个 hero(封面/幕封/问题/大引用)

#### 8 页节奏模板(可直接套用)

| 页 | 主题 | 布局 | 备注 |
|---|---|---|---|
| 1 | `hero dark` | 封面 | 开场 |
| 2 | `light` | 大字报 | 数据抛出 |
| 3 | `dark` | 左文右图 | 对比/故事 |
| 4 | `light` | Pipeline | 流程 |
| 5 | `hero light` | 章节幕封 | 呼吸 |
| 6 | `dark` | 左文右图 or 大引用 | |
| 7 | `hero dark` | 问题页 | 悬念收束 |
| 8 | `light` | 大引用/结尾 | 收尾 |

**先画这张表对齐,再动手写 slide**。跳过规划直接粘骨架 = 全是 light。

---

## Layout 1: 开场封面（Hero Cover）

```astro
<Slide theme="dark" hero animate="hero">
  <Chrome left="A Talk · 2026.04.22" right="Vol.01" />
  <div class="frame" style="display:grid; gap:4vh; align-content:center; min-height:80vh">
    <div class="kicker" data-anim>私享会 · 李继刚</div>
    <h1 class="h-hero" data-anim>一人公司</h1>
    <h2 class="h-sub" data-anim>被 AI 折叠的组织</h2>
    <p class="lead" style="max-width:60vw" data-anim>
      一个 AI 创作者 —— 在 64 天里做了 11 万行代码、在 9 个平台上持续输出，生活节奏几乎没有被改变。
    </p>
    <div class="meta-row" data-anim>
      <span>歸藏 Guizang</span><span>·</span><span>独立创作者 / CodePilot 作者</span>
    </div>
  </div>
  <Foot title="一场关于 AI · 组织 · 个体的分享" meta="— 2026 —" />
</Slide>
```

**要点**：
- 用 `hero dark` 让 WebGL 背景在大部分区域透出
- `h-hero` 是最大字号（10vw），这里作标题主视觉
- 用 `min-height:80vh + align-content:center` 让内容整体垂直居中
- 不需要 `.chrome` 里写页码，封面页自成一体

---

## Layout 2: 章节幕封（Act Divider）

```astro
<Slide theme="light" hero animate="hero">
  <Chrome left="第一幕 · 硬数据" right="Act I · 01 / 25" />
  <div class="frame" style="display:grid; gap:6vh; align-content:center; min-height:80vh">
    <div class="kicker" data-anim>Act I</div>
    <h1 class="h-hero" style="font-size:8.5vw" data-anim>硬数据</h1>
    <p class="lead" style="max-width:55vw" data-anim>
      先看数字，再谈方法。
    </p>
  </div>
  <Foot title="第一幕引子" />
</Slide>
```

**要点**：
- 极简，只需要 kicker + 大标题 + 一行引语
- 两个幕的封面可以交替 `hero light` / `hero dark`，制造节奏
- `h-hero` 字号可以从 10vw 调到 8.5vw 适配长短

---

## Layout 3: 数据大字报（Big Numbers Grid）

```astro
<Slide theme="light" animate="cascade">
  <Chrome left="过去 64 天 · 开发篇" right="Act I / Dev · 02 / 25" />
  <div class="frame" style="padding-top:6vh">
    <div class="kicker" data-anim>一个人，做了什么。</div>
    <h2 class="h-xl" data-anim>过去 64 天</h2>
    <p class="lead" style="margin-bottom:5vh" data-anim>从 0 到开源 CodePilot。</p>

    <Grid cols="6" style="margin-top:6vh">
      <StatCard label="Duration"     value="64"    unit="天"  note="从 0 到现在" />
      <StatCard label="Lines of Code" value="110K+" note="一行行写到 11 万+" />
      <StatCard label="GitHub Stars"  value="5,166" note="一个开源仓库" />
      <StatCard label="Downloads"     value="41K+"  note="装到了几万台电脑里" />
      <StatCard label="AI Providers"  value="19"    note="跨平台接入" />
      <StatCard label="Commits"       value="608+"  note="没有协作者" />
    </Grid>
  </div>
  <Foot title="项目 · CodePilot　|　github.com/codepilot" meta="Act I · Dev Numbers" />
</Slide>
```

**要点**：
- 3×2 或 4×2 网格最稳（见 `.grid-6`）
- 每个 `stat-card` 结构固定：label（英文小字）→ nb（大字数字）→ note（注释）
- 数字建议 2-3 位字符（太长会溢出），用 K / M 简写
- 留 5vh 以上的上方缓冲，让标题区先抢眼球

---

## Layout 4: 左文右图（Quote + Image）

```astro
<Slide theme="light" animate="cascade">
  <Chrome left="身份反差 · The Twist" right="03 / 25" />
  <div class="frame grid-2-7-5" style="padding-top:6vh">
    <!-- 左列：标题 + 正文 + callout，flex column 让 callout 贴列底 -->
    <div style="display:flex; flex-direction:column; justify-content:space-between; gap:3vh">
      <div>
        <div class="kicker" data-anim>BUT</div>
        <h2 class="h-xl" style="white-space:nowrap; font-size:7.2vw" data-anim>
          我不是程序员。
        </h2>
        <p class="lead" style="margin-top:3vh" data-anim>
          大学毕业之后再也没写过一行代码。过去十年做的是 UI 设计和 AI 特效。
        </p>
      </div>
      <Callout source="— 一个观察者的判断">
        "这东西在三年前，<br>
        需要一个十人团队做一年。"
      </Callout>
    </div>
    <!-- 右列：图片用标准比例 + max-height，不要 align-self:end -->
    <FrameImg src="/decks/<name>/codepilot.png" ratio="4-3" caption="CodePilot · 产品截图" />
  </div>
  <Foot title="Page 03 · 我不是程序员" />
</Slide>
```

**要点**：
- 用 `grid-2-7-5`（左 7 份、右 5 份），`align-items:start` 已在 template 预设
- **左列**用 flex column + `justify-content:space-between`：标题贴顶，callout 自然贴底
- **右列图片** **不要加 `align-self:end`**。会让图片滑到 cell 底部，低分屏下被浏览器工具栏遮挡
- 图片必须用 **标准比例类 `.r-16x10` 或 `.r-4x3`**，不要用原图奇葩比例（`2592/1798` 这种）

---

## Layout 5: 图片网格（多图对比）

```astro
<Slide theme="light" animate="cascade">
  <Chrome left="平台粉丝实证" right="Act I / Ops · 05 / 27" />
  <div class="frame" style="padding-top:5vh">
    <div class="kicker" data-anim>Proof · 粉丝实证</div>
    <h2 class="h-xl" data-anim>10 个平台 · 6 张截图</h2>

    {/* 图片网格：必须用 height:Nvh 固定，不要用 aspect-ratio */}
    <Grid cols="3-3" style="margin-top:4vh">
      <figure class="frame-img" style="height:26vh" data-anim>
        <img src="/decks/<name>/weibo.png" alt="微博 289K">
        <figcaption class="img-cap">微博 · 289K</figcaption>
      </figure>
      <figure class="frame-img" style="height:26vh" data-anim>
        <img src="/decks/<name>/twitter.png" alt="推特 137K">
        <figcaption class="img-cap">推特 · 137K</figcaption>
      </figure>
      <figure class="frame-img" style="height:26vh" data-anim>
        <img src="/decks/<name>/wechat.png" alt="公众号 96K">
        <figcaption class="img-cap">公众号 · 96K</figcaption>
      </figure>
      <figure class="frame-img" style="height:26vh" data-anim>
        <img src="/decks/<name>/jike.png" alt="即刻 26K">
        <figcaption class="img-cap">即刻 · 26K</figcaption>
      </figure>
      <figure class="frame-img" style="height:26vh" data-anim>
        <img src="/decks/<name>/xhs.png" alt="小红书 19K">
        <figcaption class="img-cap">小红书 · 19K</figcaption>
      </figure>
      <figure class="frame-img" style="height:26vh" data-anim>
        <img src="/decks/<name>/douyin.png" alt="抖音 10K">
        <figcaption class="img-cap">抖音 · 10K</figcaption>
      </figure>
    </Grid>
  </div>
  <Foot title="截图时间 · 2026.04" meta="Page 05 · 粉丝实证" />
</Slide>
```

**要点**：
- 关键：每个 `frame-img` 必须写死 `height:NNvh`（不要用 `aspect-ratio`），否则网格会撑破
- 图片会自动 `object-fit:cover + object-position:top`，只裁底部
- 用 `.grid-3-3`（2×3，2 列×3 行）或 `.grid-3`（3×1）承载

---

## Layout 6: 两列流水线（Pipeline）

```astro
<Slide theme="light" animate="pipeline">
  <Chrome left="我的工作流 · Workflow" right="Act II · 15 / 27" />
  <div class="frame">
    <div class="kicker">Pipeline · 流水线</div>
    <h2 class="h-xl">两条流水线</h2>

    {/* 第一组：文本侧 */}
    <div class="pipeline-section">
      <div class="pipeline-label">文本侧 · Text Pipeline</div>
      <Pipeline cols={5}>
        <PipelineStep nb="01" title="Draft"      desc="AI 帮我起草初稿" />
        <PipelineStep nb="02" title="Polish"     desc="AI 润色去 AI 味" />
        <PipelineStep nb="03" title="Morph"      desc="AI 变形成推特 / 小红书" />
        <PipelineStep nb="04" title="Illustrate" desc="AI 生成信息图" />
        <PipelineStep nb="05" title="Distribute" desc="一键分发 9 平台" />
      </Pipeline>
    </div>

    {/* 第二组：视频侧 */}
    <div class="pipeline-section">
      <div class="pipeline-label">视觉 · 视频侧 · Video Pipeline</div>
      <Pipeline cols={3}>
        <PipelineStep nb="06" title="Cut"   desc="AI 帮我剪辑" />
        <PipelineStep nb="07" title="Wrap"  desc="AI 帮我包装" />
        <PipelineStep nb="08" title="Cover" desc="AI 生成封面" />
      </Pipeline>
    </div>
  </div>
  <Foot title="Page 15 · 我的内容工厂" meta="Workflow" />
</Slide>
```

**要点**：
- 用 `.pipeline-section` 分组 + `.pipeline-label` 作组标题
- 两组之间用 3.6vh 的间距 + 顶部细分隔线（已在 CSS 中预设）
- 每个 step 是固定的 nb → title → desc 结构
- 步骤数不限但单行最好 ≤5 个，否则换到第二 pipeline
- **动效**:`<section>` 加 `data-animate="pipeline"`,每个 `.step` 加 `data-anim="step"`。翻到此页时步骤默认 `opacity:.15`,按 →/空格/滚轮下滑时一次点亮一个 step;**所有 step 点亮完才会翻到下一页**,可制造演讲互动感

---

## Layout 7: 悬念收束 / 问题页（Hero Question）

```astro
<Slide theme="dark" hero animate="hero">
  <Chrome left="留给你的问题" right="24 / 27" />
  <div class="frame" style="display:grid; gap:8vh; align-content:center; min-height:80vh">
    <div class="kicker" data-anim>The Question</div>
    <h1 class="h-hero" style="font-size:7vw; line-height:1.15">
      <span data-anim style="display:block">你的公司里，</span>
      <span data-anim style="display:block">哪些岗位本来就</span>
      <span data-anim style="display:block">不该由人来做？</span>
    </h1>
    <p class="lead" style="max-width:50vw" data-anim>
      这个问题，不是技术问题，是架构问题。
    </p>
  </div>
  <Foot title="Page 24 · The Question" />
</Slide>
```

**要点**：
- Hero 页留白越多越好，只放一个问题
- `h-hero` 字号视长度调整（7vw 适合 3 行，10vw 适合 1 行）
- 用 `<br>` 手工断行，确保断点在语义处
- 尾巴可以再给一行 `lead` 作为点破

---

## Layout 8: 大引用页（Big Quote · 衬线金句）

```astro
<Slide theme="light" animate="quote">
  <Chrome left="The Takeaway · 核心金句" right="18 / 25" />
  <div class="frame" style="display:grid; gap:5vh; align-content:center; min-height:80vh">
    <div class="kicker" data-anim>Quote · 金句</div>
    <QuoteBlock
      lines={['"没有交接，', '所有人都在构建。"']}
      style="font-family:var(--serif-zh);font-weight:700;font-size:5.8vw;line-height:1.2;letter-spacing:-.01em;max-width:72vw"
    />
    <p class="lead" style="max-width:55vw; opacity:.65" data-anim>
      Without the handoff, everyone builds.<br>
      And that makes all the difference.
    </p>
    <div class="meta-row" data-anim>
      <span>— Luke Wroblewski</span><span>·</span><span>2026.04.16</span>
    </div>
  </div>
  <Foot title="Page 18 · 金句" />
</Slide>
```

**要点**：
- 整页留白,只放一个大引用 + 出处
- `<blockquote>` 用 inline style 单独放大（5-6vw）,不要用 `h-hero`（那是页面主标题的命名）
- 下面跟随英文原文（lead · opacity:.65）制造层级
- 配 `meta-row` 写出处 · 日期

---

## Layout 9: 并列对比（A vs B · 旧 vs 新）

```astro
<Slide theme="light" animate="directional">
  <Chrome left="旧 vs 新 · The Shift" right="12 / 25" />
  <div class="frame" style="padding-top:5vh">
    <div class="kicker" data-anim>Before / After · 范式转变</div>
    <h2 class="h-xl" style="margin-bottom:4vh" data-anim>从交接到共建</h2>

    <Grid cols="2-6-6" style="gap:5vw 4vh">
      {/* 左列：旧 */}
      <div data-anim="left" style="padding:3vh 2vw; border-left:3px solid currentColor; opacity:.55">
        <div class="kicker" style="opacity:.9">Before · 旧模式</div>
        <h3 class="h-md" style="margin-top:2vh">设计 → 开发 → 交接</h3>
        <ul style="margin-top:3vh; padding-left:1.2em; display:flex; flex-direction:column; gap:1.4vh; font-family:var(--sans-zh); font-size:max(14px,1.1vw); line-height:1.55">
          <li>设计师在 Figma 做稿</li>
          <li>开发者盯着文件翻译像素</li>
          <li>反复 PR 沟通对齐</li>
          <li>非技术人员无法触碰代码</li>
        </ul>
      </div>
      {/* 右列：新 */}
      <div data-anim="right" style="padding:3vh 2vw; border-left:3px solid currentColor">
        <div class="kicker" style="opacity:.9">After · 新模式</div>
        <h3 class="h-md" style="margin-top:2vh">同工具 · 并行 · 共建</h3>
        <ul style="margin-top:3vh; padding-left:1.2em; display:flex; flex-direction:column; gap:1.4vh; font-family:var(--sans-zh); font-size:max(14px,1.1vw); line-height:1.55">
          <li>三个角色同时在 Intent 工作</li>
          <li>agents.md 作为共享上下文</li>
          <li>代理处理对齐 / 冲突 / 动画</li>
          <li>任何人都能安全贡献代码</li>
        </ul>
      </div>
    </Grid>
  </div>
  <Foot title="Page 12 · 范式转变" meta="Before / After" />
</Slide>
```

**要点**：
- 用 `.grid-2-6-6`（1:1）左右分半
- 左列 `opacity:.55` 做"旧"的视觉弱化,右列满亮度做"新"的突出
- 两列都用 `border-left:3px solid` + `padding-left` 做引用块感
- 每列结构统一:`kicker` → `h-md` → `<ul>` 要点,节奏一致

---

## Layout 10: 图文混排（Lead Image + Side Text）

```astro
<Slide theme="light" animate="cascade">
  <Chrome left="Design First · 设计先行" right="08 / 16" />
  <div class="frame grid-2-8-4" style="padding-top:6vh">
    {/* 左列：大段正文 + 引用 */}
    <div>
      <div class="kicker" data-anim>Phase 01 · 设计阶段</div>
      <h2 class="h-xl" style="margin-top:1vh; margin-bottom:3vh" data-anim>设计先行 · 2 周</h2>

      <p class="lead" style="margin-bottom:3vh" data-anim>
        在 Figma 中完成视觉探索与设计系统，网格 / 排版 / 颜色变量 / 可复用组件，桌面和移动端稿件几轮反馈迭代。
      </p>

      <p data-anim style="font-family:var(--sans-zh); font-size:max(14px,1.15vw); line-height:1.75; opacity:.78; margin-bottom:2.4vh">
        两周之内，视觉风格、粗略结构、方向性内容全部稳定。这是扎实的传统设计流程——在这里还没什么新鲜事。
      </p>

      <Callout source="— Luke Wroblewski" style="margin-top:3vh">
        "This phase was pretty standard.<br>Just a solid Web design process."
      </Callout>
    </div>
    {/* 右列：辅助图 · 竖版 3:4 */}
    <FrameImg src="/decks/<name>/figma.png" ratio="3-4" caption="Figma · Design System" />
  </div>
  <Foot title="Page 08 · Design First" meta="约 2 周" />
</Slide>
```

**要点**：
- `.grid-2-8-4`(8:4) 让正文占主导,图片作辅助
- 左列包含多种信息层级:kicker → 大标题 → lead → 正文段落 → callout(引用)
- 右列图片用 **竖版 3:4** 或方形 1:1,避免和左列文本竞争注意力
- 这种布局适合**页面信息量偏大**的场景(不像 Layout 4 只有一句金句)

---

## 附录：常用网格模板

| 类名 | 配比 | 用途 |
|---|---|---|
| `.grid-2-6-6` | 6:6（1:1） | 对半分 |
| `.grid-2-7-5` | 7:5 | 文字为主 + 辅助图 |
| `.grid-2-8-4` | 8:4（2:1） | 大段文字 + 小图/数据 |
| `.grid-3` | 1:1:1 | 3 项并列（案例/截图） |
| `.grid-3-3` | 2×3（2 列×3 行） | 6 图矩阵 |
| `.grid-6` | 3×2 | 6 个数据卡片 |

所有网格都预留 `gap: 3vw 4vh`（水平 3vw、竖直 4vh），可以单独覆写。

---

## 页面节奏建议

一场 25-30 页的分享，推荐以下节奏：

1. **Hero Cover**（第 1 页）
2. **Act Divider**（第一幕开场，hero light 或 hero dark）
3. **Big Numbers**（抛硬数据制造冲击）
4. **Quote + Image**（讲身份反差/挂钩）
5. **Image Grid**（证据支撑）
6. **Hero Question**（幕收束，留悬念）
7. ... 第二幕、第三幕同样节奏 ...
8. **Hero Close**（最后一页，问题或致谢）

hero 页与 non-hero 页应该 **2-3 : 1 比例交错**，不要连续超过 3 页 non-hero，也不要连续超过 2 页 hero。
