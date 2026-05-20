#include <am.h>
#include <nemu.h>
#include <klib.h>

#define SYNC_ADDR (VGACTL_ADDR + 4)

void __am_gpu_init() {
 /* uint32_t config = inl(VGACTL_ADDR);
  uint32_t width = config >> 16;
  uint32_t height = config & 0xffff;
  uint32_t *fb = (uint32_t*)(uintptr_t)FB_ADDR;
  for (int i = 0; i < width * height; i++) {
    fb[i] = i;
  }
  outl(SYNC_ADDR, 1);  */
}

void __am_gpu_config(AM_GPU_CONFIG_T *cfg) {
  uint32_t config = inl(VGACTL_ADDR);
  uint32_t width = config >> 16;
  uint32_t height = config & 0xffff;
  *cfg = (AM_GPU_CONFIG_T) {
    .present = true, .has_accel = false,
    .width = width, .height = height,
    .vmemsz = width * height * sizeof(uint32_t)
  };
}

void __am_gpu_fbdraw(AM_GPU_FBDRAW_T *ctl) {
 uint32_t screen_w = inl(VGACTL_ADDR) >> 16;
  
  // 2. 准备指针
  uint32_t *fb = (uint32_t *)(uintptr_t)FB_ADDR;
  uint32_t *pixels = (uint32_t *)ctl->pixels;

  // 3. 将 pixels 中的像素按行拷贝到显存 (FB) 的指定坐标 (x, y)
  int x = ctl->x;
  int y = ctl->y;
  int w = ctl->w;
  int h = ctl->h;

  for (int i = 0; i < h; i++) {
    for (int j = 0; j < w; j++) {
      // 目标显存的一维索引：(起始Y + 局部Y) * 屏幕总宽 + (起始X + 局部X)
      // 源像素数组的一维索引：局部Y * 色块宽度 + 局部X
      fb[(y + i) * screen_w + (x + j)] = pixels[i * w + j];
    }
  }

  // 4. 同步信号
  if (ctl->sync) {
    outl(SYNC_ADDR, 1);
  }
}

void __am_gpu_status(AM_GPU_STATUS_T *status) {
  status->ready = true;
}
void __am_gpu_memcpy(AM_GPU_MEMCPY_T *mem) {
  uint32_t screen_wh = inl(VGACTL_ADDR);
  uint32_t w = screen_wh >> 16;
  uint32_t h = screen_wh & 0xffff;
  uint32_t fb_size = w * h * sizeof(uint32_t); // 算出现实中真实的显存大小

  uint8_t *fb = (uint8_t *)(uintptr_t)FB_ADDR;

  // 安全检查：如果偏移量已经超了，直接返回
  if (mem->dest >= fb_size) return;

  // 安全检查：如果拷贝长度超了，只拷贝到显存结尾
  size_t copy_size = mem->size;
  if (mem->dest + copy_size > fb_size) {
    copy_size = fb_size - mem->dest;
  }

  memcpy(fb + mem->dest, mem->src, copy_size);
}
void __am_gpu_render(AM_GPU_RENDER_T *render) {
  // 在这个简单的模拟器里，渲染通常伴随着同步刷新
  // 我们可以直接触发一次 SDL 刷新，或者暂时留空
  outl(VGACTL_ADDR + 4, 1); 
}