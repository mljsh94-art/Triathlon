AM_SRCS := riscv/npc/start.S \
           riscv/npc/trm.c \
           riscv/npc/ioe.c \
           riscv/npc/timer.c \
           riscv/npc/input.c \
           riscv/npc/cte.c \
           riscv/npc/trap.S \
           platform/dummy/vme.c \
           platform/dummy/mpe.c

CFLAGS    += -fdata-sections -ffunction-sections
LDSCRIPTS += $(AM_HOME)/scripts/linker.ld
LDFLAGS   += --defsym=_pmem_start=0x80000000 --defsym=_entry_offset=0x0
LDFLAGS   += --gc-sections -e _start


MAINARGS_MAX_LEN = 64
MAINARGS_PLACEHOLDER = The insert-arg rule in Makefile will insert mainargs here.
CFLAGS += -DMAINARGS_MAX_LEN=$(MAINARGS_MAX_LEN) -DMAINARGS_PLACEHOLDER=\""$(MAINARGS_PLACEHOLDER)"\"
NPC_DIFFTEST ?=
NPC_HOME := $(abspath $(AM_HOME)/../npc)
PYTHON ?= python3

insert-arg: image
	@$(PYTHON) $(AM_HOME)/tools/insert-arg.py $(IMAGE).bin $(MAINARGS_MAX_LEN) "$(MAINARGS_PLACEHOLDER)" "$(mainargs)"

image: image-dep
	@$(OBJDUMP) -d $(IMAGE).elf > $(IMAGE).txt
	@echo + OBJCOPY "->" $(IMAGE_REL).bin
	@$(OBJCOPY) -S --set-section-flags .bss=alloc,contents -O binary $(IMAGE).elf $(IMAGE).bin

run: insert-arg
	@echo "[npc.mk] AM_HOME=$(AM_HOME) NPC_HOME=$(NPC_HOME)"
	$(MAKE) -C $(NPC_HOME) sim IMG=$(IMAGE).bin DIFFTEST="$(NPC_DIFFTEST)"
gdb: insert-arg
	@echo "[npc.mk] AM_HOME=$(AM_HOME) NPC_HOME=$(NPC_HOME)"
	$(MAKE) -C $(NPC_HOME) gdb IMG=$(IMAGE).bin DIFFTEST="$(NPC_DIFFTEST)"
.PHONY: insert-arg
