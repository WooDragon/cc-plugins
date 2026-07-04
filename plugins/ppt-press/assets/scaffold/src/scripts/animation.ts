/**
 * animation.ts — Motion One 动效引擎
 *
 * 加载顺序（与 maas/maas-sales 保持一致）：
 *   1. 尝试加载本地 /assets/motion.min.js（离线可用）
 *   2. 失败则 fallback 到 jsDelivr CDN
 *   3. 双双失败时：把所有 [data-anim] 设为可见，阅读不受影响
 *
 * 注意：pcdn-proposal 直接走 CDN（无本地 fallback），
 *       本模块采用 maas/maas-sales 的完整双层策略，
 *       若某个 deck 没有本地 motion.min.js，第一步静默失败即可。
 *
 * 5 种 recipe（由 slide 的 data-animate 属性指定，无则自动判断）：
 *   cascade    — 子元素逐个 stagger 100ms 淡入 + y:16→0（默认）
 *   hero       — hero 页慢 stagger 160ms + y:14→0
 *   quote      — kicker/lead fade-in + [data-anim="line"] 逐行 stagger
 *   directional — [data-anim="left|right|divider"] 方向滑入
 *   pipeline   — Space/→ 手动推进步骤，[data-anim="step"] 逐个激活
 *
 * window 挂载：
 *   window.__playSlide(i)   — navigation.ts 翻页后调用
 *   window.__pipeAdvance()  — navigation.ts 处理 Space/→/swipe 时调用
 */

/** Motion One animate / stagger 类型（运行时动态加载，用 any 占位） */
type AnimateFn  = (elements: any, keyframes: any, options?: any) => any;
type StaggerFn  = (interval: number, options?: any) => any;

const EASE: [number, number, number, number] = [0.22, 1, 0.36, 1];

/** 缓存当前页索引，供 pipeAdvance 读取 */
let lastIdx  = -1;
/** 当前 pipeline slide 的步骤游标 */
let pipeStep = -1;

/**
 * 重置 slide 内所有 [data-anim] 元素的 inline style
 * （让 CSS motion-ready 基态接管，等待下一次 animate 调用）
 */
function resetAnims(slide: HTMLElement): void {
  slide.querySelectorAll<HTMLElement>('[data-anim]').forEach(el => {
    el.style.opacity   = '';
    el.style.transform = '';
  });
}

/**
 * 播放指定页的入场动画
 *
 * @param i       目标页索引（0-indexed）
 * @param animate Motion One animate 函数
 * @param stagger Motion One stagger 函数
 */
function playSlide(
  i: number,
  animate: AnimateFn,
  stagger: StaggerFn,
  slides: HTMLElement[]
): void {
  const slide = slides[i];
  if (!slide) return;

  lastIdx = i;

  // 确定 recipe
  const recipe: string =
    slide.dataset.animate
    ?? (slide.classList.contains('hero') ? 'hero' : 'cascade');

  // ── pipeline recipe ──────────────────────────────────────────
  if (recipe === 'pipeline') {
    pipeStep = -1;
    const steps: HTMLElement[] = [];
    const preamble: HTMLElement[] = [];
    slide.querySelectorAll<HTMLElement>('[data-anim]').forEach(el => {
      (el.dataset.anim === 'step' || el.dataset.anim === 'arrow' ? steps : preamble).push(el);
    });

    steps.forEach(el => {
      el.style.opacity   = '0.15';
      el.style.transform = 'none';
    });

    preamble.forEach(el => {
      el.style.opacity   = '0';   // 显式隐藏，消除 stagger delay 期间 FOUC
      el.style.transform = '';
    });

    if (preamble.length) {
      animate(preamble, { opacity: [0, 1], y: [16, 0] },
        { duration: 0.75, delay: stagger(0.1, { start: 0.15 }), easing: EASE });
    }
    return;
  }

  // 重置后统一取 all
  resetAnims(slide);
  const all = [...slide.querySelectorAll<HTMLElement>('[data-anim]')];
  if (!all.length) return;

  // ── directional recipe ───────────────────────────────────────
  if (recipe === 'directional') {
    const lefts  = all.filter(el => el.dataset.anim === 'left');
    const divs   = all.filter(el => el.dataset.anim === 'divider');
    const rights = all.filter(el => el.dataset.anim === 'right');
    const others = all.filter(
      el => !['left', 'right', 'divider'].includes(el.dataset.anim ?? '')
    );

    if (others.length) {
      animate(others, { opacity: [0, 1], y: [12, 0] },
        { duration: 0.6, delay: stagger(0.1, { start: 0.15 }), easing: EASE });
    }
    if (lefts.length) {
      animate(lefts, { opacity: [0, 1], x: [-24, 0] },
        { duration: 0.8, delay: 0.35, easing: EASE });
    }
    if (divs.length) {
      animate(divs, { opacity: [0, 0.25] }, { duration: 0.5, delay: 0.9 });
    }
    if (rights.length) {
      animate(rights, { opacity: [0, 1], x: [24, 0] },
        { duration: 0.8, delay: 1.0, easing: EASE });
    }
    return;
  }

  // ── quote recipe ─────────────────────────────────────────────
  if (recipe === 'quote') {
    const lines  = all.filter(el => el.dataset.anim === 'line');
    const others = all.filter(el => el.dataset.anim !== 'line');

    if (others.length) {
      animate(others, { opacity: [0, 1], y: [8, 0] },
        { duration: 0.6, delay: stagger(0.12, { start: 0.2 }), easing: EASE });
    }
    if (lines.length) {
      animate(lines, { opacity: [0.35, 1], y: [10, 0] },
        { duration: 0.8, delay: stagger(0.55, { start: 0.5 }), easing: EASE });
    }
    return;
  }

  // ── hero recipe ──────────────────────────────────────────────
  if (recipe === 'hero') {
    animate(all, { opacity: [0, 1], y: [14, 0] },
      { duration: 0.9, delay: stagger(0.16, { start: 0.2 }), easing: EASE });
    return;
  }

  // ── cascade（默认）───────────────────────────────────────────
  animate(all, { opacity: [0, 1], y: [16, 0] },
    { duration: 0.75, delay: stagger(0.1, { start: 0.15 }), easing: EASE });
}

/**
 * 推进 pipeline 步骤
 *
 * @returns true  — 成功消费一步（navigation.ts 应忽略翻页）
 *          false — 当前页不是 pipeline，或步骤已全部展示
 */
function pipeAdvance(
  animate: AnimateFn,
  slides: HTMLElement[]
): boolean {
  const slide = slides[lastIdx];
  if (!slide || slide.dataset.animate !== 'pipeline') return false;

  const steps  = [...slide.querySelectorAll<HTMLElement>('[data-anim="step"]')];
  const arrows = [...slide.querySelectorAll<HTMLElement>('[data-anim="arrow"]')];

  if (pipeStep >= steps.length - 1) return false;

  pipeStep++;
  animate(steps[pipeStep], { opacity: [0.15, 1], y: [8, 0] },
    { duration: 0.5, easing: EASE });

  if (pipeStep > 0 && arrows[pipeStep - 1]) {
    animate(arrows[pipeStep - 1], { opacity: [0.15, 0.7] },
      { duration: 0.3, delay: 0.15 });
  }

  return true;
}

/**
 * 初始化动效引擎（async — 等待 Motion One 加载完成）
 *
 * 加载策略：
 *   1. 本地 /assets/motion.min.js（maas/maas-sales 离线优先）
 *   2. jsDelivr CDN
 *   3. 双双失败：显示所有 [data-anim] 元素
 */
export async function initAnimation(): Promise<void> {
  let motion: { animate: AnimateFn; stagger: StaggerFn } | null = null;

  try {
    motion = await import('/assets/motion.min.js');
  } catch (_e1) {
    try {
      motion = await import('https://cdn.jsdelivr.net/npm/motion@11.11.17/+esm');
    } catch (_e2) {
      console.warn('[animation] local + CDN both failed, disabling animations');
      // Fallback：直接显示所有动效元素
      document.querySelectorAll<HTMLElement>('[data-anim]').forEach(el => {
        el.style.opacity   = '1';
        el.style.transform = 'none';
      });
      document.querySelectorAll<HTMLElement>('[data-animate="pipeline"] [data-anim]').forEach(el => {
        el.style.opacity = '1';
      });
      return;
    }
  }

  const { animate, stagger } = motion;

  // 激活 motion-ready CSS 基态（[data-anim] 将被隐藏，等待 JS 动画）
  document.body.classList.add('motion-ready');

  const slides = [...document.querySelectorAll<HTMLElement>('.slide')];

  // 挂载到 window 供 navigation.ts 调用
  (window as any).__playSlide = (i: number) => playSlide(i, animate, stagger, slides);
  (window as any).__pipeAdvance = () => pipeAdvance(animate, slides);

  // 首屏补播：go(0) 已在 navigation.ts 中 force=true 执行（未触发动画），
  // Motion One 加载完成后此处补播第 0 页的入场动画。
  playSlide(0, animate, stagger, slides);
}
