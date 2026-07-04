/**
 * 通用 PPT 响应式测试套件
 * 自动识别 slide 结构，验证横竖屏显示完整性和翻页功能
 *
 * 规范索引: tests/ppt/README.md
 * 每个测试通过 @spec 注释与规范文档绑定（§10 Contributing）
 */

const { test, expect } = require('@playwright/test');

const TEST_CONFIG = {
  pptPath: process.env.PPT_PATH || 'decks/pcdn-proposal/index.html',
  saveScreenshots: process.env.SAVE_SCREENSHOTS !== 'false',
  screenshotDir: process.env.SCREENSHOT_DIR || 'test-results',
};

const DECK_URL = process.env.PPT_URL || `file://${process.cwd()}/${TEST_CONFIG.pptPath}`;
console.log(`[Config] Testing: ${process.env.PPT_URL || TEST_CONFIG.pptPath}`);
console.log(`[Config] URL: ${DECK_URL}`);

const VIEWPORTS = {
  mobilePortrait:  { name: 'mobile-portrait',  width: 390,  height: 844  }, // VP-4 §3
  mobileLandscape: { name: 'mobile-landscape', width: 844,  height: 390  }, // VP-5 §3
  tablet:          { name: 'tablet',           width: 768,  height: 1024 }, // VP-3 §3
  laptop:          { name: 'laptop',           width: 1440, height: 900  }, // VP-2 §3
  desktop:         { name: 'desktop',          width: 1920, height: 1080 }, // VP-1 §3
  retinaLandscape: { name: 'retina-landscape', width: 1020, height: 419  }, // VP-6 §3
  qhd:             { name: 'qhd',             width: 2560, height: 1440 }, // VP-7 §3
  qhdBrowser:      { name: 'qhd-browser',     width: 2560, height: 1260 }, // VP-8 §3
  uhd:             { name: 'uhd',             width: 3840, height: 2160 }, // VP-9 §3
  uhdBrowser:      { name: 'uhd-browser',     width: 3840, height: 1980 }, // VP-10 §3
  lowDesktop:      { name: 'low-desktop',     width: 1366, height: 588  }, // VP-2b §3：1366×768 笔记本扣≈180px chrome
};

// §5 垂直裁切判定（px）。clip 真值是下界：内容真超出则 excess 恒 ≥ 真值，
// 而 layout 未 settle 的瞬时测量只会让 excess 偏大、绝不偏小。故对 excess 采样取 min，
// 单调收敛到真值，天然过滤偶发尖峰（含 4K@DPR 的 layout 抖动）——无需按视口分层阈值。
// 自适应采样：连续 CLIP_STABLE_STREAK 次无新低即判收敛而停，最多 CLIP_MAX_SAMPLES 次。
// 收敛后噪声地板 ≤2px，统一紧阈值；该值须满足 噪声上界 < CLIP_THRESHOLD < 最小真实 clip。
const CLIP_THRESHOLD = 4;
const CLIP_STABLE_STREAK = 3;
const CLIP_MAX_SAMPLES = 10;

async function maybeScreenshot(page, name) {
  if (!TEST_CONFIG.saveScreenshots) {
    return;
  }

  await page.screenshot({
    path: `${TEST_CONFIG.screenshotDir}/${name}.png`,
    fullPage: false,
  });
}

async function detectLayoutMode(page) {
  const deck = page.locator('#deck');
  const computedStyle = await deck.evaluate((el) => {
    const style = window.getComputedStyle(el);
    return {
      position: style.position,
      display: style.display,
      transform: style.transform,
    };
  });

  const isStacked = computedStyle.position === 'static' && computedStyle.display === 'block';
  return { isStacked, computedStyle };
}

async function getSlidesInfo(page) {
  return page.evaluate(() => {
    const contentSelector = 'h1,h2,h3,h4,h5,h6,p,li,blockquote,figure,img,svg,canvas,video,table,button';
    const getText = (node) => (node.innerText || node.textContent || '').replace(/\s+/g, ' ').trim();

    return Array.from(document.querySelectorAll('#deck .slide')).map((slide, index) => {
      const rect = slide.getBoundingClientRect();
      const textLength = getText(slide).length;
      const mediaCount = slide.querySelectorAll('img,svg,canvas,video,table,figure').length;
      const visibleContentCount = Array.from(slide.querySelectorAll(contentSelector)).filter((el) => {
        const style = window.getComputedStyle(el);
        const elRect = el.getBoundingClientRect();
        const hasText = getText(el).length > 0;
        const hasMedia = /^(IMG|SVG|CANVAS|VIDEO|TABLE|FIGURE)$/.test(el.tagName);
        return style.display !== 'none' &&
          style.visibility !== 'hidden' &&
          style.opacity !== '0' &&
          elRect.width > 4 &&
          elRect.height > 4 &&
          (hasText || hasMedia);
      }).length;

      return {
        index: index + 1,
        height: Math.round(rect.height),
        width: Math.round(rect.width),
        textLength,
        mediaCount,
        visibleContentCount,
        hasContent: textLength > 0 || mediaCount > 0,
      };
    });
  });
}

async function getDeckState(page) {
  return page.evaluate(() => {
    const deck = document.getElementById('deck');
    const slides = Array.from(document.querySelectorAll('#deck .slide'));
    const dots = Array.from(document.querySelectorAll('#nav .dot'));
    const deckStyle = deck ? window.getComputedStyle(deck) : null;
    const viewportWidth = window.innerWidth;
    const viewportHeight = window.innerHeight;

    const slideStates = slides.map((slide, index) => {
      const rect = slide.getBoundingClientRect();
      const visibleWidth = Math.max(0, Math.min(rect.right, viewportWidth) - Math.max(rect.left, 0));
      const visibleHeight = Math.max(0, Math.min(rect.bottom, viewportHeight) - Math.max(rect.top, 0));
      const style = window.getComputedStyle(slide);

      return {
        index,
        left: Math.round(rect.left),
        right: Math.round(rect.right),
        visibleArea: visibleWidth * visibleHeight,
        position: style.position,
        overflowY: style.overflowY,
        touchAction: style.touchAction,
        scrollTop: slide.scrollTop,
        scrollHeight: slide.scrollHeight,
        clientHeight: slide.clientHeight,
      };
    });

    const activeDotIndex = dots.findIndex((dot) => dot.classList.contains('active'));
    const visibleSlide = slideStates.reduce(
      (best, slide) => (slide.visibleArea > best.visibleArea ? slide : best),
      { index: -1, visibleArea: 0 },
    );
    const currentIndex = activeDotIndex !== -1 ? activeDotIndex : visibleSlide.index;
    const currentSlide = slideStates.find((slide) => slide.index === currentIndex) || visibleSlide;

    return {
      currentIndex,
      activeDotIndex,
      activeDots: dots
        .map((dot, index) => (dot.classList.contains('active') ? index : -1))
        .filter((index) => index !== -1),
      dotCount: dots.length,
      visibleIndex: visibleSlide.index,
      visibleCount: slideStates.filter((slide) => slide.visibleArea > 4).length,
      bodyWidth: document.scrollingElement.scrollWidth,
      bodyHeight: document.scrollingElement.scrollHeight,
      viewportWidth,
      viewportHeight,
      windowScrollY: window.scrollY,
      deckPosition: deckStyle ? deckStyle.position : null,
      deckDisplay: deckStyle ? deckStyle.display : null,
      deckTransform: deckStyle ? deckStyle.transform : null,
      currentSlideLeft: currentSlide ? currentSlide.left : null,
      currentSlideRight: currentSlide ? currentSlide.right : null,
      currentSlidePosition: currentSlide ? currentSlide.position : null,
      currentSlideOverflowY: currentSlide ? currentSlide.overflowY : null,
      currentSlideTouchAction: currentSlide ? currentSlide.touchAction : '',
      currentSlideScrollTop: currentSlide ? currentSlide.scrollTop : 0,
      currentSlideScrollHeight: currentSlide ? currentSlide.scrollHeight : 0,
      currentSlideClientHeight: currentSlide ? currentSlide.clientHeight : 0,
    };
  });
}

async function checkVisibleOverflow(page) {
  return page.evaluate(() => {
    const viewportWidth = window.innerWidth;
    const viewportHeight = window.innerHeight;
    const slides = Array.from(document.querySelectorAll('#deck .slide'));
    const visibleSlides = slides
      .map((slide, index) => {
        const rect = slide.getBoundingClientRect();
        const visibleWidth = Math.max(0, Math.min(rect.right, viewportWidth) - Math.max(rect.left, 0));
        const visibleHeight = Math.max(0, Math.min(rect.bottom, viewportHeight) - Math.max(rect.top, 0));
        return { slide, index, rect, visibleArea: visibleWidth * visibleHeight };
      })
      .filter((item) => item.visibleArea > 4);

    const overflows = [];

    visibleSlides.forEach(({ slide, index, rect }) => {
      if (rect.width > viewportWidth + 1) {
        overflows.push({
          slide: index + 1,
          type: 'slide-horizontal-overflow',
          width: Math.round(rect.width),
          viewport: viewportWidth,
        });
      }

      slide.querySelectorAll('*').forEach((child) => {
        const childRect = child.getBoundingClientRect();
        const style = window.getComputedStyle(child);

        if (style.position === 'fixed' || childRect.width <= 10 || childRect.height <= 10) {
          return;
        }

        if (childRect.left < rect.left - 5 || childRect.right > rect.right + 5) {
          overflows.push({
            slide: index + 1,
            type: 'element-horizontal-overflow',
            tagName: child.tagName,
            className: child.className,
            left: Math.round(childRect.left),
            right: Math.round(childRect.right),
            slideLeft: Math.round(rect.left),
            slideRight: Math.round(rect.right),
          });
        }
      });
    });

    return {
      bodyWidth: document.body.scrollWidth,
      bodyHeight: document.body.scrollHeight,
      viewportWidth,
      viewportHeight,
      visibleSlides: visibleSlides.length,
      overflows,
    };
  });
}

async function findOverflowSlideIndex(page) {
  return page.evaluate(() => {
    const slides = Array.from(document.querySelectorAll('#deck .slide'));
    const candidate = slides.findIndex((slide) => slide.scrollHeight > slide.clientHeight + 1);
    return candidate === -1 ? null : candidate;
  });
}

async function goToSlide(page, index) {
  const dot = page.locator('#nav .dot').nth(index);
  await dot.click();
  await page.waitForTimeout(800);
}

async function hoverCurrentSlide(page) {
  const state = await getDeckState(page);
  const targetIndex = state.currentIndex === -1 ? 0 : state.currentIndex;
  await page.locator('#deck .slide').nth(targetIndex).hover();
}

async function checkVisibleWhitespaceBalance(page) {
  return page.evaluate(() => {
    const slides = Array.from(document.querySelectorAll('#deck .slide'));
    const viewportWidth = window.innerWidth;
    const viewportHeight = window.innerHeight;
    const visible = slides
      .map((slide, index) => {
        const rect = slide.getBoundingClientRect();
        const visibleWidth = Math.max(0, Math.min(rect.right, viewportWidth) - Math.max(rect.left, 0));
        const visibleHeight = Math.max(0, Math.min(rect.bottom, viewportHeight) - Math.max(rect.top, 0));
        return { slide, index, visibleArea: visibleWidth * visibleHeight };
      })
      .reduce((best, item) => (item.visibleArea > best.visibleArea ? item : best), { slide: null, index: -1, visibleArea: 0 });

    if (!visible.slide) {
      return { skipped: true, reason: 'no-visible-slide', issues: [] };
    }

    const { slide, index } = visible;
    if (slide.classList.contains('hero') || !slide.querySelector('.chrome') || !slide.querySelector('.foot')) {
      return { skipped: true, reason: 'non-content-slide', slide: index + 1, issues: [] };
    }

    const frame = slide.querySelector('.frame');
    if (!frame) {
      return { skipped: true, reason: 'no-frame', slide: index + 1, issues: [] };
    }

    const frameStyle = window.getComputedStyle(frame);
    if (frameStyle.display !== 'flex' || frameStyle.flexDirection !== 'column') {
      return { skipped: true, reason: 'non-flex-frame', slide: index + 1, issues: [] };
    }

    const frameRect = frame.getBoundingClientRect();
    if (frameRect.width < 40 || frameRect.height < 40) {
      return { skipped: true, reason: 'tiny-frame', slide: index + 1, issues: [] };
    }

    const toBox = (rect) => {
      const left = Math.max(frameRect.left, rect.left);
      const right = Math.min(frameRect.right, rect.right);
      const top = Math.max(frameRect.top, rect.top);
      const bottom = Math.min(frameRect.bottom, rect.bottom);
      return {
        left,
        right,
        top,
        bottom,
        width: Math.max(0, right - left),
        height: Math.max(0, bottom - top),
      };
    };

    const isVisibleElement = (el) => {
      const style = window.getComputedStyle(el);
      if (style.display === 'none' || style.visibility === 'hidden') {
        return false;
      }
      if (style.position === 'absolute' || style.position === 'fixed') {
        return false;
      }
      const rect = el.getBoundingClientRect();
      return rect.width > 10 && rect.height > 8;
    };

    const getTextBox = (el) => {
      const range = document.createRange();
      range.selectNodeContents(el);
      const rects = Array.from(range.getClientRects()).filter((rect) => rect.width > 6 && rect.height > 6);
      if (rects.length === 0) {
        return null;
      }
      return {
        left: Math.min(...rects.map((rect) => rect.left)),
        right: Math.max(...rects.map((rect) => rect.right)),
        top: Math.min(...rects.map((rect) => rect.top)),
        bottom: Math.max(...rects.map((rect) => rect.bottom)),
      };
    };

    const blockBoxes = Array.from(frame.children)
      .map((el, order) => {
        if (!isVisibleElement(el)) {
          return null;
        }
        const box = toBox(el.getBoundingClientRect());
        if (box.width <= 24 || box.height <= 12) {
          return null;
        }
        return {
          order,
          tag: el.tagName,
          className: el.className || '',
          ...box,
        };
      })
      .filter(Boolean);

    if (blockBoxes.length < 2) {
      return { skipped: true, reason: 'too-few-blocks', slide: index + 1, issues: [] };
    }

    const containerSelector = '.pipeline, .grid-6, .grid-4, .grid-3, .grid-3-3, .callout, .rowline, .step, .feature-card, .stat-card, .pillar, .option-card, .frame-img, figure, table, blockquote, ul, ol';
    const textSelector = 'h1, h2, h3, h4, h5, h6, p, .kicker';
    const visualNodes = [
      ...Array.from(frame.querySelectorAll(containerSelector)),
      ...Array.from(frame.querySelectorAll(textSelector)).filter((el) => !el.closest(containerSelector)),
    ]
      .filter((el, idx, arr) => arr.indexOf(el) === idx)
      .map((el) => {
        if (!isVisibleElement(el)) {
          return null;
        }
        const box = toBox(el.matches(textSelector) ? (getTextBox(el) || el.getBoundingClientRect()) : el.getBoundingClientRect());
        if (box.width <= 10 || box.height <= 10) {
          return null;
        }
        return box;
      })
      .filter(Boolean);

    if (visualNodes.length === 0) {
      return { skipped: true, reason: 'no-visual-nodes', slide: index + 1, issues: [] };
    }

    const visualUnion = visualNodes.reduce((union, box) => ({
      left: Math.min(union.left, box.left),
      right: Math.max(union.right, box.right),
      top: Math.min(union.top, box.top),
      bottom: Math.max(union.bottom, box.bottom),
    }), {
      left: visualNodes[0].left,
      right: visualNodes[0].right,
      top: visualNodes[0].top,
      bottom: visualNodes[0].bottom,
    });

    const topGap = Math.max(0, blockBoxes[0].top - frameRect.top);
    const bottomGap = Math.max(0, frameRect.bottom - blockBoxes[blockBoxes.length - 1].bottom);
    const leftGap = Math.max(0, visualUnion.left - frameRect.left);
    const rightGap = Math.max(0, frameRect.right - visualUnion.right);
    const innerGaps = blockBoxes.slice(1)
      .map((block, i) => ({
        size: Math.max(0, block.top - blockBoxes[i].bottom),
        before: blockBoxes[i].tag,
        after: block.tag,
      }))
      .filter((gap) => gap.size > 0);
    const maxInnerGap = innerGaps.reduce((best, gap) => (gap.size > best.size ? gap : best), { size: 0, before: '', after: '' });

    const frameHeight = frameRect.height || 1;
    const frameWidth = frameRect.width || 1;
    const topGapRatio = topGap / frameHeight;
    const bottomGapRatio = bottomGap / frameHeight;
    const leftGapRatio = leftGap / frameWidth;
    const rightGapRatio = rightGap / frameWidth;
    const innerGapRatio = maxInnerGap.size / frameHeight;
    const hasLinearContent = Boolean(frame.querySelector('.pipeline, .rowline'));
    const edgeGapThreshold = 0.52;
    const edgeImbalanceThreshold = 0.18;
    const middleGapThreshold = 0.24;
    const middleImbalanceThreshold = 0.08;
    const horizontalGapThreshold = 0.32;
    const horizontalImbalanceThreshold = 0.12;
    const title = (slide.querySelector('h1, h2')?.textContent || '').replace(/\s+/g, ' ').trim();
    const issues = [];

    if (hasLinearContent && topGapRatio > edgeGapThreshold && topGapRatio - bottomGapRatio > edgeImbalanceThreshold) {
      issues.push({ slide: index + 1, title, region: 'top', axis: 'vertical', ratio: Number(topGapRatio.toFixed(3)), size: Math.round(topGap) });
    }
    if (innerGapRatio > middleGapThreshold && innerGapRatio - Math.max(topGapRatio, bottomGapRatio) > middleImbalanceThreshold) {
      issues.push({ slide: index + 1, title, region: 'middle', axis: 'vertical', ratio: Number(innerGapRatio.toFixed(3)), size: Math.round(maxInnerGap.size), before: maxInnerGap.before, after: maxInnerGap.after });
    }
    if (hasLinearContent && bottomGapRatio > edgeGapThreshold && bottomGapRatio - topGapRatio > edgeImbalanceThreshold) {
      issues.push({ slide: index + 1, title, region: 'bottom', axis: 'vertical', ratio: Number(bottomGapRatio.toFixed(3)), size: Math.round(bottomGap) });
    }
    if (leftGapRatio > horizontalGapThreshold && leftGapRatio - rightGapRatio > horizontalImbalanceThreshold) {
      issues.push({ slide: index + 1, title, region: 'left', axis: 'horizontal', ratio: Number(leftGapRatio.toFixed(3)), size: Math.round(leftGap) });
    }
    if (rightGapRatio > horizontalGapThreshold && rightGapRatio - leftGapRatio > horizontalImbalanceThreshold) {
      issues.push({ slide: index + 1, title, region: 'right', axis: 'horizontal', ratio: Number(rightGapRatio.toFixed(3)), size: Math.round(rightGap) });
    }

    return {
      skipped: false,
      slide: index + 1,
      title,
      issues,
      metrics: {
        topGap: Math.round(topGap),
        bottomGap: Math.round(bottomGap),
        leftGap: Math.round(leftGap),
        rightGap: Math.round(rightGap),
        maxInnerGap: Math.round(maxInnerGap.size),
        blockCount: blockBoxes.length,
      },
    };
  });
}

// §5: 逐页全量检查 — 水平溢出(checkVisibleOverflow) + 垂直 frame 裁切 + 过量留白失衡
// §4: ArrowRight + waitMs（默认 1100ms = 900ms transition + 200ms render buffer）
// VP-8/VP-10（≥2560px）传 1500ms：4K 画布渲染更大，600ms buffer 更保守
async function verifyAllSlidesOverflow(page, waitMs = 1100, clipThreshold = CLIP_THRESHOLD) {
  const state = await getDeckState(page);
  const slideCount = state.dotCount;
  const allOverflows = [];
  const allClipping = [];
  const allWhitespaceIssues = [];

  // §5 消抖：测量前等字体就绪 + 一帧 rAF，消除字体异步 swap 重排导致的 run-to-run 抖动
  const settle = async () => {
    await page.evaluate(async () => {
      if (document.fonts && document.fonts.ready) await document.fonts.ready;
      await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    });
  };

  // §5 单次裁切测量：返回当前可见 slide 内 overflow:hidden 容器的 excess 列表
  const measureClip = () => page.evaluate(() => {
    const slides = Array.from(document.querySelectorAll('#deck .slide'));
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const visible = slides
      .map((s) => {
        const r = s.getBoundingClientRect();
        const visibleArea = Math.max(0, Math.min(r.bottom, vh) - Math.max(r.top, 0)) *
          Math.max(0, Math.min(r.right, vw) - Math.max(r.left, 0));
        return { slide: s, visibleArea };
      })
      .reduce((best, item) => (item.visibleArea > best.visibleArea ? item : best), { slide: null, visibleArea: 0 }).slide;
    if (!visible) return [];
    return Array.from(visible.querySelectorAll('.frame, .grid-6, .grid-4, .grid-3, .grid-9'))
      .filter((el) => {
        const s = window.getComputedStyle(el);
        return (s.overflow === 'hidden' || s.overflowY === 'hidden');
      })
      .map((el) => ({
        className: el.className,
        scrollH: Math.round(el.scrollHeight),
        clientH: Math.round(el.clientHeight),
        excess: Math.round(el.scrollHeight - el.clientHeight),
      }));
  });

  for (let i = 0; i < slideCount; i++) {
    if (i > 0) {
      await page.keyboard.press('ArrowRight');
      await page.waitForTimeout(waitMs); // §4: DOM layout 测量等待
    }

    const overflow = await checkVisibleOverflow(page);
    if (overflow.overflows.length > 0) allOverflows.push(...overflow.overflows);

    // §5 自适应采样取 min：clip 真值是下界，瞬时尖峰只会偏大。每个容器按 className 取 min(excess)，
    // 单调收敛到真值。采样持续到「连续 CLIP_STABLE_STREAK 次无任何容器刷新更低值」即判收敛而停，
    // 或触 CLIP_MAX_SAMPLES 上限——稳定视口快速收敛，4K@DPR 抖动视口多采到真值浮现，无需按视口分阈值。
    await settle();
    const minByClass = new Map();
    const metaByClass = new Map();
    let streak = 0;
    for (let s = 0; s < CLIP_MAX_SAMPLES && streak < CLIP_STABLE_STREAK; s++) {
      if (s > 0) await page.waitForTimeout(120);
      const sample = await measureClip();
      let improved = false;
      for (const e of sample) {
        const prev = minByClass.has(e.className) ? minByClass.get(e.className) : Infinity;
        if (e.excess < prev) { minByClass.set(e.className, e.excess); metaByClass.set(e.className, e); improved = true; }
      }
      streak = improved ? 0 : streak + 1;
    }
    const clipped = Array.from(minByClass.entries())
      .filter(([, excess]) => excess > clipThreshold)
      .map(([className, excess]) => ({ ...metaByClass.get(className), excess }));
    if (clipped.length > 0) allClipping.push({ slide: i + 1, clipped });

    const whitespace = await checkVisibleWhitespaceBalance(page);
    if (whitespace.issues.length > 0) allWhitespaceIssues.push(...whitespace.issues);
  }

  return { allOverflows, allClipping, allWhitespaceIssues };
}

async function swipe(session, start, end, steps = 16) {
  await session.send('Input.dispatchTouchEvent', {
    type: 'touchStart',
    touchPoints: [{ x: Math.round(start.x), y: Math.round(start.y) }],
  });

  for (let i = 1; i <= steps; i += 1) {
    await session.send('Input.dispatchTouchEvent', {
      type: 'touchMove',
      touchPoints: [{
        x: Math.round(start.x + ((end.x - start.x) * i) / steps),
        y: Math.round(start.y + ((end.y - start.y) * i) / steps),
      }],
    });
  }

  await session.send('Input.dispatchTouchEvent', {
    type: 'touchEnd',
    touchPoints: [],
  });
}

// @spec tests/ppt/README.md §7.1  §1
test('detect slide structure', async ({ page }) => {
  await page.goto(DECK_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1000);

  await expect(page.locator('#deck')).toBeAttached();
  const slides = page.locator('#deck .slide');
  const count = await slides.count();
  expect(count).toBeGreaterThan(0);

  const slidesInfo = await getSlidesInfo(page);
  console.log(`\n📊 检测到 ${count} 页 slides:`);
  slidesInfo.forEach((slide) => {
    console.log(`  Slide ${slide.index}: ${slide.width}x${slide.height}px, 文本:${slide.textLength}, 媒体:${slide.mediaCount}, 可见内容:${slide.visibleContentCount}`);
  });
});

// @spec tests/ppt/README.md §7.2 VP-1  §1 §5
test(`viewport: ${VIEWPORTS.desktop.name} — all slides no overflow`, async ({ page }) => {
  test.setTimeout(120000);
  await page.setViewportSize({ width: VIEWPORTS.desktop.width, height: VIEWPORTS.desktop.height });
  await page.goto(DECK_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1000);
  await maybeScreenshot(page, VIEWPORTS.desktop.name);

  const { isStacked } = await detectLayoutMode(page);
  expect(isStacked).toBe(false);

  // VP-1 1920×1080 是最主流桌面分辨率，必须逐页全量扫描垂直裁切（曾是盲区）
  const { allOverflows, allClipping, allWhitespaceIssues } = await verifyAllSlidesOverflow(page);
  if (allOverflows.length > 0) console.log('  Horizontal overflows:', JSON.stringify(allOverflows));
  if (allClipping.length > 0) console.log('  Vertical clipping:', JSON.stringify(allClipping));
  if (allWhitespaceIssues.length > 0) console.log('  Excessive whitespace:', JSON.stringify(allWhitespaceIssues));
  expect(allOverflows, 'horizontal overflow at desktop').toHaveLength(0);
  expect(allClipping, 'vertical clipping at desktop').toHaveLength(0);
  expect(allWhitespaceIssues, 'excessive whitespace imbalance at desktop').toHaveLength(0);

  const slidesInfo = await getSlidesInfo(page);
  slidesInfo.forEach((slide) => {
    expect(slide.hasContent).toBe(true);
    expect(slide.textLength > 20 || slide.mediaCount > 0).toBe(true);
  });
});

// @spec tests/ppt/README.md §7.3 VP-2  §4 §5
test(`viewport: ${VIEWPORTS.laptop.name} — all slides no overflow`, async ({ page }) => {
  test.setTimeout(120000); // 20 slides × (1100ms + 4×120ms 采样) + overhead
  await page.setViewportSize({ width: VIEWPORTS.laptop.width, height: VIEWPORTS.laptop.height });
  await page.goto(DECK_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1000);

  const { allOverflows, allClipping, allWhitespaceIssues } = await verifyAllSlidesOverflow(page);

  if (allOverflows.length > 0) console.log('  Horizontal overflows:', JSON.stringify(allOverflows));
  if (allClipping.length > 0) console.log('  Vertical clipping:', JSON.stringify(allClipping));
  if (allWhitespaceIssues.length > 0) console.log('  Excessive whitespace:', JSON.stringify(allWhitespaceIssues));
  expect(allOverflows, 'horizontal overflow at laptop').toHaveLength(0);
  expect(allClipping, 'vertical clipping at laptop').toHaveLength(0);
  expect(allWhitespaceIssues, 'excessive whitespace imbalance at laptop').toHaveLength(0);
});

// @spec tests/ppt/README.md §7.3b VP-2b  §4 §5
// 矮桌面（1366×768 笔记本扣 chrome）是垂直裁切的最严苛标清场景——多个真实 clip 仅在此暴露
test(`viewport: ${VIEWPORTS.lowDesktop.name} — all slides no overflow`, async ({ page }) => {
  test.setTimeout(120000);
  await page.setViewportSize({ width: VIEWPORTS.lowDesktop.width, height: VIEWPORTS.lowDesktop.height });
  await page.goto(DECK_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1000);

  const { allOverflows, allClipping, allWhitespaceIssues } = await verifyAllSlidesOverflow(page);

  if (allOverflows.length > 0) console.log('  Horizontal overflows:', JSON.stringify(allOverflows));
  if (allClipping.length > 0) console.log('  Vertical clipping:', JSON.stringify(allClipping));
  if (allWhitespaceIssues.length > 0) console.log('  Excessive whitespace:', JSON.stringify(allWhitespaceIssues));
  expect(allOverflows, 'horizontal overflow at low-desktop (VP-2b)').toHaveLength(0);
  expect(allClipping, 'vertical clipping at low-desktop (VP-2b)').toHaveLength(0);
  expect(allWhitespaceIssues, 'excessive whitespace imbalance at low-desktop (VP-2b)').toHaveLength(0);
});

// @spec tests/ppt/README.md §7.4 VP-3  §5
test(`viewport: ${VIEWPORTS.tablet.name}`, async ({ page }) => {
  await page.setViewportSize({ width: VIEWPORTS.tablet.width, height: VIEWPORTS.tablet.height });
  await page.goto(DECK_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1000);
  await maybeScreenshot(page, VIEWPORTS.tablet.name);

  const overflow = await checkVisibleOverflow(page);
  expect(overflow.bodyWidth).toBeLessThanOrEqual(overflow.viewportWidth + 1);
  expect(overflow.overflows).toHaveLength(0);
});

// @spec tests/ppt/README.md §7.5 VP-5  §2 §5
test(`viewport: ${VIEWPORTS.mobileLandscape.name}`, async ({ page }) => {
  await page.setViewportSize({ width: VIEWPORTS.mobileLandscape.width, height: VIEWPORTS.mobileLandscape.height });
  await page.goto(DECK_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1000);
  await maybeScreenshot(page, VIEWPORTS.mobileLandscape.name);

  const { isStacked } = await detectLayoutMode(page);
  expect(isStacked).toBe(false);

  const state = await getDeckState(page);
  expect(state.currentIndex).toBeGreaterThanOrEqual(0);
  expect(state.visibleCount).toBe(1);
  expect(state.currentSlideOverflowY).toBe('hidden');

  const overflow = await checkVisibleOverflow(page);
  expect(overflow.bodyWidth).toBeLessThanOrEqual(overflow.viewportWidth + 1);
  expect(overflow.overflows).toHaveLength(0);
});

// @spec tests/ppt/README.md §7.6 VP-4  §2 §5
test(`viewport: ${VIEWPORTS.mobilePortrait.name}`, async ({ page }) => {
  await page.setViewportSize({ width: VIEWPORTS.mobilePortrait.width, height: VIEWPORTS.mobilePortrait.height });
  await page.goto(DECK_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1000);
  await maybeScreenshot(page, VIEWPORTS.mobilePortrait.name);

  const { isStacked } = await detectLayoutMode(page);
  expect(isStacked).toBe(false);

  const state = await getDeckState(page);
  console.log(`  Portrait state: current=${state.currentIndex}, body=${state.bodyHeight}/${state.viewportHeight}, overflowY=${state.currentSlideOverflowY}, touchAction=${state.currentSlideTouchAction}`);
  expect(state.currentIndex).toBeGreaterThanOrEqual(0);
  expect(state.visibleCount).toBe(1);
  expect(state.bodyHeight).toBeLessThanOrEqual(state.viewportHeight + 1);
  expect(state.currentSlideOverflowY).toBe('auto');
  expect(state.currentSlideTouchAction).toContain('pan-y');
  expect(state.activeDots).toEqual([state.currentIndex]);

  const overflow = await checkVisibleOverflow(page);
  expect(overflow.bodyWidth).toBeLessThanOrEqual(overflow.viewportWidth + 1);
  expect(overflow.overflows).toHaveLength(0);
});

// @spec tests/ppt/README.md §7.7  §2 §3
test('responsive layout switch', async ({ page }) => {
  await page.setViewportSize({ width: VIEWPORTS.desktop.width, height: VIEWPORTS.desktop.height });
  await page.goto(DECK_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1000);

  let mode = await detectLayoutMode(page);
  expect(mode.isStacked).toBe(false);

  await page.setViewportSize({ width: VIEWPORTS.mobilePortrait.width, height: VIEWPORTS.mobilePortrait.height });
  await page.waitForTimeout(500);
  await goToSlide(page, 0);

  mode = await detectLayoutMode(page);
  expect(mode.isStacked).toBe(false);

  let state = await getDeckState(page);
  expect(state.currentIndex).toBeGreaterThanOrEqual(0);
  expect(state.visibleCount).toBe(1);
  expect(state.currentSlideOverflowY).toBe('auto');
  expect(state.currentSlideTouchAction).toContain('pan-y');
  expect(state.bodyHeight).toBeLessThanOrEqual(state.viewportHeight + 1);

  await page.setViewportSize({ width: VIEWPORTS.mobileLandscape.width, height: VIEWPORTS.mobileLandscape.height });
  await page.waitForTimeout(500);
  await goToSlide(page, 0);

  mode = await detectLayoutMode(page);
  expect(mode.isStacked).toBe(false);

  state = await getDeckState(page);
  expect(state.currentIndex).toBeGreaterThanOrEqual(0);
  expect(state.visibleCount).toBe(1);
  expect(state.currentSlideOverflowY).toBe('hidden');
});

// @spec tests/ppt/README.md §7.8  §1
test('nav dots click navigation', async ({ page }) => {
  await page.setViewportSize({ width: VIEWPORTS.desktop.width, height: VIEWPORTS.desktop.height });
  await page.goto(DECK_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1000);

  const initial = await getDeckState(page);
  expect(initial.dotCount).toBeGreaterThan(1);

  const targetIndex = Math.min(initial.dotCount - 1, initial.currentIndex + 1);
  await goToSlide(page, targetIndex);

  const afterClick = await getDeckState(page);
  expect(afterClick.currentIndex).toBe(targetIndex);
  expect(afterClick.activeDots).toEqual([targetIndex]);
});

// @spec tests/ppt/README.md §7.9  §2
test('wheel navigation landscape', async ({ page }) => {
  await page.setViewportSize({ width: VIEWPORTS.desktop.width, height: VIEWPORTS.desktop.height });
  await page.goto(DECK_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1000);

  const before = await getDeckState(page);
  await hoverCurrentSlide(page);
  await page.mouse.wheel(0, 600);
  await page.waitForTimeout(400);

  const after = await getDeckState(page);
  expect(after.currentIndex).toBe(Math.min(before.currentIndex + 1, before.dotCount - 1));
  expect(after.activeDots).toEqual([after.currentIndex]);
});

// @spec tests/ppt/README.md §7.10  §2
test('portrait overflow scroll uses wheel without moving the document', async ({ page }) => {
  await page.setViewportSize({ width: VIEWPORTS.mobilePortrait.width, height: VIEWPORTS.mobilePortrait.height });
  await page.goto(DECK_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1000);

  const overflowIndex = await findOverflowSlideIndex(page);
  test.skip(overflowIndex === null, 'No overflowing slide in portrait');

  await goToSlide(page, overflowIndex);
  await hoverCurrentSlide(page);

  const before = await getDeckState(page);
  expect(before.currentSlideScrollHeight).toBeGreaterThan(before.currentSlideClientHeight);

  await page.mouse.wheel(0, 700);
  await page.waitForTimeout(400);

  const after = await getDeckState(page);
  console.log(`  Wheel scroll: slide=${before.currentIndex + 1}, scrollTop ${before.currentSlideScrollTop} -> ${after.currentSlideScrollTop}`);
  expect(after.currentIndex).toBe(before.currentIndex);
  expect(after.currentSlideScrollTop).toBeGreaterThan(before.currentSlideScrollTop);
  expect(after.windowScrollY).toBe(0);
});

// @spec tests/ppt/README.md §7.11  §2
test('portrait touch keeps vertical gestures on-page and horizontal gestures for paging', async ({ browser, browserName }) => {
  test.skip(browserName !== 'chromium', 'CDP touch gestures require Chromium');

  const context = await browser.newContext({
    viewport: { width: VIEWPORTS.mobilePortrait.width, height: VIEWPORTS.mobilePortrait.height },
    hasTouch: true,
  });
  const page = await context.newPage();

  await page.goto(DECK_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1000);

  const overflowIndex = await findOverflowSlideIndex(page);
  if (overflowIndex !== null) {
    await goToSlide(page, overflowIndex);
  }

  const session = await context.newCDPSession(page);
  const beforeVertical = await getDeckState(page);

  await swipe(
    session,
    { x: VIEWPORTS.mobilePortrait.width / 2, y: VIEWPORTS.mobilePortrait.height * 0.38 },
    { x: VIEWPORTS.mobilePortrait.width / 2 + 12, y: VIEWPORTS.mobilePortrait.height * 0.78 },
  );
  await page.waitForTimeout(500);

  const afterVertical = await getDeckState(page);
  expect(afterVertical.currentIndex).toBe(beforeVertical.currentIndex);

  const beforeSwipe = await getDeckState(page);
  await swipe(
    session,
    { x: VIEWPORTS.mobilePortrait.width * 0.82, y: VIEWPORTS.mobilePortrait.height / 2 },
    { x: VIEWPORTS.mobilePortrait.width * 0.18, y: VIEWPORTS.mobilePortrait.height / 2 },
  );
  await page.waitForTimeout(600);

  const afterSwipe = await getDeckState(page);
  expect(afterSwipe.currentIndex).toBe(Math.min(beforeSwipe.currentIndex + 1, beforeSwipe.dotCount - 1));
  expect(afterSwipe.activeDots).toEqual([afterSwipe.currentIndex]);
  expect(afterSwipe.windowScrollY).toBe(0);

  await context.close();
});

// @spec tests/ppt/README.md §7.12  §2
test('touch gestures landscape', async ({ browser, browserName }) => {
  test.skip(browserName !== 'chromium', 'CDP touch gestures require Chromium');

  const context = await browser.newContext({
    viewport: { width: VIEWPORTS.mobileLandscape.width, height: VIEWPORTS.mobileLandscape.height },
    hasTouch: true,
  });
  const page = await context.newPage();

  await page.goto(DECK_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1000);

  const before = await getDeckState(page);
  const session = await context.newCDPSession(page);
  await swipe(
    session,
    { x: VIEWPORTS.mobileLandscape.width * 0.82, y: VIEWPORTS.mobileLandscape.height / 2 },
    { x: VIEWPORTS.mobileLandscape.width * 0.18, y: VIEWPORTS.mobileLandscape.height / 2 },
  );
  await page.waitForTimeout(600);

  const after = await getDeckState(page);
  expect(after.currentIndex).toBe(Math.min(before.currentIndex + 1, before.dotCount - 1));
  expect(after.currentSlideOverflowY).toBe('hidden');
  expect(after.activeDots).toEqual([after.currentIndex]);

  await context.close();
});

// @spec tests/ppt/README.md §7.13 VP-6  §4 §5
test(`viewport: ${VIEWPORTS.retinaLandscape.name} — all slides no overflow`, async ({ page }) => {
  test.setTimeout(120000);
  await page.setViewportSize({ width: VIEWPORTS.retinaLandscape.width, height: VIEWPORTS.retinaLandscape.height });
  await page.goto(DECK_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1000);

  const { allOverflows, allClipping, allWhitespaceIssues } = await verifyAllSlidesOverflow(page);

  if (allOverflows.length > 0) console.log('  Horizontal overflows:', JSON.stringify(allOverflows));
  if (allClipping.length > 0) console.log('  Vertical clipping:', JSON.stringify(allClipping));
  if (allWhitespaceIssues.length > 0) console.log('  Excessive whitespace:', JSON.stringify(allWhitespaceIssues));
  expect(allOverflows, 'horizontal overflow at retina-landscape (VP-6)').toHaveLength(0);
  expect(allClipping, 'vertical clipping at retina-landscape (VP-6)').toHaveLength(0);
  expect(allWhitespaceIssues, 'excessive whitespace imbalance at retina-landscape (VP-6)').toHaveLength(0);
});

// @spec tests/ppt/README.md §7.14 VP-7  §1 §5
test(`viewport: ${VIEWPORTS.qhd.name}`, async ({ page }) => {
  await page.setViewportSize({ width: VIEWPORTS.qhd.width, height: VIEWPORTS.qhd.height });
  await page.goto(DECK_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1000);
  await maybeScreenshot(page, VIEWPORTS.qhd.name);

  const { isStacked } = await detectLayoutMode(page);
  expect(isStacked).toBe(false);

  const overflow = await checkVisibleOverflow(page);
  console.log(`  Visible slides: ${overflow.visibleSlides}, Overflows: ${overflow.overflows.length}`);
  expect(overflow.bodyWidth).toBeLessThanOrEqual(overflow.viewportWidth + 1);
  expect(overflow.overflows).toHaveLength(0);

  const slidesInfo = await getSlidesInfo(page);
  slidesInfo.forEach((slide) => {
    expect(slide.hasContent).toBe(true);
    expect(slide.textLength > 20 || slide.mediaCount > 0).toBe(true);
  });
});

// @spec tests/ppt/README.md §7.15 VP-8  §4 §5
test(`viewport: ${VIEWPORTS.qhdBrowser.name} — all slides no overflow`, async ({ page }) => {
  test.setTimeout(120000);
  await page.setViewportSize({ width: VIEWPORTS.qhdBrowser.width, height: VIEWPORTS.qhdBrowser.height });
  await page.goto(DECK_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1000);

  const { allOverflows, allClipping, allWhitespaceIssues } = await verifyAllSlidesOverflow(page, 1500);

  if (allOverflows.length > 0) console.log('  Horizontal overflows:', JSON.stringify(allOverflows));
  if (allClipping.length > 0) console.log('  Vertical clipping:', JSON.stringify(allClipping));
  if (allWhitespaceIssues.length > 0) console.log('  Excessive whitespace:', JSON.stringify(allWhitespaceIssues));
  expect(allOverflows, 'horizontal overflow at qhd-browser (VP-8)').toHaveLength(0);
  expect(allClipping, 'vertical clipping at qhd-browser (VP-8)').toHaveLength(0);
  expect(allWhitespaceIssues, 'excessive whitespace imbalance at qhd-browser (VP-8)').toHaveLength(0);
});

// @spec tests/ppt/README.md §7.16 VP-9  §1 §5
test(`viewport: ${VIEWPORTS.uhd.name}`, async ({ page }) => {
  await page.setViewportSize({ width: VIEWPORTS.uhd.width, height: VIEWPORTS.uhd.height });
  await page.goto(DECK_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1000);
  await maybeScreenshot(page, VIEWPORTS.uhd.name);

  const { isStacked } = await detectLayoutMode(page);
  expect(isStacked).toBe(false);

  const overflow = await checkVisibleOverflow(page);
  console.log(`  Visible slides: ${overflow.visibleSlides}, Overflows: ${overflow.overflows.length}`);
  expect(overflow.bodyWidth).toBeLessThanOrEqual(overflow.viewportWidth + 1);
  expect(overflow.overflows).toHaveLength(0);

  const slidesInfo = await getSlidesInfo(page);
  slidesInfo.forEach((slide) => {
    expect(slide.hasContent).toBe(true);
    expect(slide.textLength > 20 || slide.mediaCount > 0).toBe(true);
  });
});

// @spec tests/ppt/README.md §7.17 VP-10  §4 §5
test(`viewport: ${VIEWPORTS.uhdBrowser.name} — all slides no overflow`, async ({ page }) => {
  test.setTimeout(120000);
  await page.setViewportSize({ width: VIEWPORTS.uhdBrowser.width, height: VIEWPORTS.uhdBrowser.height });
  await page.goto(DECK_URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1000);

  const { allOverflows, allClipping, allWhitespaceIssues } = await verifyAllSlidesOverflow(page, 1500);

  if (allOverflows.length > 0) console.log('  Horizontal overflows:', JSON.stringify(allOverflows));
  if (allClipping.length > 0) console.log('  Vertical clipping:', JSON.stringify(allClipping));
  if (allWhitespaceIssues.length > 0) console.log('  Excessive whitespace:', JSON.stringify(allWhitespaceIssues));
  expect(allOverflows, 'horizontal overflow at uhd-browser (VP-10)').toHaveLength(0);
  expect(allClipping, 'vertical clipping at uhd-browser (VP-10)').toHaveLength(0);
  expect(allWhitespaceIssues, 'excessive whitespace imbalance at uhd-browser (VP-10)').toHaveLength(0);
});

// @spec tests/ppt/README.md §7.18 · CJK 标题行高不足 · 大标题/副标题贴脸防治
// 根因：CJK 字身填满 em 方框，line-height<font-size 时行盒“兜不住”字身，墨迹溢出行盒、
// 吃掉与相邻文本的间距，造成视觉贴脸（拉丁字形不填满 em 故不受影响）。
// 不变量：承载 CJK 的【标题元素 h1–h6】计算行高必须 ≥ 字号（ratio ≥ 1.0）。
// 为何限定标题：贴脸风险发生在“大字号 running title 紧邻另一块文本、间距靠行盒兜字身”
// 的场景——正是标题。stat 数字（.stat-nb 等 <div> 组件）虽也用 <1 紧排 leading，但其
// label/note 间距由显式 margin 提供（实测净空 13-15px、ink 溢出仅 5-7px，不贴脸），且属
// 刻意的数字紧排；对其强加 ≥1.0 只会抬高行高把密集 stat 页顶出血，故按语义排除在标题之外。
// 纯拉丁紧排大字（.big-num/.ghost/.mid-num）本就不是标题、也不含 CJK，双重不触发。
test('CJK headings line-height ≥ font-size (no title/subtitle collision)', async ({ page }) => {
  await page.setViewportSize({ width: VIEWPORTS.desktop.width, height: VIEWPORTS.desktop.height });
  await page.goto(DECK_URL, { waitUntil: 'networkidle' });
  await page.evaluate(async () => {
    if (document.fonts && document.fonts.ready) await document.fonts.ready;
  });
  await page.waitForTimeout(500);

  const violations = await page.evaluate(() => {
    // CJK 统一/扩展A + 兼容表意 + 常用假名（覆盖中日文正文场景）
    const CJK = /[㐀-鿿豈-﫿぀-ヿ]/;
    const TOL = 1; // px，容忍亚像素取整
    const out = [];
    const seen = new Set();
    // 只查标题元素——贴脸风险的语义载体
    const headings = document.querySelectorAll('#deck .slide h1, #deck .slide h2, #deck .slide h3, #deck .slide h4, #deck .slide h5, #deck .slide h6');
    headings.forEach((el) => {
      // 只看“直接”承载 CJK 文本的标题，避免把容器的行高误算到子节点头上
      const directText = Array.from(el.childNodes)
        .filter((n) => n.nodeType === Node.TEXT_NODE)
        .map((n) => n.textContent)
        .join('');
      if (!CJK.test(directText)) return;

      const cs = getComputedStyle(el);
      const fs = parseFloat(cs.fontSize);
      const lh = cs.lineHeight === 'normal' ? fs * 1.2 : parseFloat(cs.lineHeight);
      if (!(fs > 0)) return;
      if (lh + TOL < fs) {
        const key = `${el.className || el.tagName}|${Math.round((lh / fs) * 100)}`;
        if (seen.has(key)) return;
        seen.add(key);
        out.push({
          tag: el.tagName,
          cls: el.className || el.tagName,
          fontSize: Math.round(fs),
          lineHeight: Math.round(lh),
          ratio: +(lh / fs).toFixed(3),
          sample: directText.trim().slice(0, 12),
        });
      }
    });
    return out;
  });

  if (violations.length > 0) console.log('  CJK heading line-height < 1.0:', JSON.stringify(violations, null, 2));
  expect(violations, 'CJK 标题行高不足 font-size，字身墨迹会溢出行盒逼近相邻文本').toHaveLength(0);
});

