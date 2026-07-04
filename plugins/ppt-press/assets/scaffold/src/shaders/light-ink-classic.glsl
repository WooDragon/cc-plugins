// light-ink-classic.glsl — ink-classic 主题亮色背景
// 适用：decks/maas
// 风格：Spiral Vortex（旋转涡流 · 银色珍珠）
//       domain-warp FBM 流动，无中心旋涡，鼠标轻微推拽
// Palette 特征：silverDark=vec3(0.86,0.85,0.84)，暖灰银
precision highp float;

uniform vec2  u_resolution;
uniform float u_time;
uniform vec2  u_mouse;

// 伪随机哈希
float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// 平滑噪声
float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  float a = hash(i);
  float b = hash(i + vec2(1.0, 0.0));
  float c = hash(i + vec2(0.0, 1.0));
  float d = hash(i + vec2(1.0, 1.0));
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

// 分形布朗运动（5 阶）
float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  mat2 m = mat2(0.80, 0.60, -0.60, 0.80);
  for (int i = 0; i < 5; i++) {
    v += a * noise(p);
    p  = m * p * 2.02;
    a *= 0.5;
  }
  return v;
}

void main() {
  vec2 uv = gl_FragCoord.xy / u_resolution.xy;
  vec2 p  = uv;
  p.x *= u_resolution.x / u_resolution.y;

  // 鼠标轻微推拽
  vec2  m  = u_mouse;
  m.x *= u_resolution.x / u_resolution.y;
  vec2  mDelta = p - m;
  float dl     = length(mDelta);
  p += normalize(mDelta + vec2(0.0001)) * exp(-dl * 5.0) * 0.03;

  // Domain warp（双重扭曲）
  vec2 q = vec2(
    fbm(p * 1.8 + u_time * 0.07),
    fbm(p * 1.8 + vec2(5.2, 1.3) + u_time * 0.06)
  );
  vec2 r = vec2(
    fbm(p * 2.0 + q * 1.3 + vec2(1.7, 9.2) + u_time * 0.05),
    fbm(p * 2.0 + q * 1.3 + vec2(8.3, 2.8) + u_time * 0.04)
  );
  float f = fbm(p * 2.2 + r * 1.5);

  // ink-classic 亮色 palette（暖灰银 + 米白）
  vec3 silverDark = vec3(0.86, 0.85, 0.84);
  vec3 paper      = vec3(0.955, 0.945, 0.925);
  vec3 col = mix(silverDark, paper, f);

  // 微弱彩虹漂移（淡紫 + 淡蓝）
  float ph = r.x * 2.2 + u_time * 0.35;
  col += vec3(0.78, 0.62, 0.92) * sin(ph) * 0.055;
  col += vec3(0.55, 0.72, 0.95) * sin(ph * 0.8 + 2.0) * 0.05;

  // 高光提亮
  float hl = smoothstep(0.48, 0.92, f);
  col += hl * 0.06;

  gl_FragColor = vec4(col, 1.0);
}
