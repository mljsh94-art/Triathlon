# Triathlon Spike difftest reference library (Phase 0)
#
# Outputs:
#   riscv32-spike-difftest.so  - Spike rv32imac MSU lockstep reference
#   test_spike_ref             - standalone smoke test (dlopen + single-step)

NPC_HOME    := $(abspath ..)
SPIKE_DIR   := $(abspath src/repo/riscv-isa-sim)
SPIKE_BUILD := $(SPIKE_DIR)/build
SPIKE_DIFF  := spike-diff
ARCH_INC    := $(NPC_HOME)/csrc/include
TARGET_SO   := riscv32-spike-difftest.so
SMOKE_BIN   := test_spike_ref
DEMO_BIN    := test_mismatch_dump

CXX         ?= g++
CXXFLAGS    ?= -std=c++17 -O2 -fPIC -Wall -Wextra
LDFLAGS     ?= -shared -Wl,-soname,$(TARGET_SO)

SPIKE_LIBS  := -lriscv -Wl,--whole-archive -lsoftfloat -Wl,--no-whole-archive \
               -lfesvr -lfdt -ldisasm -lpthread
SPIKE_INCS  := -I$(SPIKE_BUILD) -I$(SPIKE_DIR) -I$(SPIKE_DIR)/riscv \
               -I$(SPIKE_DIR)/fesvr -I$(SPIKE_DIR)/disasm \
               -I$(SPIKE_DIR)/softfloat -I$(ARCH_INC)
SPIKE_LDPATH := -L$(SPIKE_BUILD)

.PHONY: all spike spike-diff smoke check demo-mismatch clean

all: $(TARGET_SO) smoke

spike:
	@if [ ! -f "$(SPIKE_BUILD)/Makefile" ]; then \
		echo "[ref] configure spike in $(SPIKE_BUILD)"; \
		mkdir -p "$(SPIKE_BUILD)"; \
		cd "$(SPIKE_BUILD)" && "$(SPIKE_DIR)/configure" --prefix="$(SPIKE_BUILD)/install"; \
	fi
	$(MAKE) -C "$(SPIKE_BUILD)" -j$$(nproc)

$(TARGET_SO): $(SPIKE_DIFF)/difftest.cc spike
	$(CXX) $(CXXFLAGS) $(SPIKE_INCS) $(LDFLAGS) -o $@ \
		$(SPIKE_DIFF)/difftest.cc $(SPIKE_BUILD)/softfloat_state.o \
		$(SPIKE_LDPATH) $(SPIKE_LIBS)
	strip --strip-unneeded $@

smoke: $(SMOKE_BIN)

$(SMOKE_BIN): test_spike_ref.cpp $(TARGET_SO)
	$(CXX) $(CXXFLAGS) -I$(ARCH_INC) -o $@ test_spike_ref.cpp -ldl

check: smoke
	LD_LIBRARY_PATH="$(abspath .):$(SPIKE_BUILD):$$LD_LIBRARY_PATH" \
		./$(SMOKE_BIN) ./$(TARGET_SO)

$(DEMO_BIN): test_mismatch_dump.cpp $(TARGET_SO) ../csrc/lib/difftest_client.cpp
	$(CXX) $(CXXFLAGS) -I$(ARCH_INC) -o $@ test_mismatch_dump.cpp \
		../csrc/lib/difftest_client.cpp -ldl

demo-mismatch: $(DEMO_BIN)
	LD_LIBRARY_PATH="$(abspath .):$(SPIKE_BUILD):$$LD_LIBRARY_PATH" \
		./$(DEMO_BIN) ./$(TARGET_SO)

clean:
	rm -f $(TARGET_SO) $(SMOKE_BIN) $(DEMO_BIN)
