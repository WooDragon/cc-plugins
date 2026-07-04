// dark-ink-classic.glsl — ink-classic 主题暗色背景
// 适用：decks/maas、decks/maas-sales（早期版本）
// 风格：Holographic Dispersion（全息色散 · 钛金暗流）
//       彩虹微扰 + 鼠标径向涟漪
// Palette 特征：a=vec3(0.12,0.12,0.13)，接近纯黑调性
precision highp float;

uniform vec2  u_resolution;
uniform float u_time;
uniform vec2  u_mouse;

// 余弦调色板函数（Inigo Quilez）
vec3 palette(float t, vec3 a, vec3 b, vec3 c, vec3 d) {
  return a + b * cos(6.28318 * (c * t + d));
}

void main() {
  vec2 uv = gl_FragCoord.xy / u_resolution.xy;
  vec2 p  = uv * 2.0 - 1.0;
  p.x *= u_resolution.x / u_resolution.y;

  // 鼠标径向涟漪
  vec2  m  = u_mouse * 2.0 - 1.0;
  m.x *= u_resolution.x / u_resolution.y;
  float md = length(p - m);
  float mr = sin(md * 15.0 - u_time * 4.0) * exp(-md * 3.0);
  p += mr * 0.08;

  vec2 p0 = p;

  // 正弦叠加扭曲
  for (float i = 1.0; i < 4.0; i++) {
    p.x += 0.1 / i * sin(i * 3.0 * p.y + u_time * 0.4) + 0.05;
    p.y += 0.1 / i * cos(i * 2.0 * p.x + u_time * 0.3) - 0.05;
  }

  float r   = length(p);
  float ang = atan(p.y, p.x);

  // ink-classic 暗色 palette（钛金/暗流色调）
  vec3 a = vec3(0.12, 0.12, 0.13);
  vec3 b = vec3(0.03, 0.04, 0.05);
  vec3 c = vec3(1.0,  1.0,  1.0);
  vec3 d = vec3(0.1,  0.2,  0.4);

  vec3 col = palette(r * 1.5 + p0.x * 0.5 + u_time * 0.1, a, b, c, d);

  // 全息色散微扰
  float disp = sin(r * 25.0 - u_time * 1.5 + ang * 2.0) * 0.5 + 0.5;
  col += vec3(disp * 0.015, disp * 0.01, disp * 0.02);

  // 高光点
  float hi = pow(sin(p.x * 4.0 + p.y * 3.0 + u_time) * 0.5 + 0.5, 8.0);
  col += hi * 0.08;

  // 与基色混合（压暗）
  vec3 base = vec3(0.05, 0.05, 0.06);
  col = mix(base, col, 0.85);

  gl_FragColor = vec4(col, 1.0);
}
