TOPNAME ?= tb_triathlon
NXDC_FILES = constr/top.nxdc
INC_PATH ?= vsrc vsrc/include
NPC_HOME ?= $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TRIATHLON_HOME ?= $(abspath $(NPC_HOME)/..)

BUILD_DIR = ./build
OBJ_DIR = $(BUILD_DIR)/obj_dir
BIN = $(BUILD_DIR)/$(TOPNAME)

ifeq ($(ASSERT),1)
  VL_ASSERT_FLAG := --assert
  ASSERT_CFG := $(OBJ_DIR)/.assert_mode_1
else
  VL_ASSERT_FLAG := --noassert
  ASSERT_CFG := $(OBJ_DIR)/.assert_mode_0
endif

VERILATOR = verilator
VERILATOR_CFLAGS += -MMD --build -cc \
				-O3 -j $(shell nproc) --threads 2 \
				--x-assign fast --x-initial fast $(VL_ASSERT_FLAG) -sv \
				--output-split 30000 --output-split-cfuncs 30000 \
				-MAKEFLAGS OPT_FAST=-O3 \
				-MAKEFLAGS OPT_SLOW=-O3 \
				-MAKEFLAGS OPT_GLOBAL=-O3
VERILATOR_CFLAGS += --Wno-fatal --Wno-WIDTH

default: $(BIN)

LLVM_LIBS := $(shell llvm-config --libs 2>/dev/null)

$(shell mkdir -p $(BUILD_DIR))

# # constraint file
# SRC_AUTO_BIND = $(abspath $(BUILD_DIR)/auto_bind.cpp)
# $(SRC_AUTO_BIND): $(NXDC_FILES)
# 	python3 $(NVBOARD_HOME)/scripts/auto_pin_bind.py $^ $@

# project source

PKG_VSRCS = \
	$(abspath ./vsrc/include/sim_assert.sv) \
	$(abspath ./vsrc/include/config_pkg.sv) \
	$(abspath ./vsrc/include/test_config_pkg.sv) \
	$(abspath ./vsrc/include/build_config_pkg.sv) \
	$(abspath ./vsrc/include/global_config_pkg.sv) \
	$(abspath ./vsrc/include/debug_bus_pkg.sv) \
	$(abspath ./vsrc/include/core_contract_pkg.sv) \
	$(abspath ./vsrc/include/riscv_pkg.sv) \
	$(abspath ./vsrc/include/decode_pkg.sv)

DESIGN_VSRCS = $(shell find $(abspath ./vsrc) \
	-path $(abspath ./vsrc/include) -prune -o \
	-path $(abspath ./vsrc/test) -prune -o \
	\( -name "*.sv" -o -name "*.v" \) -print)

TOP_SV = $(firstword $(wildcard \
	$(abspath ./vsrc/test/$(TOPNAME).sv) \
	$(abspath ./vsrc/$(TOPNAME).sv)))

SIM_MAIN ?= $(firstword $(wildcard \
	$(abspath ./csrc/npc_main.cpp) \
	$(abspath ./csrc/npc_main.cc) \
	$(abspath ./csrc/npc_main.c) \
	$(abspath ./csrc/sim_main.cpp) \
	$(abspath ./csrc/sim_main.cc) \
	$(abspath ./csrc/sim_main.c) \
	$(abspath ./csrc/main.cpp) \
	$(abspath ./csrc/main.cc) \
	$(abspath ./csrc/main.c)))
SIM_SRCS ?= $(sort $(wildcard $(abspath ./csrc/lib/*.cpp)))

VSRCS = $(PKG_VSRCS) $(DESIGN_VSRCS) $(TOP_SV)
CSRCS = $(SIM_MAIN) $(SIM_SRCS) $(SRC_AUTO_BIND)

# # rules for NVBoard
# include $(NVBOARD_HOME)/scripts/nvboard.mk
DIFFTEST_SO ?= $(NPC_HOME)/ref/riscv32-spike-difftest.so
DIFFTEST ?= $(if $(wildcard $(DIFFTEST_SO)),-d $(DIFFTEST_SO),)
SPIKE_REF_LD_PATH := $(NPC_HOME)/ref:$(NPC_HOME)/ref/src/repo/riscv-isa-sim/build

# rules for verilator
IMG ?=
ARGS ?=
NPC_EXE := $(strip $(ARGS) $(DIFFTEST) $(IMG))
INCFLAGS = $(addprefix -I, $(INC_PATH))
CXXFLAGS += $(INCFLAGS) -I$(abspath ./include) -I$(abspath ./csrc/include) -DTOP_NAME="\"V$(TOPNAME)\"" -std=c++17 -O3 -march=native -fno-plt
LDFLAGS += -lreadline -ldl -pie $(LLVM_LIBS)

NEED_CHECKS := $(filter-out clean clean-all help,$(MAKECMDGOALS))
ifneq ($(NEED_CHECKS),)
  ifeq ($(strip $(TOP_SV)),)
    $(error TOPNAME=$(TOPNAME) not found. Expected vsrc/$(TOPNAME).sv or vsrc/test/$(TOPNAME).sv)
  endif
  ifeq ($(strip $(SIM_MAIN)),)
    $(error No simulator main found. Set SIM_MAIN=... or add csrc/npc_main.cpp)
  endif
else ifeq ($(MAKECMDGOALS),)
  ifeq ($(strip $(TOP_SV)),)
    $(error TOPNAME=$(TOPNAME) not found. Expected vsrc/$(TOPNAME).sv or vsrc/test/$(TOPNAME).sv)
  endif
  ifeq ($(strip $(SIM_MAIN)),)
    $(error No simulator main found. Set SIM_MAIN=... or add csrc/npc_main.cpp)
  endif
endif

$(ASSERT_CFG):
	@mkdir -p $(OBJ_DIR)
	@rm -f $(OBJ_DIR)/.assert_mode_0 $(OBJ_DIR)/.assert_mode_1
	@touch $@

$(BIN): $(VSRCS) $(CSRCS) $(NVBOARD_ARCHIVE) $(ASSERT_CFG)
# 	@rm -rf $(OBJ_DIR)
	$(VERILATOR) $(VERILATOR_CFLAGS) \
		--top-module $(TOPNAME) $^ \
		$(addprefix -CFLAGS , $(CXXFLAGS)) $(addprefix -LDFLAGS , $(LDFLAGS)) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BIN))

all: default
	@echo "Write this Makefile by your self."

sim: $(BIN)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	@echo $(INCFLAGS)
	@LD_LIBRARY_PATH="$(SPIKE_REF_LD_PATH):$$LD_LIBRARY_PATH" $^ $(NPC_EXE)

.PHONY: profile-report profile-task profile-baseline profile-index profile-dashboard profile-clean \
	verify-unit verify-difftest verify-assert-programs verify-cover verify-all

verify-unit:
	bash $(abspath ./scripts/subshell/run_assert_unit.sh) $(or $(MODULE),all)

verify-difftest:
	bash $(abspath ./scripts/subshell/run_difftest_suite.sh)

verify-assert-programs:
	bash $(abspath ./scripts/subshell/run_assert_programs.sh)

verify-cover:
	bash $(abspath ./scripts/subshell/run_cover_check.sh)

verify-all:
	$(MAKE) verify-unit MODULE=all
	$(MAKE) verify-difftest
	$(MAKE) verify-assert-programs
	$(MAKE) verify-cover

PROFILE_TOOL_DIR := $(abspath ./tools/profiler)
CROSS_COMPILE ?= riscv64-unknown-elf-
PROFILE_OUT_DIR ?=
PROFILE_ROOT ?= $(abspath ./profile)
PROFILE_TAG ?= latest
PROFILE_DISPLAY_NAME ?=
PROFILE_TAG_DIR ?= $(abspath ./profile/$(PROFILE_TAG))

profile-report:
	@if [ -n "$(PROFILE_OUT_DIR)" ]; then \
		OUT_DIR=$(PROFILE_OUT_DIR) CROSS_COMPILE=$(CROSS_COMPILE) \
			PROFILE_DISPLAY_NAME=$(PROFILE_DISPLAY_NAME) \
			$(PROFILE_TOOL_DIR)/run_profile.sh; \
	else \
		CROSS_COMPILE=$(CROSS_COMPILE) \
			PROFILE_DISPLAY_NAME=$(PROFILE_DISPLAY_NAME) \
			$(PROFILE_TOOL_DIR)/run_profile.sh; \
	fi

profile-task:
	$(MAKE) profile-report CROSS_COMPILE=$(CROSS_COMPILE) \
		PROFILE_OUT_DIR=$(PROFILE_TAG_DIR) PROFILE_DISPLAY_NAME=$(PROFILE_DISPLAY_NAME)

profile-baseline:
	$(MAKE) profile-task CROSS_COMPILE=$(CROSS_COMPILE) PROFILE_TAG=baseline

profile-index:
	python3 $(PROFILE_TOOL_DIR)/build_index.py --profile-root $(PROFILE_ROOT)

profile-dashboard: profile-index
	python3 $(PROFILE_TOOL_DIR)/build_dashboard.py --profile-root $(PROFILE_ROOT)

profile-clean:
	rm -rf $(PROFILE_ROOT)

clean:
	rm -rf $(BUILD_DIR)
