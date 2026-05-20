include $(AM_HOME)/scripts/isa/riscv.mk
include $(AM_HOME)/scripts/platform/npc.mk
CFLAGS  += -DISA_H=\"riscv/riscv.h\"
COMMON_CFLAGS += -march=rv32ima -mabi=ilp32  # overwrite
LDFLAGS       += -melf32lriscv                              # overwrite
