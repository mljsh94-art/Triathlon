ifneq ($(shell command -v riscv64-unknown-elf-gcc 2>/dev/null),)
CROSS_COMPILE ?= riscv64-unknown-elf-
COMMON_CFLAGS += --specs=picolibc.specs
else ifneq ($(shell command -v riscv64-elf-gcc 2>/dev/null),)
CROSS_COMPILE ?= riscv64-elf-
else
CROSS_COMPILE ?= riscv64-linux-gnu-
endif
COMMON_CFLAGS := -fno-pic -march=rv64gc -mcmodel=medany -mstrict-align
CFLAGS        += $(COMMON_CFLAGS) -static
ASFLAGS       += $(COMMON_CFLAGS) -O0
LDFLAGS       += -melf64lriscv

# overwrite ARCH_H defined in $(AM_HOME)/Makefile
ARCH_H := arch/riscv.h
