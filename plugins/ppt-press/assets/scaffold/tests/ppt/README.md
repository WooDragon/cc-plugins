# PPT 响应式测试套件 — 权威规范

本文档是测试底线规范。测试代码通过 `// @spec tests/ppt/README.md §N.M` 注释与本文档绑定。
修改测试前必须先修改对应规范条目（见 §10）。

**目录**：[§1 设计契约](#1-design-contract设计契约) · [§2 浏览器契约](#2-browser-contract浏览器行为契约) · [§3 视口矩阵](#3-viewport-matrix视口矩阵) · [§4 动画时序](#4-animation-timing-contract动画时序契约) · [§5 溢出契约](#5-overflow-contract溢出契约) · [§6 Test API](#6-test-apitest-api) · [§7 测试清单](#7-test-suite测试套件19-项) · [§8 失败场景](#8-failure-scenarios失败场景) · [§9 CI](#9-ci-integrationci-集成) · [§10 贡献规范](#10-contributing贡献规范)

---

## §1 Design Contract（设计契约）

PPT 在所有视口下保持**单页全屏**模式：

| 不变量 | 要求 |
|--------|------|
| 无文档滚动 | `window.scrollY` 恒为 0；`#deck` 不离开视口 |
| 单 slide 可见 | 任意时刻视口内只有 1 个 slide 的 `visibleArea > 4px²` |
| slide 无水平溢出 | 可见 slide 的 `rect.width ≤ viewportWidth + 1`；其子元素不突破 slide 边界 ±5px |
| 翻页锁 700ms | 连续导航触发间隔 < 700ms 被静默忽略 |

---

## §2 Browser Contract（浏览器行为契约）

| 视口方向 | `#deck` position | slide overflowY | slide touchAction | 翻页方式 |
|----------|-----------------|-----------------|-------------------|---------|
| landscape | fixed | hidden | auto | ArrowKey / wheel / swipe-horizontal |
| portrait (≤600px) | fixed | auto（active slide） | pan-y | swipe-horizontal；wheel → 仅滚 active slide，不翻页 |

竖屏唯一导航约束：纵向 touch 只滚当前页，不触发翻页；横向 touch/swipe 翻页。

---

## §3 Viewport Matrix（视口矩阵）

| ID | 名称 | 尺寸 | 触发断点 | 说明 |
|----|------|------|----------|------|
| VP-1 | desktop | 1920×1080 | — | 最主流桌面分辨率，逐页全量溢出扫描基准 |
| VP-2 | laptop | 1440×900 | — | 标准笔记本，逐页全量溢出检查基准 |
| VP-2b | low-desktop | 1366×588 | max-height:600px landscape | 1366×768 笔记本扣≈180px chrome 的可视高，矮桌面垂直裁切最严苛标清场景 |
| VP-3 | tablet | 768×1024 | max-width:900px | 平板竖屏 |
| VP-4 | mobile-portrait | 390×844 | max-width:600px portrait | 手机竖屏，active slide 页内滚动 |
| VP-5 | mobile-landscape | 844×390 | max-height:600px landscape | 手机横屏单页翻页 |
| VP-6 | retina-landscape | 1020×419 | max-height:600px landscape | macOS Retina @2x CSS 视口（物理 2040×838 / DPR 2）。`6vw=61px` 可覆盖 vh 封顶——历史溢出根因。`setViewportSize(1020,419)` 足以触发断点，无需 `deviceScaleFactor:2` |
| VP-7 | qhd | 2560×1440 | — | 2K 标准全屏 |
| VP-8 | qhd-browser | 2560×1260 | — | 2K 浏览器窗口（扣≈180px chrome），逐页全量溢出扫描基准 |
| VP-9 | uhd | 3840×2160 | — | 4K@100% 标准全屏 |
| VP-10 | uhd-browser | 3840×1980 | — | 4K@100% 浏览器窗口（扣≈180px chrome），逐页全量溢出扫描基准 |

---

## §4 Animation Timing Contract（动画时序契约）

| 事件 | 时长 | 等待目的 |
|------|------|---------|
| slide 过渡（CSS transition） | 900ms | 翻页动画 |
| cascade 入场（`[data-anim]`） | 0.15s delay + N×0.1s stagger + 0.75s duration；9 元素 ≈ 1.7s | 内容出现 |
| DOM layout 测量等待 | ≥ 1100ms（900ms + 200ms buffer） | `opacity/transform` 不影响 layout；此等待已足够 |
| 视觉截图等待 | ≥ 3000ms | 须等 cascade 动画完全可见 |
| 翻页锁 | 700ms | 测试中连续导航间隔必须 > 700ms |

---

## §5 Overflow Contract（溢出契约）

> 本节是出血的**检测**契约。出血的盒模型根因与**设计侧避免机制**（`var()` 矮屏收紧 / `min()` 自适应 / 内容预算）见 [`docs/layout-overflow-prevention.md`](../../docs/layout-overflow-prevention.md)。

两类溢出 + 一类留白失衡均需检测。垂直裁切用消抖 + 自适应采样取 min 消除测量噪声后，统一 `CLIP_THRESHOLD=4px` 紧阈值（不按视口分层）：

| 类型 | 检测条件 | 判定 |
|------|----------|------|
| 水平溢出 | `slide.rect.width > viewportWidth + 1` 或子元素超出 slide ±5px | FAIL |
| 垂直 frame 裁切 | `.frame/.grid-*` 容器（`overflow:hidden`）采样取 min 后 `scrollHeight − clientHeight > CLIP_THRESHOLD(4px)` | FAIL |
| 过量留白失衡 | 内容 slide（含 `.chrome` + `.foot`，且 `.frame` 为 `flex-column`）的 `middle` 空白 > frame 高度 24%；含 `.pipeline` / `.rowline` 的线性正文页若 `top` / `bottom` 任一边缘空白 > frame 高度 52% 且明显偏向单侧；`left` / `right` 任一边缘空白 > frame 宽度 32% 且明显偏向单侧 | FAIL |

**垂直裁切消抖机制（关键）**：clip 真值是下界——内容真超出则 `excess` 恒 ≥ 真值，而 layout 未 settle 的瞬时测量只会让 `excess` 偏大、绝不偏小。故测量前先 `document.fonts.ready` + 双 rAF 等字体重排稳定，再对每个容器按 className 跨多次采样取 `min(excess)`，单调收敛到真值。采样自适应：连续 `CLIP_STABLE_STREAK(3)` 次无任何容器刷新更低值即判收敛而停，最多 `CLIP_MAX_SAMPLES(10)` 次——稳定视口快速收敛（通常 3-4 次），4K@DPR 子像素抖动视口多采到真值浮现。收敛后噪声地板 ≤2px < 阈值 4px < 最小真实 clip，无需按视口设不同阈值。

`overflow:hidden` 的 silent clip 不会在 body 层体现，必须直接测量容器。
留白检测只作用于内容 slide；hero / divider 等刻意稀疏页面跳过。多列 grid 内容页只做 `middle` / `left` / `right` 失衡检查，`top` / `bottom` 仅对 `.pipeline` / `.rowline` 这类线性正文页启用，避免把正常稀疏卡片页误报成缺陷。
水平检测由 `checkVisibleOverflow()` 实现；垂直裁切和留白失衡由 `verifyAllSlidesOverflow()` 统一收集。

---

## §6 Test API（测试辅助函数）

文件内 helper 函数（非浏览器 window API）：

| 函数 | 签名 | 用途 |
|------|------|------|
| `goToSlide` | `(page, index)` | 点击第 index 个 nav dot + wait 800ms |
| `checkVisibleOverflow` | `(page)` → `{bodyWidth, bodyHeight, viewportWidth, viewportHeight, visibleSlides, overflows[]}` | 当前可见 slide 的水平溢出数据 |
| `getDeckState` | `(page)` → state object | 完整 deck 状态（currentIndex, dotCount, overflowY, touchAction 等） |
| `getSlidesInfo` | `(page)` → array | 全部 slide 的尺寸/文本/媒体指标 |
| `detectLayoutMode` | `(page)` → `{isStacked, computedStyle}` | 检测 #deck 是否退化成垂直堆叠 |
| `findOverflowSlideIndex` | `(page)` → `number\|null` | 找到第一个内容溢出（scrollHeight > clientHeight + 1）的 slide |
| `hoverCurrentSlide` | `(page)` | hover 当前 slide 以激活 wheel 事件 |
| `swipe` | `(session, start, end, steps=16)` | CDP 模拟触摸滑动；`session = context.newCDPSession(page)` |
| `verifyAllSlidesOverflow` | `(page, waitMs?, clipThreshold?)` → `{allOverflows[], allClipping[], allWhitespaceIssues[]}` | 逐页翻遍所有 slide，同时检测水平溢出（§5 checkVisibleOverflow）、垂直 frame 裁切（§5 消抖 + 自适应采样取 min，阈值 `CLIP_THRESHOLD`）和过量留白失衡 |

**翻页导航模式**（§7.3 和 §7.13 使用）：slide 0 直接加载；slide 1..N-1 用
`page.keyboard.press('ArrowRight')` + `waitForTimeout(1100)`（§4 DOM layout 测量等待）。

---

## §7 Test Suite（测试套件，19 项）

| § | 测试名 | 视口 | 验证契约 |
|---|--------|------|---------|
| §7.1 | detect slide structure | default | slide 结构自动检测，`#deck` 存在，slide 数量 > 0 |
| §7.2 | viewport: desktop — all slides no overflow | VP-1 | 逐页全量水平+垂直溢出检查（§5）+ 过量留白失衡检测 + 所有 slide hasContent；1920×1080 最主流桌面分辨率 |
| §7.3 | viewport: laptop — all slides no overflow | VP-2 | 逐页全量水平+垂直溢出检查（§5）+ 过量留白失衡检测 |
| §7.3b | viewport: low-desktop — all slides no overflow | VP-2b | 逐页全量水平+垂直溢出检查（§5）+ 过量留白失衡检测；矮桌面（1366×588）垂直裁切最严苛标清场景 |
| §7.4 | viewport: tablet | VP-3 | bodyWidth ≤ viewportWidth+1；首页水平溢出=0 |
| §7.5 | viewport: mobile-landscape | VP-5 | isStacked=false；visibleCount=1；overflowY=hidden；首页水平溢出=0 |
| §7.6 | viewport: mobile-portrait | VP-4 | isStacked=false；visibleCount=1；bodyHeight ≤ viewportHeight+1；overflowY=auto；touchAction ∋ pan-y |
| §7.7 | responsive layout switch | VP-1→VP-4→VP-5 | 视口切换后 §2 Browser Contract 持续成立 |
| §7.8 | nav dots click navigation | VP-1 | dot 点击后 currentIndex 和 activeDots 正确更新 |
| §7.9 | wheel navigation landscape | VP-1 | mouse.wheel 触发翻页，currentIndex +1 |
| §7.10 | portrait overflow scroll uses wheel without moving the document | VP-4 | wheel 滚动只滚 active slide（scrollTop 增加），document 不移动（windowScrollY=0） |
| §7.11 | portrait touch keeps vertical gestures on-page and horizontal gestures for paging | VP-4 | 纵向 swipe 不翻页；横向 swipe 翻页且 windowScrollY=0 |
| §7.12 | touch gestures landscape | VP-5 | 横向 swipe 翻页；overflowY=hidden |
| §7.13 | viewport: retina-landscape — all slides no overflow | VP-6 | 逐页全量水平+垂直溢出检查（§5）+ 过量留白失衡检测；验证 macOS Retina @2x CSS 视口 6vw 覆盖问题已修复 |
| §7.14 | viewport: qhd | VP-7 | isStacked=false；首页水平溢出=0；所有 slide hasContent |
| §7.15 | viewport: qhd-browser — all slides no overflow | VP-8 | 逐页全量水平+垂直溢出检查（§5）+ 过量留白失衡检测 |
| §7.16 | viewport: uhd | VP-9 | isStacked=false；首页水平溢出=0；所有 slide hasContent |
| §7.17 | viewport: uhd-browser — all slides no overflow | VP-10 | 逐页全量水平+垂直溢出检查（§5）+ 过量留白失衡检测 |
| §7.18 | CJK headings line-height ≥ font-size (no title/subtitle collision) | VP-1 | 扫描每个 slide 内直接承载 CJK 文本的标题元素（`h1`–`h6`），断言计算 `line-height ≥ font-size`（ratio ≥ 1.0，容忍 1px）；防含中文大标题因字身溢出行盒与副标题/正文“贴脸”。限定标题是因贴脸风险的语义载体即标题；数字组件（.stat-nb）CJK 值间距靠显式 margin、不受此约束（详见 `docs/layout-overflow-prevention.md` §3.4） |

---

## §8 Failure Scenarios（失败场景）

| 失败信息 | 原因 | 修复 |
|---------|------|------|
| `isStacked toBe false` | #deck 退化成垂直堆叠 | 检查 `position:fixed` 与 media query 是否被覆盖 |
| `overflows` 非空 | 可见 slide 存在真实水平溢出 | 检查 slide 内元素是否突破 slide 边界；注意排除离屏 slide |
| `allClipping` 非空 | `.frame/.grid-*` 容器被 `overflow:hidden` 裁切 | 检查容器高度计算；文字大小 / 行高 / padding 是否过大 |
| `currentSlideOverflowY toBe auto` | 竖屏 active slide 缺失页内滚动 | 检查 portrait CSS 是否设置 `overflow-y:auto` |
| `currentSlideTouchAction toContain pan-y` | 竖屏纵向 touch 被拦截 | 检查 `touch-action` 与 `touchmove` `preventDefault` 逻辑 |
| `currentIndex` 不符合预期 | 翻页导航失效 | 检查 `navigation.ts` 是否正确驱动 currentIndex 与 active dot |
| `allWhitespaceIssues` 非空 | 内容 slide 的 `middle` 或线性正文页的 `top` / `bottom` / `left` / `right` 出现异常大空白 | 先看 `.frame` 是否被 `margin-top:auto` / 过窄容器 / 错误网格列数分配了剩余空间，再看该页是否属于应跳过的 hero / divider 或多列 grid 页面 |
| §7.13 失败而 §7.3 通过 | Retina CSS 视口（1020×419）触发了 `max-height:600px landscape`，字体 vw 值超出 vh 封顶 | 检查 `min(xvw, xvh)` 封顶是否覆盖该断点 |

---

## §9 CI Integration（CI 集成）

```bash
npm run build
npm run preview &
sleep 2
FAIL=0
for d in maas maas-sales pcdn-proposal ai-workflow aiforces-gateway; do
  PPT_URL=http://localhost:4321/decks/$d/ \
    npx playwright test tests/ppt/generic-ppt.spec.js --reporter=line || FAIL=1
done
kill %1
exit $FAIL
```

验收条件：4 decks × 17 tests = **68 项全部通过**。

```yaml
# .github/workflows/test-ppt.yml
name: Test PPT
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-node@v3
      - run: npm ci
      - run: npx playwright install --with-deps chromium
      - run: |
          npm run build
          npm run preview &
          sleep 2
          FAIL=0
          for d in maas maas-sales pcdn-proposal; do
            PPT_URL=http://localhost:4321/decks/$d/ \
              npx playwright test tests/ppt/generic-ppt.spec.js --reporter=line || FAIL=1
          done
          kill %1
          exit $FAIL
```

---

## §10 Contributing（贡献规范）

**Spec-First Rule**：添加、删除或修改测试前，**必须先**修改本文档对应的 §7 条目。

测试代码通过注释与规范绑定：

```javascript
// @spec tests/ppt/README.md §7.N  §<适用契约节>
test('test name', async ({ page }) => { ... });
```

无 `@spec` 注释的测试代码视为不完整，PR review 应拒绝合并。

**修改工作流**：

1. 修改 `tests/ppt/README.md` 对应 §7 条目（及受影响的 §1–§6）
2. 修改 `tests/ppt/generic-ppt.spec.js` 中对应测试和 `@spec` 注释
3. 同步更新 `CLAUDE.md`（必测项计数、视口说明）
4. 运行全量回归（§9），确认 68 项通过

---

## 附：运行方法

```bash
# 测试指定 deck
export PPT_URL=http://localhost:4321/decks/pcdn-proposal/
npx playwright test tests/ppt/generic-ppt.spec.js

# 不生成截图（加速）
export SAVE_SCREENSHOTS=false
npx playwright test tests/ppt/generic-ppt.spec.js

# 过滤特定测试
npx playwright test tests/ppt/generic-ppt.spec.js --grep "retina"
npx playwright test tests/ppt/generic-ppt.spec.js --grep "portrait"
npx playwright test tests/ppt/generic-ppt.spec.js --reporter=list
```
