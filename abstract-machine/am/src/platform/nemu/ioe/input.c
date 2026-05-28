#include <am.h>
#include <nemu.h>

#define KEYDOWN_MASK 0x8000

void __am_input_keybrd(AM_INPUT_KEYBRD_T *kbd) {
  int data = inl(KBD_ADDR);
  kbd->keydown = data & KEYDOWN_MASK;
  kbd->keycode = kbd->keydown ? data & (KEYDOWN_MASK - 1) : AM_KEY_NONE;
}
