#include <am.h>
#include <klib-macros.h>

void __am_timer_init();
void __am_timer_rtc(AM_TIMER_RTC_T *);
void __am_timer_uptime(AM_TIMER_UPTIME_T *);

#define UART_BASE 0x10000000L
#define UART_RB   0
#define UART_TH   0
#define UART_LS   5
#define UART_LS_DR   0x01
#define UART_LS_THRE 0x20
#define PS2_BASE 0x10011000L
#define VGA_FB_BASE 0x21000000L
#define VGA_WIDTH   640
#define VGA_HEIGHT  480

static void __am_timer_config(AM_TIMER_CONFIG_T *cfg) {
  cfg->present = true;
  cfg->has_rtc = true;
}

static inline void outb(uintptr_t addr, uint8_t data) {
  *(volatile uint8_t *)addr = data;
}

static inline uint8_t inb(uintptr_t addr) {
  return *(volatile uint8_t *)addr;
}

static char uart_getch() {
  if ((inb(UART_BASE + UART_LS) & UART_LS_DR) == 0) {
    return (char)-1;
  }
  return inb(UART_BASE + UART_RB);
}

static void __am_uart_config(AM_UART_CONFIG_T *cfg) {
  cfg->present = true;
}

static void __am_uart_tx(AM_UART_TX_T *uart) {
  while ((inb(UART_BASE + UART_LS) & UART_LS_THRE) == 0);
  outb(UART_BASE + UART_TH, uart->data);
}

static void __am_uart_rx(AM_UART_RX_T *uart) {
  uart->data = uart_getch();
}

static void __am_input_config(AM_INPUT_CONFIG_T *cfg) {
  cfg->present = true;
}

static void __am_gpu_config(AM_GPU_CONFIG_T *cfg) {
  cfg->present = true;
  cfg->has_accel = false;
  cfg->width = VGA_WIDTH;
  cfg->height = VGA_HEIGHT;
  cfg->vmemsz = VGA_WIDTH * VGA_HEIGHT * sizeof(uint32_t);
}

static void __am_gpu_status(AM_GPU_STATUS_T *status) {
  status->ready = true;
}

static void __am_gpu_fbdraw(AM_GPU_FBDRAW_T *ctl) {
  uint32_t *pixels = (uint32_t *)ctl->pixels;
  volatile uint32_t *fb = (volatile uint32_t *)VGA_FB_BASE;

  if (pixels == NULL || ctl->w <= 0 || ctl->h <= 0) {
    return;
  }

  for (int y = 0; y < ctl->h; y++) {
    int dst_y = ctl->y + y;
    if (dst_y < 0 || dst_y >= VGA_HEIGHT) {
      continue;
    }
    for (int x = 0; x < ctl->w; x++) {
      int dst_x = ctl->x + x;
      if (dst_x < 0 || dst_x >= VGA_WIDTH) {
        continue;
      }
      fb[dst_y * VGA_WIDTH + dst_x] = pixels[y * ctl->w + x];
    }
  }
}

static int key_from_char(char ch) {
  switch (ch) {
    case 0x1b: return AM_KEY_ESCAPE;
    case '\r':
    case '\n': return AM_KEY_RETURN;
    case '\b':
    case 0x7f: return AM_KEY_BACKSPACE;
    case '\t': return AM_KEY_TAB;
    case ' ': return AM_KEY_SPACE;
    case '`': return AM_KEY_GRAVE;
    case '-': return AM_KEY_MINUS;
    case '=': return AM_KEY_EQUALS;
    case '[': return AM_KEY_LEFTBRACKET;
    case ']': return AM_KEY_RIGHTBRACKET;
    case '\\': return AM_KEY_BACKSLASH;
    case ';': return AM_KEY_SEMICOLON;
    case '\'': return AM_KEY_APOSTROPHE;
    case ',': return AM_KEY_COMMA;
    case '.': return AM_KEY_PERIOD;
    case '/': return AM_KEY_SLASH;
    case '0': return AM_KEY_0;
    case '1': return AM_KEY_1;
    case '2': return AM_KEY_2;
    case '3': return AM_KEY_3;
    case '4': return AM_KEY_4;
    case '5': return AM_KEY_5;
    case '6': return AM_KEY_6;
    case '7': return AM_KEY_7;
    case '8': return AM_KEY_8;
    case '9': return AM_KEY_9;
    case 'a':
    case 'A': return AM_KEY_A;
    case 'b':
    case 'B': return AM_KEY_B;
    case 'c':
    case 'C': return AM_KEY_C;
    case 'd':
    case 'D': return AM_KEY_D;
    case 'e':
    case 'E': return AM_KEY_E;
    case 'f':
    case 'F': return AM_KEY_F;
    case 'g':
    case 'G': return AM_KEY_G;
    case 'h':
    case 'H': return AM_KEY_H;
    case 'i':
    case 'I': return AM_KEY_I;
    case 'j':
    case 'J': return AM_KEY_J;
    case 'k':
    case 'K': return AM_KEY_K;
    case 'l':
    case 'L': return AM_KEY_L;
    case 'm':
    case 'M': return AM_KEY_M;
    case 'n':
    case 'N': return AM_KEY_N;
    case 'o':
    case 'O': return AM_KEY_O;
    case 'p':
    case 'P': return AM_KEY_P;
    case 'q':
    case 'Q': return AM_KEY_Q;
    case 'r':
    case 'R': return AM_KEY_R;
    case 's':
    case 'S': return AM_KEY_S;
    case 't':
    case 'T': return AM_KEY_T;
    case 'u':
    case 'U': return AM_KEY_U;
    case 'v':
    case 'V': return AM_KEY_V;
    case 'w':
    case 'W': return AM_KEY_W;
    case 'x':
    case 'X': return AM_KEY_X;
    case 'y':
    case 'Y': return AM_KEY_Y;
    case 'z':
    case 'Z': return AM_KEY_Z;
    default:
      return AM_KEY_NONE;
  }
}

static int esc_state = 0;
static bool ps2_extended = false;
static bool ps2_released = false;

static int key_from_ps2(uint8_t scancode, bool extended) {
  if (extended) {
    switch (scancode) {
      case 0x11: return AM_KEY_RALT;
      case 0x14: return AM_KEY_RCTRL;
      case 0x1f: return AM_KEY_APPLICATION;
      case 0x6b: return AM_KEY_LEFT;
      case 0x69: return AM_KEY_END;
      case 0x6c: return AM_KEY_HOME;
      case 0x70: return AM_KEY_INSERT;
      case 0x71: return AM_KEY_DELETE;
      case 0x72: return AM_KEY_DOWN;
      case 0x74: return AM_KEY_RIGHT;
      case 0x75: return AM_KEY_UP;
      case 0x7a: return AM_KEY_PAGEDOWN;
      case 0x7d: return AM_KEY_PAGEUP;
      default: return AM_KEY_NONE;
    }
  }

  switch (scancode) {
    case 0x76: return AM_KEY_ESCAPE;
    case 0x05: return AM_KEY_F1;
    case 0x06: return AM_KEY_F2;
    case 0x04: return AM_KEY_F3;
    case 0x0c: return AM_KEY_F4;
    case 0x03: return AM_KEY_F5;
    case 0x0b: return AM_KEY_F6;
    case 0x83: return AM_KEY_F7;
    case 0x0a: return AM_KEY_F8;
    case 0x01: return AM_KEY_F9;
    case 0x09: return AM_KEY_F10;
    case 0x78: return AM_KEY_F11;
    case 0x07: return AM_KEY_F12;
    case 0x0e: return AM_KEY_GRAVE;
    case 0x16: return AM_KEY_1;
    case 0x1e: return AM_KEY_2;
    case 0x26: return AM_KEY_3;
    case 0x25: return AM_KEY_4;
    case 0x2e: return AM_KEY_5;
    case 0x36: return AM_KEY_6;
    case 0x3d: return AM_KEY_7;
    case 0x3e: return AM_KEY_8;
    case 0x46: return AM_KEY_9;
    case 0x45: return AM_KEY_0;
    case 0x4e: return AM_KEY_MINUS;
    case 0x55: return AM_KEY_EQUALS;
    case 0x66: return AM_KEY_BACKSPACE;
    case 0x0d: return AM_KEY_TAB;
    case 0x15: return AM_KEY_Q;
    case 0x1d: return AM_KEY_W;
    case 0x24: return AM_KEY_E;
    case 0x2d: return AM_KEY_R;
    case 0x2c: return AM_KEY_T;
    case 0x35: return AM_KEY_Y;
    case 0x3c: return AM_KEY_U;
    case 0x43: return AM_KEY_I;
    case 0x44: return AM_KEY_O;
    case 0x4d: return AM_KEY_P;
    case 0x54: return AM_KEY_LEFTBRACKET;
    case 0x5b: return AM_KEY_RIGHTBRACKET;
    case 0x5d: return AM_KEY_BACKSLASH;
    case 0x58: return AM_KEY_CAPSLOCK;
    case 0x1c: return AM_KEY_A;
    case 0x1b: return AM_KEY_S;
    case 0x23: return AM_KEY_D;
    case 0x2b: return AM_KEY_F;
    case 0x34: return AM_KEY_G;
    case 0x33: return AM_KEY_H;
    case 0x3b: return AM_KEY_J;
    case 0x42: return AM_KEY_K;
    case 0x4b: return AM_KEY_L;
    case 0x4c: return AM_KEY_SEMICOLON;
    case 0x52: return AM_KEY_APOSTROPHE;
    case 0x5a: return AM_KEY_RETURN;
    case 0x12: return AM_KEY_LSHIFT;
    case 0x1a: return AM_KEY_Z;
    case 0x22: return AM_KEY_X;
    case 0x21: return AM_KEY_C;
    case 0x2a: return AM_KEY_V;
    case 0x32: return AM_KEY_B;
    case 0x31: return AM_KEY_N;
    case 0x3a: return AM_KEY_M;
    case 0x41: return AM_KEY_COMMA;
    case 0x49: return AM_KEY_PERIOD;
    case 0x4a: return AM_KEY_SLASH;
    case 0x59: return AM_KEY_RSHIFT;
    case 0x14: return AM_KEY_LCTRL;
    case 0x11: return AM_KEY_LALT;
    case 0x29: return AM_KEY_SPACE;
    default: return AM_KEY_NONE;
  }
}

static void __am_input_keybrd(AM_INPUT_KEYBRD_T *kbd) {
  int key = AM_KEY_NONE;
  uint8_t ps2_code = inb(PS2_BASE);

  if (ps2_code != 0) {
    if (ps2_code == 0xe0) {
      ps2_extended = true;
      kbd->keydown = false;
      kbd->keycode = AM_KEY_NONE;
      return;
    }
    if (ps2_code == 0xf0) {
      ps2_released = true;
      kbd->keydown = false;
      kbd->keycode = AM_KEY_NONE;
      return;
    }

    key = key_from_ps2(ps2_code, ps2_extended);
    kbd->keydown = !ps2_released;
    kbd->keycode = key;
    ps2_extended = false;
    ps2_released = false;
    return;
  }

  char ch = uart_getch();

  if (ch == (char)-1) {
    kbd->keydown = false;
    kbd->keycode = AM_KEY_NONE;
    return;
  }

  if (esc_state == 1) {
    if (ch == '[') {
      esc_state = 2;
      kbd->keydown = false;
      kbd->keycode = AM_KEY_NONE;
      return;
    }
    esc_state = 0;
    key = AM_KEY_ESCAPE;
  } else if (esc_state == 2) {
    switch (ch) {
      case 'A': key = AM_KEY_UP; break;
      case 'B': key = AM_KEY_DOWN; break;
      case 'C': key = AM_KEY_RIGHT; break;
      case 'D': key = AM_KEY_LEFT; break;
      default: key = AM_KEY_NONE; break;
    }
    esc_state = 0;
  } else if (ch == 0x1b) {
    esc_state = 1;
    kbd->keydown = false;
    kbd->keycode = AM_KEY_NONE;
    return;
  } else {
    key = key_from_char(ch);
  }

  if (key == AM_KEY_NONE) {
    kbd->keydown = false;
    kbd->keycode = AM_KEY_NONE;
    return;
  }

  kbd->keydown = true;
  kbd->keycode = key;
}

static void fail(void *buf) {
  halt(1);
}

bool ioe_init() {
  __am_timer_init();
  return true;
}

void ioe_read(int reg, void *buf) {
  switch (reg) {
    case AM_UART_CONFIG:  __am_uart_config(buf); break;
    case AM_UART_RX:      __am_uart_rx(buf); break;
    case AM_TIMER_CONFIG: __am_timer_config(buf); break;
    case AM_TIMER_RTC:    __am_timer_rtc(buf); break;
    case AM_TIMER_UPTIME: __am_timer_uptime(buf); break;
    case AM_INPUT_CONFIG: __am_input_config(buf); break;
    case AM_INPUT_KEYBRD: __am_input_keybrd(buf); break;
    case AM_GPU_CONFIG:   __am_gpu_config(buf); break;
    case AM_GPU_STATUS:   __am_gpu_status(buf); break;
    default: fail(buf); break;
  }
}

void ioe_write(int reg, void *buf) {
  switch (reg) {
    case AM_UART_TX:     __am_uart_tx(buf); break;
    case AM_GPU_FBDRAW:  __am_gpu_fbdraw(buf); break;
    default: fail(buf); break;
  }
}
