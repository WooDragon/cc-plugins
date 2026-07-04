/**
 * navigation.ts — 翻页导航引擎
 *
 * 职责：
 *   - 维护当前页索引 idx
 *   - 支持横屏 CSS transform 翻页 + 竖屏 CSS left 翻页（hybrid portrait）
 *   - 700ms 翻页锁（防止连续快速翻页）
 *   - 键盘：ArrowLeft/Right、PageUp/Down、Space、Home/End
 *   - 滚轮：deltaX+deltaY 判向，300ms 节流累积
 *   - 触屏：三态机（idle→pending→decided），24px 水平阈值，竖屏允许纵向滚动
 *   - 导航点 `.dot` 渲染与 active 同步
 *   - window.resize 时重新 syncDeckLayout（修正横竖屏切换）
 *
 * 与外部的接口（挂载到 window）：
 *   window.__go(n)          — overview.ts 点击缩略图跳转
 *   window.__playSlide(i)   — animation.ts 入场动画触发（由 navigation.ts 调用）
 *   window.__pipeAdvance()  — animation.ts pipeline 步骤推进（由 navigation.ts 调用）
 */

/** 检测当前是否处于竖屏模式（mobile portrait） */
const isPortrait = (): boolean =>
  window.matchMedia('(max-width:600px) and (orientation:portrait)').matches;

// ============ 模块作用域状态 ============
let idx       = 0;
let lockUntil = 0;

let deck:   HTMLElement;
let slides: NodeListOf<HTMLElement>;
let nav:    HTMLElement;
let total:  number;

// ============ 核心翻页函数 ============

/**
 * 更新 deck 的 CSS 布局（横屏 transform / 竖屏 CSS class）
 */
function syncDeckLayout(): void {
  if (isPortrait()) {
    // 竖屏：position:absolute + left CSS，deck 不 translate
    (deck as HTMLElement).style.width     = '100vw';
    (deck as HTMLElement).style.transform = '';
    slides.forEach((slide, i) => {
      slide.classList.toggle('active', i === idx);
      slide.classList.toggle('before', i < idx);
      slide.classList.toggle('after',  i > idx);
    });
    return;
  }

  // 横屏：translateX 翻页
  (deck as HTMLElement).style.width     = `${total * 100}vw`;
  (deck as HTMLElement).style.transform = `translateX(${-idx * 100}vw)`;
  slides.forEach(slide => slide.classList.remove('active', 'before', 'after'));
}

/**
 * 更新导航点 active 状态 + 主题切换 + 触发入场动画
 *
 * @param play  是否触发动画（force 跳转时不播放）
 */
function updateDeckChrome(play: boolean = true): void {
  // 更新导航点
  nav.querySelectorAll<HTMLElement>('.dot').forEach((dot, i) => {
    dot.classList.toggle('active', i === idx);
  });

  // 主题切换（优先读 data-theme，其次从 class 推断）
  const el = slides[idx];
  const th = el.dataset.theme
    ?? (el.classList.contains('light') ? 'light'
      : el.classList.contains('dark')  ? 'dark'
      : 'dark');
  document.body.classList.toggle('light-bg', th === 'light');

  // 翻页中段触发入场动画（450ms 延迟等 CSS transition 中段）
  if (play && (window as any).__playSlide) {
    setTimeout(() => (window as any).__playSlide(idx), 450);
  }
}

/**
 * 跳转到第 n 页
 *
 * @param n      目标页码（0-indexed）
 * @param force  强制跳转（忽略 lock，不触发动画，用于 resize 修正）
 */
export function go(n: number, force: boolean = false): void {
  if (!force && Date.now() < lockUntil) return;

  idx = Math.max(0, Math.min(total - 1, n));
  syncDeckLayout();
  updateDeckChrome(!force);

  if (force) return;
  lockUntil = Date.now() + 700;
}

// ============ 导航点渲染 ============

function renderDots(): void {
  slides.forEach((_, i) => {
    const btn = document.createElement('button');
    btn.className = 'dot';
    btn.dataset.i = String(i);
    btn.setAttribute('aria-label', `Page ${i + 1}`);
    btn.onclick = () => go(i);
    nav.appendChild(btn);
  });
}

// ============ 键盘事件 ============

function onKeydown(e: KeyboardEvent): void {
  if (e.key === 'Escape') {
    // ESC 由 overview.ts 处理
    return;
  }

  const forward  = ['ArrowRight', 'PageDown', ' ', 'ArrowDown'];
  const backward = ['ArrowLeft',  'PageUp',  'ArrowUp'];

  if (forward.includes(e.key)) {
    e.preventDefault();
    // pipeline 先消费
    if ((window as any).__pipeAdvance && (window as any).__pipeAdvance()) return;
    go(idx + 1);
    return;
  }

  if (backward.includes(e.key)) {
    e.preventDefault();
    go(idx - 1);
    return;
  }

  if (e.key === 'Home') { e.preventDefault(); go(0);       return; }
  if (e.key === 'End')  { e.preventDefault(); go(total - 1); return; }
}

// ============ 滚轮事件 ============

let wheelTO: ReturnType<typeof setTimeout> | null = null;
let wheelAcc = 0;

function onWheel(e: WheelEvent): void {
  // 竖屏：只处理水平滚动（触控板双指横扫）
  if (isPortrait()) {
    if (Math.abs(e.deltaX) > Math.abs(e.deltaY) && Math.abs(e.deltaX) > 30) {
      e.preventDefault();
      go(idx + (e.deltaX > 0 ? 1 : -1));
    }
    return;
  }

  // 横屏：累积 deltaY+deltaX，超过 50 时触发翻页
  wheelAcc += e.deltaY + e.deltaX;
  if (Math.abs(wheelAcc) > 50) {
    if (wheelAcc > 0 && (window as any).__pipeAdvance && (window as any).__pipeAdvance()) {
      wheelAcc = 0;
    } else {
      go(idx + (wheelAcc > 0 ? 1 : -1));
      wheelAcc = 0;
    }
  }

  if (wheelTO !== null) clearTimeout(wheelTO);
  wheelTO = setTimeout(() => { wheelAcc = 0; }, 150);
}

// ============ 触屏事件（三态机） ============

type GestureState = 'idle' | 'pending' | 'scroll' | 'swipe';

let tx = 0;
let ty = 0;
let gesture: GestureState = 'idle';

function onTouchStart(e: TouchEvent): void {
  tx = e.touches[0].clientX;
  ty = e.touches[0].clientY;
  gesture = 'pending';
}

function onTouchMove(e: TouchEvent): void {
  // 横屏时不干预（让浏览器处理）
  if (!isPortrait()) return;

  const cx = e.touches[0].clientX;
  const cy = e.touches[0].clientY;
  const dx = cx - tx;
  const dy = cy - ty;

  if (gesture === 'pending') {
    // 优先判纵向滚动
    if (Math.abs(dy) > 10 && Math.abs(dy) >= Math.abs(dx)) {
      gesture = 'scroll';
      return;
    }
    // 水平判定：dx > 24px 且比 dy 明显大
    if (Math.abs(dx) > 24 && Math.abs(dx) > Math.abs(dy) + 6) {
      gesture = 'swipe';
    }
  }

  // 已确认横向滑动：阻止页面默认纵向滚动
  if (gesture === 'swipe') e.preventDefault();
}

function onTouchEnd(e: TouchEvent): void {
  const dx = e.changedTouches[0].clientX - tx;
  const dy = e.changedTouches[0].clientY - ty;

  if (isPortrait()) {
    if (gesture !== 'swipe') { gesture = 'idle'; return; }
    gesture = 'idle';
    if (Math.abs(dx) > Math.abs(dy) && Math.abs(dx) > 80) {
      e.preventDefault();
      if (dx < 0 && (window as any).__pipeAdvance && (window as any).__pipeAdvance()) return;
      go(idx + (dx < 0 ? 1 : -1));
    }
    return;
  }

  // 横屏：简单判断
  gesture = 'idle';
  if (Math.abs(dx) > Math.abs(dy) && Math.abs(dx) > 80) {
    e.preventDefault();
    if (dx < 0 && (window as any).__pipeAdvance && (window as any).__pipeAdvance()) return;
    go(idx + (dx < 0 ? 1 : -1));
  }
}

// ============ 初始化入口 ============

/**
 * 初始化导航系统
 *
 * 应在 DOM ready 后调用（Astro 的 script 标签默认在 </body> 前执行，
 * 或使用 DOMContentLoaded 确保安全）。
 */
export function initNavigation(): void {
  deck   = document.getElementById('deck')! as HTMLElement;
  slides = deck.querySelectorAll<HTMLElement>('.slide');
  nav    = document.getElementById('nav')! as HTMLElement;
  total  = slides.length;

  // 渲染导航点
  renderDots();

  // 注册事件
  window.addEventListener('keydown',    onKeydown);
  window.addEventListener('wheel',      onWheel,      { passive: false });
  window.addEventListener('touchstart', onTouchStart, { passive: true  });
  window.addEventListener('touchmove',  onTouchMove,  { passive: false });
  window.addEventListener('touchend',   onTouchEnd,   { passive: false });

  // resize 时修正布局（横竖屏切换）
  let resizeTO: ReturnType<typeof setTimeout> | null = null;
  window.addEventListener('resize', () => {
    if (resizeTO !== null) clearTimeout(resizeTO);
    resizeTO = setTimeout(() => go(idx, true), 120);
  });

  // 暴露到 window 供 overview.ts 跳转
  (window as any).__go = go;

  // 初始跳到第 0 页（force=true 不触发动画，animation.ts 初始化后补播）
  go(0, true);
}
