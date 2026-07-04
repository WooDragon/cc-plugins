// vertex.glsl — 共享顶点着色器
// 所有 PPT deck 共用此顶点着色器，仅将顶点坐标直接传递到裁剪空间。
attribute vec2 position;
void main() {
  gl_Position = vec4(position, 0.0, 1.0);
}
