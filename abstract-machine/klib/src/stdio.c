#include <am.h>
#include <klib.h>
#include <klib-macros.h>
#include <stdarg.h>

#if !defined(__ISA_NATIVE__) || defined(__NATIVE_USE_KLIB__)

#include <stdarg.h>

// 假设已实现的底层字符输出函数

int printf(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);

    int count = 0;
    char buffer[32]; // 足够处理32位整数/十六进制

    while (*fmt) {
        if (*fmt != '%') {
            putch(*fmt);
            count++;
            fmt++;
            continue;
        }

        fmt++; // 跳过 '%'
        switch (*fmt) {
            case 's': {
                char *str = va_arg(args, char *);
                while (*str) {
                    putch(*str);
                    str++;
                    count++;
                }
                break;
            }
            case 'd': {
                int num = va_arg(args, int);
                int len = 0;
                if (num < 0) {
                    putch('-');
                    count++;
                    num = -num;
                }
                do {
                    buffer[len++] = '0' + (num % 10);
                    num /= 10;
                } while (num > 0 && len < sizeof(buffer)-1);
                while (len--) {
                    putch(buffer[len]);
                    count++;
                }
                break;
            }
            case 'x': {
                unsigned int num = va_arg(args, unsigned int);
                const char *hex = "0123456789abcdef";
                int len = 0;
                do {
                    buffer[len++] = hex[num % 16];
                    num /= 16;
                } while (num > 0 && len < sizeof(buffer)-1);
                while (len--) {
                    putch(buffer[len]);
                    count++;
                }
                break;
            }
            case 'c': {
                char c = (char)va_arg(args, int);
                putch(c);
                count++;
                break;
            }
            case '%': {
                putch('%');
                count++;
                break;
            }
            default: {
                putch('%');
                putch(*fmt);
                count += 2;
                break;
            }
        }
        fmt++;
    }
    va_end(args);
    return count;
}

int vsprintf(char *out, const char *fmt, va_list ap) {
  panic("Not implemented");
}

int sprintf(char *out, const char *fmt, ...) {
  // panic("Not implemented");
  va_list args;
  va_start(args, fmt);
  char *p = out;  // {{ 输出指针初始化 }}

  // {{ 主解析循环 }}
  while (*fmt) {
      if (*fmt != '%') {          // {{ 普通字符直接复制 }}
          *p++ = *fmt++;
          continue;
      }

      fmt++; // skip '%'
      switch (*fmt++) {           // {{ 格式解析 }}
          case 's': {             // {{ 字符串处理 }}
              const char *str = va_arg(args, const char*);
              while (*str) *p++ = *str++;  // 逐字符复制直到\0
              break;
          }
          case 'd': {             // {{ 整数处理 }}
              int num = va_arg(args, int);
              if (num < 0) {      // 负数处理
                  *p++ = '-';
                  num = -num;
              }
              char buf[128];       // {{ 数字转字符串缓冲 }}
              char *ptr = buf;
              do {                // 反向生成数字字符
                  *ptr++ = '0' + num % 10;
                  num /= 10;
              } while (num > 0);
              while (ptr != buf) *p++ = *--ptr;  // 正向写入输出
              break;
          }
          default:                // {{ 不支持的格式符 }}
              *p++ = '%';
              p[-1] = fmt[-1];    // 保留原格式字符
      }
  }

  *p = '\0';         // {{ 终止符 }}
  va_end(args);
  return p - out;     // {{ 返回字符计数 }}
}

int snprintf(char *out, size_t n, const char *fmt, ...) {
  panic("Not implemented");
}

int vsnprintf(char *out, size_t n, const char *fmt, va_list ap) {
  panic("Not implemented");
}

#endif
