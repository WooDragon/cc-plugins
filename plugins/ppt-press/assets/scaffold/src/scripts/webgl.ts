/**
 * webgl.ts — WebGL 双背景引导器
 *
 * 负责：
 *   - 从 DOM 读取 <script id="shader-dark"> / <script id="shader-light"> 获取 fragment shader 源码
 *   - 编译顶点着色器 + fragment 着色器，链接程序
 *   - 绑定覆盖全屏的四边形（quad）
 *   - RAF 循环更新 u_time uniform
 *   - mousemove / touchmove 更新 u_mouse uniform（归一化坐标）
 *
 * 使用方式：
 *   1. 在 HTML 中放置带内联 GLSL 的 <script> 标签：
 *      <script id="shader-dark"  type="x-shader/x-fragment">...GLSL...</script>
 *      <script id="shader-light" type="x-shader/x-fragment">...GLSL...</script>
 *   2. 准备两个 canvas：<canvas id="bg-dark" class="bg"> <canvas id="bg-light" class="bg">
 *   3. 调用 bootGL(darkCanvas, lightCanvas)
 */

/** 顶点着色器（固定，所有 deck 共用） */
const VERTEX_SHADER_SRC =
  `attribute vec2 position;void main(){gl_Position=vec4(position,0.0,1.0);}`;

/** 全屏四边形顶点数据（两个三角形，覆盖 NDC [-1,1]x[-1,1]） */
const QUAD_VERTICES = new Float32Array([
  -1, -1,
   1, -1,
  -1,  1,
  -1,  1,
   1, -1,
   1,  1,
]);

/**
 * 编译单个着色器
 * @param gl    WebGL 上下文
 * @param type  VERTEX_SHADER 或 FRAGMENT_SHADER
 * @param src   GLSL 源码字符串
 * @returns     编译好的 WebGLShader
 */
function compileShader(
  gl: WebGLRenderingContext,
  type: number,
  src: string
): WebGLShader {
  const shader = gl.createShader(type)!;
  gl.shaderSource(shader, src);
  gl.compileShader(shader);
  return shader;
}

/**
 * 为单个 canvas 创建 WebGL 渲染函数
 *
 * @param canvas  目标 canvas 元素
 * @param fsSrc   fragment shader GLSL 源码
 * @returns       渲染函数 (tSec: number) => boolean，RAF 每帧调用；
 *                若 WebGL 不支持则返回始终返回 false 的空函数
 */
function createRenderer(
  canvas: HTMLCanvasElement,
  fsSrc: string
): (tSec: number) => boolean {
  const gl = canvas.getContext('webgl', { alpha: false, antialias: true });
  if (!gl) return () => false;

  // 编译、链接着色器程序
  const prog = gl.createProgram()!;
  gl.attachShader(prog, compileShader(gl, gl.VERTEX_SHADER, VERTEX_SHADER_SRC));
  gl.attachShader(prog, compileShader(gl, gl.FRAGMENT_SHADER, fsSrc));
  gl.linkProgram(prog);
  gl.useProgram(prog);

  // 上传四边形顶点
  const buf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER, QUAD_VERTICES, gl.STATIC_DRAW);

  // 绑定 position attribute
  const posLoc = gl.getAttribLocation(prog, 'position');
  gl.enableVertexAttribArray(posLoc);
  gl.vertexAttribPointer(posLoc, 2, gl.FLOAT, false, 0, 0);

  // 获取 uniform 位置
  const lRes: WebGLUniformLocation | null = gl.getUniformLocation(prog, 'u_resolution');
  const lT:   WebGLUniformLocation | null = gl.getUniformLocation(prog, 'u_time');
  const lM:   WebGLUniformLocation | null = gl.getUniformLocation(prog, 'u_mouse');

  /** 处理 canvas 尺寸变化 */
  function resize(): void {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width  = window.innerWidth  * dpr;
    canvas.height = window.innerHeight * dpr;
    gl.viewport(0, 0, canvas.width, canvas.height);
  }

  window.addEventListener('resize', resize);
  resize();

  // 返回每帧渲染函数（由外部 RAF 循环调用）
  return (tSec: number): boolean => {
    gl.uniform2f(lRes, canvas.width, canvas.height);
    gl.uniform1f(lT, tSec);
    gl.uniform2f(lM, mouse.x, 1 - mouse.y);
    gl.drawArrays(gl.TRIANGLES, 0, 6);
    return true;
  };
}

/** 当前鼠标/触摸位置（归一化坐标，默认居中） */
const mouse = { x: 0.5, y: 0.5 };

/**
 * 启动 WebGL 双背景
 *
 * 从 DOM 中的 <script id="shader-dark" type="x-shader/x-fragment"> 和
 * <script id="shader-light" type="x-shader/x-fragment"> 读取 GLSL 源码，
 * 然后为两个 canvas 各自创建渲染器并启动 RAF 循环。
 *
 * @param dark   id="bg-dark"  的 canvas 元素
 * @param light  id="bg-light" 的 canvas 元素
 */
export function bootGL(
  dark: HTMLCanvasElement,
  light: HTMLCanvasElement
): void {
  // 从 DOM 读取着色器源码
  const darkSrc  = document.getElementById('shader-dark')?.textContent  ?? '';
  const lightSrc = document.getElementById('shader-light')?.textContent ?? '';

  if (!darkSrc || !lightSrc) {
    console.warn('[webgl] shader script tags not found — WebGL backgrounds disabled');
    return;
  }

  // 注册鼠标事件
  window.addEventListener('mousemove', (e: MouseEvent) => {
    mouse.x = e.clientX / window.innerWidth;
    mouse.y = e.clientY / window.innerHeight;
  });

  window.addEventListener('touchmove', (e: TouchEvent) => {
    const t = e.touches[0];
    mouse.x = t.clientX / window.innerWidth;
    mouse.y = t.clientY / window.innerHeight;
  }, { passive: true });

  // 创建渲染函数
  const renderDark  = createRenderer(dark, darkSrc);
  const renderLight = createRenderer(light, lightSrc);

  const t0 = Date.now();

  // RAF 循环
  (function loop(): void {
    const tSec = (Date.now() - t0) / 1000;
    renderDark(tSec);
    renderLight(tSec);
    requestAnimationFrame(loop);
  })();
}
