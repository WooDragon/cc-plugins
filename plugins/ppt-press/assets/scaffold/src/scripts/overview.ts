/**
 * overview.ts — ESC 索引缩略图网格
 *
 * 职责：
 *   - ESC 键切换全屏索引视图（竖屏下禁用）
 *   - 4 列缩略图网格，每格缩放克隆当前 slide DOM
 *   - 点击格子后关闭 overview 并跳转到对应页
 *
 * 依赖 window.__go(n) （由 navigation.ts 暴露）
 */

const isPortrait = (): boolean =>
  window.matchMedia('(max-width:600px) and (orientation:portrait)').matches;

/** 从导航点推断当前活跃页索引 */
function activeIdx(): number {
  const dots = document.querySelectorAll<HTMLElement>('#nav .dot');
  for (let i = 0; i < dots.length; i++) {
    if (dots[i].classList.contains('active')) return i;
  }
  return 0;
}

export function initOverview(): void {
  const deck   = document.getElementById('deck')!;
  const slides  = deck.querySelectorAll<HTMLElement>('.slide');
  const total   = slides.length;

  // 创建 overlay 容器
  const ov = document.createElement('div');
  ov.id = 'overview';
  ov.style.cssText = [
    'position:fixed', 'inset:0', 'z-index:100',
    'background:rgba(var(--ink-rgb),.92)',
    'backdrop-filter:blur(12px)',
    'display:none', 'overflow-y:auto', 'padding:4vh 4vw',
  ].join(';');
  document.body.appendChild(ov);

  let overviewOn = false;

  function buildOverview(): void {
    const idx = activeIdx();
    ov.innerHTML = '';
    const grid = document.createElement('div');
    grid.style.cssText = [
      'display:grid',
      'grid-template-columns:repeat(4,1fr)',
      'gap:2vh 1.6vw',
      'max-width:90vw',
      'margin:0 auto',
    ].join(';');

    slides.forEach((s, i) => {
      const card = document.createElement('div');
      const isActive = i === idx;
      const borderColor = isActive
        ? 'rgba(var(--paper-rgb),.8)'
        : 'rgba(var(--paper-rgb),.15)';
      card.style.cssText = [
        'cursor:pointer', 'border-radius:6px', 'overflow:hidden',
        `border:2px solid ${borderColor}`, 'transition:border-color .2s',
      ].join(';');
      card.onmouseenter = () => {
        card.style.borderColor = 'rgba(var(--paper-rgb),.6)';
      };
      card.onmouseleave = () => {
        card.style.borderColor = isActive
          ? 'rgba(var(--paper-rgb),.8)'
          : 'rgba(var(--paper-rgb),.15)';
      };

      const bg = s.classList.contains('light') ? 'var(--paper)' : 'var(--ink)';
      const wrap = document.createElement('div');
      wrap.style.cssText = [
        'width:100%', 'aspect-ratio:16/9', 'overflow:hidden',
        'position:relative', 'pointer-events:none', `background:${bg}`,
      ].join(';');

      const clone = s.cloneNode(true) as HTMLElement;
      const scale = 1 / 4.5;
      clone.style.cssText = [
        'width:100vw', 'height:100vh',
        `transform:scale(${scale})`, 'transform-origin:top left',
        'position:absolute', 'top:0', 'left:0', 'pointer-events:none',
      ].join(';');
      wrap.appendChild(clone);

      const label = document.createElement('div');
      label.style.cssText = [
        'padding:6px 10px',
        'font-family:var(--mono)',
        'font-size:11px', 'letter-spacing:.18em',
        'text-transform:uppercase',
        'color:var(--paper)', 'opacity:.7',
      ].join(';');
      label.textContent = `${i + 1} / ${total}`;

      card.appendChild(wrap);
      card.appendChild(label);
      card.onclick = () => {
        toggleOverview();
        (window as any).__go?.(i);
      };
      grid.appendChild(card);
    });

    ov.appendChild(grid);
  }

  function toggleOverview(): void {
    if (isPortrait()) return;
    overviewOn = !overviewOn;
    if (overviewOn) {
      buildOverview();
      ov.style.display = 'block';
    } else {
      ov.style.display = 'none';
    }
  }

  window.addEventListener('keydown', (e: KeyboardEvent) => {
    if (e.key === 'Escape') {
      e.preventDefault();
      toggleOverview();
    }
  });
}
