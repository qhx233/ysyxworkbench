#include <am.h>
#include <klib.h>
#include <klib-macros.h>
#include <stdarg.h>

#if !defined(__ISA_NATIVE__) || defined(__NATIVE_USE_KLIB__)


static char *i2a(int n, char *s) {
  if (n == 0) { *s++ = '0'; return s; } // 注意不要返回 s+1，直接返回推进后的 s
  
  unsigned int un; // 使用无符号整数来规避 INT_MIN 取反溢出的问题
  if (n < 0) { 
    *s++ = '-'; 
    un = (unsigned int)(-(n + 1)) + 1; // 绝对安全的取反方式，或者直接写 -(unsigned)n 也可以
  } else {
    un = (unsigned int)n;
  }

  char buf[16];
  int i = 0;
  while (un > 0) {
    buf[i++] = '0' + (un % 10);
    un /= 10;
  }
  while (i > 0) {
    *s++ = buf[--i];
  }
  return s;
}


int printf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  
  // 准备一个临时缓冲区，存放格式化后的字符串
  // 2048 字节对当前的裸机调试来说绝对够用了
  char buf[2048]; 
  int len = vsprintf(buf, fmt, ap);
  va_end(ap);

  // 遍历缓冲区，调用 AM 提供的 putch 输出到串口
  for (int i = 0; i < len; i++) {
    putch(buf[i]);
  }
  
  return len;
}

int vsprintf(char *out, const char *fmt, va_list ap) {
  char *p = out;
  for (const char *f = fmt; *f; f++) {
    if (*f != '%') {
      *p++ = *f;
      continue;
    }
    f++;
    switch (*f) {
      case 'd': { 
        p = i2a(va_arg(ap, int), p); 
        break;
      }
      case 's': { 
        char *s = va_arg(ap, char *); 
        if (s == NULL) s = "(null)"; // 加个防崩溃小保护
        while (*s) *p++ = *s++; 
        break;
      }
      case '%': { 
        *p++ = '%'; 
        break; 
      }
      case 'c': { char c = (char)va_arg(ap, int); *p++ = c; break; }
      default: break;
    }
  }
  *p = '\0';
  return p - out;

}

int sprintf(char *out, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);

  char *p = out;
  for (const char *f = fmt; *f; f++) {
    if (*f != '%') {
      *p++ = *f;
      continue;
    }
    f++;
    switch (*f) {
      case 'd':{ p = i2a(va_arg(ap, int), p); break;}
      case 's': { char *s = va_arg(ap, char *); while (*s) *p++ = *s++; break;}
      case '%': {*p++ = '%'; break; }
      default: break;
    }
  }
  *p = '\0';
  va_end(ap);
  return p - out;
}

int snprintf(char *out, size_t n, const char *fmt, ...) {
  panic("Not implemented");
}

int vsnprintf(char *out, size_t n, const char *fmt, va_list ap) {
  panic("Not implemented");
}

#endif
