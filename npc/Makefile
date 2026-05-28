TOPNAME ?= tb_triathlon
NXDC_FILES = constr/top.nxdc
INC_PATH ?= vsrc vsrc/include
NPC_HOME ?= $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TRIATHLON_HOME ?= $(abspath $(NPC_HOME)/..)

VERILATOR = verilator
VL_JOBS ?= $(shell nproc)
VL_THREADS ?= 2
VL_OPTFLAGS ?= -O3 -march=native -fno-plt
VL_OPTLEVEL ?= -O3
VERILATOR_CFLAGS += -MMD --build -cc \
				-O3 -j $(VL_JOBS) --threads $(VL_THREADS) \
				--x-assign fast --x-initial fast --noassert -sv \
				--output-split 30000 --output-split-cfuncs 30000 \
				-MAKEFLAGS OPT_FAST=$(VL_OPTLEVEL) \
				-MAKEFLAGS OPT_SLOW=$(VL_OPTLEVEL) \
				-MAKEFLAGS OPT_GLOBAL=$(VL_OPTLEVEL)
VERILATOR_CFLAGS += --Wno-fatal --Wno-WIDTH

BUILD_DIR = ./build
OBJ_DIR = $(BUILD_DIR)/obj_dir
BIN = $(BUILD_DIR)/$(TOPNAME)

default: $(BIN)

LLVM_LIBS := $(shell llvm-config --libs 2>/dev/null)

$(shell mkdir -p $(BUILD_DIR))

# # constraint file
# SRC_AUTO_BIND = $(abspath $(BUILD_DIR)/auto_bind.cpp)
# $(SRC_AUTO_BIND): $(NXDC_FILES)
# 	python3 $(NVBOARD_HOME)/scripts/auto_pin_bind.py $^ $@

# project source

PKG_VSRCS = \
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
DIFFTEST_SO ?= $(NPC_HOME)/ref/riscv32-nemu-interpreter-so
DIFFTEST ?= $(if $(wildcard $(DIFFTEST_SO)),-d $(DIFFTEST_SO),)

# rules for verilator
IMG ?=
ARGS ?=
NPC_EXE := $(strip $(ARGS) $(DIFFTEST) $(IMG))
INCFLAGS = $(addprefix -I, $(INC_PATH))
CXX_OPTFLAGS ?= $(VL_OPTFLAGS)
ifeq ($(DEBUG),1)
CXX_OPTFLAGS := -O0 -g
endif
CXXFLAGS += $(INCFLAGS) -I$(abspath ./include) -I$(abspath ./csrc/include) -DTOP_NAME="\"V$(TOPNAME)\"" -std=c++17 $(CXX_OPTFLAGS)
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

$(BIN): $(VSRCS) $(CSRCS) $(NVBOARD_ARCHIVE)
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
	@$^ $(NPC_EXE)

gdb: $(BIN)
	$(call git_commit, "debug RTL") # DO NOT REMOVE THIS LINE!!!
	gdb -s $(BIN) --args $(BIN) $(NPC_EXE)

.PHONY: profile-report profile-parse profile-task profile-baseline linux-smoke bench

PROFILE_TOOL_DIR := $(abspath ./tools/profiler)
PROFILE_OUT_DIR ?=
PROFILE_PARSE_DIR ?= $(if $(strip $(PROFILE_OUT_DIR)),$(PROFILE_OUT_DIR),$(abspath ./build/profile/latest))
PROFILE_TAG ?= latest
PROFILE_TAG_DIR ?= $(abspath ./build/profile/$(PROFILE_TAG))

profile-report:
	@if [ -n "$(PROFILE_OUT_DIR)" ]; then \
		OUT_DIR=$(PROFILE_OUT_DIR) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) \
			$(PROFILE_TOOL_DIR)/run_profile.sh; \
	else \
		ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) \
			$(PROFILE_TOOL_DIR)/run_profile.sh; \
	fi

profile-parse:
	python3 $(PROFILE_TOOL_DIR)/parse_profile.py \
		--log-dir $(PROFILE_PARSE_DIR) \
		--template $(PROFILE_TOOL_DIR)/report_template.md \
		--out-json $(PROFILE_PARSE_DIR)/summary.json \
		--out-md $(PROFILE_PARSE_DIR)/report.md

profile-task:
	$(MAKE) profile-report ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) \
		PROFILE_OUT_DIR=$(PROFILE_TAG_DIR)
	$(MAKE) profile-parse PROFILE_PARSE_DIR=$(PROFILE_TAG_DIR)

profile-baseline:
	$(MAKE) profile-task ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) PROFILE_TAG=baseline

linux-smoke:
	$(abspath ./scripts/run_linux_smoke.sh)

BENCH_IMG ?= $(IMG)
BENCH_ARGS ?= --max-cycles=10000000 --progress=0
bench: $(BIN)
	@if [ -z "$(BENCH_IMG)" ]; then echo "[bench] BENCH_IMG or IMG is required"; exit 1; fi
	@echo "[bench] start"; \
	start=$$(date +%s); \
	$(BIN) $(BENCH_ARGS) $(DIFFTEST) $(BENCH_IMG); \
	end=$$(date +%s); \
	echo "[bench] elapsed=$$((end - start))s"

clean:
	rm -rf $(BUILD_DIR)
